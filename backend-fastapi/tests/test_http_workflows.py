"""Run the same HTTP acceptance scenarios without a database server."""
import pytest
from fastapi.testclient import TestClient
from app.main import create_app
from app.security import hash_password
from fakes import MemoryFactory
from test_marketplace import (
    test_declaration_and_malformed_stage_inputs,
    test_two_distinct_customer_fraud_reports_block_even_high_rating,
    test_public_registration_cannot_create_staff_and_wrong_code_is_rejected,
    SECRET,test_registration_jwt_duration_and_guest_boundaries,
    test_full_trip_document_gate_review_notifications_and_rebuild,
    test_customer_ownership_driver_assignment_and_private_documents,
    test_company_invitation_employee_price_redaction_and_company_block,
    test_admin_moderator_and_revoked_blocked_sessions,
    test_low_rating_automatically_blocks_carrier,
    test_concurrent_customer_approvals_pick_only_one_driver,
)


@pytest.fixture
def client(monkeypatch):
    factory=MemoryFactory()
    factory.transaction=factory
    from app.services import auth_service, transport_order_service, document_service
    from app.api.controllers import transport_order_controller, auth_controller, user_controller, document_controller, fleet_controller, admin_controller
    for module in (auth_service, transport_order_service, transport_order_controller, user_controller, document_controller, fleet_controller, admin_controller):
        monkeypatch.setattr(module, 'UserRepository', lambda connection: connection.users)
        monkeypatch.setattr(module, 'TransportOrderRepository', lambda connection: connection.transport_order)
        monkeypatch.setattr(module, 'DocumentRepository', lambda connection: connection.documents)
    with factory() as uow:
        uow.users.create({'username':'admin','password_hash':hash_password('123456'),'role':'ADMIN','name':'Administrator','status':'ACTIVE','verification':'APPROVED','bootstrap_admin':True,'phone_verified':True})
    with TestClient(create_app(settings={'JWT_SECRET':SECRET,'MOCK_SMS':'true'},database_override=factory)) as client:yield client
