from datetime import datetime
from typing import TypedDict, Literal
from uuid import UUID
Role = Literal['CUSTOMER', 'DRIVER', 'COMPANY', 'EMPLOYEE', 'MODERATOR', 'ADMIN']

class User(TypedDict):
    id: UUID
    username: str
    password_hash: str
    role: Role
    name: str
    email: str
    phone: str
    city: str
    company_id: UUID | None
    vehicle_plate: str
    vehicle_type: str
    tax_id: str
    contact_name: str
    fleet_size: int
    status: str
    verification: str
    terms_accepted: bool
    declaration_accepted: bool
    declaration_at: datetime | None
    phone_verified: bool
    token_version: int
    must_change_password: bool
    bootstrap_admin: bool
    rating: float | None
    block_reason: str | None
    created_at: datetime