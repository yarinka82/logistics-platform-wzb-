from pydantic import BaseModel, Field, ConfigDict

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)

class Photo(Input):
    photo: str = Field(max_length=7_100_000)
