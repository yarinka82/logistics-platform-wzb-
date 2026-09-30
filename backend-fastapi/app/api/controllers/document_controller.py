from app.repositories.user_repository import UserRepository
from app.repositories.transport_order_repository import TransportOrderRepository
from app.repositories.document_repository import DocumentRepository
'HTTP controller for serving private documents and photos.'
from uuid import UUID
from fastapi import APIRouter, Depends, Request, Response
from .auth_controller import current_user

class DocumentController:

    def __init__(self):
        self.router = APIRouter(prefix='/api', tags=['Documents'])
        self.router.add_api_route('/documents/{document_id}', self.document, methods=['GET'])

    def document(self, document_id: UUID, request: Request, user=Depends(current_user)):
        raise NotImplementedError()