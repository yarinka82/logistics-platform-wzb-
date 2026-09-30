from dataclasses import dataclass

@dataclass
class Driver:
    id: str
    name: str
    vehicle_plate: str
    vehicle_type: str