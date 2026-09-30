from app.repositories.user_repository import UserRepository
'HTTP controller for company fleet and employee driver management.'
from fastapi import APIRouter, Depends, Request
from app.domain.errors import Forbidden
from app.services.auth_service import safe_user
from app.api.dto.admin_dto import ManagedUser
from .auth_controller import current_user

class FleetController:

    def __init__(self):
        self.router = APIRouter(prefix='/api', tags=['Fleet management'])
        self.router.add_api_route('/fleet', self.fleet, methods=['GET'])
        self.router.add_api_route('/fleet', self.invite, methods=['POST'])

    def fleet(self, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def invite(self, body: ManagedUser, request: Request, user=Depends(current_user)):
        raise NotImplementedError()