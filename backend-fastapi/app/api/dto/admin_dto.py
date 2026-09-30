from pydantic import BaseModel, Field, ConfigDict, field_validator
from typing import Literal

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)

class ManagedUser(Input):
    username: str = Field(min_length=3, max_length=40, pattern=r'^[a-zA-Z0-9_.-]+$')
    password: str = Field(min_length=6, max_length=128)
    role: Literal['CUSTOMER', 'DRIVER', 'COMPANY', 'EMPLOYEE', 'MODERATOR', 'ADMIN'] = 'EMPLOYEE'
    name: str = Field(min_length=2, max_length=120)
    phone: str = Field(min_length=5, max_length=30)
    vehicle_plate: str = Field(default='', max_length=30)
    vehicle_type: str = Field(default='', max_length=60)
    email: str = Field(default='', max_length=160)

    @field_validator('username')
    @classmethod
    def lowercase(cls, value): return value.lower()

class Block(Input):
    blocked: bool
