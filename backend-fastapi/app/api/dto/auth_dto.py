from pydantic import BaseModel, Field, ConfigDict, field_validator
from typing import Literal

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)

class Registration(Input):
    username: str = Field(min_length=3, max_length=40, pattern=r'^[a-zA-Z0-9_.-]+$')
    password: str = Field(min_length=6, max_length=128)
    role: Literal['CUSTOMER', 'DRIVER', 'COMPANY']
    name: str = Field(min_length=2, max_length=120)
    phone: str = Field(min_length=5, max_length=30)
    email: str = Field(default='', max_length=160)
    city: str = Field(default='Würzburg', min_length=1, max_length=120)
    vehicle_plate: str = Field(default='', max_length=30)
    vehicle_type: str = Field(default='', max_length=60)
    tax_id: str = Field(default='', max_length=80)
    contact_name: str = Field(default='', max_length=120)
    fleet_size: int = Field(default=0, ge=0, le=10000)
    terms_accepted: bool
    declaration_accepted: bool = False
    document: str | None = Field(default=None, max_length=7_100_000)

    @field_validator('username')
    @classmethod
    def lowercase(cls, value): return value.lower()

class Login(Input):
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=1, max_length=128)

class Activation(Input):
    verification_token: str = Field(max_length=4096)
    code: str = Field(min_length=4, max_length=4)
