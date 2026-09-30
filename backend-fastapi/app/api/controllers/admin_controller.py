from app.repositories.user_repository import UserRepository
'HTTP controller for platform administration and user management.'
from uuid import UUID
from fastapi import APIRouter, Depends, Request
from app.domain.errors import Forbidden
from app.services.auth_service import safe_user
from app.api.dto.admin_dto import ManagedUser, Block
from .auth_controller import current_user

class AdminController:

    def __init__(self):
        self.router = APIRouter(prefix='/api', tags=['Administration'])
        self.router.add_api_route('/admin/users', self.users, methods=['GET'])
        self.router.add_api_route('/admin/users', self.create, methods=['POST'])
        self.router.add_api_route('/admin/users/{user_id}/status', self.block, methods=['POST'])
        self.router.add_api_route('/projections/rebuild', self.rebuild, methods=['POST'])

    def users(self, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def create(self, body: ManagedUser, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def block(self, user_id: UUID, body: Block, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def rebuild(self, request: Request, user=Depends(current_user)):
        raise NotImplementedError()