from copy import deepcopy
from dataclasses import dataclass, field
from app.domain.errors import DomainError
from . import events

@dataclass
class Shipment:
    id: str = ''
    version: int = 0
    status: str = ''
    customer_id: str = ''
    carrier_id: str = None
    driver_id: str = None
    documents: list = field(default_factory=list)
    review: dict = None

    @classmethod
    def rebuild(cls, events_list: list[dict]) -> 'Shipment':
        raise NotImplementedError()

    def apply(self, event: dict) -> None:
        raise NotImplementedError()

    def take(self, carrier_id: str, driver_id: str) -> dict:
        raise NotImplementedError()

    def depart(self, driver_id: str, coordinates: dict) -> dict:
        raise NotImplementedError()

    def arrive(self, driver_id: str, coordinates: dict) -> dict:
        raise NotImplementedError()

    def upload_document(self, driver_id: str, document_id: str) -> dict:
        raise NotImplementedError()

    def complete(self, driver_id: str, coordinates: dict) -> dict:
        raise NotImplementedError()

    def add_review(self, customer_id: str, rating: int, fraud: bool, note: str) -> dict:
        raise NotImplementedError()

    def _require_status(self, expected: str):
        raise NotImplementedError()

    def _require_driver(self, driver_id: str):
        raise NotImplementedError()