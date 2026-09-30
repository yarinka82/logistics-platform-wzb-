"""Password hashing and narrowly scoped HS256 JWT signing with standard-library crypto."""
import base64
import hashlib
import hmac
import json
import secrets
import time
from uuid import uuid4
from app.domain.errors import Unauthorized
TOKEN_LIFETIME = 30 * 24 * 60 * 60

def hash_password(password: str) -> str:
    raise NotImplementedError()

def check_password(password: str, encoded: str) -> bool:
    raise NotImplementedError()

def b64(data: bytes) -> str:
    raise NotImplementedError()

class TokenCodec:

    def __init__(self, secret: str):
        if len(secret) < 32:
            raise RuntimeError('JWT_SECRET must contain at least 32 characters')
        self._secret = secret.encode()

    def issue(self, user: dict, purpose: str='access') -> str:
        raise NotImplementedError()

    def decode(self, token: str, purpose: str='access') -> dict:
        raise NotImplementedError()