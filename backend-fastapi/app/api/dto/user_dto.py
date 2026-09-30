from pydantic import BaseModel, Field, ConfigDict

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)

class Profile(Input):
    name: str = Field(min_length=2, max_length=120)
    email: str = Field(default='', max_length=160)
    city: str = Field(min_length=1, max_length=120)
    vehicle_plate: str = Field(default='', max_length=30)
    vehicle_type: str = Field(default='', max_length=60)
    contact_name: str = Field(default='', max_length=120)

class Password(Input):
    old_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=6, max_length=128)

class Verification(Input):
    tax_id: str = Field(min_length=1, max_length=80)
    declaration_accepted: bool
    document: str = Field(max_length=7_100_000)
