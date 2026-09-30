from dataclasses import dataclass
from datetime import datetime

@dataclass
class TransportOrder:
    id: str
    customer_id: str
    origin: str
    destination: str
    cargo: str
    price: float
    loading_at: datetime
    status: str