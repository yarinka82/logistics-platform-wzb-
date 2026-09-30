from contextlib import contextmanager
from psycopg.errors import UniqueViolation
from app.domain.errors import DuplicateWrite
"""PostgreSQL connection and schema bootstrap configuration."""
from pathlib import Path
from typing import Any

import psycopg
from psycopg.rows import dict_row


class Database:
    def __init__(self, database_url: str):
        self._database_url = database_url

    def connect(self) -> psycopg.Connection[dict[str, Any]]:
        return psycopg.connect(
            self._database_url, row_factory=dict_row, connect_timeout=5,
        )

    def initialize(self) -> None:
        with self.connect() as connection:
            connection.execute(Path(__file__).with_name("schema.sql").read_text())

    @contextmanager
    def transaction(self, *, read_only=False):
        """Share one real SQL transaction across the repositories used by a request."""
        try:
            with self.connect() as connection:
                if read_only:
                    connection.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
                yield connection
        except UniqueViolation as error:
            raise DuplicateWrite("A uniqueness constraint rejected this write") from error
