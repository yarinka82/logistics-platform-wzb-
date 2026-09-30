from uuid import uuid4
from app.domain.errors import NotFound

class DocumentRepository:

    def __init__(self, connection):
        self.connection = connection

    def create(self, user_id, purpose, mime_type, data, order_id=None):
        raise NotImplementedError()

    def get(self, doc_id):
        raise NotImplementedError()

    def list(self, user_id):
        raise NotImplementedError()