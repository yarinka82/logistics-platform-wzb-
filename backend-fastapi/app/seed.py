from uuid import uuid4, UUID
import datetime

def run_seeder(database, hash_password, transport_order_service):
    with database.connect() as conn:
        conn.execute('SELECT pg_advisory_xact_lock(487313)')
        existing = conn.execute("SELECT COUNT(*) as c FROM app_user WHERE username LIKE 'customer%'").fetchone()
        if existing['c'] > 0:
            return # Already seeded

        # 1. Create Users
        users = {}
        for i in range(1, 4):
            u_id = uuid4()
            conn.execute('''INSERT INTO app_user(id,username,password_hash,role,name,status,verification,phone_verified)
                VALUES(%s,%s,%s,'CUSTOMER',%s,'ACTIVE','APPROVED',TRUE)''',
                (u_id, f'customer{i}', hash_password('123456'), f'Customer {i}'))
            users[f'customer{i}'] = {'id': str(u_id), 'role': 'CUSTOMER', 'token_version': 0}
            
        for i in range(1, 4):
            u_id = uuid4()
            conn.execute('''INSERT INTO app_user(id,username,password_hash,role,name,status,verification,phone_verified,declaration_accepted,vehicle_plate,vehicle_type)
                VALUES(%s,%s,%s,'DRIVER',%s,'ACTIVE','APPROVED',TRUE,TRUE,'WÜ-AB 123','Sprinter')''',
                (u_id, f'courier{i}', hash_password('123456'), f'Courier {i}'))
            users[f'courier{i}'] = {'id': str(u_id), 'role': 'DRIVER', 'token_version': 0, 'verification': 'APPROVED'}
            
    # 2. Create Orders using the Service
    svc = transport_order_service
    
    def pub(customer_key, cargo, hours_offset=0):
        return svc.publish(users[customer_key], {
            'origin': 'Würzburg Hbf', 'destination': 'Frankfurt Airport', 'city': 'Würzburg',
            'cargo': cargo, 'cargo_type': 'General freight', 'price': 150.0 + len(cargo)*2,
            'loading_at': (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=hours_offset)).isoformat()
        }, uuid4())
        
    try:
        # 15 PUBLISHED orders
        pub_cargoes = [
            "Solar panels", "Lighting fixtures", "Bicycles", "Fitness equipment", "Toys and games",
            "Packaging materials", "Printed marketing materials", "Cosmetics and beauty products", 
            "Beverages (Wine)", "Coffee beans", "Restaurant equipment", "Ceramic tiles",
            "Hardware tools", "Safety gear", "Auto accessories"
        ]
        for i, cargo in enumerate(pub_cargoes):
            pub(f'customer{(i%3)+1}', cargo, hours_offset=24+i)

        # 10 ASSIGNED orders
        fake_img = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        
        def progress_order(customer_key, courier_key, cargo, target_state, hours_offset):
            o = pub(customer_key, cargo, hours_offset)
            o = svc.execute(users[courier_key], UUID(o['id']), 'take', {'declaration_accepted': True}, o['version'], uuid4())
            if target_state == 'ASSIGNED': return
            
            o = svc.execute(users[courier_key], UUID(o['id']), 'depart', {'coordinates': {'latitude': 49.7, 'longitude': 9.9}}, o['version'], uuid4())
            if target_state == 'IN_TRANSIT': return
            
            o = svc.execute(users[courier_key], UUID(o['id']), 'arrive', {'coordinates': {'latitude': 50.1, 'longitude': 8.5}}, o['version'], uuid4())
            if target_state == 'ARRIVED': return
            
            o = svc.execute(users[courier_key], UUID(o['id']), 'document', {'photo': fake_img}, o['version'], uuid4())
            o = svc.execute(users[courier_key], UUID(o['id']), 'complete', {'coordinates': {'latitude': 50.1, 'longitude': 8.5}}, o['version'], uuid4())

        # Customer 1 (5 orders)
        progress_order('customer1', 'courier1', 'Pallet of books', 'ASSIGNED', -2)
        progress_order('customer1', 'courier2', 'Construction materials', 'IN_TRANSIT', -4)
        progress_order('customer1', 'courier3', 'Office furniture', 'ARRIVED', -10)
        progress_order('customer1', 'courier1', 'Electronics', 'DELIVERED', -24)
        progress_order('customer1', 'courier2', 'Medical supplies', 'ASSIGNED', 2)

        # Customer 2 (3 orders)
        progress_order('customer2', 'courier3', 'Car parts', 'IN_TRANSIT', -5)
        progress_order('customer2', 'courier1', 'Event equipment', 'ARRIVED', -8)
        progress_order('customer2', 'courier2', 'Frozen food', 'DELIVERED', -48)

        # Customer 3 (2 orders)
        progress_order('customer3', 'courier3', 'Textiles', 'IN_TRANSIT', -6)
        progress_order('customer3', 'courier1', 'Agricultural machinery parts', 'DELIVERED', -72)
        
    except Exception as e:
        import traceback
        traceback.print_exc()
