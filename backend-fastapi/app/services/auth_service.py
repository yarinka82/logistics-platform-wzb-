from app.repositories.user_repository import UserRepository
from app.repositories.document_repository import DocumentRepository
'Registration, sessions and profiles using concrete SQL repositories.'
import base64
from datetime import datetime, timezone
from uuid import UUID
from app.domain.errors import Conflict, DomainError, DuplicateWrite, Forbidden, Unauthorized, RateLimited
PUBLIC_ROLES = {'CUSTOMER', 'DRIVER', 'COMPANY'}
STAFF_ROLES = {'ADMIN', 'MODERATOR'}

def safe_user(user):
    raise NotImplementedError()

def image_bytes(value: str):
    raise NotImplementedError()

class AuthService:

    def __init__(self, database, tokens, hash_password, check_password, mock_sms=True):
        self.database = database
        self.tokens = tokens
        self.hash_password = hash_password
        self.check_password = check_password
        self.mock_sms = mock_sms
        self.dummy_hash = hash_password('constant-time-invalid-user')

    def throttle(self, key, maximum=20):
        raise NotImplementedError()

    def register(self, data):
        raise NotImplementedError()

    def verify(self, token, code):
        raise NotImplementedError()

    def login(self, username, password):
        raise NotImplementedError()

    @staticmethod
    def ensure_active(user, connection):
        raise NotImplementedError()

    def authenticate(self, token):
        raise NotImplementedError()

    def logout(self, user):
        raise NotImplementedError()

    def profile(self, user):
        raise NotImplementedError()

    def update_profile(self, user, data):
        raise NotImplementedError()

    def change_password(self, user, old_password, new_password):
        raise NotImplementedError()

    def create_managed(self, actor, data):
        raise NotImplementedError()

    def block(self, actor, target_id, blocked):
        raise NotImplementedError()

    def complete_verification(self, user, data):
        raise NotImplementedError()