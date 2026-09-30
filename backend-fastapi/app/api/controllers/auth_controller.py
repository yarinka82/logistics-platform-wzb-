from app.repositories.user_repository import UserRepository
from app.repositories.document_repository import DocumentRepository
'HTTP controller for registration, login, logout and phone activation.'
from fastapi import APIRouter, Depends, Request, Response
from app.domain.errors import Unauthorized
from app.services.auth_service import safe_user, image_bytes
from app.api.dto.auth_dto import Registration, Login, Activation

def optional_user(request: Request):
    raise NotImplementedError()

def current_user(user=Depends(optional_user)):
    raise NotImplementedError()

def cookie(response, request, token):
    raise NotImplementedError()

class AuthController:

    def __init__(self):
        self.router = APIRouter(prefix='/api', tags=['Authentication'])
        for path, method, handler in [('/auth/register', 'POST', self.register), ('/auth/verify', 'POST', self.verify), ('/auth/login', 'POST', self.login), ('/auth/logout', 'POST', self.logout)]:
            self.router.add_api_route(path, handler, methods=[method])

    def register(self, body: Registration, request: Request):
        raise NotImplementedError()

    def verify(self, body: Activation, request: Request, response: Response):
        raise NotImplementedError()

    def login(self, body: Login, request: Request, response: Response):
        raise NotImplementedError()

    def logout(self, request: Request, response: Response, user=Depends(current_user)):
        raise NotImplementedError()