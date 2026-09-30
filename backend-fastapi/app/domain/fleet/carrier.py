from dataclasses import dataclass

@dataclass
class Carrier:
    id: str
    name: str
    rating: float
    is_company: bool