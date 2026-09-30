from uuid import UUID, uuid4
from copy import deepcopy
from app.domain.shipment.shipment import Shipment
from app.domain.identity.user import User
from app.domain.errors import Conflict, DomainError, DuplicateWrite, Forbidden
from app.repositories.user_repository import UserRepository
from app.repositories.transport_order_repository import TransportOrderRepository
from app.repositories.document_repository import DocumentRepository
from .auth_service import image_bytes
STAFF = {'ADMIN', 'MODERATOR'}

class TransportOrderService:

    def __init__(self, database, rating_threshold=3.2):
        self.database = database
        self.rating_threshold = rating_threshold

    def _get_active_actor(self, user_dict: dict, connection) -> dict:
        raise NotImplementedError()

    @staticmethod
    def _is_related(state: dict, user_dict: dict) -> bool:
        raise NotImplementedError()

    def view(self, row, user_dict, connection, detail=False):
        raise NotImplementedError()

    def list(self, user_dict, scope, city, cargo_type):
        raise NotImplementedError()

    def detail(self, order_id, user_dict):
        raise NotImplementedError()

    def publish(self, user_dict, data, command_id):
        raise NotImplementedError()

    def execute(self, user_dict, order_id, action, data, expected_version, command_id):
        raise NotImplementedError()

    def _handle_take(self, aggregate: Shipment, actor: dict, data: dict, connection):
        raise NotImplementedError()

    def _handle_document(self, aggregate: Shipment, actor: dict, data: dict, order_id, connection):
        raise NotImplementedError()

    def _dispatch_notifications(self, action: str, aggregate: Shipment, event_type: str, payload: dict, connection):
        raise NotImplementedError()

    def _process_review(self, aggregate: Shipment, payload: dict, actor: dict, order_id, connection):
        raise NotImplementedError()