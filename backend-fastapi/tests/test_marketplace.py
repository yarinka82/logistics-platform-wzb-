"""Real PostgreSQL tests for identity, permissions, event transactions and marketplace workflows."""
import os
from uuid import uuid4,UUID
from concurrent.futures import ThreadPoolExecutor

import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg.conninfo import make_conninfo

from app.main import create_app
from app.security import TokenCodec,TOKEN_LIFETIME
from app.domain.errors import Conflict,Unauthorized

SECRET='test-secret-with-more-than-thirty-two-characters'
PHOTO='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0TsAAAAASUVORK5CYII='
LOCATION={'latitude':49.7913,'longitude':9.9534}


@pytest.fixture
def database_url():
    url=os.environ.get('TEST_DATABASE_URL')
    if not url: pytest.skip('Set TEST_DATABASE_URL for PostgreSQL integration tests')
    schema='market_test_'+uuid4().hex
    with psycopg.connect(url) as conn: conn.execute(f'CREATE SCHEMA "{schema}"')
    try: yield make_conninfo(url,options=f'-c search_path={schema}')
    finally:
        with psycopg.connect(url) as conn: conn.execute(f'DROP SCHEMA "{schema}" CASCADE')


@pytest.fixture
def client(database_url):
    settings={'JWT_SECRET':SECRET,'ADMIN_USERNAME':'admin','ADMIN_PASSWORD':'123456','MOCK_SMS':'true'}
    with TestClient(create_app(database_url,settings)) as client: yield client


def register(client,role,name):
    response=client.post('/api/auth/register',json={
        'username':name,'password':'password123','role':role,'name':name.title(),'phone':'+491234567890','city':'Würzburg',
        'terms_accepted':True,'declaration_accepted':role!='CUSTOMER','tax_id':'DE12345' if role!='CUSTOMER' else '',
        'vehicle_plate':'WZ-123','vehicle_type':'Sprinter 3.5t','document':PHOTO if role!='CUSTOMER' else None,
    })
    assert response.status_code==200,response.text
    result=client.post('/api/auth/verify',json={'verification_token':response.json()['verification_token'],'code':'0000'})
    assert result.status_code==200,result.text
    return result.json()['user']


def login(client,name,password='password123'):
    response=client.post('/api/auth/login',json={'username':name,'password':password})
    assert response.status_code==200,response.text
    return response


def publish(client):
    response=client.post('/api/orders',json={'origin':'Würzburg 97070','destination':'Frankfurt 60311','city':'Würzburg',
        'cargo':'Two pallets','cargo_type':'Pallets','price':250,'loading_at':'2026-10-02T10:00:00Z','command_id':str(uuid4())})
    assert response.status_code==201,response.text
    return response.json()


def command(client,order_id,action,data=None,version=None,command_id=None):
    if action=='take': data={'declaration_accepted':True,**(data or {})}
    if version is None: version=client.get('/api/orders/'+order_id).json()['version']
    return client.post(f'/api/orders/{order_id}/commands/{action}',json={'command_id':str(command_id or uuid4()),'expected_version':version,'data':data or {}})


def accepted_trip(client):
    customer=register(client,'CUSTOMER','alice')
    order=publish(client)
    driver=register(client,'DRIVER','driver1')
    assert command(client,order['id'],'take').status_code==200
    login(client,'alice')
    
    
    login(client,'driver1')
    return customer,driver,order


def complete(client,order):
    for action in ['depart','arrive']:
        result=command(client,order['id'],action,{'coordinates':LOCATION})
        assert result.status_code==200,result.text
    assert command(client,order['id'],'document',{'photo':PHOTO}).status_code==200
    result=command(client,order['id'],'complete',{'coordinates':LOCATION,'confirmed':True})
    assert result.status_code==200,result.text


def test_registration_jwt_duration_and_guest_boundaries(client):
    register(client,'CUSTOMER','alice')
    order=publish(client)
    token=client.cookies.get('wzb_session')
    claims=TokenCodec(SECRET).decode(token)
    assert claims['exp']-claims['iat']==TOKEN_LIFETIME==2592000
    with pytest.raises(Unauthorized): TokenCodec(SECRET).decode(token[:-3]+'abc')
    assert client.post('/api/auth/logout').status_code==200
    guest=client.get('/api/orders').json()[0]
    assert 'price' not in guest and 'customer_id' not in guest
    assert client.post('/api/orders',json={}).status_code==401
    assert client.get('/api/admin/users').status_code==401
    assert client.get('/api/orders/'+order['id']).json().get('contacts') is None
    client.cookies.set('wzb_session',token)
    assert client.get('/api/me').status_code==401


