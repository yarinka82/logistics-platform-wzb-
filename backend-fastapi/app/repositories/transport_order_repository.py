from psycopg.types.json import Jsonb
from uuid import uuid4
from app.domain.errors import NotFound

class TransportOrderRepository:

    def __init__(self, connection):
        self.connection = connection

    def create(self, order_id):
        raise NotImplementedError()

    def lock(self, order_id):
        raise NotImplementedError()

    def events(self, order_id):
        raise NotImplementedError()

    def existing(self, command_id):
        raise NotImplementedError()

    def append(self, order_id, version, kind, payload, user_id, command_id, command_data):
        raise NotImplementedError()

    def project(self, order_id, version, state_dict, created_at):
        raise NotImplementedError()

    def get(self, order_id):
        raise NotImplementedError()

    def list(self):
        raise NotImplementedError()

    def all_ids(self):
        raise NotImplementedError()