from app.repositories.user_repository import UserRepository
from app.repositories.transport_order_repository import TransportOrderRepository
from app.repositories.document_repository import DocumentRepository
'HTTP controller for freight order listing, publishing and trip commands.'
from typing import Literal
from uuid import UUID
from fastapi import APIRouter, Depends, Request, Response
from app.api.dto.transport_order_dto import OrderInput, Command
from .auth_controller import optional_user, current_user

class TransportOrderController:

    def __init__(self):
        self.router = APIRouter(prefix='/api', tags=['Transport orders'])
        self.router.add_api_route('/orders', self.list, methods=['GET'])
        self.router.add_api_route('/orders', self.publish, methods=['POST'], status_code=201)
        self.router.add_api_route('/orders/{order_id}', self.detail, methods=['GET'])
        self.router.add_api_route('/orders/{order_id}/commands/{action}', self.command, methods=['POST'])

    def list(self, request: Request, scope: Literal['market', 'mine']='market', city: str='', cargo_type: str='', user=Depends(optional_user)):
        raise NotImplementedError()

    def detail(self, order_id: UUID, request: Request, user=Depends(optional_user)):
        raise NotImplementedError()

    def publish(self, body: OrderInput, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def command(self, order_id: UUID, action: Literal['take', 'depart', 'arrive', 'document', 'complete', 'review'], body: Command, request: Request, user=Depends(current_user)):
        raise NotImplementedError()