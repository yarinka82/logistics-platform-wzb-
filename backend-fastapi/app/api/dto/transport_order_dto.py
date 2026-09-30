from datetime import datetime
from uuid import UUID
from pydantic import BaseModel, Field, ConfigDict, field_validator
from typing import Literal

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)

class OrderInput(Input):
    origin: str = Field(min_length=2, max_length=200)
    destination: str = Field(min_length=2, max_length=200)
    city: str = Field(default='Würzburg', min_length=1, max_length=100)
    cargo: str = Field(min_length=3, max_length=1000)
    cargo_type: Literal['General freight', 'Furniture', 'Pallets', 'Vehicle', 'Other']
    price: float = Field(gt=0, le=1_000_000, allow_inf_nan=False)
    loading_at: datetime
    command_id: UUID

    @field_validator('loading_at')
    @classmethod
    def timezone_required(cls, value):
        if value.tzinfo is None: raise ValueError('Include a timezone in loading_at')
        return value

class Command(Input):
    command_id: UUID
    expected_version: int = Field(ge=1)
    data: dict = Field(default_factory=dict)
