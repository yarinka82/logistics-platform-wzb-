from app.repositories.user_repository import UserRepository
from app.repositories.document_repository import DocumentRepository
'HTTP controller for user profiles, avatars, notifications and carrier verification.'
from fastapi import APIRouter, Depends, Request, Response
from app.services.auth_service import safe_user, image_bytes
from app.api.dto.user_dto import Profile, Password, Verification
from app.api.dto.document_dto import Photo
from .auth_controller import current_user, cookie

class UserController:

    def __init__(self):
        self.router = APIRouter(prefix='/api', tags=['User profiles'])
        for path, method, handler in [('/me', 'GET', self.me), ('/me', 'PATCH', self.update), ('/couriers', 'GET', self.couriers), ('/me/password', 'POST', self.password), ('/me/avatar', 'POST', self.avatar), ('/me/verification', 'POST', self.verification), ('/notifications', 'GET', self.notifications), ('/notifications/read', 'POST', self.read_notifications)]:
            self.router.add_api_route(path, handler, methods=[method])

    def me(self, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def update(self, body: Profile, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def password(self, body: Password, request: Request, response: Response, user=Depends(current_user)):
        raise NotImplementedError()

    def avatar(self, body: Photo, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def verification(self, body: Verification, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def notifications(self, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def read_notifications(self, request: Request, user=Depends(current_user)):
        raise NotImplementedError()

    def couriers(self, request: Request):
        raise NotImplementedError()