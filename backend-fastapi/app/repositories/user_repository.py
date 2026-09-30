from app.domain.identity.user import User
from uuid import UUID, uuid4
from app.domain.errors import NotFound, RateLimited

class UserRepository:

    def __init__(self, connection):
        self.connection = connection

    def get(self, user_id, lock=False) -> User:
        raise NotImplementedError()

    def by_username(self, username) -> User | None:
        raise NotImplementedError()

    def list_couriers(self):
        raise NotImplementedError()

    def list(self, company_id=None) -> list[User]:
        raise NotImplementedError()

    def create(self, data) -> User:
        raise NotImplementedError()

    def update(self, user_id, **changes) -> User:
        raise NotImplementedError()

    def notify(self, user_id, shipment_id, message):
        raise NotImplementedError()

    def notifications(self, user_id):
        raise NotImplementedError()

    def read_notifications(self, user_id):
        raise NotImplementedError()

    def add_review(self, order_id, customer_id, carrier_id, driver_id, rating, fraud, note):
        raise NotImplementedError()

    def reviews(self, user_id):
        raise NotImplementedError()

    def rate_limit(self, key, maximum):
        raise NotImplementedError()