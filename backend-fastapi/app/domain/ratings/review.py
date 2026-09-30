from dataclasses import dataclass

@dataclass
class Review:
    shipment_id: str
    rating: int
    fraud: bool
    note: str