def test_full_trip_document_gate_review_notifications_and_rebuild(client):
    customer,driver,order=accepted_trip(client)
    assert command(client,order['id'],'depart',{'coordinates':LOCATION}).status_code==200
    assert command(client,order['id'],'arrive',{'coordinates':LOCATION}).status_code==200
    before=client.get('/api/orders/'+order['id']).json()['version']
    assert command(client,order['id'],'complete',{'coordinates':LOCATION,'confirmed':True}).status_code==409
    assert client.get('/api/orders/'+order['id']).json()['version']==before
    cmd=uuid4()
    uploaded=command(client,order['id'],'document',{'photo':PHOTO},command_id=cmd)
    assert uploaded.status_code==200,uploaded.text
    repeated=command(client,order['id'],'document',{'photo':PHOTO},version=before,command_id=cmd)
    assert repeated.status_code==200,repeated.text
    doc=uploaded.json()['documents'][0]
    assert command(client,order['id'],'complete',{'coordinates':LOCATION,'confirmed':True}).status_code==200
    login(client,'alice')
    assert client.get('/api/documents/'+doc).status_code==200
    assert client.get('/api/notifications').json()
    assert command(client,order['id'],'review',{'rating':5,'fraud':False}).status_code==200
    original=client.get('/api/orders/'+order['id']).json()
    login(client,'admin','123456')
    assert client.post('/api/projections/rebuild').json()['rebuilt']==1
    login(client,'alice')
    assert client.get('/api/orders/'+order['id']).json()==original


def test_customer_ownership_driver_assignment_and_private_documents(client):
    _,_,order=accepted_trip(client)
    complete(client,order)
    doc=client.get('/api/orders/'+order['id']).json()['documents'][0]
    register(client,'CUSTOMER','outsider')
    assert client.get('/api/orders/'+order['id']).status_code==403
    assert client.get('/api/documents/'+doc).status_code==403
    assert command(client,order['id'],'approve',{'offer_id':str(uuid4())},version=8).status_code==403
    register(client,'DRIVER','otherdriver')
    assert command(client,order['id'],'depart',{'coordinates':LOCATION},version=8).status_code in {403,409}
    assert client.get('/api/admin/users').status_code==403
    assert client.post('/api/projections/rebuild').status_code==403


def test_company_invitation_employee_price_redaction_and_company_block(client):
    customer=register(client,'CUSTOMER','customer')
    order=publish(client)
    company=register(client,'COMPANY','company')
    invitation=client.post('/api/fleet',json={'username':'employee','password':'temporary123','role':'EMPLOYEE','name':'Employee One','phone':'+4911111111','vehicle_plate':'WZ-EMP','vehicle_type':'Truck'})
    assert invitation.status_code==200,invitation.text
    token=invitation.json()['invitation']['verification_token']
    employee=client.post('/api/auth/verify',json={'verification_token':token,'code':'0000'}).json()['user']
    changed=client.post('/api/me/password',json={'old_password':'temporary123','new_password':'password123'})
    assert changed.status_code==200
    assert client.get('/api/orders').status_code==403
    login(client,'company')
    assert command(client,order['id'],'take',{'driver_id':employee['id']}).status_code==200
    login(client,'customer')
    
    
    login(client,'employee')
    mine=client.get('/api/orders?scope=mine').json()
    assert len(mine)==1 and 'price' not in mine[0]
    detail=client.get('/api/orders/'+order['id']).json()
    assert 'price' not in detail and 'price' not in str(detail.get('timeline',[]))
    employee_token=client.cookies.get('wzb_session')
    login(client,'admin','123456')
    assert client.post('/api/admin/users/'+company['id']+'/status',json={'blocked':True}).status_code==200
    client.cookies.set('wzb_session',employee_token)
    assert client.get('/api/me').status_code==403


def test_admin_moderator_and_revoked_blocked_sessions(client):
    driver=register(client,'DRIVER','driver')
    driver_token=client.cookies.get('wzb_session')
    admin=login(client,'admin','123456').json()['user']
    created=client.post('/api/admin/users',json={'username':'moderator','password':'temporary123','role':'MODERATOR','name':'Moderator','phone':'+49111111'})
    assert created.status_code==200
    login(client,'moderator','temporary123')
    client.post('/api/me/password',json={'old_password':'temporary123','new_password':'password123'})
    assert client.get('/api/admin/users').status_code==200
    assert client.post('/api/admin/users',json={'username':'hacker','password':'password123','role':'ADMIN','name':'Bad actor','phone':'+49111111'}).status_code==403
    assert client.post('/api/admin/users/'+admin['id']+'/status',json={'blocked':True}).status_code==403
    assert client.post('/api/admin/users/'+driver['id']+'/status',json={'blocked':True}).status_code==200
    client.cookies.set('wzb_session',driver_token)
    assert client.get('/api/me').status_code in {401,403}


