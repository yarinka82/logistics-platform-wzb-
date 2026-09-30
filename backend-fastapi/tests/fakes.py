"""Transactional in-memory repository doubles. Production always uses PostgreSQL."""
from copy import deepcopy
from datetime import datetime,timezone
from threading import RLock
from uuid import UUID,uuid4
from app.domain.errors import NotFound,DuplicateWrite


def now():return datetime.now(timezone.utc)

def key(value):return str(value)


class MemoryUsers:
    def __init__(self,state):self.state=state
    def get(self,id,lock=False):
        if key(id) not in self.state['users']:raise NotFound('User not found')
        return deepcopy(self.state['users'][key(id)])
    def by_username(self,name):return next((deepcopy(u) for u in self.state['users'].values() if u['username']==name.lower()),None)
    def create(self,data):
        if self.by_username(data['username']):raise DuplicateWrite()
        user={'id':uuid4(),'email':'','phone':'','city':'Würzburg','company_id':None,'vehicle_plate':'','vehicle_type':'','tax_id':'','contact_name':'','fleet_size':0,'status':'PENDING','verification':'PENDING','terms_accepted':False,'declaration_accepted':False,'declaration_at':None,'phone_verified':False,'token_version':0,'must_change_password':False,'bootstrap_admin':False,'rating':None,'block_reason':None,'created_at':now(),**data}
        user={k:v for k,v in user.items() if k not in {'password','document'}}
        self.state['users'][key(user['id'])]=user
        return deepcopy(user)
    def update(self,id,**changes):
        self.state['users'][key(id)].update(changes);return self.get(id)
    def list(self,company_id=None):return [deepcopy(u) for u in self.state['users'].values() if not company_id or u['company_id']==company_id]
    def notify(self,user_id,shipment_id,message):self.state['notifications'].append({'id':uuid4(),'user_id':user_id,'shipment_id':shipment_id,'message':message,'read':False,'created_at':now()})
    def notifications(self,user_id):return [deepcopy(n) for n in self.state['notifications'] if n['user_id']==user_id]
    def read_notifications(self,user_id):
        for note in self.state['notifications']:
            if note['user_id']==user_id:note['read']=True
    def add_review(self,order_id,customer_id,carrier_id,driver_id,rating,fraud,note):
        if any(r['shipment_id']==order_id for r in self.state['reviews']):raise DuplicateWrite()
        self.state['reviews'].insert(0,{'shipment_id':order_id,'customer_id':customer_id,'carrier_id':carrier_id,'driver_id':driver_id,'rating':rating,'fraud':fraud,'note':note,'created_at':now()})
    def reviews(self,user_id):return [deepcopy(r) for r in self.state['reviews'] if user_id in {r['carrier_id'],r['driver_id']}]
    def rate_limit(self,name,maximum):
        self.state['rates'][name]=self.state['rates'].get(name,0)+1;return self.state['rates'][name]<=maximum


class MemoryTransportOrder:
    def __init__(self,state):self.state=state
    def create(self,id):self.state['events'][key(id)]=[]
    def lock(self,id):
        if key(id) not in self.state['events']:raise NotFound('Order not found')
    def events(self,id):self.lock(id);return deepcopy(self.state['events'][key(id)])
    def existing(self,command_id):return next((deepcopy(e) for events in self.state['events'].values() for e in events if e['command_id']==command_id),None)
    def append(self,order_id,version,kind,payload,user_id,command_id,command_data):
        if self.existing(command_id):raise DuplicateWrite()
        event={'event_id':uuid4(),'shipment_id':order_id,'version':version,'event_type':kind,'payload':deepcopy(payload),'actor':str(user_id),'command_id':command_id,'command_data':deepcopy(command_data),'occurred_at':now(),'schema_version':1}
        self.state['events'][key(order_id)].append(event);return deepcopy(event)
    def project(self,order_id,aggregate,created_at):self.state['projections'][key(order_id)]={'shipment_id':order_id,'last_event_version':aggregate.version,'created_at':created_at,'state':deepcopy(aggregate.state)}
    def get(self,id):
        if key(id) not in self.state['projections']:raise NotFound('Order not found')
        return deepcopy(self.state['projections'][key(id)])
    def list(self):return list(deepcopy(self.state['projections']).values())
    def all_ids(self):return [UUID(id) for id in self.state['events']]


class MemoryDocuments:
    def __init__(self,state):self.state=state
    def create(self,user_id,purpose,mime_type,data,order_id=None):
        id=uuid4();self.state['documents'][key(id)]={'id':id,'owner_id':user_id,'purpose':purpose,'mime_type':mime_type,'data':data,'shipment_id':order_id,'created_at':now()};return id
    def get(self,id):
        if key(id) not in self.state['documents']:raise NotFound('Document not found')
        return deepcopy(self.state['documents'][key(id)])
    def list(self,user_id):return [{k:d[k] for k in ['id','purpose','created_at']} for d in reversed(list(self.state['documents'].values())) if d['owner_id']==user_id and not d['shipment_id']]


class MemoryUnitOfWork:
    def __init__(self,factory):self.factory=factory
    def __enter__(self):
        self.factory.lock.acquire();self.snapshot=deepcopy(self.factory.state)
        self.users=MemoryUsers(self.factory.state);self.transport_order=MemoryTransportOrder(self.factory.state);self.documents=MemoryDocuments(self.factory.state)
        return self
    def __exit__(self,typ,value,tb):
        if typ:self.factory.state.clear();self.factory.state.update(self.snapshot)
        self.factory.lock.release()
    def ping(self):pass


class MemoryFactory:
    def __init__(self):self.state={'users':{},'events':{},'projections':{},'documents':{},'notifications':[],'reviews':[],'rates':{}};self.lock=RLock()
    def __call__(self,read_only=False):return MemoryUnitOfWork(self)
