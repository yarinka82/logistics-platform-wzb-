"""Framework-independent errors shared across application boundaries."""


class DomainError(Exception):
    """A command violates a business rule."""


class NotFound(Exception):
    """The requested resource does not exist."""


class Conflict(Exception):
    """The command conflicts with already persisted state."""


class DuplicateWrite(Exception):
    """Persistence rejected a duplicate command ID or stream version."""


class Unauthorized(Exception):
    """A valid, current login is required."""


class Forbidden(Exception):
    """The authenticated actor does not have permission."""


class RateLimited(Exception):
    """Too many authentication attempts."""