def test_low_rating_automatically_blocks_carrier(client):
    _,driver,order=accepted_trip(client)
    complete(client,order)
    login(client,'alice')
    assert command(client,order['id'],'review',{'rating':2,'fraud':False}).status_code==200
    response=client.post('/api/auth/login',json={'username':'driver1','password':'password123'})
    assert response.status_code==403
    login(client,'admin','123456')
    account=next(u for u in client.get('/api/admin/users').json() if u['id']==driver['id'])
    assert account['status']=='BLOCKED' and account['rating']==2


def test_concurrent_customer_approvals_pick_only_one_driver(client):
    customer=register(client,'CUSTOMER','customer')
    order=publish(client)
    for name in ['firstdriver','seconddriver']:
        register(client,'DRIVER',name)
        assert command(client,order['id'],'take').status_code==200
    login(client,'customer')
    detail=client.get('/api/orders/'+order['id']).json()
    auth=client.app.state.auth
    actor=auth.authenticate(client.cookies.get('wzb_session'))
    service=client.app.state.transport_order
    def approve(offer):
        try:
            service.execute(actor,UUID(order['id']),'approve',{'offer_id':offer['id']},detail['version'],uuid4())
            return 'ok'
        except Conflict:return 'conflict'
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(approve,detail['offers']))==['conflict','ok']
    final=client.get('/api/orders/'+order['id']).json()
    assert final['status']=='AWAITING_DEPARTURE'
    assert sorted(o['status'] for o in final['offers'])==['APPROVED','REJECTED']


def test_rollback_projection_failure_and_event_immutability(client,database_url,monkeypatch):
    from app.repositories.transport_order_repository import MarketRepository
    register(client,'CUSTOMER','alice')
    order=publish(client)
    register(client,'DRIVER','driver')
    actor=client.app.state.auth.authenticate(client.cookies.get('wzb_session'))
    def fail(*args):raise RuntimeError('Simulated projector failure')
    monkeypatch.setattr(MarketRepository,'project',fail)
    with pytest.raises(RuntimeError): client.app.state.transport_order.execute(actor,UUID(order['id']),'take',{'declaration_accepted':True},1,uuid4())
    with psycopg.connect(database_url) as conn:
        assert conn.execute('SELECT count(*) FROM shipment_event WHERE shipment_id=%s',(order['id'],)).fetchone()[0]==1
    with pytest.raises(psycopg.errors.RaiseException):
        with psycopg.connect(database_url) as conn:conn.execute('DELETE FROM shipment_event WHERE shipment_id=%s',(order['id'],))


def test_declaration_and_malformed_stage_inputs(client):
    register(client,'CUSTOMER','customer')
    order=publish(client)
    register(client,'DRIVER','driver')
    rejected=command(client,order['id'],'take',{'declaration_accepted':False})
    assert rejected.status_code==409
    assert client.get('/api/orders/'+order['id']).json()['version']==1
    assert command(client,order['id'],'take').status_code==200
    login(client,'customer')
    
    
    login(client,'driver')
    for coordinates in ['invalid',[],{'latitude':True,'longitude':9},{'latitude':91,'longitude':9}]:
        assert command(client,order['id'],'depart',{'coordinates':coordinates}).status_code==409
    assert client.get('/api/orders/'+order['id']).json()['status']=='AWAITING_DEPARTURE'


def test_two_distinct_customer_fraud_reports_block_even_high_rating(client):
    register(client,'DRIVER','driver')
    for name in ['customerone','customertwo']:
        register(client,'CUSTOMER',name)
        order=publish(client)
        login(client,'driver')
        assert command(client,order['id'],'take').status_code==200
        login(client,name)
        
        
        login(client,'driver')
        complete(client,order)
        login(client,name)
        assert command(client,order['id'],'review',{'rating':5,'fraud':True}).status_code==200
    assert client.post('/api/auth/login',json={'username':'driver','password':'password123'}).status_code==403


def test_public_registration_cannot_create_staff_and_wrong_code_is_rejected(client):
    payload={'username':'intruder','password':'password123','role':'ADMIN','name':'Intruder','phone':'+491234567','terms_accepted':True}
    assert client.post('/api/auth/register',json=payload).status_code in {403,422}
    payload['role']='CUSTOMER'
    result=client.post('/api/auth/register',json=payload)
    token=result.json()['verification_token']
    assert client.post('/api/auth/verify',json={'verification_token':token,'code':'1234'}).status_code==401
    assert client.post('/api/auth/verify',json={'verification_token':token,'code':'0000'}).status_code==200
    assert client.post('/api/auth/verify',json={'verification_token':token,'code':'0000'}).status_code==401
