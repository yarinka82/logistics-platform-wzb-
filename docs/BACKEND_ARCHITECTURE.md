# Backend architecture

The project uses three PostgreSQL tables: `shipment_stream` provides identity, `shipment_event` contains authoritative facts, and `shipment_projection` contains a rebuildable current view. Events reference streams with a many-to-one foreign key; each projection's primary key is also a foreign key to its stream. `(shipment_id, version)` remains unique.

## Responsibilities

| Layer | Class / interface | Responsibility |
| --- | --- | --- |
| Controller | `ShipmentController` | Route HTTP requests to application use cases |
| Controller | Request models and error handlers | Validate HTTP input and map errors to HTTP responses |
| Application | `ShipmentService` | Coordinate commands, replay, version checks, idempotency, and transactions |
| Domain | `Shipment` | Decide valid transitions and apply persisted facts deterministically |
| Application ports | `EventRepository`, `ProjectionRepository` | Define persistence contracts without importing database libraries |
| Application ports | `UnitOfWork`, `UnitOfWorkFactory` | Define the transaction boundary and its factory |
| Repository adapters | `PostgresEventRepository`, `PostgresProjectionRepository` | Execute SQL for their respective storage responsibilities |
| Infrastructure | `PostgresUnitOfWork` | Share one connection, commit or roll back, and translate database uniqueness errors |
| Infrastructure | `Database` | Open PostgreSQL connections and initialize the schema |
| Composition root | `main.py` | Connect concrete adapters to the service and register controllers |

The event repository provides explicit append operations rather than generic update/delete CRUD methods. The projection repository can update its rows because they are derived state.

## Command execution

1. FastAPI validates the request and calls a `ShipmentController` method.
2. The controller delegates to `ShipmentService.execute()`.
3. The service enters a unit of work, then locks the shipment stream.
4. The event repository loads the stream. The `Shipment` aggregate replays it.
5. The service checks the expected version; the aggregate decides whether the requested transition is valid.
6. The event repository appends the new fact. The aggregate applies it in memory.
7. The projection repository saves the derived state using the same transaction.
8. Leaving the unit of work commits both writes, or rolls them back if a step failed.

Read-model rebuilds replay stored events. They never modify the event rows.

## SOLID in this implementation

- **Single responsibility:** HTTP, business decisions, use-case coordination, SQL, and transaction management have separate owners.
- **Open/closed:** another storage adapter can implement the ports without rewriting the application service.
- **Liskov substitution:** adapters must preserve the repository and transaction contracts, including ordering, missing-resource errors, uniqueness, and rollback semantics.
- **Interface segregation:** event storage and projection storage have separate interfaces; consumers do not receive an unrestricted database connection.
- **Dependency inversion:** `ShipmentService` depends on interfaces in `application/ports.py`; `main.py` injects the PostgreSQL implementation.

Python `Protocol` provides structural interfaces, so adapters do not need artificial inheritance. OOP here means objects with clear responsibilities and injected collaborators, not an inheritance hierarchy for every function.

## Testing boundaries

`test_domain.py` tests transition rules directly. `test_service.py` supplies mock ports with no database. `test_architecture.py` prevents the inner layers from importing FastAPI or PostgreSQL adapters. Integration tests verify the real repositories, transactions, and controllers together against PostgreSQL.
