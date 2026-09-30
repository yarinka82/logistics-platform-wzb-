-- Streams provide identity only. Current business state lives in no stream column.
CREATE TABLE IF NOT EXISTS shipment_stream (
    shipment_id UUID PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- This append-only table is the authoritative record of every shipment.
CREATE TABLE IF NOT EXISTS shipment_event (
    event_id UUID PRIMARY KEY,
    shipment_id UUID NOT NULL REFERENCES shipment_stream(shipment_id),
    version INTEGER NOT NULL CHECK (version > 0),
    event_type TEXT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    payload JSONB NOT NULL,
    actor TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    command_id UUID NOT NULL UNIQUE,
    command_data JSONB NOT NULL,
    UNIQUE (shipment_id, version)
);

-- This read model is disposable: rebuild it by replaying shipment_event.
CREATE TABLE IF NOT EXISTS shipment_projection (
    shipment_id UUID PRIMARY KEY REFERENCES shipment_stream(shipment_id),
    description TEXT NOT NULL,
    status TEXT NOT NULL,
    location TEXT NOT NULL,
    last_event_version INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

-- Reject accidental UPDATE/DELETE of facts even if application code has a bug.
CREATE OR REPLACE FUNCTION reject_event_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'Shipment events are append-only';
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS shipment_event_append_only ON shipment_event;
CREATE TRIGGER shipment_event_append_only
BEFORE UPDATE OR DELETE ON shipment_event
FOR EACH ROW EXECUTE FUNCTION reject_event_mutation();

-- Identity is conventional transactional data; trip business facts stay event-sourced.
CREATE TABLE IF NOT EXISTS app_user (
    id UUID PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('CUSTOMER','DRIVER','COMPANY','EMPLOYEE','MODERATOR','ADMIN')),
    name TEXT NOT NULL,
    email TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    city TEXT NOT NULL DEFAULT 'Würzburg',
    company_id UUID REFERENCES app_user(id),
    vehicle_plate TEXT NOT NULL DEFAULT '',
    vehicle_type TEXT NOT NULL DEFAULT '',
    tax_id TEXT NOT NULL DEFAULT '',
    contact_name TEXT NOT NULL DEFAULT '',
    fleet_size INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'PENDING',
    verification TEXT NOT NULL DEFAULT 'PENDING',
    terms_accepted BOOLEAN NOT NULL DEFAULT FALSE,
    declaration_accepted BOOLEAN NOT NULL DEFAULT FALSE,
    declaration_at TIMESTAMPTZ,
    phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
    token_version INTEGER NOT NULL DEFAULT 0,
    must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
    bootstrap_admin BOOLEAN NOT NULL DEFAULT FALSE,
    rating DOUBLE PRECISION,
    block_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX IF NOT EXISTS single_bootstrap_admin ON app_user(bootstrap_admin) WHERE bootstrap_admin;
ALTER TABLE shipment_projection ADD COLUMN IF NOT EXISTS state JSONB NOT NULL DEFAULT '{}';
CREATE TABLE IF NOT EXISTS user_document (
    id UUID PRIMARY KEY,
    owner_id UUID NOT NULL REFERENCES app_user(id),
    shipment_id UUID REFERENCES shipment_stream(shipment_id),
    purpose TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    data BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS notification (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES app_user(id),
    shipment_id UUID REFERENCES shipment_stream(shipment_id),
    message TEXT NOT NULL,
    read BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS notification_user ON notification(user_id, created_at DESC);
CREATE TABLE IF NOT EXISTS driver_review (
    shipment_id UUID PRIMARY KEY REFERENCES shipment_stream(shipment_id),
    customer_id UUID NOT NULL REFERENCES app_user(id),
    carrier_id UUID NOT NULL REFERENCES app_user(id),
    driver_id UUID NOT NULL REFERENCES app_user(id),
    rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
    fraud BOOLEAN NOT NULL DEFAULT FALSE,
    note TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS auth_rate_limit (
    key TEXT PRIMARY KEY,
    hits INTEGER NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
