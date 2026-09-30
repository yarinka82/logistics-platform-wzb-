from app.repositories.user_repository import UserRepository
from app.repositories.transport_order_repository import TransportOrderRepository
from app.repositories.document_repository import DocumentRepository
'Document access control and retrieval.'
from app.domain.errors import Forbidden
STAFF = {'ADMIN', 'MODERATOR'}

class DocumentService:

    def __init__(self, database):
        self.database = database

    @staticmethod
    def _related(state, user):
        raise NotImplementedError()

    def get_document(self, user, doc_id):
        raise NotImplementedError()