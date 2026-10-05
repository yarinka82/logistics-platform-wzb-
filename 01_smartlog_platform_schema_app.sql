-- ============================================================================
-- SMARTLOG EUROPE: UNIFIED DATABASE SCHEMA
-- File:        01_smartlog_platform_schema_app.sql
-- Database:    smartlog_db — ONE PostgreSQL database, several schemas
-- Target DBMS: PostgreSQL 16+ (17/18 recommended) with PostGIS
-- Run once on an EMPTY database:
--     psql -v ON_ERROR_STOP=1 -d smartlog_db -f 01_smartlog_platform_schema_app.sql
--
-- SCHEMAS
--   core       logistics marketplace: countries, VAT, clients, vehicles, drivers,
--              orders, deliveries, GPS track, documents, costs, fraud reports
--   app        accounts (tenants), users (passwordless e-mail codes), memberships,
--              devices, sessions, consents, customer lifecycle, audit log
--   billing    plans, versioned prices, entitlements, subscriptions (1/3/6/12
--              months), invoices (GoBD), credit notes, payments (payment system
--              NAME only), discounts, webhook inbox
--   marketing  channels, campaigns, ads, ad spend, attribution, app installs
--   analytics  SmartLog SaaS KPIs (MRR, cohorts, unit economics) and the
--              customer-facing logistics KPI star schema with a ~1 minute
--              refresh queue; dashboards and the AI assistant read only here
--   ops        helpers: UUIDv7, partitions, retention, nightly job
--
-- KEY RELATIONSHIPS BETWEEN SCHEMAS
--   app.accounts.client_id            -> core.clients        (1:1, tenant <-> counterparty)
--   app.users.driver_id               -> core.drivers        (login of a driver)
--   core.costs.client_id              -> core.clients        (owner of every cost)
--   billing.subscriptions.account_id  -> app.accounts        (only paying carriers)
--   billing.payments.payment_system_code -> billing.payment_systems (name only)
--   analytics.* account_id            -> app.accounts        (row-level security)
--
-- JOBS TO SCHEDULE (pg_cron, Celery beat or cron):
--   every minute : SELECT analytics.process_refresh_queue();   -- customer KPIs, ~1 min latency
--   nightly 02:00: SELECT ops.run_nightly();                   -- reconciliation, SaaS KPIs, retention
-- ============================================================================

BEGIN;

-- ############################################################################
-- PART 0. EXTENSIONS, SCHEMAS, SEARCH PATH
-- ############################################################################
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive e-mail
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_bytes() for UUIDv7

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS billing;
CREATE SCHEMA IF NOT EXISTS marketing;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS ops;

DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path = core, app, billing, marketing, analytics, ops, public',
                   current_database());
END;
$$;

SET search_path = core, app, billing, marketing, analytics, ops, public;

-- ############################################################################
-- PART 1. SCHEMA core — LOGISTICS MARKETPLACE
-- (from 001_smartlog_core_mvp_marketplace_schema.sql, business rules unchanged;
--  objects now live in schema "core"; costs.client_id built in)
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 1.1. ENUM TYPES
-- ----------------------------------------------------------------------------
CREATE TYPE core.client_type_enum AS ENUM (
    'individual',          -- B2C client (private shipping / moving)
    'company',             -- B2B client (SMB, VAT payer): shipper OR fleet carrier
    'solo_carrier'         -- self-employed carrier registered on the exchange
);

CREATE TYPE core.driver_type_enum AS ENUM (
    'self_employed',       -- sole proprietorship (Gewerbe / Solo-Selbstständige)
    'company_employee'     -- fleet company staff driver
);

CREATE TYPE core.driver_status_enum AS ENUM (
    'available', 'on_trip', 'off_duty',
    'inactive'             -- blocked or suspended
);

CREATE TYPE core.order_status_enum AS ENUM (
    'draft',               -- draft created by customer
    'published',           -- listed on the exchange
    'confirmed',           -- matched & mutually confirmed
    'in_transit',          -- cargo picked up
    'delivered',           -- driver marked as delivered (e-POD uploaded)
    'closed',              -- customer / accountant confirmed, invoice-ready
    'cancelled'
);

CREATE TYPE core.match_status_enum AS ENUM ('pending', 'both_confirmed', 'rejected');

CREATE TYPE core.executor_type_enum AS ENUM (
    'fop_driver',          -- solo courier / independent driver
    'carrier_company'      -- transport company / subcontractor fleet
);

CREATE TYPE core.cargo_type_enum AS ENUM ('box', 'pallet', 'parcel', 'bulk', 'fragile', 'other');

CREATE TYPE core.delivery_status_enum AS ENUM ('planned', 'in_transit', 'delivered', 'cancelled');

CREATE TYPE core.delay_status_enum AS ENUM ('on_time', 'delayed');

CREATE TYPE core.delay_reason_enum AS ENUM (
    'traffic', 'weather', 'loading_delay', 'customer_delay', 'vehicle_issue', 'route_issue', 'other'
);

CREATE TYPE core.incident_type_enum AS ENUM (
    'None', 'Traffic_Stau', 'Weather_Force_Majeure', 'Dock_Waiting', 'Vehicle_Breakdown',
    'Driver_Route_Deviation', 'Cargo_Handling_Damage', 'Paperwork_CMR_Error'
);

CREATE TYPE core.cost_type_enum AS ENUM ('fuel', 'maintenance', 'work_reward', 'other');

CREATE TYPE core.document_type_enum AS ENUM (
    'electronic_cmr', 'delivery_photo', 'damage_act', 'weight_ticket', 'invoice'
);

CREATE TYPE core.document_status_enum AS ENUM ('pending', 'confirmed', 'rejected');

-- ----------------------------------------------------------------------------
-- 1.2. EU COUNTRIES & VAT
-- ----------------------------------------------------------------------------
CREATE TABLE core.supported_countries (
    country_code   char(2) PRIMARY KEY,                                  -- ISO 3166-1 alpha-2
    country_name   varchar(100) NOT NULL,
    is_active      boolean NOT NULL DEFAULT FALSE,
    activated_at   timestamptz,
    CONSTRAINT chk_country_code_format CHECK (country_code ~ '^[A-Z]{2}$')
);

INSERT INTO core.supported_countries (country_code, country_name, is_active, activated_at) VALUES
    ('DE', 'Germany', TRUE, CURRENT_TIMESTAMP),
    ('AT', 'Austria', FALSE, NULL), ('BE', 'Belgium', FALSE, NULL), ('BG', 'Bulgaria', FALSE, NULL),
    ('HR', 'Croatia', FALSE, NULL), ('CY', 'Cyprus', FALSE, NULL), ('CZ', 'Czechia', FALSE, NULL),
    ('DK', 'Denmark', FALSE, NULL), ('EE', 'Estonia', FALSE, NULL), ('FI', 'Finland', FALSE, NULL),
    ('FR', 'France', FALSE, NULL), ('GR', 'Greece', FALSE, NULL), ('HU', 'Hungary', FALSE, NULL),
    ('IE', 'Ireland', FALSE, NULL), ('IT', 'Italy', FALSE, NULL), ('LV', 'Latvia', FALSE, NULL),
    ('LT', 'Lithuania', FALSE, NULL), ('LU', 'Luxembourg', FALSE, NULL), ('MT', 'Malta', FALSE, NULL),
    ('NL', 'Netherlands', FALSE, NULL), ('PL', 'Poland', FALSE, NULL), ('PT', 'Portugal', FALSE, NULL),
    ('RO', 'Romania', FALSE, NULL), ('SK', 'Slovakia', FALSE, NULL), ('SI', 'Slovenia', FALSE, NULL),
    ('ES', 'Spain', FALSE, NULL), ('SE', 'Sweden', FALSE, NULL)
ON CONFLICT (country_code) DO NOTHING;

CREATE TABLE core.vat_rates (
    vat_rate_id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2) NOT NULL REFERENCES core.supported_countries(country_code) ON UPDATE CASCADE,
    standard_rate_pct  numeric(4,2) NOT NULL CHECK (standard_rate_pct >= 0.00),
    valid_from         date NOT NULL,
    valid_to           date,
    CONSTRAINT chk_vat_rate_period CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE UNIQUE INDEX idx_vat_rates_current_per_country ON core.vat_rates(country_code) WHERE valid_to IS NULL;

INSERT INTO core.vat_rates (country_code, standard_rate_pct, valid_from) VALUES ('DE', 19.00, '2007-01-01');

-- ----------------------------------------------------------------------------
-- 1.3. CORE ENTITIES
-- ----------------------------------------------------------------------------
CREATE TABLE core.clients (
    client_id           varchar(32) PRIMARY KEY,                          -- C-### or CL-YYYY-######
    client_type         core.client_type_enum NOT NULL DEFAULT 'company',
    full_legal_name     varchar(150) NOT NULL,
    vat_id              varchar(30),                                      -- USt-IdNr
    tax_number          varchar(30),                                      -- Steuernummer
    contact_email       varchar(100) NOT NULL,
    contact_phone       varchar(30) NOT NULL,
    billing_street      varchar(255) NOT NULL,
    billing_postal_code varchar(10) NOT NULL,                             -- PLZ
    billing_city        varchar(100) NOT NULL,
    billing_country     char(2) NOT NULL REFERENCES core.supported_countries(country_code) ON UPDATE CASCADE,
    is_verified         boolean NOT NULL DEFAULT FALSE,
    is_active           boolean NOT NULL DEFAULT TRUE,
    verified_by         varchar(150),                                     -- who verified (staff e-mail / system)
    verified_at         timestamptz,
    created_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Business clients and carriers (self-employed driver or small company)
    -- register with a Steuernummer or USt-IdNr: needed to issue invoices.
    CONSTRAINT chk_company_tax_compliance CHECK (
        (client_type IN ('company', 'solo_carrier') AND (vat_id IS NOT NULL OR tax_number IS NOT NULL)) OR
        (client_type = 'individual')
    ),
    CONSTRAINT chk_client_verification_log CHECK (
        (is_verified = FALSE AND verified_by IS NULL AND verified_at IS NULL) OR
        (is_verified = TRUE  AND verified_by IS NOT NULL AND verified_at IS NOT NULL)
    )
);

CREATE TABLE core.vehicles (
    vehicle_id                  varchar(32) PRIMARY KEY,                  -- VH-####
    license_plate               varchar(20) NOT NULL UNIQUE,
    vehicle_type                varchar(32) NOT NULL,
    gross_vehicle_weight_kg     integer NOT NULL CHECK (gross_vehicle_weight_kg > 0),
    payload_capacity_kg         numeric(10,2) NOT NULL CHECK (payload_capacity_kg > 0),
    pallet_capacity             integer NOT NULL DEFAULT 0 CHECK (pallet_capacity >= 0),
    fuel_type                   varchar(20) NOT NULL DEFAULT 'diesel',
    euro_emission_class         varchar(10) NOT NULL DEFAULT 'Euro_6',    -- for German LKW-Maut
    tuv_inspection_expiry_date  date NOT NULL,                            -- mandatory inspection (HU/AU)
    is_active                   boolean NOT NULL DEFAULT TRUE,
    is_test                     boolean NOT NULL DEFAULT FALSE,
    owner_client_id             varchar(32) REFERENCES core.clients(client_id) ON UPDATE CASCADE ON DELETE SET NULL,  -- legal owner / operator
    created_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE core.drivers (
    driver_id                   varchar(32) PRIMARY KEY,                  -- DR-####
    linked_client_id            varchar(32) NOT NULL REFERENCES core.clients(client_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    driver_type                 core.driver_type_enum NOT NULL DEFAULT 'self_employed',
    full_name                   varchar(100) NOT NULL,
    phone_number                varchar(30) NOT NULL,
    base_city                   varchar(100) NOT NULL,
    driving_license_categories  varchar(50) NOT NULL,                     -- B, BE, C1, C1E, C, CE
    driving_license_expiry_date date NOT NULL,
    code_95_categories          varchar(50),                              -- EU Code 95 (BKrFQG)
    code_95_expiry_date         date,
    has_adr                     boolean NOT NULL DEFAULT FALSE,
    adr_expiry_date             date,
    avg_customer_rating         numeric(3,2) NOT NULL DEFAULT 5.00 CHECK (avg_customer_rating BETWEEN 1.00 AND 5.00),
    total_reviews_count         integer NOT NULL DEFAULT 0 CHECK (total_reviews_count >= 0),
    service_compliance_rate     numeric(5,2) NOT NULL DEFAULT 100.00 CHECK (service_compliance_rate BETWEEN 0.00 AND 100.00),
    status                      core.driver_status_enum NOT NULL DEFAULT 'available',
    blocked_at                  timestamptz,                              -- set by auto-block (1.6)
    blocked_reason              text,
    default_vehicle_id          varchar(32) REFERENCES core.vehicles(vehicle_id) ON UPDATE CASCADE ON DELETE SET NULL,
    is_verified                 boolean NOT NULL DEFAULT FALSE,
    is_test                     boolean NOT NULL DEFAULT FALSE,
    created_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_driver_code95_consistency CHECK (
        (code_95_categories IS NULL AND code_95_expiry_date IS NULL) OR
        (code_95_categories IS NOT NULL AND code_95_expiry_date IS NOT NULL)
    ),
    CONSTRAINT chk_driver_adr_consistency CHECK (
        (has_adr = FALSE AND adr_expiry_date IS NULL) OR
        (has_adr = TRUE AND adr_expiry_date IS NOT NULL)
    )
);

-- No separate routes table: planned/actual distance live on deliveries, GPS
-- points on orders and delivery_track_points; deliveries.route_id is a plain code.
CREATE TABLE core.orders (
    order_id                    varchar(32) PRIMARY KEY,                  -- SL-YYYY-######
    order_date                  date NOT NULL,
    client_id                   varchar(32) NOT NULL REFERENCES core.clients(client_id) ON UPDATE CASCADE,   -- shipper
    status                      core.order_status_enum NOT NULL DEFAULT 'published',
    amount_eur                  numeric(12,2) NOT NULL CHECK (amount_eur >= 0.00),                          -- net
    vat_rate_pct                numeric(4,2) NOT NULL DEFAULT 19.00,
    is_reverse_charge           boolean NOT NULL DEFAULT FALSE,

    origin_address              varchar(255) NOT NULL,
    origin_city                 varchar(100) NOT NULL,
    origin_postal_code          varchar(10) NOT NULL,
    origin_country              char(2) NOT NULL REFERENCES core.supported_countries(country_code) ON UPDATE CASCADE,
    origin_location             geometry(Point, 4326),
    destination_address         varchar(255) NOT NULL,
    destination_city            varchar(100) NOT NULL,
    destination_postal_code     varchar(10) NOT NULL,
    destination_country         char(2) NOT NULL REFERENCES core.supported_countries(country_code) ON UPDATE CASCADE,
    destination_location        geometry(Point, 4326),

    pickup_at                   timestamptz NOT NULL,
    planned_delivery_at         timestamptz NOT NULL,
    cargo_type                  core.cargo_type_enum NOT NULL,
    cargo_weight_kg             numeric(10,2) NOT NULL CHECK (cargo_weight_kg > 0),
    cargo_units                 integer NOT NULL CHECK (cargo_units >= 1),
    adr_required                boolean NOT NULL DEFAULT FALSE,

    -- two-sided matching (no dispatcher)
    executor_type               core.executor_type_enum,
    executor_id                 varchar(32),                              -- DR-#### or C-###
    executor_name               varchar(255),
    shipper_confirmed           boolean NOT NULL DEFAULT FALSE,
    shipper_confirmed_at        timestamptz,
    carrier_confirmed           boolean NOT NULL DEFAULT FALSE,
    carrier_confirmed_at        timestamptz,
    match_status                core.match_status_enum NOT NULL DEFAULT 'pending',

    closed_by                   varchar(150),                             -- who confirmed after delivery
    closed_at                   timestamptz,

    is_test                     boolean NOT NULL DEFAULT FALSE,
    created_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_order_time_window CHECK (planned_delivery_at >= pickup_at),
    CONSTRAINT chk_order_match_consistency CHECK (
        match_status <> 'both_confirmed' OR (shipper_confirmed = TRUE AND carrier_confirmed = TRUE)
    ),
    CONSTRAINT chk_reverse_charge_zero_vat CHECK (is_reverse_charge = FALSE OR vat_rate_pct = 0.00),
    CONSTRAINT chk_order_closed_log CHECK (
        (status <> 'closed' AND closed_by IS NULL AND closed_at IS NULL) OR
        (status = 'closed'  AND closed_by IS NOT NULL AND closed_at IS NOT NULL)
    )
);

CREATE TABLE core.deliveries (
    delivery_id                 varchar(32) PRIMARY KEY,                  -- DL-YYYY-######
    order_id                    varchar(32) NOT NULL REFERENCES core.orders(order_id) ON UPDATE CASCADE,
    route_id                    varchar(32) NOT NULL,                     -- RT-##### (plain code, no FK)
    driver_id                   varchar(32) REFERENCES core.drivers(driver_id) ON UPDATE CASCADE,
    vehicle_id                  varchar(32) REFERENCES core.vehicles(vehicle_id) ON UPDATE CASCADE,
    delivery_status             core.delivery_status_enum NOT NULL DEFAULT 'planned',
    planned_start_time          timestamptz NOT NULL,
    actual_start_time           timestamptz,
    planned_end_time            timestamptz NOT NULL,
    actual_end_time             timestamptz,
    planned_distance_km         numeric(8,2) NOT NULL CHECK (planned_distance_km > 0),
    actual_distance_km          numeric(8,2) CHECK (actual_distance_km >= 0),
    planned_duration_minutes    integer,
    delivery_duration_minutes   integer,
    delay_minutes               integer DEFAULT 0,
    delay_status                core.delay_status_enum DEFAULT 'on_time',
    delay_reason                core.delay_reason_enum,
    incident_type               core.incident_type_enum NOT NULL DEFAULT 'None',
    is_driver_liable            boolean NOT NULL DEFAULT FALSE,
    customer_rating_stars       numeric(2,1) CHECK (customer_rating_stars BETWEEN 1.0 AND 5.0),
    customer_feedback_comment   text,
    proof_of_delivery_url       varchar(255),
    is_test                     boolean NOT NULL DEFAULT FALSE,
    created_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_delivery_time_window CHECK (planned_end_time > planned_start_time)
);

CREATE TABLE core.delivery_track_points (
    track_point_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delivery_id     varchar(32) NOT NULL REFERENCES core.deliveries(delivery_id) ON UPDATE CASCADE ON DELETE CASCADE,
    recorded_at     timestamptz NOT NULL,
    location        geometry(Point, 4326) NOT NULL,
    speed_kmh       numeric(5,2)
);

-- Files (PDF, JPG, PNG) live in S3 / MinIO; the database stores URLs and keys only.
CREATE TABLE core.shipment_documents (
    document_id                 varchar(32) PRIMARY KEY,                  -- DOC-YYYY-######
    delivery_id                 varchar(32) NOT NULL REFERENCES core.deliveries(delivery_id) ON UPDATE CASCADE ON DELETE CASCADE,
    document_type               core.document_type_enum NOT NULL,
    document_url                text NOT NULL,
    s3_object_key               varchar(512),
    file_name                   varchar(255) NOT NULL,
    file_size_bytes             bigint,
    mime_type                   varchar(100) NOT NULL DEFAULT 'application/pdf',
    verification_status         core.document_status_enum NOT NULL DEFAULT 'pending',
    signed_by_name              varchar(100),
    signed_at                   timestamptz,
    signature_geo_location      geometry(Point, 4326),                    -- e-POD signature coordinates
    rejection_reason            text,
    created_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Every cost belongs to a tenant (client_id). If the backend does not send
-- it, trigger 1.7 derives it from the driver, the vehicle owner or the
-- driver of the delivery.
CREATE TABLE core.costs (
    cost_id             varchar(32) PRIMARY KEY,                          -- CS-YYYY-######
    cost_date           date NOT NULL,
    client_id           varchar(32) NOT NULL REFERENCES core.clients(client_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    cost_type           core.cost_type_enum NOT NULL,
    cost_subtype        varchar(32) NOT NULL,
    is_repair           boolean NOT NULL DEFAULT FALSE,
    cost_amount_eur     numeric(12,2) NOT NULL DEFAULT 0.00 CHECK (cost_amount_eur >= 0.00),
    driver_payout_eur   numeric(12,2) NOT NULL DEFAULT 0.00 CHECK (driver_payout_eur >= 0.00),
    delivery_id         varchar(32) REFERENCES core.deliveries(delivery_id) ON UPDATE CASCADE ON DELETE SET NULL,
    driver_id           varchar(32) REFERENCES core.drivers(driver_id) ON UPDATE CASCADE ON DELETE SET NULL,
    vehicle_id          varchar(32) REFERENCES core.vehicles(vehicle_id) ON UPDATE CASCADE ON DELETE SET NULL,
    is_private_expense  boolean NOT NULL DEFAULT FALSE,                   -- driver's personal expense
    fuel_liters         numeric(8,2) CHECK (fuel_liters >= 0),
    notes               text,
    is_test             boolean NOT NULL DEFAULT FALSE,
    created_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_is_repair_only_for_maintenance CHECK (is_repair = FALSE OR cost_type = 'maintenance'),
    CONSTRAINT chk_cost_subtype_domain CHECK (
        cost_subtype IN (
            'diesel', 'petrol', 'adblue', 'electricity', 'cng_lng',                       -- fuel
            'scheduled_service', 'tech_inspection', 'repair', 'tires', 'washing',        -- maintenance
            'trip_fee', 'base_salary', 'per_diem', 'bonus', 'driver_allowance',          -- work_reward
            'tolls', 'parking', 'fines', 'claims', 'insurance', 'ferry_bridge'           -- other
        )
    )
);

-- Customer complaints about drivers ("Report fraud"); 2 reports or a
-- rating below 3.20 block the driver automatically (1.6).
CREATE TABLE core.fraud_reports (
    report_id           varchar(32) PRIMARY KEY,                          -- FR-YYYY-######
    reported_driver_id  varchar(32) NOT NULL REFERENCES core.drivers(driver_id) ON UPDATE CASCADE ON DELETE CASCADE,
    reporter_client_id  varchar(32) NOT NULL REFERENCES core.clients(client_id) ON UPDATE CASCADE,
    order_id            varchar(32) REFERENCES core.orders(order_id) ON UPDATE CASCADE ON DELETE SET NULL,
    reason              text NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ----------------------------------------------------------------------------
-- 1.4. INDEXES
-- ----------------------------------------------------------------------------
CREATE INDEX idx_clients_country_type ON core.clients(billing_country, client_type);
CREATE INDEX idx_vehicles_owner_client_id ON core.vehicles(owner_client_id);
CREATE INDEX idx_drivers_linked_client ON core.drivers(linked_client_id);

CREATE INDEX idx_orders_client_id ON core.orders(client_id);
CREATE INDEX idx_orders_status_date ON core.orders(status, order_date);
CREATE INDEX idx_orders_match_status ON core.orders(match_status) WHERE match_status <> 'both_confirmed';
CREATE INDEX idx_orders_origin_loc ON core.orders USING GIST(origin_location);
CREATE INDEX idx_orders_dest_loc ON core.orders USING GIST(destination_location);
CREATE INDEX idx_orders_client_tracking ON core.orders(client_id, order_date DESC, order_id);
CREATE INDEX idx_orders_created_at ON core.orders(created_at);
CREATE INDEX idx_orders_carrier_confirmed_at ON core.orders(carrier_confirmed_at) WHERE match_status = 'both_confirmed';

CREATE INDEX idx_deliveries_order_id ON core.deliveries(order_id);
CREATE INDEX idx_deliveries_route_id ON core.deliveries(route_id);
CREATE INDEX idx_deliveries_driver_status ON core.deliveries(driver_id, delivery_status);
CREATE INDEX idx_deliveries_vehicle_status ON core.deliveries(vehicle_id, delivery_status);
CREATE INDEX idx_deliveries_actual_end ON core.deliveries(actual_end_time);

CREATE INDEX idx_track_points_delivery ON core.delivery_track_points(delivery_id, recorded_at);
CREATE INDEX idx_track_points_geom ON core.delivery_track_points USING GIST(location);

CREATE INDEX idx_shipment_docs_delivery ON core.shipment_documents(delivery_id);
CREATE INDEX idx_shipment_docs_status ON core.shipment_documents(verification_status);
CREATE INDEX idx_shipment_docs_created ON core.shipment_documents(created_at);

CREATE INDEX idx_costs_client_date ON core.costs(client_id, cost_date);
CREATE INDEX idx_costs_created_at ON core.costs(created_at);
CREATE INDEX idx_costs_delivery_id ON core.costs(delivery_id);
CREATE INDEX idx_costs_driver_date ON core.costs(driver_id, cost_date);
CREATE INDEX idx_costs_vehicle_date ON core.costs(vehicle_id, cost_date);
CREATE INDEX idx_costs_is_repair ON core.costs(is_repair);
CREATE INDEX idx_costs_subtype ON core.costs(cost_subtype);

CREATE INDEX idx_fraud_reports_driver ON core.fraud_reports(reported_driver_id);

-- ----------------------------------------------------------------------------
-- 1.5. INTEGRITY TRIGGERS & REAL-TIME EVENTS
-- ----------------------------------------------------------------------------

-- Client country must be activated.
CREATE OR REPLACE FUNCTION core.trg_validate_client_country() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT COALESCE((SELECT is_active FROM core.supported_countries WHERE country_code = NEW.billing_country), FALSE) THEN
        RAISE EXCEPTION 'Country % is not yet activated for platform operations', NEW.billing_country;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_client_country_check
    BEFORE INSERT OR UPDATE OF billing_country ON core.clients
    FOR EACH ROW EXECUTE FUNCTION core.trg_validate_client_country();

-- Order origin and destination countries must be activated.
CREATE OR REPLACE FUNCTION core.trg_validate_order_countries() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT COALESCE((SELECT is_active FROM core.supported_countries WHERE country_code = NEW.origin_country), FALSE) THEN
        RAISE EXCEPTION 'origin_country % is not yet activated for operations', NEW.origin_country;
    END IF;
    IF NOT COALESCE((SELECT is_active FROM core.supported_countries WHERE country_code = NEW.destination_country), FALSE) THEN
        RAISE EXCEPTION 'destination_country % is not yet activated for operations', NEW.destination_country;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_order_countries_check
    BEFORE INSERT OR UPDATE OF origin_country, destination_country ON core.orders
    FOR EACH ROW EXECUTE FUNCTION core.trg_validate_order_countries();

-- VAT rate by date; cross-border orders -> reverse charge 0 %.
-- Simplified rule (country pair only); real VAT treatment also depends on
-- the counterparty's VAT status — to be confirmed with a Steuerberater.
CREATE OR REPLACE FUNCTION core.trg_set_order_vat_rate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_rate numeric(4,2);
BEGIN
    IF NEW.origin_country <> NEW.destination_country THEN
        NEW.is_reverse_charge := TRUE;
        NEW.vat_rate_pct := 0.00;
        RETURN NEW;
    END IF;
    IF NEW.is_reverse_charge THEN
        NEW.vat_rate_pct := 0.00;
        RETURN NEW;
    END IF;

    SELECT standard_rate_pct INTO v_rate
    FROM core.vat_rates
    WHERE country_code = NEW.origin_country
      AND valid_from <= NEW.order_date
      AND (valid_to IS NULL OR valid_to > NEW.order_date)
    ORDER BY valid_from DESC
    LIMIT 1;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'No VAT rate defined for country % on date %', NEW.origin_country, NEW.order_date;
    END IF;
    NEW.vat_rate_pct := v_rate;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_order_vat_rate
    BEFORE INSERT OR UPDATE OF origin_country, destination_country, order_date, is_reverse_charge ON core.orders
    FOR EACH ROW EXECUTE FUNCTION core.trg_set_order_vat_rate();

-- fop_driver executor must exist.
CREATE OR REPLACE FUNCTION core.trg_validate_order_executor() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.executor_type = 'fop_driver' AND NEW.executor_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.drivers WHERE driver_id = NEW.executor_id) THEN
        RAISE EXCEPTION 'executor_id % not found in drivers (executor_type = fop_driver)', NEW.executor_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_order_executor_check
    BEFORE INSERT OR UPDATE OF executor_type, executor_id ON core.orders
    FOR EACH ROW EXECUTE FUNCTION core.trg_validate_order_executor();

-- ADR cargo requires an ADR-certified fop_driver (carrier_company drivers are not registered on the platform).
CREATE OR REPLACE FUNCTION core.trg_validate_order_adr_compliance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_has_adr boolean;
BEGIN
    IF NEW.adr_required AND NEW.executor_type = 'fop_driver' AND NEW.executor_id IS NOT NULL THEN
        SELECT has_adr INTO v_has_adr FROM core.drivers WHERE driver_id = NEW.executor_id;
        IF v_has_adr IS NULL THEN
            RAISE EXCEPTION 'executor_id % not found in drivers (adr compliance check)', NEW.executor_id;
        END IF;
        IF NOT v_has_adr THEN
            RAISE EXCEPTION 'Order % requires adr_required = TRUE, but driver % does not hold a valid ADR certificate (has_adr = FALSE)',
                NEW.order_id, NEW.executor_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_order_adr_check
    BEFORE INSERT OR UPDATE OF executor_type, executor_id, adr_required ON core.orders
    FOR EACH ROW EXECUTE FUNCTION core.trg_validate_order_adr_compliance();

-- driver_type must match the client type of the employer / own company
-- (hired drivers are created by the fleet owner, PM spec):
--   self_employed -> solo_carrier, company_employee -> company.
CREATE OR REPLACE FUNCTION core.trg_validate_driver_linked_client() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_client_type core.client_type_enum;
BEGIN
    IF NEW.linked_client_id IS NULL THEN
        RAISE EXCEPTION 'driver % must have linked_client_id set at creation time', NEW.driver_id;
    END IF;
    SELECT client_type INTO v_client_type FROM core.clients WHERE client_id = NEW.linked_client_id;
    IF v_client_type IS NULL THEN
        RAISE EXCEPTION 'linked_client_id % not found in clients', NEW.linked_client_id;
    END IF;
    IF NEW.driver_type = 'self_employed' AND v_client_type <> 'solo_carrier' THEN
        RAISE EXCEPTION 'self_employed driver % must link to a client with client_type=solo_carrier, got % (client %)',
            NEW.driver_id, v_client_type, NEW.linked_client_id;
    END IF;
    IF NEW.driver_type = 'company_employee' AND v_client_type <> 'company' THEN
        RAISE EXCEPTION 'company_employee driver % must link to a client with client_type=company, got % (client %)',
            NEW.driver_id, v_client_type, NEW.linked_client_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_driver_linked_client_check
    BEFORE INSERT OR UPDATE OF driver_type, linked_client_id ON core.drivers
    FOR EACH ROW EXECUTE FUNCTION core.trg_validate_driver_linked_client();

-- Delivery status changes -> PostgreSQL NOTIFY (backend forwards via WebSocket).
CREATE OR REPLACE FUNCTION core.trg_notify_delivery_status_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.delivery_status IS DISTINCT FROM OLD.delivery_status THEN
        PERFORM pg_notify('delivery_status_channel',
            json_build_object('delivery_id', NEW.delivery_id, 'order_id', NEW.order_id,
                              'delivery_status', NEW.delivery_status, 'updated_at', NEW.updated_at)::text);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_delivery_status_notify
    AFTER INSERT OR UPDATE OF delivery_status ON core.deliveries
    FOR EACH ROW EXECUTE FUNCTION core.trg_notify_delivery_status_change();

-- ----------------------------------------------------------------------------
-- 1.6. DRIVER RATING, COMPLIANCE SCORE & AUTO-BLOCK (real time)
-- ----------------------------------------------------------------------------

-- Blocks a driver automatically when avg rating < 3.20 or >= 2 fraud reports
-- (MVP: total count, not "2 in a row"; thresholds hard-coded).
CREATE OR REPLACE FUNCTION core.fn_evaluate_driver_auto_block(p_driver_id varchar) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_rating       numeric(3,2);
    v_report_count integer;
    v_reason       text := NULL;
BEGIN
    SELECT avg_customer_rating INTO v_rating
    FROM core.drivers WHERE driver_id = p_driver_id AND status <> 'inactive';
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_report_count FROM core.fraud_reports WHERE reported_driver_id = p_driver_id;

    IF v_rating < 3.20 THEN
        v_reason := 'auto_block: avg_customer_rating ' || v_rating || ' < 3.20';
    ELSIF v_report_count >= 2 THEN
        v_reason := 'auto_block: fraud_reports_count ' || v_report_count || ' >= 2';
    END IF;

    IF v_reason IS NOT NULL THEN
        UPDATE core.drivers
        SET status = 'inactive', blocked_at = CURRENT_TIMESTAMP, blocked_reason = v_reason
        WHERE driver_id = p_driver_id;
    END IF;
END;
$$;

-- Smart Skip: incident-free trips of a 100 % driver skip the 90-day recalculation.
-- Compliance = 40 % on-time + 40 % incident-free + 20 % proof-of-delivery (last 90 days).
CREATE OR REPLACE FUNCTION core.trg_update_driver_ratings() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_driver_id          varchar(32) := NEW.driver_id;
    v_curr_compliance    numeric(5,2);
    v_avg_rating         numeric(3,2);
    v_total_reviews      integer;
    v_on_time_rate       numeric;
    v_incident_free_rate numeric;
    v_pod_rate           numeric;
BEGIN
    IF v_driver_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT service_compliance_rate INTO v_curr_compliance FROM core.drivers WHERE driver_id = v_driver_id;

    IF v_curr_compliance = 100.00
       AND COALESCE(NEW.delay_minutes, 0) = 0
       AND NEW.is_driver_liable = FALSE
       AND NEW.incident_type = 'None'
       AND NEW.customer_rating_stars IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT COALESCE(ROUND(AVG(customer_rating_stars), 2), 5.00), COUNT(customer_rating_stars)
    INTO v_avg_rating, v_total_reviews
    FROM core.deliveries
    WHERE driver_id = v_driver_id AND customer_rating_stars IS NOT NULL;

    SELECT
        ROUND((COUNT(*) FILTER (WHERE actual_end_time <= planned_end_time
                                   OR (actual_end_time > planned_end_time AND is_driver_liable = FALSE)
              )::numeric / NULLIF(COUNT(*), 0)) * 100, 2),
        ROUND((COUNT(*) FILTER (WHERE is_driver_liable = FALSE)::numeric / NULLIF(COUNT(*), 0)) * 100, 2),
        ROUND((COUNT(*) FILTER (WHERE proof_of_delivery_url IS NOT NULL AND incident_type <> 'Paperwork_CMR_Error'
              )::numeric / NULLIF(COUNT(*), 0)) * 100, 2)
    INTO v_on_time_rate, v_incident_free_rate, v_pod_rate
    FROM core.deliveries
    WHERE driver_id = v_driver_id
      AND delivery_status = 'delivered'
      AND actual_end_time >= CURRENT_DATE - INTERVAL '90 days';

    UPDATE core.drivers
    SET avg_customer_rating     = v_avg_rating,
        total_reviews_count     = v_total_reviews,
        service_compliance_rate = ROUND(0.40 * COALESCE(v_on_time_rate, 100.00)
                                      + 0.40 * COALESCE(v_incident_free_rate, 100.00)
                                      + 0.20 * COALESCE(v_pod_rate, 100.00), 2),
        updated_at              = CURRENT_TIMESTAMP
    WHERE driver_id = v_driver_id;

    PERFORM core.fn_evaluate_driver_auto_block(v_driver_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_delivery_update
    AFTER INSERT OR UPDATE OF delivery_status, customer_rating_stars, is_driver_liable, incident_type, proof_of_delivery_url
    ON core.deliveries
    FOR EACH ROW EXECUTE FUNCTION core.trg_update_driver_ratings();

CREATE OR REPLACE FUNCTION core.trg_fraud_report_autoblock() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM core.fn_evaluate_driver_auto_block(NEW.reported_driver_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_fraud_report_insert
    AFTER INSERT ON core.fraud_reports
    FOR EACH ROW EXECUTE FUNCTION core.trg_fraud_report_autoblock();

-- ----------------------------------------------------------------------------
-- 1.7. COST OWNER (tenant): derive client_id and reject foreign drivers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.trg_set_cost_client_id() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_driver_client varchar(32);
BEGIN
    IF NEW.driver_id IS NOT NULL THEN
        SELECT linked_client_id INTO v_driver_client FROM core.drivers WHERE driver_id = NEW.driver_id;
    END IF;

    IF NEW.client_id IS NULL THEN
        NEW.client_id := COALESCE(
            v_driver_client,
            (SELECT owner_client_id FROM core.vehicles WHERE vehicle_id = NEW.vehicle_id),
            (SELECT dr.linked_client_id FROM core.deliveries d JOIN core.drivers dr ON dr.driver_id = d.driver_id
              WHERE d.delivery_id = NEW.delivery_id));
    END IF;

    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'Cost % has no owner: set client_id (or driver_id / vehicle_id with a known owner)', NEW.cost_id;
    END IF;
    IF v_driver_client IS NOT NULL AND v_driver_client <> NEW.client_id THEN
        RAISE EXCEPTION 'Cost %: driver % belongs to client %, not to %', NEW.cost_id, NEW.driver_id, v_driver_client, NEW.client_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_cost_client_id
    BEFORE INSERT OR UPDATE OF client_id, driver_id, vehicle_id, delivery_id ON core.costs
    FOR EACH ROW EXECUTE FUNCTION core.trg_set_cost_client_id();

-- ----------------------------------------------------------------------------
-- 1.8. SPATIAL FUNCTION & LIVE OPERATIONAL VIEWS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.build_actual_route_geometry(p_delivery_id varchar)
RETURNS geometry
LANGUAGE sql STABLE AS $$
    SELECT ST_MakeLine(location ORDER BY recorded_at)
    FROM core.delivery_track_points
    WHERE delivery_id = p_delivery_id;
$$;

CREATE OR REPLACE VIEW core.v_deliveries_analytics AS
SELECT d.delivery_id, d.order_id, d.route_id, d.driver_id, d.vehicle_id, d.delivery_status,
       d.planned_start_time, d.actual_start_time, d.planned_end_time, d.actual_end_time,
       d.planned_distance_km, d.actual_distance_km,
       (d.actual_distance_km - d.planned_distance_km) AS distance_deviation_km,
       ROUND(((d.actual_distance_km - d.planned_distance_km) / NULLIF(d.planned_distance_km, 0)) * 100, 2) AS distance_deviation_pct,
       d.delay_minutes, d.delay_status, d.delay_reason, d.incident_type, d.is_driver_liable,
       d.customer_rating_stars, d.proof_of_delivery_url, d.is_test
FROM core.deliveries d;

CREATE OR REPLACE VIEW core.v_customer_order_tracking AS
SELECT o.order_id, o.client_id, o.status AS order_status, o.match_status,
       o.origin_city, o.origin_country, o.destination_city, o.destination_country,
       o.pickup_at, o.planned_delivery_at,
       d.delivery_id, d.delivery_status, d.actual_start_time, d.actual_end_time, d.delay_minutes, d.delay_status
FROM core.orders o
LEFT JOIN core.deliveries d ON d.order_id = o.order_id;

-- Note: customer-facing finance KPIs come from the analytics star schema
-- (PART 3); the two views below are kept for back-office use.
CREATE OR REPLACE VIEW core.v_driver_net_income AS
SELECT c.driver_id, d.full_name, d.driver_type,
       SUM(c.driver_payout_eur) AS total_gross_payout_eur,
       SUM(CASE WHEN NOT c.is_private_expense THEN c.cost_amount_eur ELSE 0 END) AS corporate_operating_expenses_eur,
       SUM(CASE WHEN c.is_private_expense THEN c.cost_amount_eur ELSE 0 END) AS private_driver_expenses_eur,
       (SUM(c.driver_payout_eur) - SUM(c.cost_amount_eur)) AS net_driver_take_home_eur
FROM core.costs c
JOIN core.drivers d ON c.driver_id = d.driver_id
GROUP BY c.driver_id, d.full_name, d.driver_type;

CREATE OR REPLACE VIEW core.v_delivery_profitability AS
SELECT d.delivery_id, o.order_id, o.amount_eur AS gross_revenue_eur,
       COALESCE(SUM(c.cost_amount_eur) FILTER (WHERE NOT c.is_private_expense), 0.00) AS direct_operating_costs_eur,
       COALESCE(SUM(c.driver_payout_eur), 0.00) AS driver_reward_eur,
       (o.amount_eur
        - COALESCE(SUM(c.cost_amount_eur) FILTER (WHERE NOT c.is_private_expense), 0.00)
        - COALESCE(SUM(c.driver_payout_eur), 0.00)) AS net_gross_profit_eur,
       ROUND(((o.amount_eur
               - COALESCE(SUM(c.cost_amount_eur) FILTER (WHERE NOT c.is_private_expense), 0.00)
               - COALESCE(SUM(c.driver_payout_eur), 0.00)) / NULLIF(o.amount_eur, 0)) * 100, 2) AS gross_margin_pct
FROM core.deliveries d
JOIN core.orders o ON d.order_id = o.order_id
LEFT JOIN core.costs c ON d.delivery_id = c.delivery_id
GROUP BY d.delivery_id, o.order_id, o.amount_eur;

-- ############################################################################
-- PART 2. SCHEMAS app, billing, marketing, analytics (SaaS) + ops
-- (from 04_smartlog_platform_schema_v3.sql)
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 2.1. OPS HELPERS
-- ----------------------------------------------------------------------------

-- 2.1.1. Time-ordered UUID (RFC 9562 v7). Better B-tree locality than v4 for
--      insert-heavy tables. On PostgreSQL 18 this can be replaced by the
--      native uuidv7().
CREATE OR REPLACE FUNCTION ops.uuid_generate_v7() RETURNS uuid
LANGUAGE sql VOLATILE AS $$
    SELECT encode(
        set_bit(
            set_bit(
                overlay(
                    uuid_send(gen_random_uuid())
                    PLACING substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
                    FROM 1 FOR 6
                ),
                52, 1
            ),
            53, 1
        ),
        'hex'
    )::uuid;
$$;

-- 2.1.2. Generic updated_at maintenance (001 has none; applied to new tables here).
CREATE OR REPLACE FUNCTION ops.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

-- 2.1.3. Create monthly range partitions [p_from_month, p_to_month] for a
--      table partitioned by a DATE or TIMESTAMPTZ column. Idempotent.
CREATE OR REPLACE FUNCTION ops.ensure_monthly_partitions(
    p_parent     regclass,
    p_from_month date,
    p_to_month   date
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_month   date := date_trunc('month', p_from_month)::date;
    v_last    date := date_trunc('month', p_to_month)::date;
    v_schema  text;
    v_table   text;
    v_part    text;
    v_created integer := 0;
BEGIN
    SELECT n.nspname, c.relname INTO v_schema, v_table
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_parent;

    WHILE v_month <= v_last LOOP
        v_part := format('%s_y%sm%s', v_table, to_char(v_month, 'YYYY'), to_char(v_month, 'MM'));
        IF to_regclass(format('%I.%I', v_schema, v_part)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                v_schema, v_part, p_parent, v_month, (v_month + INTERVAL '1 month')::date
            );
            v_created := v_created + 1;
        END IF;
        v_month := (v_month + INTERVAL '1 month')::date;
    END LOOP;
    RETURN v_created;
END;
$$;

-- 2.1.4. Retention by partition drop (cheap) instead of DELETE (bloat, vacuum).
CREATE OR REPLACE FUNCTION ops.drop_monthly_partitions_older_than(
    p_parent      regclass,
    p_keep_months integer
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_cutoff  date := (date_trunc('month', CURRENT_DATE) - make_interval(months => p_keep_months))::date;
    v_rec     record;
    v_dropped integer := 0;
BEGIN
    FOR v_rec IN
        SELECT n.nspname AS schema_name, c.relname AS part_name
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE i.inhparent = p_parent
          AND c.relname ~ '_y[0-9]{4}m[0-9]{2}$'
          AND to_date(substring(c.relname FROM '_y([0-9]{4})m') || substring(c.relname FROM 'm([0-9]{2})$') || '01', 'YYYYMMDD') < v_cutoff
    LOOP
        EXECUTE format('DROP TABLE %I.%I', v_rec.schema_name, v_rec.part_name);
        v_dropped := v_dropped + 1;
    END LOOP;
    RETURN v_dropped;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2.2. ENUM TYPES (only for stable state machines; changeable lists are
--    lookup tables so that values can be added / retired without DDL)
-- ----------------------------------------------------------------------------

CREATE TYPE app.account_type_enum AS ENUM (
    'solo_carrier',        -- self-employed driver, pays a subscription
    'fleet_company',       -- company with hired drivers, pays a subscription
    'shipper_company',     -- business that publishes freight, free
    'shipper_individual'   -- private person that publishes freight, free
);

CREATE TYPE app.lifecycle_stage_enum AS ENUM (
    'registered',          -- signed up, e-mail not yet confirmed
    'verified',            -- e-mail confirmed with one-time code
    'onboarded',           -- profile / company data / first vehicle completed
    'activated',           -- first real value (see metric 'activation')
    'trialing',            -- free trial running
    'trial_expired',       -- trial ended without payment
    'paying',              -- has a paid, live subscription
    'churned'              -- was paying, subscription ended
);

CREATE TYPE app.lifecycle_event_enum AS ENUM (
    'signed_up', 'email_verified', 'onboarding_completed', 'activated',
    'trial_started', 'trial_expired', 'first_payment', 'churned', 'reactivated'
);

CREATE TYPE app.user_status_enum AS ENUM (
    'pending_verification', 'active', 'suspended', 'deleted'
);

CREATE TYPE app.membership_role_enum AS ENUM (
    'owner',        -- legal owner of the account, manages billing
    'admin',        -- full access except ownership transfer
    'dispatcher',   -- manages orders and drivers
    'accountant',   -- invoices, closing orders ('closed' status in core)
    'driver',       -- hired or self-employed driver (e-POD, statuses)
    'viewer'        -- read-only
);

CREATE TYPE app.membership_status_enum AS ENUM ('invited', 'active', 'revoked');

CREATE TYPE app.otp_channel_enum AS ENUM ('email', 'sms');

CREATE TYPE app.otp_purpose_enum AS ENUM (
    'signup',            -- confirm e-mail during registration
    'login',             -- passwordless login
    'email_change',      -- confirm a new e-mail address
    'invite_accept',     -- hired driver / staff accepts an invitation
    'account_deletion'   -- confirm GDPR erasure request
);

CREATE TYPE app.client_platform_enum AS ENUM (
    'desktop_web', 'mobile_web', 'ios_app', 'android_app', 'tablet_app'
);

CREATE TYPE app.consent_type_enum AS ENUM (
    'terms_of_service', 'privacy_policy', 'marketing_email',
    'analytics_cookies', 'marketing_cookies'
);

CREATE TYPE app.consent_method_enum AS ENUM (
    'signup_checkbox', 'double_opt_in', 'cookie_banner', 'settings_page', 'support_request'
);

CREATE TYPE app.audit_actor_enum AS ENUM ('user', 'staff', 'system', 'webhook');

-- Paid term: 1, 3, 6 or 12 months.
CREATE TYPE billing.billing_interval_enum AS ENUM ('month', 'quarter', 'half_year', 'year');

CREATE OR REPLACE FUNCTION billing.interval_months(p_interval billing.billing_interval_enum) RETURNS smallint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE p_interval WHEN 'month' THEN 1 WHEN 'quarter' THEN 3 WHEN 'half_year' THEN 6 WHEN 'year' THEN 12 END::smallint;
$$;

CREATE TYPE billing.subscription_status_enum AS ENUM (
    'incomplete',   -- created, first payment not confirmed yet
    'trialing',
    'active',
    'past_due',     -- renewal payment failed, dunning in progress
    'paused',
    'cancelled'
);

CREATE TYPE billing.subscription_event_enum AS ENUM (
    'trial_started', 'trial_converted', 'trial_expired', 'new_paid',
    'upgrade', 'downgrade', 'billing_interval_change',
    'payment_failed', 'payment_recovered',
    'cancellation_scheduled', 'cancellation_revoked',
    'churned', 'reactivated'
);

CREATE TYPE billing.invoice_status_enum AS ENUM ('draft', 'open', 'paid', 'uncollectible', 'void');

CREATE TYPE billing.tax_treatment_enum AS ENUM (
    'domestic_standard',   -- seller country VAT (DE 19 %)
    'reverse_charge_eu',   -- B2B, other EU country, valid VAT ID -> 0 %
    'export_non_eu',       -- outside the EU
    'exempt'               -- other legal exemption (document the reason)
);

CREATE TYPE billing.invoice_line_type_enum AS ENUM (
    'subscription', 'proration', 'discount', 'add_on', 'one_off'
);

CREATE TYPE billing.payment_status_enum AS ENUM (
    'pending', 'succeeded', 'failed', 'refunded', 'partially_refunded'
);

CREATE TYPE billing.credit_note_reason_enum AS ENUM (
    'customer_request', 'duplicate_charge', 'service_issue', 'fraud', 'billing_error', 'other'
);

CREATE TYPE billing.discount_type_enum AS ENUM ('percentage', 'fixed_amount');

CREATE TYPE billing.webhook_status_enum AS ENUM ('received', 'processed', 'failed', 'ignored');

CREATE TYPE billing.feature_value_type_enum AS ENUM ('boolean', 'limit');

CREATE TYPE analytics.platform_cost_category_enum AS ENUM (
    'infrastructure', 'ai_inference', 'email_sms', 'support',
    'third_party_software', 'other'
);

-- ----------------------------------------------------------------------------
-- 2.3. SCHEMA app — IDENTITY, ACCOUNTS, LIFECYCLE
-- ----------------------------------------------------------------------------

-- 2.3.1. Accounts: one row = one tenant (paying carrier or free shipper).
--      Milestone timestamps are written ONLY by the lifecycle trigger (3.9).
CREATE TABLE app.accounts (
    account_id                uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    account_number            varchar(20) NOT NULL UNIQUE,              -- ACC-2026-000101, shown on invoices / support
    account_type              app.account_type_enum NOT NULL,
    is_billable               boolean GENERATED ALWAYS AS (account_type IN ('solo_carrier', 'fleet_company')) STORED,
    client_id                 varchar(32) UNIQUE
                              REFERENCES core.clients(client_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    legal_name                varchar(150) NOT NULL,
    country_code              char(2) NOT NULL
                              REFERENCES core.supported_countries(country_code) ON UPDATE CASCADE,
    vat_id                    varchar(30),
    vat_id_validated_at       timestamptz,                               -- VIES check, required for reverse charge
    tax_number                varchar(30),
    billing_email             citext,
    currency_code             char(3) NOT NULL DEFAULT 'EUR' CHECK (currency_code ~ '^[A-Z]{3}$'),
    locale                    varchar(10) NOT NULL DEFAULT 'de-DE',
    timezone                  varchar(50) NOT NULL DEFAULT 'Europe/Berlin',
    declared_fleet_size       integer CHECK (declared_fleet_size IS NULL OR declared_fleet_size >= 0),
    fleet_size_band           varchar(10) GENERATED ALWAYS AS (
                                  CASE
                                      WHEN declared_fleet_size IS NULL THEN NULL
                                      WHEN declared_fleet_size <= 1  THEN 'solo'
                                      WHEN declared_fleet_size <= 5  THEN 'micro'
                                      WHEN declared_fleet_size <= 20 THEN 'small'
                                      WHEN declared_fleet_size <= 50 THEN 'medium'
                                      ELSE 'large'
                                  END) STORED,

    -- Referral programme
    referral_code             varchar(20) UNIQUE,
    referred_by_account_id    uuid REFERENCES app.accounts(account_id) ON DELETE SET NULL,

    -- Customer lifecycle (maintained by trigger from account_lifecycle_events)
    lifecycle_stage           app.lifecycle_stage_enum NOT NULL DEFAULT 'registered',
    signed_up_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cohort_month              date GENERATED ALWAYS AS (date_trunc('month', signed_up_at AT TIME ZONE 'UTC')::date) STORED,
    email_verified_at         timestamptz,
    onboarding_completed_at   timestamptz,
    activated_at              timestamptz,
    trial_started_at          timestamptz,
    first_paid_at             timestamptz,                               -- conversion moment: first succeeded payment
    churned_at                timestamptz,                               -- latest churn
    last_reactivated_at       timestamptz,

    -- Payment snapshot of the paying client (maintained by trigger from
    -- billing.payments). ONLY the name of the payment system is stored —
    -- never card numbers, IBAN or other payment credentials (GDPR, PCI DSS).
    payment_system_code       varchar(30),                               -- system of the last successful payment (FK below)
    last_paid_at              timestamptz,                               -- date and time of the last successful payment
    last_paid_period_months   smallint CHECK (last_paid_period_months IS NULL OR last_paid_period_months IN (1, 3, 6, 12)),
    paid_until                date,                                      -- access paid up to and including this day

    is_test                   boolean NOT NULL DEFAULT FALSE,
    anonymized_at             timestamptz,                               -- GDPR erasure (row kept for invoices)
    created_at                timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_accounts_vat_validation CHECK (vat_id_validated_at IS NULL OR vat_id IS NOT NULL),
    CONSTRAINT chk_accounts_no_self_referral CHECK (referred_by_account_id IS DISTINCT FROM account_id)
);

COMMENT ON COLUMN app.accounts.first_paid_at IS
    'Moment the account became a paying customer: first succeeded payment. Set once by trigger.';
COMMENT ON COLUMN app.accounts.client_id IS
    'Link to core.clients. NULL until onboarding creates the logistics counterparty.';

-- 2.3.1.1. account_type must match core.clients.client_type
--        (core 'company' is used both by shippers and fleet carriers; the
--        account type is what disambiguates them).
CREATE OR REPLACE FUNCTION app.trg_validate_account_client_type() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_client_type text;
BEGIN
    IF NEW.client_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT client_type::text INTO v_client_type FROM core.clients WHERE client_id = NEW.client_id;

    IF (NEW.account_type = 'solo_carrier'       AND v_client_type <> 'solo_carrier')
    OR (NEW.account_type = 'fleet_company'      AND v_client_type <> 'company')
    OR (NEW.account_type = 'shipper_company'    AND v_client_type <> 'company')
    OR (NEW.account_type = 'shipper_individual' AND v_client_type <> 'individual') THEN
        RAISE EXCEPTION 'account_type % does not match core.clients.client_type % (client %)',
            NEW.account_type, v_client_type, NEW.client_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_account_client_type
    BEFORE INSERT OR UPDATE OF account_type, client_id ON app.accounts
    FOR EACH ROW EXECUTE FUNCTION app.trg_validate_account_client_type();

-- 2.3.2. Users: one row = one person with a login. No password is stored.
--      The same person keeps one user across accounts (see memberships).
CREATE TABLE app.users (
    user_id               uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    email                 citext NOT NULL UNIQUE,
    email_verified_at     timestamptz,
    phone_e164            varchar(16) CHECK (phone_e164 IS NULL OR phone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
    phone_verified_at     timestamptz,
    full_name             varchar(100) NOT NULL,
    preferred_language    varchar(5) NOT NULL DEFAULT 'de',
    timezone              varchar(50) NOT NULL DEFAULT 'Europe/Berlin',
    status                app.user_status_enum NOT NULL DEFAULT 'pending_verification',
    driver_id             varchar(32) UNIQUE
                          REFERENCES core.drivers(driver_id) ON UPDATE CASCADE ON DELETE SET NULL,
    signup_platform       app.client_platform_enum,
    security_stamp        uuid NOT NULL DEFAULT gen_random_uuid(),       -- rotate to log out all sessions
    last_login            timestamptz,                                   -- updated on login, not per request
    is_staff              boolean NOT NULL DEFAULT FALSE,                -- SmartLog employees (Django admin)
    is_superuser          boolean NOT NULL DEFAULT FALSE,
    anonymized_at         timestamptz,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_users_active_requires_verified_email CHECK (
        status <> 'active' OR email_verified_at IS NOT NULL
    ),
    CONSTRAINT chk_users_superuser_is_staff CHECK (NOT is_superuser OR is_staff)
);

-- 2.3.3. Memberships: user <-> account with a role. Covers the PM flow
--      "owner adds a hired driver" (status 'invited' until the driver
--      confirms the code) and multi-account users (accountant of 2 fleets).
CREATE TABLE app.account_memberships (
    membership_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE RESTRICT,
    user_id               uuid NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    role                  app.membership_role_enum NOT NULL,
    status                app.membership_status_enum NOT NULL DEFAULT 'invited',
    invited_by_user_id    uuid REFERENCES app.users(user_id) ON DELETE SET NULL,
    invited_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    accepted_at           timestamptz,
    revoked_at            timestamptz,
    revoke_reason         varchar(30) CHECK (revoke_reason IS NULL OR revoke_reason IN ('left_by_user', 'removed_by_owner', 'account_closed')),
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_membership_account_user UNIQUE (account_id, user_id),
    CONSTRAINT chk_membership_state CHECK (
        (status = 'invited' AND accepted_at IS NULL AND revoked_at IS NULL) OR
        (status = 'active'  AND accepted_at IS NOT NULL AND revoked_at IS NULL) OR
        (status = 'revoked' AND revoked_at IS NOT NULL AND revoke_reason IS NOT NULL)
    )
);

CREATE UNIQUE INDEX uq_membership_one_active_owner
    ON app.account_memberships(account_id) WHERE role = 'owner' AND status = 'active';
CREATE INDEX idx_memberships_user ON app.account_memberships(user_id) WHERE status <> 'revoked';

-- 2.3.4. One-time codes (e-mail OTP; SMS kept for the PM "owner adds driver" flow).
--      Only an HMAC-SHA256 of the code (keyed with the server secret) is
--      stored. Rate limiting per IP lives in the infrastructure layer
--      (owner decision 2026-09-23); per-address limits are enforced here
--      by the backend through idx_otp_recent.
CREATE TABLE app.auth_challenges (
    challenge_id          uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    user_id               uuid NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    channel               app.otp_channel_enum NOT NULL DEFAULT 'email',
    purpose               app.otp_purpose_enum NOT NULL,
    destination           varchar(254) NOT NULL,                        -- e-mail or E.164 phone the code was sent to
    code_hash             char(64) NOT NULL,                            -- hex HMAC-SHA256, never the code
    expires_at            timestamptz NOT NULL,
    attempts_count        smallint NOT NULL DEFAULT 0 CHECK (attempts_count >= 0),
    max_attempts          smallint NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 10),
    consumed_at           timestamptz,
    invalidated_at        timestamptz,                                  -- superseded by a newer code
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_otp_lifetime CHECK (expires_at > created_at AND expires_at <= created_at + INTERVAL '30 minutes'),
    CONSTRAINT chk_otp_attempts CHECK (attempts_count <= max_attempts)
);

CREATE INDEX idx_otp_recent ON app.auth_challenges(destination, purpose, created_at DESC);
CREATE INDEX idx_otp_open_by_user ON app.auth_challenges(user_id, purpose)
    WHERE consumed_at IS NULL AND invalidated_at IS NULL;

-- 2.3.5. Devices: one row = one app installation / browser of a user.
--      Several devices per user (phone + office PC), push token per device.
CREATE TABLE app.user_devices (
    device_id             uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    user_id               uuid NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    installation_id       varchar(100) NOT NULL,                        -- generated by the client on first start
    platform              app.client_platform_enum NOT NULL,
    os_name               varchar(30),
    os_version            varchar(30),
    app_version           varchar(20),
    device_brand          varchar(50),                                  -- NULL allowed: browsers often hide it
    push_provider         varchar(10) CHECK (push_provider IS NULL OR push_provider IN ('fcm', 'apns', 'webpush')),
    push_token            varchar(512),
    first_seen_at         timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, -- throttled update (<= 1 per day)
    revoked_at            timestamptz,
    CONSTRAINT uq_device_user_installation UNIQUE (user_id, installation_id)
);

-- 2.3.6. Sessions: refresh tokens for web and mobile clients.
--      Deliberately NO last_activity_at: activity goes to user_activity_daily.
CREATE TABLE app.user_sessions (
    session_id            uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    user_id               uuid NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    device_id             uuid REFERENCES app.user_devices(device_id) ON DELETE SET NULL,
    refresh_token_hash    char(64) NOT NULL UNIQUE,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at            timestamptz NOT NULL,
    revoked_at            timestamptz,
    revoke_reason         varchar(30),
    CONSTRAINT chk_session_expiry CHECK (expires_at > created_at)
);

CREATE INDEX idx_sessions_user_live ON app.user_sessions(user_id) WHERE revoked_at IS NULL;

-- 2.3.7. Daily activity (DAU/WAU/MAU, stickiness, health score).
--      Backend keeps "seen" flags in memory/Redis and upserts at most
--      once per user per 15 minutes. Partitioned by month.
CREATE TABLE app.user_activity_daily (
    activity_date         date NOT NULL,
    user_id               uuid NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE CASCADE,
    platform              app.client_platform_enum NOT NULL,
    first_seen_at         timestamptz NOT NULL,
    last_seen_at          timestamptz NOT NULL,
    flush_count           integer NOT NULL DEFAULT 1 CHECK (flush_count >= 1),
    PRIMARY KEY (activity_date, user_id, platform)
) PARTITION BY RANGE (activity_date);

CREATE INDEX idx_activity_account_date ON app.user_activity_daily(account_id, activity_date);

-- 2.3.8. Consent log (GDPR Art. 7: consent must be provable; TDDDG §25 for
--      cookies; UWG §7 double opt-in for marketing e-mail). Append-only:
--      a withdrawal is a new row with granted = FALSE.
CREATE TABLE app.consent_records (
    consent_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id               uuid REFERENCES app.users(user_id) ON DELETE SET NULL,
    account_id            uuid REFERENCES app.accounts(account_id) ON DELETE SET NULL,
    consent_type          app.consent_type_enum NOT NULL,
    granted               boolean NOT NULL,
    document_version      varchar(20) NOT NULL,                        -- version of the policy text shown
    method                app.consent_method_enum NOT NULL,
    requested_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    confirmed_at          timestamptz,                                  -- DOI click / code confirmation
    source_platform       app.client_platform_enum,
    CONSTRAINT chk_consent_subject CHECK (user_id IS NOT NULL OR account_id IS NOT NULL),
    CONSTRAINT chk_consent_doi CHECK (
        NOT (consent_type = 'marketing_email' AND granted) OR confirmed_at IS NOT NULL
    )
);

CREATE INDEX idx_consents_user_type ON app.consent_records(user_id, consent_type, requested_at DESC);

-- 2.3.9. Customer lifecycle events: the single source for the funnel
--      "sign-up -> e-mail verified -> onboarded -> activated -> trial ->
--      first payment -> churn / reactivation". Append-only.
CREATE TABLE app.account_lifecycle_events (
    event_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE CASCADE,
    event_type            app.lifecycle_event_enum NOT NULL,
    occurred_at           timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    user_id               uuid REFERENCES app.users(user_id) ON DELETE SET NULL,
    subscription_id       uuid,                                         -- FK added after billing.subscriptions
    source                varchar(20) NOT NULL DEFAULT 'backend'
                          CHECK (source IN ('backend', 'db_trigger', 'nightly_job', 'webhook', 'admin')),
    metadata              jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- One-time milestones can happen only once per account (idempotent inserts:
-- INSERT ... ON CONFLICT DO NOTHING).
CREATE UNIQUE INDEX uq_lifecycle_one_time_events
    ON app.account_lifecycle_events(account_id, event_type)
    WHERE event_type IN ('signed_up', 'email_verified', 'onboarding_completed', 'activated',
                         'trial_started', 'first_payment');
CREATE INDEX idx_lifecycle_type_time ON app.account_lifecycle_events(event_type, occurred_at);

CREATE OR REPLACE FUNCTION app.lifecycle_stage_rank(p_stage app.lifecycle_stage_enum) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_stage
        WHEN 'registered'    THEN 1
        WHEN 'verified'      THEN 2
        WHEN 'onboarded'     THEN 3
        WHEN 'activated'     THEN 4
        WHEN 'trialing'      THEN 5
        WHEN 'trial_expired' THEN 5
        WHEN 'paying'        THEN 6
        WHEN 'churned'       THEN 6
    END::smallint;
$$;

-- Applies a lifecycle event to the account: sets the milestone timestamp
-- (first occurrence only) and moves the stage forward, never backwards,
-- except for the explicit churn / reactivation transitions.
CREATE OR REPLACE FUNCTION app.trg_apply_lifecycle_event() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_current app.lifecycle_stage_enum;
    v_target  app.lifecycle_stage_enum;
BEGIN
    SELECT lifecycle_stage INTO v_current FROM app.accounts WHERE account_id = NEW.account_id FOR UPDATE;

    v_target := CASE NEW.event_type
        WHEN 'email_verified'       THEN 'verified'
        WHEN 'onboarding_completed' THEN 'onboarded'
        WHEN 'activated'            THEN 'activated'
        WHEN 'trial_started'        THEN 'trialing'
        ELSE NULL
    END::app.lifecycle_stage_enum;

    UPDATE app.accounts a SET
        email_verified_at       = CASE WHEN NEW.event_type = 'email_verified'       THEN COALESCE(a.email_verified_at, NEW.occurred_at)       ELSE a.email_verified_at END,
        onboarding_completed_at = CASE WHEN NEW.event_type = 'onboarding_completed' THEN COALESCE(a.onboarding_completed_at, NEW.occurred_at) ELSE a.onboarding_completed_at END,
        activated_at            = CASE WHEN NEW.event_type = 'activated'            THEN COALESCE(a.activated_at, NEW.occurred_at)            ELSE a.activated_at END,
        trial_started_at        = CASE WHEN NEW.event_type = 'trial_started'        THEN COALESCE(a.trial_started_at, NEW.occurred_at)        ELSE a.trial_started_at END,
        first_paid_at           = CASE WHEN NEW.event_type = 'first_payment'        THEN COALESCE(a.first_paid_at, NEW.occurred_at)           ELSE a.first_paid_at END,
        churned_at              = CASE WHEN NEW.event_type = 'churned'              THEN NEW.occurred_at                                      ELSE a.churned_at END,
        last_reactivated_at     = CASE WHEN NEW.event_type = 'reactivated'          THEN NEW.occurred_at                                      ELSE a.last_reactivated_at END,
        lifecycle_stage = CASE
            WHEN NEW.event_type IN ('first_payment', 'reactivated') THEN 'paying'::app.lifecycle_stage_enum
            WHEN NEW.event_type = 'churned'                           THEN 'churned'::app.lifecycle_stage_enum
            WHEN NEW.event_type = 'trial_expired' AND v_current = 'trialing' THEN 'trial_expired'::app.lifecycle_stage_enum
            WHEN v_target IS NOT NULL
                 AND v_current NOT IN ('paying', 'churned')
                 AND app.lifecycle_stage_rank(v_target) > app.lifecycle_stage_rank(v_current) THEN v_target
            ELSE a.lifecycle_stage
        END
    WHERE a.account_id = NEW.account_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_lifecycle_event
    AFTER INSERT ON app.account_lifecycle_events
    FOR EACH ROW EXECUTE FUNCTION app.trg_apply_lifecycle_event();

-- 2.3.9.1. 'signed_up' is written automatically when the account is created.
CREATE OR REPLACE FUNCTION app.trg_account_signed_up() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO app.account_lifecycle_events (account_id, event_type, occurred_at, source)
    VALUES (NEW.account_id, 'signed_up', NEW.signed_up_at, 'db_trigger')
    ON CONFLICT (account_id, event_type)
        WHERE event_type IN ('signed_up', 'email_verified', 'onboarding_completed', 'activated', 'trial_started', 'first_payment')
    DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_account_insert_signed_up
    AFTER INSERT ON app.accounts
    FOR EACH ROW EXECUTE FUNCTION app.trg_account_signed_up();

-- 2.3.9.2. 'email_verified' is written when the OWNER confirms the e-mail code.
CREATE OR REPLACE FUNCTION app.trg_user_email_verified() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.email_verified_at IS NULL AND NEW.email_verified_at IS NOT NULL THEN
        INSERT INTO app.account_lifecycle_events (account_id, event_type, occurred_at, user_id, source)
        SELECT m.account_id, 'email_verified', NEW.email_verified_at, NEW.user_id, 'db_trigger'
        FROM app.account_memberships m
        WHERE m.user_id = NEW.user_id AND m.role = 'owner' AND m.status <> 'revoked'
        ON CONFLICT (account_id, event_type)
            WHERE event_type IN ('signed_up', 'email_verified', 'onboarding_completed', 'activated', 'trial_started', 'first_payment')
        DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_user_email_verified
    AFTER UPDATE OF email_verified_at ON app.users
    FOR EACH ROW EXECUTE FUNCTION app.trg_user_email_verified();

-- 2.3.10. Audit log (security, GoBD traceability of billing changes).
--       Partitioned by month; retention by partition drop.
CREATE TABLE app.audit_log (
    audit_id              bigint GENERATED ALWAYS AS IDENTITY,
    occurred_at           timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    actor_type            app.audit_actor_enum NOT NULL,
    actor_user_id         uuid,                                         -- no FK: log must survive user anonymisation
    account_id            uuid,
    action                varchar(60) NOT NULL,                         -- 'subscription.plan_changed', 'member.removed'
    entity_type           varchar(60) NOT NULL,
    entity_id             varchar(64) NOT NULL,
    old_values            jsonb,
    new_values            jsonb,
    request_id            varchar(64),
    PRIMARY KEY (audit_id, occurred_at)
) PARTITION BY RANGE (occurred_at);

CREATE INDEX idx_audit_account_time ON app.audit_log(account_id, occurred_at);
CREATE INDEX idx_audit_entity ON app.audit_log(entity_type, entity_id);

-- ----------------------------------------------------------------------------
-- 2.4. SCHEMA billing — PLANS, PRICES, ENTITLEMENTS, SUBSCRIPTIONS
-- ----------------------------------------------------------------------------

CREATE TABLE billing.plans (
    plan_code             varchar(32) PRIMARY KEY,                      -- PLAN-SOLO, PLAN-FLEET-SMB
    plan_name             varchar(100) NOT NULL,
    target_account_type   app.account_type_enum NOT NULL
                          CHECK (target_account_type IN ('solo_carrier', 'fleet_company')),
    tier_rank             smallint NOT NULL,                            -- orders plans for upgrade/downgrade reports
    is_public             boolean NOT NULL DEFAULT TRUE,
    is_active             boolean NOT NULL DEFAULT TRUE,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Versioned prices: a price change is a NEW row, history stays intact.
CREATE TABLE billing.plan_prices (
    price_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_code             varchar(32) NOT NULL REFERENCES billing.plans(plan_code) ON UPDATE CASCADE,
    billing_interval      billing.billing_interval_enum NOT NULL,
    currency_code         char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
    country_code          char(2) REFERENCES core.supported_countries(country_code) ON UPDATE CASCADE, -- NULL = all countries
    unit_amount           numeric(12,2) NOT NULL CHECK (unit_amount >= 0),               -- net, per interval
    mrr_amount            numeric(12,4) GENERATED ALWAYS AS (
                              unit_amount / billing.interval_months(billing_interval)
                          ) STORED,
    stripe_price_id       varchar(100) UNIQUE,
    valid_from            date NOT NULL,
    valid_to              date,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_price_validity CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE UNIQUE INDEX uq_plan_price_current
    ON billing.plan_prices(plan_code, billing_interval, currency_code, COALESCE(country_code, '--'))
    WHERE valid_to IS NULL;

CREATE TABLE billing.features (
    feature_code          varchar(40) PRIMARY KEY,                      -- max_vehicles, api_access, ai_assistant_queries
    feature_name          varchar(100) NOT NULL,
    value_type            billing.feature_value_type_enum NOT NULL,
    unit                  varchar(30),                                  -- vehicles, users, queries_per_month
    description           text
);

-- Plan -> feature -> limit. A new feature is a new row, not ALTER TABLE.
CREATE TABLE billing.plan_entitlements (
    plan_code             varchar(32) NOT NULL REFERENCES billing.plans(plan_code) ON UPDATE CASCADE,
    feature_code          varchar(40) NOT NULL REFERENCES billing.features(feature_code) ON UPDATE CASCADE,
    is_enabled            boolean NOT NULL DEFAULT TRUE,
    limit_value           integer CHECK (limit_value IS NULL OR limit_value >= 0), -- NULL = unlimited
    PRIMARY KEY (plan_code, feature_code)
);

CREATE TABLE billing.churn_reasons (
    reason_code           varchar(40) PRIMARY KEY,
    reason_label          varchar(100) NOT NULL,
    is_voluntary          boolean NOT NULL,
    is_active             boolean NOT NULL DEFAULT TRUE
);

-- Current state of a subscription. Price and MRR are SNAPSHOTS taken when
-- the price was assigned, so later price-list changes never rewrite history.
CREATE TABLE billing.subscriptions (
    subscription_id       uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE RESTRICT,
    plan_code             varchar(32) NOT NULL REFERENCES billing.plans(plan_code) ON UPDATE CASCADE,
    price_id              bigint NOT NULL REFERENCES billing.plan_prices(price_id),
    status                billing.subscription_status_enum NOT NULL DEFAULT 'incomplete',
    billing_interval      billing.billing_interval_enum NOT NULL,
    currency_code         char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
    quantity              integer NOT NULL DEFAULT 1 CHECK (quantity >= 1),
    unit_amount           numeric(12,2) NOT NULL CHECK (unit_amount >= 0),               -- snapshot, net, after recurring discount
    mrr_amount            numeric(12,4) GENERATED ALWAYS AS (
                              unit_amount * quantity / billing.interval_months(billing_interval)
                          ) STORED,
    trial_start_at        timestamptz,
    trial_end_at          timestamptz,
    current_period_start  timestamptz,
    current_period_end    timestamptz,
    cancel_at_period_end  boolean NOT NULL DEFAULT FALSE,
    cancel_requested_at   timestamptz,
    ended_at              timestamptz,
    churn_reason_code     varchar(40) REFERENCES billing.churn_reasons(reason_code),
    churn_feedback        text,
    stripe_subscription_id varchar(100) UNIQUE,
    stripe_customer_id    varchar(100),
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_sub_period CHECK (current_period_end IS NULL OR current_period_end > current_period_start),
    CONSTRAINT chk_sub_trial CHECK (trial_end_at IS NULL OR trial_end_at > trial_start_at),
    CONSTRAINT chk_sub_ended CHECK ((status = 'cancelled') = (ended_at IS NOT NULL))
);

-- One live subscription per account.
CREATE UNIQUE INDEX uq_subscription_one_live_per_account
    ON billing.subscriptions(account_id)
    WHERE status IN ('incomplete', 'trialing', 'active', 'past_due', 'paused');
CREATE INDEX idx_subscriptions_status ON billing.subscriptions(status);

ALTER TABLE app.account_lifecycle_events
    ADD CONSTRAINT fk_lifecycle_subscription
    FOREIGN KEY (subscription_id) REFERENCES billing.subscriptions(subscription_id) ON DELETE SET NULL;

-- 2.4.1. Subscriptions may only belong to billable accounts, and the plan
--      must target the account type.
CREATE OR REPLACE FUNCTION billing.trg_validate_subscription() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_account_type app.account_type_enum;
    v_plan_target  app.account_type_enum;
    v_price_plan   varchar(32);
    v_price_intv   billing.billing_interval_enum;
    v_price_curr   char(3);
BEGIN
    SELECT account_type INTO v_account_type FROM app.accounts WHERE account_id = NEW.account_id;
    SELECT target_account_type INTO v_plan_target FROM billing.plans WHERE plan_code = NEW.plan_code;
    SELECT plan_code, billing_interval, currency_code INTO v_price_plan, v_price_intv, v_price_curr
    FROM billing.plan_prices WHERE price_id = NEW.price_id;

    IF v_account_type NOT IN ('solo_carrier', 'fleet_company') THEN
        RAISE EXCEPTION 'Account % (%) is not billable; shippers use the platform free of charge',
            NEW.account_id, v_account_type;
    END IF;
    IF v_plan_target <> v_account_type THEN
        RAISE EXCEPTION 'Plan % targets %, but account % is %', NEW.plan_code, v_plan_target, NEW.account_id, v_account_type;
    END IF;
    IF v_price_plan <> NEW.plan_code OR v_price_intv <> NEW.billing_interval OR v_price_curr <> NEW.currency_code THEN
        RAISE EXCEPTION 'price_id % (%/%/%) does not match subscription plan/interval/currency (%/%/%)',
            NEW.price_id, v_price_plan, v_price_intv, v_price_curr, NEW.plan_code, NEW.billing_interval, NEW.currency_code;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_subscription_validate
    BEFORE INSERT OR UPDATE OF account_id, plan_code, price_id, billing_interval, currency_code ON billing.subscriptions
    FOR EACH ROW EXECUTE FUNCTION billing.trg_validate_subscription();

-- 2.4.2. Subscription event log (MRR movement audit trail). Append-only.
--      MRR counted as recurring revenue only in 'active' and 'past_due'.
CREATE TABLE billing.subscription_events (
    event_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id       uuid NOT NULL REFERENCES billing.subscriptions(subscription_id) ON DELETE RESTRICT,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE RESTRICT,
    event_type            billing.subscription_event_enum NOT NULL,
    previous_plan_code    varchar(32),
    new_plan_code         varchar(32),
    previous_mrr_amount   numeric(12,4) NOT NULL DEFAULT 0,
    new_mrr_amount        numeric(12,4) NOT NULL DEFAULT 0,
    mrr_delta_amount      numeric(12,4) GENERATED ALWAYS AS (new_mrr_amount - previous_mrr_amount) STORED,
    currency_code         char(3) NOT NULL,
    reason_code           varchar(40) REFERENCES billing.churn_reasons(reason_code),
    occurred_at           timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_sub_events_account_time ON billing.subscription_events(account_id, occurred_at);
CREATE INDEX idx_sub_events_type_time ON billing.subscription_events(event_type, occurred_at);

CREATE OR REPLACE FUNCTION billing.trg_log_subscription_change() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_old_paying boolean;
    v_new_paying boolean;
    v_old_mrr    numeric(12,4) := 0;
    v_new_mrr    numeric(12,4);
    v_now        timestamptz := CURRENT_TIMESTAMP;
    v_new_kind   billing.subscription_event_enum;
BEGIN
    v_new_paying := NEW.status IN ('active', 'past_due');
    v_new_mrr    := CASE WHEN v_new_paying THEN NEW.mrr_amount ELSE 0 END;

    -- A first paid start is 'new_paid'; for an account that churned before it is 'reactivated'.
    v_new_kind := CASE
        WHEN EXISTS (SELECT 1 FROM app.accounts WHERE account_id = NEW.account_id AND lifecycle_stage = 'churned')
        THEN 'reactivated' ELSE 'new_paid' END::billing.subscription_event_enum;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status = 'trialing' THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, new_plan_code, currency_code, occurred_at)
            VALUES (NEW.subscription_id, NEW.account_id, 'trial_started', NEW.plan_code, NEW.currency_code, COALESCE(NEW.trial_start_at, v_now));
            INSERT INTO app.account_lifecycle_events (account_id, event_type, occurred_at, subscription_id, source)
            VALUES (NEW.account_id, 'trial_started', COALESCE(NEW.trial_start_at, v_now), NEW.subscription_id, 'db_trigger')
            ON CONFLICT (account_id, event_type)
                WHERE event_type IN ('signed_up', 'email_verified', 'onboarding_completed', 'activated', 'trial_started', 'first_payment')
            DO NOTHING;
        ELSIF v_new_paying THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, new_plan_code, new_mrr_amount, currency_code)
            VALUES (NEW.subscription_id, NEW.account_id, v_new_kind, NEW.plan_code, v_new_mrr, NEW.currency_code);
        END IF;
        RETURN NEW;
    END IF;

    v_old_paying := OLD.status IN ('active', 'past_due');
    v_old_mrr    := CASE WHEN v_old_paying THEN OLD.mrr_amount ELSE 0 END;

    -- Status transitions
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        IF OLD.status = 'trialing' AND v_new_paying THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, previous_plan_code, new_plan_code, new_mrr_amount, currency_code)
            VALUES (NEW.subscription_id, NEW.account_id, 'trial_converted', OLD.plan_code, NEW.plan_code, v_new_mrr, NEW.currency_code);

        ELSIF OLD.status = 'incomplete' AND v_new_paying THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, new_plan_code, new_mrr_amount, currency_code)
            VALUES (NEW.subscription_id, NEW.account_id, v_new_kind, NEW.plan_code, v_new_mrr, NEW.currency_code);

        ELSIF OLD.status = 'trialing' AND NEW.status = 'cancelled' THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, previous_plan_code, currency_code, reason_code)
            VALUES (NEW.subscription_id, NEW.account_id, 'trial_expired', OLD.plan_code, NEW.currency_code, NEW.churn_reason_code);
            INSERT INTO app.account_lifecycle_events (account_id, event_type, subscription_id, source)
            VALUES (NEW.account_id, 'trial_expired', NEW.subscription_id, 'db_trigger');

        ELSIF OLD.status = 'active' AND NEW.status = 'past_due' THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, new_plan_code, previous_mrr_amount, new_mrr_amount, currency_code)
            VALUES (NEW.subscription_id, NEW.account_id, 'payment_failed', NEW.plan_code, v_old_mrr, v_new_mrr, NEW.currency_code);

        ELSIF OLD.status = 'past_due' AND NEW.status = 'active' THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, new_plan_code, previous_mrr_amount, new_mrr_amount, currency_code)
            VALUES (NEW.subscription_id, NEW.account_id, 'payment_recovered', NEW.plan_code, v_old_mrr, v_new_mrr, NEW.currency_code);

        ELSIF OLD.status IN ('active', 'past_due', 'paused') AND NEW.status = 'cancelled' THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, previous_plan_code, previous_mrr_amount, currency_code, reason_code)
            VALUES (NEW.subscription_id, NEW.account_id, 'churned', OLD.plan_code, OLD.mrr_amount, NEW.currency_code, NEW.churn_reason_code);
            INSERT INTO app.account_lifecycle_events (account_id, event_type, subscription_id, source, metadata)
            VALUES (NEW.account_id, 'churned', NEW.subscription_id, 'db_trigger',
                    jsonb_build_object('reason_code', NEW.churn_reason_code, 'plan_code', OLD.plan_code));

        ELSIF OLD.status = 'paused' AND v_new_paying THEN
            INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, new_plan_code, new_mrr_amount, currency_code)
            VALUES (NEW.subscription_id, NEW.account_id, 'reactivated', NEW.plan_code, v_new_mrr, NEW.currency_code);
        END IF;
    END IF;

    -- Plan / price changes while paying
    IF v_old_paying AND v_new_paying
       AND (OLD.price_id IS DISTINCT FROM NEW.price_id OR OLD.quantity IS DISTINCT FROM NEW.quantity
            OR OLD.unit_amount IS DISTINCT FROM NEW.unit_amount) THEN
        INSERT INTO billing.subscription_events (
            subscription_id, account_id, event_type, previous_plan_code, new_plan_code,
            previous_mrr_amount, new_mrr_amount, currency_code)
        VALUES (
            NEW.subscription_id, NEW.account_id,
            CASE
                WHEN OLD.plan_code = NEW.plan_code AND OLD.billing_interval <> NEW.billing_interval THEN 'billing_interval_change'
                WHEN NEW.mrr_amount >= OLD.mrr_amount THEN 'upgrade'
                ELSE 'downgrade'
            END::billing.subscription_event_enum,
            OLD.plan_code, NEW.plan_code, OLD.mrr_amount, NEW.mrr_amount, NEW.currency_code);
    END IF;

    -- Cancellation scheduled / revoked (voluntary churn intent)
    IF OLD.cancel_at_period_end IS DISTINCT FROM NEW.cancel_at_period_end AND NEW.status <> 'cancelled' THEN
        INSERT INTO billing.subscription_events (subscription_id, account_id, event_type, new_plan_code, previous_mrr_amount, new_mrr_amount, currency_code, reason_code)
        VALUES (NEW.subscription_id, NEW.account_id,
                CASE WHEN NEW.cancel_at_period_end THEN 'cancellation_scheduled' ELSE 'cancellation_revoked' END::billing.subscription_event_enum,
                NEW.plan_code, v_new_mrr, v_new_mrr, NEW.currency_code, NEW.churn_reason_code);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_subscription_change
    AFTER INSERT OR UPDATE OF status, price_id, quantity, unit_amount, cancel_at_period_end ON billing.subscriptions
    FOR EACH ROW EXECUTE FUNCTION billing.trg_log_subscription_change();

-- 2.4.3. Reactivation: a NEW subscription for an account that has churned
--      before is a reactivation, not new business.
CREATE OR REPLACE FUNCTION billing.trg_detect_reactivation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('active', 'past_due')
       AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('active', 'past_due'))
       AND EXISTS (SELECT 1 FROM app.accounts WHERE account_id = NEW.account_id AND lifecycle_stage = 'churned') THEN
        INSERT INTO app.account_lifecycle_events (account_id, event_type, subscription_id, source)
        VALUES (NEW.account_id, 'reactivated', NEW.subscription_id, 'db_trigger');
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_subscription_reactivation
    AFTER INSERT OR UPDATE OF status ON billing.subscriptions
    FOR EACH ROW EXECUTE FUNCTION billing.trg_detect_reactivation();

-- ----------------------------------------------------------------------------
-- 2.5. SCHEMA billing — INVOICES (GoBD), CREDIT NOTES, PAYMENTS, DISCOUNTS
-- ----------------------------------------------------------------------------

-- Invoice numbering: Stripe Billing issues gap-free sequential numbers per
-- account prefix (e.g. SL-DE-2026-0001). If billing moves off Stripe, add a
-- number-sequence table with SELECT ... FOR UPDATE per (entity, year).
CREATE TABLE billing.invoices (
    invoice_id            uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    invoice_number        varchar(50) UNIQUE,                           -- NULL only while draft
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE RESTRICT,
    subscription_id       uuid REFERENCES billing.subscriptions(subscription_id) ON DELETE RESTRICT,
    status                billing.invoice_status_enum NOT NULL DEFAULT 'draft',
    currency_code         char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
    subtotal_amount       numeric(12,2) NOT NULL CHECK (subtotal_amount >= 0),          -- net before discount
    discount_amount       numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    tax_amount            numeric(12,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    total_amount          numeric(12,2) GENERATED ALWAYS AS (subtotal_amount - discount_amount + tax_amount) STORED,
    tax_treatment         billing.tax_treatment_enum NOT NULL,
    tax_rate_pct          numeric(5,2) NOT NULL CHECK (tax_rate_pct >= 0),
    -- Customer snapshot at issue time (legal requirement: invoice shows the data valid then)
    customer_legal_name   varchar(150) NOT NULL,
    customer_country_code char(2) NOT NULL,
    customer_vat_id       varchar(30),
    billing_period_start  date,
    billing_period_end    date,
    issued_at             timestamptz,
    due_at                timestamptz,
    paid_at               timestamptz,
    voided_at             timestamptz,
    pdf_url               text,
    einvoice_format       varchar(20) CHECK (einvoice_format IS NULL OR einvoice_format IN ('xrechnung', 'zugferd')),
    stripe_invoice_id     varchar(100) UNIQUE,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_invoice_issued CHECK (status = 'draft' OR (invoice_number IS NOT NULL AND issued_at IS NOT NULL)),
    CONSTRAINT chk_invoice_paid CHECK ((status = 'paid') = (paid_at IS NOT NULL)),
    CONSTRAINT chk_invoice_reverse_charge CHECK (
        tax_treatment NOT IN ('reverse_charge_eu', 'export_non_eu') OR (tax_amount = 0 AND tax_rate_pct = 0)
    ),
    CONSTRAINT chk_invoice_rc_vat_id CHECK (tax_treatment <> 'reverse_charge_eu' OR customer_vat_id IS NOT NULL),
    CONSTRAINT chk_invoice_discount CHECK (discount_amount <= subtotal_amount)
);

CREATE INDEX idx_invoices_account_issued ON billing.invoices(account_id, issued_at);
CREATE INDEX idx_invoices_status ON billing.invoices(status) WHERE status IN ('open', 'uncollectible');

CREATE TABLE billing.invoice_line_items (
    line_item_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id            uuid NOT NULL REFERENCES billing.invoices(invoice_id) ON DELETE RESTRICT,
    line_type             billing.invoice_line_type_enum NOT NULL,
    description           varchar(255) NOT NULL,
    plan_code             varchar(32) REFERENCES billing.plans(plan_code) ON UPDATE CASCADE,
    price_id              bigint REFERENCES billing.plan_prices(price_id),
    quantity              numeric(10,2) NOT NULL DEFAULT 1,
    unit_amount           numeric(12,2) NOT NULL,                       -- negative for discounts / proration credits
    amount                numeric(12,2) NOT NULL,
    period_start          date,
    period_end            date
);

CREATE INDEX idx_invoice_lines_invoice ON billing.invoice_line_items(invoice_id);

-- GoBD: an issued invoice must not be changed or deleted. Only status
-- progression and payment / void metadata may change; corrections go
-- through billing.credit_notes.
CREATE OR REPLACE FUNCTION billing.trg_protect_issued_invoice() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'draft' THEN
            RAISE EXCEPTION 'Invoice % is issued and cannot be deleted (GoBD); use a credit note', OLD.invoice_number;
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.status <> 'draft' AND (
           NEW.invoice_number        IS DISTINCT FROM OLD.invoice_number
        OR NEW.account_id            IS DISTINCT FROM OLD.account_id
        OR NEW.currency_code         IS DISTINCT FROM OLD.currency_code
        OR NEW.subtotal_amount       IS DISTINCT FROM OLD.subtotal_amount
        OR NEW.discount_amount       IS DISTINCT FROM OLD.discount_amount
        OR NEW.tax_amount            IS DISTINCT FROM OLD.tax_amount
        OR NEW.tax_treatment         IS DISTINCT FROM OLD.tax_treatment
        OR NEW.tax_rate_pct          IS DISTINCT FROM OLD.tax_rate_pct
        OR NEW.customer_legal_name   IS DISTINCT FROM OLD.customer_legal_name
        OR NEW.customer_country_code IS DISTINCT FROM OLD.customer_country_code
        OR NEW.customer_vat_id       IS DISTINCT FROM OLD.customer_vat_id
        OR NEW.issued_at             IS DISTINCT FROM OLD.issued_at
        OR NEW.status = 'draft') THEN
        RAISE EXCEPTION 'Invoice % is issued; amounts, customer data and number are immutable (GoBD)', OLD.invoice_number;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_invoice_protect
    BEFORE UPDATE OR DELETE ON billing.invoices
    FOR EACH ROW EXECUTE FUNCTION billing.trg_protect_issued_invoice();

CREATE OR REPLACE FUNCTION billing.trg_protect_issued_invoice_lines() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_invoice_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END;
    v_status     billing.invoice_status_enum;
BEGIN
    SELECT status INTO v_status FROM billing.invoices WHERE invoice_id = v_invoice_id;
    IF v_status <> 'draft' THEN
        RAISE EXCEPTION 'Line items of issued invoice % are immutable (GoBD)', v_invoice_id;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_before_invoice_lines_protect
    BEFORE INSERT OR UPDATE OR DELETE ON billing.invoice_line_items
    FOR EACH ROW EXECUTE FUNCTION billing.trg_protect_issued_invoice_lines();

-- Credit notes (Gutschrift / Stornorechnung): the only way to correct or
-- refund an issued invoice. Append-only.
CREATE TABLE billing.credit_notes (
    credit_note_id        uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    credit_note_number    varchar(50) NOT NULL UNIQUE,
    invoice_id            uuid NOT NULL REFERENCES billing.invoices(invoice_id) ON DELETE RESTRICT,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE RESTRICT,
    reason                billing.credit_note_reason_enum NOT NULL,
    currency_code         char(3) NOT NULL,
    subtotal_amount       numeric(12,2) NOT NULL CHECK (subtotal_amount >= 0),
    tax_amount            numeric(12,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    total_amount          numeric(12,2) GENERATED ALWAYS AS (subtotal_amount + tax_amount) STORED,
    refunded_amount       numeric(12,2) NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0), -- cash returned
    memo                  text,
    issued_at             timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    stripe_credit_note_id varchar(100) UNIQUE,
    CONSTRAINT chk_credit_note_refund CHECK (refunded_amount <= subtotal_amount + tax_amount)
);

CREATE INDEX idx_credit_notes_invoice ON billing.credit_notes(invoice_id);

CREATE OR REPLACE FUNCTION billing.trg_credit_notes_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'billing.credit_notes is append-only (GoBD); issue a new credit note instead';
END;
$$;

CREATE TRIGGER trg_before_credit_notes_change
    BEFORE UPDATE OR DELETE ON billing.credit_notes
    FOR EACH ROW EXECUTE FUNCTION billing.trg_credit_notes_append_only();

-- Payment systems: NAMES only (as shown to the customer). No integration
-- details, no credentials. New systems are added as rows, not as DDL.
CREATE TABLE billing.payment_systems (
    payment_system_code   varchar(30) PRIMARY KEY CHECK (payment_system_code ~ '^[a-z][a-z0-9_]*$'),
    payment_system_name   varchar(60) NOT NULL,
    is_active             boolean NOT NULL DEFAULT TRUE,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE app.accounts
    ADD CONSTRAINT fk_accounts_payment_system
    FOREIGN KEY (payment_system_code) REFERENCES billing.payment_systems(payment_system_code) ON UPDATE CASCADE;

-- Payments: every charge attempt (dunning) and its outcome. fee_amount is
-- the payment-provider fee, needed for gross margin.
CREATE TABLE billing.payments (
    payment_id            uuid PRIMARY KEY DEFAULT ops.uuid_generate_v7(),
    invoice_id            uuid NOT NULL REFERENCES billing.invoices(invoice_id) ON DELETE RESTRICT,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE RESTRICT,
    attempt_number        smallint NOT NULL CHECK (attempt_number >= 1),
    status                billing.payment_status_enum NOT NULL DEFAULT 'pending',
    payment_system_code   varchar(30) REFERENCES billing.payment_systems(payment_system_code) ON UPDATE CASCADE,
                                                                        -- name only; card / IBAN numbers are never stored
    paid_period_months    smallint CHECK (paid_period_months IS NULL OR paid_period_months IN (1, 3, 6, 12)),
    period_start          date,                                         -- first day covered by this payment
    period_end            date,                                         -- last day covered (paid until, inclusive)
    currency_code         char(3) NOT NULL,
    amount                numeric(12,2) NOT NULL CHECK (amount >= 0),
    fee_amount            numeric(12,2) NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
    net_amount            numeric(12,2) GENERATED ALWAYS AS (amount - fee_amount) STORED,
    failure_code          varchar(60),
    failure_message       text,
    attempted_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    succeeded_at          timestamptz,
    stripe_payment_intent_id varchar(100),
    stripe_charge_id      varchar(100) UNIQUE,
    CONSTRAINT uq_payment_attempt UNIQUE (invoice_id, attempt_number),
    CONSTRAINT chk_payment_success CHECK ((status IN ('succeeded', 'refunded', 'partially_refunded')) = (succeeded_at IS NOT NULL)),
    CONSTRAINT chk_payment_failure CHECK (status <> 'failed' OR failure_code IS NOT NULL),
    CONSTRAINT chk_payment_period CHECK (period_end IS NULL OR period_start IS NULL OR period_end >= period_start),
    CONSTRAINT chk_payment_success_period CHECK (
        status <> 'succeeded' OR (paid_period_months IS NOT NULL AND period_start IS NOT NULL AND period_end IS NOT NULL)
    )
);

CREATE INDEX idx_payments_account_time ON billing.payments(account_id, attempted_at);
CREATE INDEX idx_payments_system ON billing.payments(payment_system_code, succeeded_at);

-- Paid term and period are filled automatically when the backend does not
-- send them: term from the subscription interval, period from the invoice
-- (else from the payment day, Europe/Berlin).
CREATE OR REPLACE FUNCTION billing.trg_payment_fill_period() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_months      smallint;
    v_inv_start   date;
    v_inv_end     date;
BEGIN
    SELECT billing.interval_months(s.billing_interval), i.billing_period_start, i.billing_period_end
    INTO v_months, v_inv_start, v_inv_end
    FROM billing.invoices i
    LEFT JOIN billing.subscriptions s ON s.subscription_id = i.subscription_id
    WHERE i.invoice_id = NEW.invoice_id;

    NEW.paid_period_months := COALESCE(NEW.paid_period_months, v_months);
    NEW.period_start := COALESCE(NEW.period_start, v_inv_start,
                                 (COALESCE(NEW.succeeded_at, NEW.attempted_at) AT TIME ZONE 'Europe/Berlin')::date);
    IF NEW.period_end IS NULL AND NEW.paid_period_months IS NOT NULL THEN
        NEW.period_end := COALESCE(
            CASE WHEN NEW.period_start = v_inv_start THEN v_inv_end END,
            (NEW.period_start + make_interval(months => NEW.paid_period_months) - INTERVAL '1 day')::date);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_payment_fill_period
    BEFORE INSERT OR UPDATE OF status, invoice_id, paid_period_months, period_start, period_end ON billing.payments
    FOR EACH ROW EXECUTE FUNCTION billing.trg_payment_fill_period();

-- Conversion moment: the first succeeded payment of the account.
CREATE OR REPLACE FUNCTION billing.trg_payment_first_payment() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'succeeded' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'succeeded') THEN
        INSERT INTO app.account_lifecycle_events (account_id, event_type, occurred_at, source, metadata)
        VALUES (NEW.account_id, 'first_payment', NEW.succeeded_at, 'db_trigger',
                jsonb_build_object('payment_id', NEW.payment_id, 'amount', NEW.amount, 'currency_code', NEW.currency_code))
        ON CONFLICT (account_id, event_type)
            WHERE event_type IN ('signed_up', 'email_verified', 'onboarding_completed', 'activated', 'trial_started', 'first_payment')
        DO NOTHING;

        -- Payment snapshot on the client's account (a late-arriving older
        -- payment never overwrites a newer one; paid_until only moves forward).
        UPDATE app.accounts a SET
            payment_system_code     = CASE WHEN a.last_paid_at IS NULL OR NEW.succeeded_at >= a.last_paid_at
                                           THEN COALESCE(NEW.payment_system_code, a.payment_system_code) ELSE a.payment_system_code END,
            last_paid_period_months = CASE WHEN a.last_paid_at IS NULL OR NEW.succeeded_at >= a.last_paid_at
                                           THEN NEW.paid_period_months ELSE a.last_paid_period_months END,
            last_paid_at            = GREATEST(a.last_paid_at, NEW.succeeded_at),
            paid_until              = GREATEST(a.paid_until, NEW.period_end)
        WHERE a.account_id = NEW.account_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_payment_first_payment
    AFTER INSERT OR UPDATE OF status ON billing.payments
    FOR EACH ROW EXECUTE FUNCTION billing.trg_payment_first_payment();

CREATE TABLE billing.discount_codes (
    discount_code_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                  citext NOT NULL UNIQUE,
    discount_type         billing.discount_type_enum NOT NULL,
    discount_value        numeric(10,2) NOT NULL CHECK (discount_value > 0),
    currency_code         char(3),                                      -- required for fixed_amount
    duration_months       smallint CHECK (duration_months IS NULL OR duration_months >= 1), -- NULL = forever
    applies_to_plan_code  varchar(32) REFERENCES billing.plans(plan_code) ON UPDATE CASCADE,
    referrer_account_id   uuid REFERENCES app.accounts(account_id) ON DELETE SET NULL,
    campaign_id           varchar(64),                                  -- FK added after marketing.campaigns
    max_redemptions       integer CHECK (max_redemptions IS NULL OR max_redemptions > 0),
    times_redeemed        integer NOT NULL DEFAULT 0 CHECK (times_redeemed >= 0),
    valid_from            date NOT NULL,
    valid_to              date,
    is_active             boolean NOT NULL DEFAULT TRUE,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_discount_pct CHECK (discount_type <> 'percentage' OR discount_value <= 100),
    CONSTRAINT chk_discount_fixed_currency CHECK (discount_type <> 'fixed_amount' OR currency_code IS NOT NULL),
    CONSTRAINT chk_discount_validity CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE billing.discount_redemptions (
    redemption_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discount_code_id      bigint NOT NULL REFERENCES billing.discount_codes(discount_code_id),
    subscription_id       uuid NOT NULL REFERENCES billing.subscriptions(subscription_id) ON DELETE RESTRICT,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE RESTRICT,
    redeemed_at           timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_redemption_code_subscription UNIQUE (discount_code_id, subscription_id)
);

CREATE OR REPLACE FUNCTION billing.trg_apply_discount_redemption() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_code billing.discount_codes%ROWTYPE;
    v_plan varchar(32);
BEGIN
    SELECT * INTO v_code FROM billing.discount_codes WHERE discount_code_id = NEW.discount_code_id FOR UPDATE;
    SELECT plan_code INTO v_plan FROM billing.subscriptions WHERE subscription_id = NEW.subscription_id;

    IF NOT v_code.is_active THEN
        RAISE EXCEPTION 'Discount code % is not active', v_code.code;
    END IF;
    IF CURRENT_DATE < v_code.valid_from OR (v_code.valid_to IS NOT NULL AND CURRENT_DATE > v_code.valid_to) THEN
        RAISE EXCEPTION 'Discount code % is outside its validity period', v_code.code;
    END IF;
    IF v_code.max_redemptions IS NOT NULL AND v_code.times_redeemed >= v_code.max_redemptions THEN
        RAISE EXCEPTION 'Discount code % has reached its redemption limit', v_code.code;
    END IF;
    IF v_code.applies_to_plan_code IS NOT NULL AND v_code.applies_to_plan_code <> v_plan THEN
        RAISE EXCEPTION 'Discount code % is valid only for plan %', v_code.code, v_code.applies_to_plan_code;
    END IF;
    IF v_code.referrer_account_id = NEW.account_id THEN
        RAISE EXCEPTION 'An account cannot redeem its own referral code';
    END IF;

    UPDATE billing.discount_codes SET times_redeemed = times_redeemed + 1 WHERE discount_code_id = NEW.discount_code_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_discount_redemption
    BEFORE INSERT ON billing.discount_redemptions
    FOR EACH ROW EXECUTE FUNCTION billing.trg_apply_discount_redemption();

-- Payment-provider webhooks: store first, process asynchronously, exactly once.
CREATE TABLE billing.webhook_inbox (
    webhook_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider              varchar(20) NOT NULL DEFAULT 'stripe',
    provider_event_id     varchar(100) NOT NULL,
    event_type            varchar(100) NOT NULL,
    payload               jsonb NOT NULL,
    status                billing.webhook_status_enum NOT NULL DEFAULT 'received',
    processing_attempts   smallint NOT NULL DEFAULT 0,
    last_error            text,
    received_at           timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processed_at          timestamptz,
    CONSTRAINT uq_webhook_provider_event UNIQUE (provider, provider_event_id)
);

CREATE INDEX idx_webhook_pending ON billing.webhook_inbox(received_at) WHERE status IN ('received', 'failed');

-- ----------------------------------------------------------------------------
-- 2.6. SCHEMA marketing — ACQUISITION & ATTRIBUTION
-- ----------------------------------------------------------------------------

CREATE TABLE marketing.channels (
    channel_code          varchar(40) PRIMARY KEY,                      -- google_search, meta_instagram, referral
    channel_name          varchar(100) NOT NULL,
    channel_group         varchar(30) NOT NULL CHECK (channel_group IN
                              ('paid_search', 'paid_social', 'display', 'organic_search', 'organic_social',
                               'referral', 'partner', 'email', 'direct', 'app_store', 'other')),
    is_paid               boolean NOT NULL,
    is_active             boolean NOT NULL DEFAULT TRUE
);

CREATE TABLE marketing.campaigns (
    campaign_id           varchar(64) PRIMARY KEY,                      -- CMP-DE-2026-DRIVERS-SEARCH
    channel_code          varchar(40) NOT NULL REFERENCES marketing.channels(channel_code) ON UPDATE CASCADE,
    platform_campaign_id  varchar(100),                                 -- id in Google Ads / Meta
    campaign_name         varchar(150) NOT NULL,
    target_account_type   app.account_type_enum,                        -- lets CAC be computed per segment
    target_country_code   char(2) REFERENCES core.supported_countries(country_code) ON UPDATE CASCADE,
    target_audience       varchar(100),
    utm_source            varchar(100),
    utm_medium            varchar(100),
    utm_campaign          varchar(150),
    start_date            date NOT NULL,
    end_date              date,
    is_active             boolean NOT NULL DEFAULT TRUE,
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_campaign_dates CHECK (end_date IS NULL OR end_date >= start_date)
);

CREATE INDEX idx_campaigns_utm ON marketing.campaigns(utm_source, utm_medium, utm_campaign);

ALTER TABLE billing.discount_codes
    ADD CONSTRAINT fk_discount_campaign
    FOREIGN KEY (campaign_id) REFERENCES marketing.campaigns(campaign_id) ON UPDATE CASCADE ON DELETE SET NULL;

-- Ad / creative level (A/B tests of texts and banners).
CREATE TABLE marketing.ads (
    ad_id                 varchar(64) PRIMARY KEY,
    campaign_id           varchar(64) NOT NULL REFERENCES marketing.campaigns(campaign_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    platform_ad_id        varchar(100),
    ad_group_name         varchar(150),
    creative_name         varchar(150),
    creative_variant      varchar(20),                                  -- 'A', 'B', ...
    utm_content           varchar(150),
    created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Daily spend, imported nightly; re-upserted for the last 7 days because
-- ad platforms correct clicks and costs retroactively.
CREATE TABLE marketing.ad_spend_daily (
    spend_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    spend_date            date NOT NULL,
    campaign_id           varchar(64) NOT NULL REFERENCES marketing.campaigns(campaign_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    ad_id                 varchar(64) REFERENCES marketing.ads(ad_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    currency_code         char(3) NOT NULL,
    impressions           integer NOT NULL DEFAULT 0 CHECK (impressions >= 0),
    clicks                integer NOT NULL DEFAULT 0 CHECK (clicks >= 0),
    cost_amount           numeric(12,2) NOT NULL DEFAULT 0 CHECK (cost_amount >= 0),     -- net of VAT
    synced_at             timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_spend_clicks CHECK (clicks <= impressions OR impressions = 0)
);

CREATE UNIQUE INDEX uq_ad_spend_day
    ON marketing.ad_spend_daily(spend_date, campaign_id, COALESCE(ad_id, ''));

-- Attribution: ONE row per account, written once at sign-up from the UTM
-- parameters the client kept in cookie/localStorage. No IP address, no
-- device fingerprint.
CREATE TABLE marketing.account_attribution (
    account_id                uuid PRIMARY KEY REFERENCES app.accounts(account_id) ON DELETE CASCADE,
    had_tracking_consent      boolean NOT NULL,                         -- first-touch data only if TRUE
    first_touch_at            timestamptz,
    first_touch_channel_code  varchar(40) REFERENCES marketing.channels(channel_code) ON UPDATE CASCADE,
    first_touch_campaign_id   varchar(64) REFERENCES marketing.campaigns(campaign_id) ON UPDATE CASCADE ON DELETE SET NULL,
    first_touch_ad_id         varchar(64) REFERENCES marketing.ads(ad_id) ON UPDATE CASCADE ON DELETE SET NULL,
    first_utm_source          varchar(100),
    first_utm_medium          varchar(100),
    first_utm_campaign        varchar(150),
    first_utm_content         varchar(150),
    first_utm_term            varchar(150),
    first_landing_path        varchar(255),                             -- path only, no query string
    first_referrer_domain     varchar(255),
    last_touch_channel_code   varchar(40) REFERENCES marketing.channels(channel_code) ON UPDATE CASCADE,
    last_touch_campaign_id    varchar(64) REFERENCES marketing.campaigns(campaign_id) ON UPDATE CASCADE ON DELETE SET NULL,
    signup_platform           app.client_platform_enum NOT NULL,
    signup_os_name            varchar(30),
    signup_country_code       char(2),                                  -- derived from IP at request time; IP not stored
    referral_code_used        varchar(20),
    discount_code_used        citext,
    created_at                timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_attribution_consent CHECK (
        had_tracking_consent OR (first_touch_at IS NULL AND first_utm_source IS NULL AND first_referrer_domain IS NULL)
    )
);

CREATE INDEX idx_attribution_channel ON marketing.account_attribution(first_touch_channel_code);
CREATE INDEX idx_attribution_campaign ON marketing.account_attribution(first_touch_campaign_id);

-- Mobile installs, daily aggregate from the MMP (AppsFlyer / Adjust).
CREATE TABLE marketing.app_installs_daily (
    install_row_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    install_date          date NOT NULL,
    platform              app.client_platform_enum NOT NULL CHECK (platform IN ('ios_app', 'android_app')),
    channel_code          varchar(40) NOT NULL REFERENCES marketing.channels(channel_code) ON UPDATE CASCADE,
    campaign_id           varchar(64) REFERENCES marketing.campaigns(campaign_id) ON UPDATE CASCADE ON DELETE SET NULL,
    country_code          char(2),
    installs              integer NOT NULL CHECK (installs >= 0),
    source_system         varchar(30) NOT NULL,
    synced_at             timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX uq_installs_day
    ON marketing.app_installs_daily(install_date, platform, channel_code, COALESCE(campaign_id, ''), COALESCE(country_code, '--'));

-- ----------------------------------------------------------------------------
-- 2.7. SCHEMA analytics — ROLLUPS FOR DASHBOARDS AND THE AI ASSISTANT
-- ----------------------------------------------------------------------------

-- 2.7.1. Daily product usage per account (bridge to core), partitioned.
CREATE TABLE analytics.account_usage_daily (
    usage_date            date NOT NULL,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE CASCADE,
    orders_published      integer NOT NULL DEFAULT 0,                   -- shipper side
    orders_accepted       integer NOT NULL DEFAULT 0,                   -- carrier side, both parties confirmed
    deliveries_completed  integer NOT NULL DEFAULT 0,
    active_drivers        integer NOT NULL DEFAULT 0,
    active_vehicles       integer NOT NULL DEFAULT 0,
    active_users          integer NOT NULL DEFAULT 0,
    documents_uploaded    integer NOT NULL DEFAULT 0,
    refreshed_at          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (usage_date, account_id)
) PARTITION BY RANGE (usage_date);

CREATE INDEX idx_usage_account_date ON analytics.account_usage_daily(account_id, usage_date);

-- 2.7.2. FX rates to the reporting currency (EUR), e.g. ECB reference rates.
CREATE TABLE analytics.fx_rates_daily (
    rate_date             date NOT NULL,
    currency_code         char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
    eur_per_unit          numeric(18,8) NOT NULL CHECK (eur_per_unit > 0),
    source                varchar(20) NOT NULL DEFAULT 'ecb',
    PRIMARY KEY (rate_date, currency_code)
);

CREATE OR REPLACE FUNCTION analytics.to_eur(p_amount numeric, p_currency char(3), p_date date)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_currency = 'EUR' THEN p_amount
        ELSE p_amount * (
            SELECT eur_per_unit FROM analytics.fx_rates_daily
            WHERE currency_code = p_currency AND rate_date <= p_date
            ORDER BY rate_date DESC LIMIT 1)
    END;
$$;

-- 2.7.3. Daily MRR snapshot per account: the ground truth for MRR history,
--      churn and cohort revenue. A missing row means MRR = 0 that day.
CREATE TABLE analytics.fct_mrr_daily (
    snapshot_date         date NOT NULL,
    account_id            uuid NOT NULL REFERENCES app.accounts(account_id) ON DELETE CASCADE,
    subscription_id       uuid NOT NULL,
    plan_code             varchar(32) NOT NULL,
    status                billing.subscription_status_enum NOT NULL,
    billing_interval      billing.billing_interval_enum NOT NULL,
    currency_code         char(3) NOT NULL,
    mrr_amount            numeric(12,4) NOT NULL,                       -- 0 for trialing / paused
    mrr_amount_eur        numeric(12,4),                                -- NULL if FX rate missing
    PRIMARY KEY (snapshot_date, account_id)
);

-- 2.7.4. Cohorts: accounts grouped by sign-up month and segment, tracked
--      month by month (activation, conversion, paying, MRR).
CREATE TABLE analytics.fct_cohort_monthly (
    cohort_month              date NOT NULL,
    activity_month            date NOT NULL,
    months_since_signup       smallint NOT NULL,
    account_type              app.account_type_enum NOT NULL,
    country_code              char(2) NOT NULL,
    acquisition_channel_code  varchar(40) NOT NULL,                     -- 'unknown' when not attributed
    signup_platform           varchar(20) NOT NULL,
    fleet_size_band           varchar(10) NOT NULL,                     -- 'unknown' when not declared
    cohort_accounts           integer NOT NULL,
    verified_accounts         integer NOT NULL,                         -- cumulative by end of activity_month
    activated_accounts        integer NOT NULL,
    converted_accounts        integer NOT NULL,                         -- first payment done (cumulative)
    paying_accounts           integer NOT NULL,                         -- MRR > 0 at month end
    mrr_amount_eur            numeric(14,2) NOT NULL,
    refreshed_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (cohort_month, activity_month, account_type, country_code,
                 acquisition_channel_code, signup_platform, fleet_size_band)
);

-- 2.7.5. Platform operating costs (for gross margin; payment fees come from
--      billing.payments automatically).
CREATE TABLE analytics.platform_costs_monthly (
    cost_month            date NOT NULL CHECK (cost_month = date_trunc('month', cost_month)::date),
    cost_category         analytics.platform_cost_category_enum NOT NULL,
    currency_code         char(3) NOT NULL DEFAULT 'EUR',
    amount                numeric(12,2) NOT NULL CHECK (amount >= 0),
    notes                 text,
    PRIMARY KEY (cost_month, cost_category, currency_code)
);

-- 2.7.6. Monthly SaaS unit economics per segment ('all' + each billable account type).
CREATE TABLE analytics.fct_unit_economics_monthly (
    month                     date NOT NULL,
    segment                   varchar(20) NOT NULL,                     -- 'all', 'solo_carrier', 'fleet_company'
    paying_accounts_start     integer NOT NULL,
    new_paying_accounts       integer NOT NULL,
    reactivated_accounts      integer NOT NULL,
    churned_accounts          integer NOT NULL,
    paying_accounts_end       integer NOT NULL,
    mrr_start_eur             numeric(14,2) NOT NULL,
    new_mrr_eur               numeric(14,2) NOT NULL,
    expansion_mrr_eur         numeric(14,2) NOT NULL,
    contraction_mrr_eur       numeric(14,2) NOT NULL,                   -- positive number
    churned_mrr_eur           numeric(14,2) NOT NULL,                   -- positive number
    reactivation_mrr_eur      numeric(14,2) NOT NULL,
    mrr_end_eur               numeric(14,2) NOT NULL,
    logo_churn_rate_pct       numeric(7,2),
    gross_revenue_retention_pct numeric(7,2),
    net_revenue_retention_pct numeric(7,2),
    arpa_eur                  numeric(12,2),
    ad_spend_eur              numeric(14,2) NOT NULL,
    cac_eur                   numeric(12,2),                            -- ad spend / new paying accounts
    payment_fees_eur          numeric(12,2) NOT NULL,
    platform_costs_eur        numeric(14,2) NOT NULL,                   -- only in segment 'all'
    gross_margin_pct          numeric(7,2),                             -- company level, reused per segment
    trailing_3m_churn_pct     numeric(7,2),
    ltv_eur                   numeric(14,2),                            -- ARPA * gross margin / trailing churn
    ltv_to_cac                numeric(8,2),
    cac_payback_months        numeric(8,1),
    refreshed_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (month, segment)
);

-- 2.7.7. KPI dictionary (semantic layer): one agreed definition per metric,
--      used by dashboards and by the AI assistant instead of ad-hoc SQL.
CREATE TABLE analytics.metric_definitions (
    metric_code           varchar(60) PRIMARY KEY,
    metric_name           varchar(120) NOT NULL,
    description           text NOT NULL,
    formula               text NOT NULL,
    source_object         varchar(120) NOT NULL,                        -- table / view / column
    grain                 varchar(40) NOT NULL,
    unit                  varchar(20) NOT NULL,
    version               smallint NOT NULL DEFAULT 1,
    updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 2.8. REFRESH FUNCTIONS (called by ops.run_nightly, section 3.7)
-- ----------------------------------------------------------------------------

-- 2.8.1. Usage bridge from core for one business day (Europe/Berlin).
--      Also records the 'activated' milestone:
--        carriers -> first completed delivery; shippers -> first published order.
CREATE OR REPLACE FUNCTION analytics.refresh_account_usage_daily(p_date date)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_from  timestamptz := p_date::timestamp AT TIME ZONE 'Europe/Berlin';
    v_to    timestamptz := (p_date + 1)::timestamp AT TIME ZONE 'Europe/Berlin';
    v_rows  integer;
BEGIN
    PERFORM ops.ensure_monthly_partitions('analytics.account_usage_daily', p_date, p_date);

    WITH acc AS (
        SELECT account_id, client_id FROM app.accounts WHERE client_id IS NOT NULL AND anonymized_at IS NULL
    ),
    published AS (
        SELECT o.client_id, COUNT(*) AS n
        FROM core.orders o
        WHERE o.created_at >= v_from AND o.created_at < v_to AND o.status <> 'draft' AND NOT o.is_test
        GROUP BY o.client_id
    ),
    carrier_drivers AS (
        SELECT dr.driver_id, dr.linked_client_id AS client_id FROM core.drivers dr
    ),
    accepted AS (
        SELECT COALESCE(cd.client_id, o.executor_id) AS client_id, COUNT(*) AS n
        FROM core.orders o
        LEFT JOIN carrier_drivers cd ON o.executor_type = 'fop_driver' AND cd.driver_id = o.executor_id
        WHERE o.match_status = 'both_confirmed'
          AND o.carrier_confirmed_at >= v_from AND o.carrier_confirmed_at < v_to
          AND NOT o.is_test
        GROUP BY 1
    ),
    delivered AS (
        SELECT cd.client_id,
               COUNT(*)                     AS deliveries_completed,
               COUNT(DISTINCT d.driver_id)  AS active_drivers,
               COUNT(DISTINCT d.vehicle_id) AS active_vehicles
        FROM core.deliveries d
        JOIN carrier_drivers cd ON cd.driver_id = d.driver_id
        WHERE d.delivery_status = 'delivered'
          AND d.actual_end_time >= v_from AND d.actual_end_time < v_to
          AND NOT d.is_test
        GROUP BY cd.client_id
    ),
    docs AS (
        SELECT cd.client_id, COUNT(*) AS n
        FROM core.shipment_documents sd
        JOIN core.deliveries d ON d.delivery_id = sd.delivery_id
        JOIN carrier_drivers cd ON cd.driver_id = d.driver_id
        WHERE sd.created_at >= v_from AND sd.created_at < v_to
        GROUP BY cd.client_id
    ),
    users_active AS (
        SELECT account_id, COUNT(DISTINCT user_id) AS n
        FROM app.user_activity_daily
        WHERE activity_date = p_date
        GROUP BY account_id
    )
    INSERT INTO analytics.account_usage_daily AS u (
        usage_date, account_id, orders_published, orders_accepted, deliveries_completed,
        active_drivers, active_vehicles, active_users, documents_uploaded, refreshed_at)
    SELECT p_date, acc.account_id,
           COALESCE(pub.n, 0), COALESCE(acp.n, 0), COALESCE(dl.deliveries_completed, 0),
           COALESCE(dl.active_drivers, 0), COALESCE(dl.active_vehicles, 0),
           COALESCE(ua.n, 0), COALESCE(dc.n, 0), CURRENT_TIMESTAMP
    FROM acc
    LEFT JOIN published    pub ON pub.client_id = acc.client_id
    LEFT JOIN accepted     acp ON acp.client_id = acc.client_id
    LEFT JOIN delivered    dl  ON dl.client_id  = acc.client_id
    LEFT JOIN docs         dc  ON dc.client_id  = acc.client_id
    LEFT JOIN users_active ua  ON ua.account_id = acc.account_id
    WHERE COALESCE(pub.n, 0) + COALESCE(acp.n, 0) + COALESCE(dl.deliveries_completed, 0)
        + COALESCE(ua.n, 0) + COALESCE(dc.n, 0) > 0                     -- keep the table sparse
    ON CONFLICT (usage_date, account_id) DO UPDATE SET
        orders_published     = EXCLUDED.orders_published,
        orders_accepted      = EXCLUDED.orders_accepted,
        deliveries_completed = EXCLUDED.deliveries_completed,
        active_drivers       = EXCLUDED.active_drivers,
        active_vehicles      = EXCLUDED.active_vehicles,
        active_users         = EXCLUDED.active_users,
        documents_uploaded   = EXCLUDED.documents_uploaded,
        refreshed_at         = EXCLUDED.refreshed_at;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- Activation milestone (definition v1, see analytics.metric_definitions 'activation')
    INSERT INTO app.account_lifecycle_events (account_id, event_type, occurred_at, source, metadata)
    SELECT u.account_id, 'activated', v_to - INTERVAL '1 second', 'nightly_job',
           jsonb_build_object('rule', CASE WHEN a.is_billable THEN 'first_delivery_completed' ELSE 'first_order_published' END,
                              'usage_date', p_date)
    FROM analytics.account_usage_daily u
    JOIN app.accounts a ON a.account_id = u.account_id
    WHERE u.usage_date = p_date
      AND a.activated_at IS NULL
      AND ((a.is_billable AND u.deliveries_completed > 0) OR (NOT a.is_billable AND u.orders_published > 0))
    ON CONFLICT (account_id, event_type)
        WHERE event_type IN ('signed_up', 'email_verified', 'onboarding_completed', 'activated', 'trial_started', 'first_payment')
    DO NOTHING;

    RETURN v_rows;
END;
$$;

-- 2.8.2. MRR snapshot of the current subscription state for p_date.
CREATE OR REPLACE FUNCTION analytics.snapshot_mrr_daily(p_date date DEFAULT CURRENT_DATE)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_rows integer;
BEGIN
    DELETE FROM analytics.fct_mrr_daily WHERE snapshot_date = p_date;

    INSERT INTO analytics.fct_mrr_daily (
        snapshot_date, account_id, subscription_id, plan_code, status,
        billing_interval, currency_code, mrr_amount, mrr_amount_eur)
    SELECT p_date, s.account_id, s.subscription_id, s.plan_code, s.status,
           s.billing_interval, s.currency_code,
           CASE WHEN s.status IN ('active', 'past_due') THEN s.mrr_amount ELSE 0 END,
           analytics.to_eur(CASE WHEN s.status IN ('active', 'past_due') THEN s.mrr_amount ELSE 0 END, s.currency_code, p_date)
    FROM billing.subscriptions s
    JOIN app.accounts a ON a.account_id = s.account_id
    WHERE s.status IN ('trialing', 'active', 'past_due', 'paused')
      AND NOT a.is_test;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- 2.8.3. Cohort table: full rebuild (small: one row per cohort x month x segment).
CREATE OR REPLACE FUNCTION analytics.refresh_cohort_monthly()
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_rows       integer;
    v_last_snap  date := (SELECT MAX(snapshot_date) FROM analytics.fct_mrr_daily);
BEGIN
    TRUNCATE analytics.fct_cohort_monthly;

    WITH acc AS (
        SELECT a.account_id, a.cohort_month, a.account_type, a.country_code,
               COALESCE(att.first_touch_channel_code, 'unknown')  AS channel,
               COALESCE(att.signup_platform::text, 'unknown')    AS platform,
               COALESCE(a.fleet_size_band, 'unknown')             AS fleet_band,
               a.email_verified_at, a.activated_at, a.first_paid_at
        FROM app.accounts a
        LEFT JOIN marketing.account_attribution att ON att.account_id = a.account_id
        WHERE NOT a.is_test
    ),
    months AS (
        SELECT acc.*, gs::date AS activity_month,
               LEAST((gs + INTERVAL '1 month' - INTERVAL '1 day')::date, COALESCE(v_last_snap, CURRENT_DATE)) AS month_end
        FROM acc
        CROSS JOIN LATERAL generate_series(acc.cohort_month, date_trunc('month', CURRENT_DATE), INTERVAL '1 month') gs
    )
    INSERT INTO analytics.fct_cohort_monthly (
        cohort_month, activity_month, months_since_signup, account_type, country_code,
        acquisition_channel_code, signup_platform, fleet_size_band,
        cohort_accounts, verified_accounts, activated_accounts, converted_accounts,
        paying_accounts, mrr_amount_eur)
    SELECT m.cohort_month, m.activity_month,
           ((EXTRACT(YEAR FROM age(m.activity_month, m.cohort_month)) * 12)
             + EXTRACT(MONTH FROM age(m.activity_month, m.cohort_month)))::smallint,
           m.account_type, m.country_code, m.channel, m.platform, m.fleet_band,
           COUNT(*),
           COUNT(*) FILTER (WHERE m.email_verified_at < m.month_end + 1),
           COUNT(*) FILTER (WHERE m.activated_at      < m.month_end + 1),
           COUNT(*) FILTER (WHERE m.first_paid_at     < m.month_end + 1),
           COUNT(*) FILTER (WHERE f.mrr_amount > 0),
           COALESCE(SUM(f.mrr_amount_eur), 0)
    FROM months m
    LEFT JOIN analytics.fct_mrr_daily f
           ON f.account_id = m.account_id AND f.snapshot_date = m.month_end
    GROUP BY m.cohort_month, m.activity_month, m.account_type, m.country_code, m.channel, m.platform, m.fleet_band;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- 2.8.4. Unit economics for one month. MRR movements are derived by
--      comparing each account's MRR at the previous and current month end
--      (from fct_mrr_daily), which is robust against missed events.
--      Limitation: an account that starts and churns inside the same month
--      is not visible in month-end snapshots.
CREATE OR REPLACE FUNCTION analytics.refresh_unit_economics_monthly(p_month date)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_month      date := date_trunc('month', p_month)::date;
    v_last_snap  date := (SELECT MAX(snapshot_date) FROM analytics.fct_mrr_daily);
    v_cur_end    date;
    v_prev_end   date;
    v_rows       integer;
BEGIN
    v_cur_end  := LEAST((v_month + INTERVAL '1 month' - INTERVAL '1 day')::date, v_last_snap);
    v_prev_end := (v_month - INTERVAL '1 day')::date;

    DELETE FROM analytics.fct_unit_economics_monthly WHERE month = v_month;

    WITH prev AS (
        SELECT account_id, COALESCE(mrr_amount_eur, 0) AS mrr FROM analytics.fct_mrr_daily WHERE snapshot_date = v_prev_end
    ),
    cur AS (
        SELECT account_id, COALESCE(mrr_amount_eur, 0) AS mrr FROM analytics.fct_mrr_daily WHERE snapshot_date = v_cur_end
    ),
    movement AS (
        SELECT a.account_id, a.account_type::text AS account_type,
               COALESCE(p.mrr, 0) AS mrr_prev, COALESCE(c.mrr, 0) AS mrr_cur,
               (a.first_paid_at IS NOT NULL AND a.first_paid_at < v_month) AS paid_before
        FROM app.accounts a
        LEFT JOIN prev p ON p.account_id = a.account_id
        LEFT JOIN cur  c ON c.account_id = a.account_id
        WHERE a.is_billable AND NOT a.is_test
          AND (p.account_id IS NOT NULL OR c.account_id IS NOT NULL)
    ),
    agg AS (
        SELECT COALESCE(account_type, 'all') AS segment,
               COUNT(*) FILTER (WHERE mrr_prev > 0)                                     AS paying_start,
               COUNT(*) FILTER (WHERE mrr_prev = 0 AND mrr_cur > 0 AND NOT paid_before) AS new_paying,
               COUNT(*) FILTER (WHERE mrr_prev = 0 AND mrr_cur > 0 AND paid_before)     AS reactivated,
               COUNT(*) FILTER (WHERE mrr_prev > 0 AND mrr_cur = 0)                     AS churned,
               COUNT(*) FILTER (WHERE mrr_cur > 0)                                      AS paying_end,
               COALESCE(SUM(mrr_prev), 0)                                                            AS mrr_start,
               COALESCE(SUM(mrr_cur)  FILTER (WHERE mrr_prev = 0 AND NOT paid_before), 0)            AS new_mrr,
               COALESCE(SUM(mrr_cur - mrr_prev) FILTER (WHERE mrr_prev > 0 AND mrr_cur > mrr_prev), 0) AS expansion,
               COALESCE(SUM(mrr_prev - mrr_cur) FILTER (WHERE mrr_prev > 0 AND mrr_cur > 0 AND mrr_cur < mrr_prev), 0) AS contraction,
               COALESCE(SUM(mrr_prev) FILTER (WHERE mrr_prev > 0 AND mrr_cur = 0), 0)                AS churned_mrr,
               COALESCE(SUM(mrr_cur)  FILTER (WHERE mrr_prev = 0 AND paid_before), 0)                AS reactivation_mrr,
               COALESCE(SUM(mrr_cur), 0)                                                             AS mrr_end
        FROM movement
        GROUP BY GROUPING SETS ((account_type), ())
    ),
    spend AS (
        SELECT COALESCE(c.target_account_type::text, 'unassigned') AS segment,
               SUM(analytics.to_eur(s.cost_amount, s.currency_code, s.spend_date)) AS ad_spend
        FROM marketing.ad_spend_daily s
        JOIN marketing.campaigns c ON c.campaign_id = s.campaign_id
        WHERE s.spend_date >= v_month AND s.spend_date < v_month + INTERVAL '1 month'
        GROUP BY 1
    ),
    fees AS (
        SELECT a.account_type::text AS segment,
               SUM(analytics.to_eur(p.fee_amount, p.currency_code, p.succeeded_at::date)) AS fees
        FROM billing.payments p
        JOIN app.accounts a ON a.account_id = p.account_id
        WHERE p.succeeded_at >= v_month AND p.succeeded_at < v_month + INTERVAL '1 month'
        GROUP BY 1
    ),
    platform AS (
        SELECT COALESCE(SUM(analytics.to_eur(amount, currency_code, cost_month)), 0) AS costs
        FROM analytics.platform_costs_monthly WHERE cost_month = v_month
    )
    INSERT INTO analytics.fct_unit_economics_monthly (
        month, segment, paying_accounts_start, new_paying_accounts, reactivated_accounts,
        churned_accounts, paying_accounts_end, mrr_start_eur, new_mrr_eur, expansion_mrr_eur,
        contraction_mrr_eur, churned_mrr_eur, reactivation_mrr_eur, mrr_end_eur,
        logo_churn_rate_pct, gross_revenue_retention_pct, net_revenue_retention_pct, arpa_eur,
        ad_spend_eur, cac_eur, payment_fees_eur, platform_costs_eur)
    SELECT v_month, g.segment, g.paying_start, g.new_paying, g.reactivated, g.churned, g.paying_end,
           g.mrr_start, g.new_mrr, g.expansion, g.contraction, g.churned_mrr, g.reactivation_mrr, g.mrr_end,
           ROUND(100.0 * g.churned / NULLIF(g.paying_start, 0), 2),
           ROUND(100.0 * (g.mrr_start - g.contraction - g.churned_mrr) / NULLIF(g.mrr_start, 0), 2),
           ROUND(100.0 * (g.mrr_start + g.expansion - g.contraction - g.churned_mrr) / NULLIF(g.mrr_start, 0), 2),
           ROUND(g.mrr_end / NULLIF(g.paying_end, 0), 2),
           COALESCE(CASE WHEN g.segment = 'all' THEN (SELECT SUM(ad_spend) FROM spend)
                         ELSE (SELECT ad_spend FROM spend s WHERE s.segment = g.segment) END, 0),
           NULL,
           COALESCE(CASE WHEN g.segment = 'all' THEN (SELECT SUM(fees) FROM fees)
                         ELSE (SELECT fees FROM fees f WHERE f.segment = g.segment) END, 0),
           CASE WHEN g.segment = 'all' THEN (SELECT costs FROM platform) ELSE 0 END
    FROM agg g;

    -- Derived ratios: CAC, company gross margin, trailing churn, LTV, payback.
    UPDATE analytics.fct_unit_economics_monthly u
    SET cac_eur = ROUND(u.ad_spend_eur / NULLIF(u.new_paying_accounts, 0), 2)
    WHERE u.month = v_month;

    UPDATE analytics.fct_unit_economics_monthly u
    SET gross_margin_pct = (
            SELECT ROUND(100.0 * (a.mrr_end_eur - a.payment_fees_eur - a.platform_costs_eur) / NULLIF(a.mrr_end_eur, 0), 2)
            FROM analytics.fct_unit_economics_monthly a
            WHERE a.month = v_month AND a.segment = 'all'),
        trailing_3m_churn_pct = (
            SELECT ROUND(100.0 * SUM(t.churned_accounts) / NULLIF(SUM(t.paying_accounts_start), 0), 2)
            FROM analytics.fct_unit_economics_monthly t
            WHERE t.segment = u.segment AND t.month > v_month - INTERVAL '3 months' AND t.month <= v_month)
    WHERE u.month = v_month;

    UPDATE analytics.fct_unit_economics_monthly u
    SET ltv_eur = ROUND(u.arpa_eur * (u.gross_margin_pct / 100.0) / NULLIF(u.trailing_3m_churn_pct / 100.0, 0), 2),
        cac_payback_months = ROUND(u.cac_eur / NULLIF(u.arpa_eur * u.gross_margin_pct / 100.0, 0), 1)
    WHERE u.month = v_month;

    UPDATE analytics.fct_unit_economics_monthly u
    SET ltv_to_cac = ROUND(u.ltv_eur / NULLIF(u.cac_eur, 0), 2)
    WHERE u.month = v_month;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2.9. VIEWS (security_invoker: row-level security of the caller applies)
-- ----------------------------------------------------------------------------

-- 2.9.1. Account 360: one row per account for dashboards, support and the AI assistant.
CREATE OR REPLACE VIEW analytics.v_account_360 WITH (security_invoker = true) AS
SELECT
    a.account_id, a.account_number, a.account_type, a.is_billable, a.country_code,
    a.fleet_size_band, a.lifecycle_stage, a.cohort_month,
    a.signed_up_at, a.email_verified_at, a.onboarding_completed_at, a.activated_at,
    a.trial_started_at, a.first_paid_at, a.churned_at, a.last_reactivated_at,
    a.payment_system_code, a.last_paid_at, a.last_paid_period_months, a.paid_until,
    ROUND(EXTRACT(EPOCH FROM (a.first_paid_at - a.signed_up_at)) / 86400.0, 1) AS days_signup_to_first_payment,
    att.first_touch_channel_code, att.first_touch_campaign_id, att.signup_platform,
    s.plan_code, s.status AS subscription_status, s.billing_interval, s.currency_code, s.mrr_amount,
    s.current_period_end, s.cancel_at_period_end,
    u30.deliveries_30d, u30.orders_published_30d, u30.active_days_30d, u30.last_usage_date,
    CASE
        WHEN a.lifecycle_stage = 'churned'                                           THEN 'churned'
        WHEN a.lifecycle_stage = 'trial_expired'                                     THEN 'trial_expired'
        WHEN s.status = 'trialing' AND COALESCE(u30.active_days_30d, 0) = 0          THEN 'at_risk_trial_no_usage'
        WHEN s.status IN ('active', 'past_due') AND COALESCE(u30.active_days_30d, 0) = 0 THEN 'at_risk_no_usage'
        WHEN s.status = 'past_due'                                                   THEN 'at_risk_payment'
        WHEN s.cancel_at_period_end                                                  THEN 'at_risk_cancel_scheduled'
        ELSE 'healthy'
    END AS health_flag
FROM app.accounts a
LEFT JOIN marketing.account_attribution att ON att.account_id = a.account_id
LEFT JOIN LATERAL (
    SELECT * FROM billing.subscriptions s
    WHERE s.account_id = a.account_id
    ORDER BY (s.status IN ('incomplete', 'trialing', 'active', 'past_due', 'paused')) DESC, s.created_at DESC
    LIMIT 1
) s ON TRUE
LEFT JOIN LATERAL (
    SELECT SUM(deliveries_completed) AS deliveries_30d,
           SUM(orders_published)     AS orders_published_30d,
           COUNT(*)                  AS active_days_30d,
           MAX(usage_date)           AS last_usage_date
    FROM analytics.account_usage_daily u
    WHERE u.account_id = a.account_id AND u.usage_date > CURRENT_DATE - 30
) u30 ON TRUE
WHERE NOT a.is_test;

-- 2.9.2. Conversion funnel by sign-up cohort month and account type.
CREATE OR REPLACE VIEW analytics.v_conversion_funnel WITH (security_invoker = true) AS
SELECT
    a.cohort_month,
    a.account_type,
    COUNT(*)                                        AS signed_up,
    COUNT(a.email_verified_at)                      AS email_verified,
    COUNT(a.onboarding_completed_at)                AS onboarded,
    COUNT(a.activated_at)                           AS activated,
    COUNT(a.trial_started_at)                       AS trial_started,
    COUNT(a.first_paid_at)                          AS converted_to_paid,
    ROUND(100.0 * COUNT(a.email_verified_at) / NULLIF(COUNT(*), 0), 1)        AS verify_rate_pct,
    ROUND(100.0 * COUNT(a.first_paid_at) / NULLIF(COUNT(a.trial_started_at), 0), 1) AS trial_to_paid_pct,
    ROUND(100.0 * COUNT(a.first_paid_at) / NULLIF(COUNT(*), 0), 1)            AS signup_to_paid_pct,
    percentile_cont(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (a.first_paid_at - a.signed_up_at)) / 86400.0
    ) FILTER (WHERE a.first_paid_at IS NOT NULL)    AS median_days_to_paid
FROM app.accounts a
WHERE NOT a.is_test
GROUP BY a.cohort_month, a.account_type;

-- ----------------------------------------------------------------------------
-- 2.10. SECURITY: ROLES & ROW-LEVEL SECURITY
-- ----------------------------------------------------------------------------
-- smartlog_tenant_reader : used by the AI assistant / customer dashboards,
--                          sees only rows of app.current_account_id.
-- smartlog_analyst       : internal BI, reads analytics.* only (all tenants).
-- The backend role owns the tables and is not restricted by RLS.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smartlog_tenant_reader') THEN
        CREATE ROLE smartlog_tenant_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smartlog_analyst') THEN
        CREATE ROLE smartlog_analyst NOLOGIN;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION app.current_account_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('app.current_account_id', true), '')::uuid;
$$;

GRANT USAGE ON SCHEMA app, billing, marketing, analytics TO smartlog_tenant_reader;
GRANT SELECT ON app.accounts, billing.subscriptions, billing.invoices, billing.payments,
                marketing.account_attribution, analytics.account_usage_daily, analytics.fct_mrr_daily,
                analytics.v_account_360, analytics.metric_definitions
      TO smartlog_tenant_reader;
GRANT EXECUTE ON FUNCTION app.current_account_id() TO smartlog_tenant_reader;

GRANT USAGE ON SCHEMA analytics TO smartlog_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO smartlog_analyst;

DO $$
DECLARE
    v_tbl text;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY[
        'app.accounts', 'billing.subscriptions', 'billing.invoices', 'billing.payments',
        'marketing.account_attribution', 'analytics.account_usage_daily', 'analytics.fct_mrr_daily'
    ] LOOP
        EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', v_tbl);
        EXECUTE format(
            'CREATE POLICY p_tenant_isolation ON %s FOR SELECT TO smartlog_tenant_reader USING (account_id = app.current_account_id())',
            v_tbl);
    END LOOP;

    FOREACH v_tbl IN ARRAY ARRAY['analytics.account_usage_daily', 'analytics.fct_mrr_daily'] LOOP
        EXECUTE format('CREATE POLICY p_analyst_all ON %s FOR SELECT TO smartlog_analyst USING (true)', v_tbl);
    END LOOP;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2.11. updated_at TRIGGERS
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_tbl text;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY[
        'app.accounts', 'app.users', 'app.account_memberships',
        'billing.subscriptions', 'billing.invoices', 'marketing.campaigns'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_before_update_set_updated_at BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at()',
            v_tbl);
    END LOOP;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2.12. NIGHTLY JOB & RETENTION
-- ----------------------------------------------------------------------------
-- Schedule (Europe/Berlin), e.g. with pg_cron or the backend scheduler:
--   02:00  SELECT ops.run_nightly();                 -- all steps below
--   02:30  backend: import ad spend (UPSERT last 7 days), MMP installs, ECB FX
-- ad spend / installs / FX are imported by the backend because they call
-- external APIs; everything else runs inside the database.
-- ops.run_nightly() is defined in PART 3 (includes the logistics KPI refresh).

-- ----------------------------------------------------------------------------
-- 2.13. INITIAL PARTITIONS
-- ----------------------------------------------------------------------------
SELECT ops.ensure_monthly_partitions('app.user_activity_daily',       date_trunc('month', CURRENT_DATE)::date - 31, CURRENT_DATE + 92);
SELECT ops.ensure_monthly_partitions('app.audit_log',                 date_trunc('month', CURRENT_DATE)::date - 31, CURRENT_DATE + 92);
SELECT ops.ensure_monthly_partitions('analytics.account_usage_daily', date_trunc('month', CURRENT_DATE)::date - 31, CURRENT_DATE + 92);

-- ----------------------------------------------------------------------------
-- 2.14. SEED DATA
-- ----------------------------------------------------------------------------

INSERT INTO marketing.channels (channel_code, channel_name, channel_group, is_paid) VALUES
    ('google_search',    'Google Search Ads',   'paid_search',    TRUE),
    ('google_display',   'Google Display',      'display',        TRUE),
    ('meta_facebook',    'Meta Facebook',       'paid_social',    TRUE),
    ('meta_instagram',   'Meta Instagram',      'paid_social',    TRUE),
    ('linkedin',         'LinkedIn Ads',        'paid_social',    TRUE),
    ('tiktok',           'TikTok Ads',          'paid_social',    TRUE),
    ('apple_search_ads', 'Apple Search Ads',    'app_store',      TRUE),
    ('organic_search',   'Organic Search',      'organic_search', FALSE),
    ('organic_social',   'Organic Social',      'organic_social', FALSE),
    ('app_store_organic','App Store Organic',   'app_store',      FALSE),
    ('referral_program', 'Customer Referral',   'referral',       FALSE),
    ('partner',          'Partner',             'partner',        FALSE),
    ('email',            'E-mail',              'email',          FALSE),
    ('direct',           'Direct',              'direct',         FALSE)
ON CONFLICT (channel_code) DO NOTHING;

-- Payment system names only (no integration is configured by this script).
INSERT INTO billing.payment_systems (payment_system_code, payment_system_name) VALUES
    ('card',              'Credit / Debit Card'),
    ('sepa_direct_debit', 'SEPA Direct Debit'),
    ('bank_transfer',     'Bank Transfer'),
    ('paypal',            'PayPal'),
    ('apple_pay',         'Apple Pay'),
    ('google_pay',        'Google Pay'),
    ('klarna',            'Klarna'),
    ('other',             'Other')
ON CONFLICT (payment_system_code) DO NOTHING;

INSERT INTO billing.churn_reasons (reason_code, reason_label, is_voluntary) VALUES
    ('price_too_high',       'Price too high',              TRUE),
    ('not_enough_freight',   'Not enough freight offers',   TRUE),
    ('missing_features',     'Missing features',            TRUE),
    ('technical_issues',     'Technical issues',            TRUE),
    ('switching_competitor', 'Switching to competitor',     TRUE),
    ('business_closed',      'Business closed',             TRUE),
    ('seasonal_pause',       'Seasonal pause',              TRUE),
    ('payment_failed',       'Payment failed (dunning)',    FALSE),
    ('other',                'Other',                       TRUE)
ON CONFLICT (reason_code) DO NOTHING;

INSERT INTO billing.plans (plan_code, plan_name, target_account_type, tier_rank) VALUES
    ('PLAN-SOLO',       'Solo Driver',        'solo_carrier',  1),
    ('PLAN-FLEET-SMB',  'Fleet Operator SMB', 'fleet_company', 2),
    ('PLAN-FLEET-PRO',  'Fleet Operator Pro', 'fleet_company', 3)
ON CONFLICT (plan_code) DO NOTHING;

-- Prices taken over from v2. PLAN-FLEET-PRO has only a monthly price in v2;
-- an annual price is NOT invented here.
INSERT INTO billing.plan_prices (plan_code, billing_interval, currency_code, unit_amount, valid_from) VALUES
    ('PLAN-SOLO',      'month', 'EUR',  29.00, DATE '2026-01-01'),
    ('PLAN-SOLO',      'year',  'EUR', 290.00, DATE '2026-01-01'),
    ('PLAN-FLEET-SMB', 'month', 'EUR',  99.00, DATE '2026-01-01'),
    ('PLAN-FLEET-SMB', 'year',  'EUR', 990.00, DATE '2026-01-01'),
    ('PLAN-FLEET-PRO', 'month', 'EUR', 299.00, DATE '2026-01-01');

INSERT INTO billing.features (feature_code, feature_name, value_type, unit, description) VALUES
    ('max_vehicles',          'Vehicles on the platform',     'limit',   'vehicles',          'Maximum number of active vehicles'),
    ('max_driver_logins',     'Driver logins',                'limit',   'users',             'Maximum number of active driver memberships'),
    ('freight_matching',      'Freight exchange matching',    'boolean', NULL,                'Accept and confirm published orders'),
    ('advanced_telematics',   'Advanced telematics',          'boolean', NULL,                'GPS deviation analytics and delay alerts'),
    ('api_access',            'REST API access',              'boolean', NULL,                'Integration with customer ERP / TMS'),
    ('ai_assistant_queries',  'AI assistant queries',         'limit',   'queries_per_month', 'Monthly quota of AI assistant questions (future)')
ON CONFLICT (feature_code) DO NOTHING;

INSERT INTO billing.plan_entitlements (plan_code, feature_code, is_enabled, limit_value) VALUES
    ('PLAN-SOLO',      'max_vehicles',         TRUE,   1),
    ('PLAN-SOLO',      'max_driver_logins',    TRUE,   1),
    ('PLAN-SOLO',      'freight_matching',     TRUE,   NULL),
    ('PLAN-SOLO',      'advanced_telematics',  FALSE,  NULL),
    ('PLAN-SOLO',      'api_access',           FALSE,  NULL),
    ('PLAN-SOLO',      'ai_assistant_queries', FALSE,  0),
    ('PLAN-FLEET-SMB', 'max_vehicles',         TRUE,  10),
    ('PLAN-FLEET-SMB', 'max_driver_logins',    TRUE,  10),
    ('PLAN-FLEET-SMB', 'freight_matching',     TRUE,   NULL),
    ('PLAN-FLEET-SMB', 'advanced_telematics',  TRUE,   NULL),
    ('PLAN-FLEET-SMB', 'api_access',           TRUE,   NULL),
    ('PLAN-FLEET-SMB', 'ai_assistant_queries', FALSE,  0),
    ('PLAN-FLEET-PRO', 'max_vehicles',         TRUE,  50),
    ('PLAN-FLEET-PRO', 'max_driver_logins',    TRUE,  50),
    ('PLAN-FLEET-PRO', 'freight_matching',     TRUE,   NULL),
    ('PLAN-FLEET-PRO', 'advanced_telematics',  TRUE,   NULL),
    ('PLAN-FLEET-PRO', 'api_access',           TRUE,   NULL),
    ('PLAN-FLEET-PRO', 'ai_assistant_queries', FALSE,  0)
ON CONFLICT (plan_code, feature_code) DO NOTHING;

INSERT INTO analytics.metric_definitions (metric_code, metric_name, description, formula, source_object, grain, unit) VALUES
    ('signup_to_paid_conversion', 'Sign-up to Paid Conversion',
     'Share of accounts of a sign-up cohort that made at least one successful payment.',
     'COUNT(first_paid_at) / COUNT(*) per cohort_month', 'analytics.v_conversion_funnel.signup_to_paid_pct', 'cohort_month x account_type', '%'),
    ('days_to_first_payment', 'Days to First Payment',
     'Time from sign-up to the first successful payment (conversion moment).',
     'first_paid_at - signed_up_at', 'analytics.v_account_360.days_signup_to_first_payment', 'account', 'days'),
    ('trial_to_paid_conversion', 'Trial to Paid Conversion',
     'Share of accounts that started a trial and later paid.',
     'COUNT(first_paid_at) / COUNT(trial_started_at)', 'analytics.v_conversion_funnel.trial_to_paid_pct', 'cohort_month x account_type', '%'),
    ('activation', 'Activation (v1)',
     'Carrier: first completed delivery. Shipper: first published order. Detected by the nightly job.',
     'first day with deliveries_completed > 0 (billable) or orders_published > 0 (shipper)', 'app.accounts.activated_at', 'account', 'timestamp'),
    ('mrr', 'Monthly Recurring Revenue',
     'Normalised recurring revenue of active and past_due subscriptions (price divided by the months of the paid term: 1, 3, 6 or 12), in EUR.',
     'SUM(mrr_amount_eur) at snapshot date', 'analytics.fct_mrr_daily', 'day', 'EUR'),
    ('logo_churn_rate', 'Logo Churn Rate',
     'Paying accounts at month start that have MRR = 0 at month end.',
     'churned_accounts / paying_accounts_start', 'analytics.fct_unit_economics_monthly.logo_churn_rate_pct', 'month x segment', '%'),
    ('net_revenue_retention', 'Net Revenue Retention',
     'MRR retained from accounts paying at month start, including expansion.',
     '(mrr_start + expansion - contraction - churned_mrr) / mrr_start', 'analytics.fct_unit_economics_monthly.net_revenue_retention_pct', 'month x segment', '%'),
    ('cac', 'Customer Acquisition Cost',
     'Ad spend of the month divided by accounts that became paying for the first time in that month.',
     'ad_spend_eur / new_paying_accounts', 'analytics.fct_unit_economics_monthly.cac_eur', 'month x segment', 'EUR'),
    ('ltv', 'Customer Lifetime Value',
     'ARPA multiplied by gross margin and divided by trailing 3-month logo churn.',
     'arpa_eur * gross_margin_pct / trailing_3m_churn_pct', 'analytics.fct_unit_economics_monthly.ltv_eur', 'month x segment', 'EUR'),
    ('gross_margin', 'Gross Margin',
     'MRR minus payment-provider fees and platform operating costs, divided by MRR.',
     '(mrr_end - payment_fees - platform_costs) / mrr_end', 'analytics.fct_unit_economics_monthly.gross_margin_pct', 'month', '%')
ON CONFLICT (metric_code) DO NOTHING;

-- ############################################################################
-- PART 3. CUSTOMER-FACING LOGISTICS KPIs — STAR SCHEMA + REFRESH QUEUE
-- (from 05_smartlog_logistics_kpi_star_schema.sql)
-- Revenue: deliveries 'delivered' with order 'delivered' / 'closed', dated by
-- completion (Europe/Berlin). Costs: cost_amount_eur + driver_payout_eur,
-- private expenses excluded.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 3.1. DIMENSION: DATE + GERMAN PUBLIC HOLIDAYS
-- ----------------------------------------------------------------------------

-- 3.1.1. Public holidays per country and region (ISO 3166-2 subdivision code
--      without country prefix: 'BY', 'NW', ... ; 'ALL' = nationwide).
--      Seeded by rule for Germany; other countries are added when activated.
--      Rules reflect the state as known in 2026 — verify against the
--      official sources of the Länder before relying on them for planning.
CREATE TABLE analytics.dim_public_holiday (
    holiday_date          date NOT NULL,
    country_code          char(2) NOT NULL,
    region_code           varchar(3) NOT NULL DEFAULT 'ALL',
    holiday_name          varchar(80) NOT NULL,
    holiday_name_en       varchar(80) NOT NULL,
    PRIMARY KEY (holiday_date, country_code, region_code)
);

CREATE OR REPLACE FUNCTION analytics.easter_sunday(p_year integer) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    a int := p_year % 19;  b int := p_year / 100;  c int := p_year % 100;
    d int := b / 4;        e int := b % 4;         f int := (b + 8) / 25;
    g int := (b - f + 1) / 3;
    h int := (19 * a + b - d - g + 15) % 30;
    i int := c / 4;        k int := c % 4;
    l int := (32 + 2 * e + 2 * i - h - k) % 7;
    m int := (a + 11 * h + 22 * l) / 451;
BEGIN
    RETURN make_date(p_year, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
END;
$$;

CREATE OR REPLACE FUNCTION analytics.seed_public_holidays_de(p_from_year integer, p_to_year integer)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_year   integer;
    v_easter date;
    v_rows   integer := 0;
    v_n      integer;
BEGIN
    FOR v_year IN p_from_year .. p_to_year LOOP
        v_easter := analytics.easter_sunday(v_year);

        INSERT INTO analytics.dim_public_holiday (holiday_date, country_code, region_code, holiday_name, holiday_name_en)
        SELECT h.d, 'DE', r.region, h.name_de, h.name_en
        FROM (VALUES
            (make_date(v_year, 1, 1),   'Neujahr',                    'New Year''s Day',        ARRAY['ALL'], 1900),
            (make_date(v_year, 1, 6),   'Heilige Drei Könige',        'Epiphany',               ARRAY['BW','BY','ST'], 1900),
            (make_date(v_year, 3, 8),   'Internationaler Frauentag',  'International Women''s Day', ARRAY['BE'], 2019),
            (make_date(v_year, 3, 8),   'Internationaler Frauentag',  'International Women''s Day', ARRAY['MV'], 2023),
            (v_easter - 2,              'Karfreitag',                 'Good Friday',            ARRAY['ALL'], 1900),
            (v_easter + 1,              'Ostermontag',                'Easter Monday',          ARRAY['ALL'], 1900),
            (make_date(v_year, 5, 1),   'Tag der Arbeit',             'Labour Day',             ARRAY['ALL'], 1900),
            (v_easter + 39,             'Christi Himmelfahrt',        'Ascension Day',          ARRAY['ALL'], 1900),
            (v_easter + 50,             'Pfingstmontag',              'Whit Monday',            ARRAY['ALL'], 1900),
            (v_easter + 60,             'Fronleichnam',               'Corpus Christi',         ARRAY['BW','BY','HE','NW','RP','SL'], 1900),
            (make_date(v_year, 8, 15),  'Mariä Himmelfahrt',          'Assumption Day',         ARRAY['SL'], 1900),
            (make_date(v_year, 9, 20),  'Weltkindertag',              'World Children''s Day',  ARRAY['TH'], 2019),
            (make_date(v_year, 10, 3),  'Tag der Deutschen Einheit',  'German Unity Day',       ARRAY['ALL'], 1900),
            (make_date(v_year, 10, 31), 'Reformationstag',            'Reformation Day',        ARRAY['BB','MV','SN','ST','TH'], 1900),
            (make_date(v_year, 10, 31), 'Reformationstag',            'Reformation Day',        ARRAY['HB','HH','NI','SH'], 2018),
            (make_date(v_year, 11, 1),  'Allerheiligen',              'All Saints'' Day',       ARRAY['BW','BY','NW','RP','SL'], 1900),
            (make_date(v_year, 11, 22) - ((EXTRACT(ISODOW FROM make_date(v_year, 11, 22))::int - 3 + 7) % 7),
                                        'Buß- und Bettag',            'Day of Repentance',      ARRAY['SN'], 1900),
            (make_date(v_year, 12, 25), '1. Weihnachtstag',           'Christmas Day',          ARRAY['ALL'], 1900),
            (make_date(v_year, 12, 26), '2. Weihnachtstag',           'Boxing Day',             ARRAY['ALL'], 1900)
        ) AS h(d, name_de, name_en, regions, since_year)
        CROSS JOIN LATERAL unnest(h.regions) AS r(region)
        WHERE v_year >= h.since_year
        ON CONFLICT DO NOTHING;

        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_rows := v_rows + v_n;
    END LOOP;
    RETURN v_rows;
END;
$$;

-- 3.1.2. Calendar dimension (one row per day).
CREATE TABLE analytics.dim_date (
    date_key                  date PRIMARY KEY,
    year                      smallint NOT NULL,
    quarter                   smallint NOT NULL,
    month                     smallint NOT NULL,
    month_start               date NOT NULL,
    month_name_en             varchar(10) NOT NULL,
    iso_year                  smallint NOT NULL,
    iso_week                  smallint NOT NULL,
    week_start                date NOT NULL,                            -- Monday
    day_of_month              smallint NOT NULL,
    iso_day_of_week           smallint NOT NULL,                        -- 1 = Monday .. 7 = Sunday
    day_name_en               varchar(10) NOT NULL,
    is_weekend                boolean NOT NULL,
    is_holiday_de_nationwide  boolean NOT NULL DEFAULT FALSE,
    de_holiday_regions        varchar(3)[] NOT NULL DEFAULT '{}',       -- Länder with a holiday that day
    holiday_name_de           varchar(80),
    is_working_day_de         boolean NOT NULL                          -- Mon-Fri and no nationwide holiday
);

CREATE INDEX idx_dim_date_month ON analytics.dim_date(month_start);
CREATE INDEX idx_dim_date_week ON analytics.dim_date(week_start);

CREATE OR REPLACE FUNCTION analytics.ensure_dim_date(p_from date, p_to date)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_rows integer;
BEGIN
    PERFORM analytics.seed_public_holidays_de(EXTRACT(YEAR FROM p_from)::int, EXTRACT(YEAR FROM p_to)::int);

    INSERT INTO analytics.dim_date AS d (
        date_key, year, quarter, month, month_start, month_name_en, iso_year, iso_week, week_start,
        day_of_month, iso_day_of_week, day_name_en, is_weekend,
        is_holiday_de_nationwide, de_holiday_regions, holiday_name_de, is_working_day_de)
    SELECT g::date,
           EXTRACT(YEAR FROM g)::smallint, EXTRACT(QUARTER FROM g)::smallint, EXTRACT(MONTH FROM g)::smallint,
           date_trunc('month', g)::date, trim(to_char(g, 'Month')),
           EXTRACT(ISOYEAR FROM g)::smallint, EXTRACT(WEEK FROM g)::smallint, date_trunc('week', g)::date,
           EXTRACT(DAY FROM g)::smallint, EXTRACT(ISODOW FROM g)::smallint, trim(to_char(g, 'Day')),
           EXTRACT(ISODOW FROM g) IN (6, 7),
           COALESCE(h.nationwide, FALSE), COALESCE(h.regions, '{}'), h.name,
           EXTRACT(ISODOW FROM g) NOT IN (6, 7) AND NOT COALESCE(h.nationwide, FALSE)
    FROM generate_series(p_from, p_to, INTERVAL '1 day') g
    LEFT JOIN LATERAL (
        SELECT bool_or(region_code = 'ALL')                                         AS nationwide,
               array_agg(DISTINCT region_code ORDER BY region_code) FILTER (WHERE region_code <> 'ALL') AS regions,
               min(holiday_name)                                                    AS name
        FROM analytics.dim_public_holiday
        WHERE holiday_date = g::date AND country_code = 'DE'
    ) h ON TRUE
    ON CONFLICT (date_key) DO UPDATE SET
        is_holiday_de_nationwide = EXCLUDED.is_holiday_de_nationwide,
        de_holiday_regions       = EXCLUDED.de_holiday_regions,
        holiday_name_de          = EXCLUDED.holiday_name_de,
        is_working_day_de        = EXCLUDED.is_working_day_de;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3.2. FACT TABLES
-- ----------------------------------------------------------------------------

-- 3.2.1. One row per delivered delivery (revenue recognised).
CREATE TABLE analytics.fct_delivery (
    delivery_id               varchar(32) PRIMARY KEY,
    order_id                  varchar(32) NOT NULL,
    completion_date           date NOT NULL REFERENCES analytics.dim_date(date_key),
    completed_at              timestamptz NOT NULL,
    carrier_client_id         varchar(32),                              -- tenant that earned the revenue
    carrier_account_id        uuid,
    shipper_client_id         varchar(32) NOT NULL,                     -- tenant that paid the freight
    shipper_account_id        uuid,
    driver_id                 varchar(32),
    vehicle_id                varchar(32),
    order_status              varchar(20) NOT NULL,                     -- 'delivered' | 'closed'
    is_revenue_confirmed      boolean NOT NULL,                         -- order closed by customer / accountant
    revenue_share             numeric(9,6) NOT NULL,                    -- share of the order amount
    revenue_net_eur           numeric(12,2) NOT NULL,
    vat_rate_pct              numeric(4,2) NOT NULL,
    is_reverse_charge         boolean NOT NULL,
    cargo_type                varchar(20),
    cargo_weight_kg           numeric(10,2),
    origin_country            char(2) NOT NULL,
    origin_postal_code        varchar(10),
    destination_country       char(2) NOT NULL,
    destination_postal_code   varchar(10),
    is_cross_border           boolean NOT NULL,
    planned_distance_km       numeric(8,2),
    actual_distance_km        numeric(8,2),
    distance_km               numeric(8,2) NOT NULL,                    -- actual, else planned
    delay_minutes             integer NOT NULL DEFAULT 0,
    is_on_time                boolean NOT NULL,
    is_driver_liable          boolean NOT NULL,
    incident_type             varchar(40),
    customer_rating_stars     numeric(2,1),
    direct_costs_eur          numeric(12,2) NOT NULL DEFAULT 0,         -- costs booked on this delivery
    refreshed_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_fct_delivery_carrier_date ON analytics.fct_delivery(carrier_client_id, completion_date);
CREATE INDEX idx_fct_delivery_shipper_date ON analytics.fct_delivery(shipper_client_id, completion_date);
CREATE INDEX idx_fct_delivery_driver_date  ON analytics.fct_delivery(driver_id, completion_date);
CREATE INDEX idx_fct_delivery_vehicle_date ON analytics.fct_delivery(vehicle_id, completion_date);

-- 3.2.2. One row per cost line (private expenses kept but flagged).
CREATE TABLE analytics.fct_cost (
    cost_id                   varchar(32) PRIMARY KEY,
    cost_date                 date NOT NULL REFERENCES analytics.dim_date(date_key),
    client_id                 varchar(32) NOT NULL,
    account_id                uuid,
    cost_type                 varchar(20) NOT NULL,
    cost_subtype              varchar(32) NOT NULL,
    is_repair                 boolean NOT NULL,
    cost_amount_eur           numeric(12,2) NOT NULL,
    driver_payout_eur         numeric(12,2) NOT NULL,
    total_cost_eur            numeric(12,2) GENERATED ALWAYS AS (cost_amount_eur + driver_payout_eur) STORED,
    is_private_expense        boolean NOT NULL,
    delivery_id               varchar(32),
    driver_id                 varchar(32),
    vehicle_id                varchar(32),
    fuel_liters               numeric(8,2),
    refreshed_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_fct_cost_client_date  ON analytics.fct_cost(client_id, cost_date);
CREATE INDEX idx_fct_cost_driver_date  ON analytics.fct_cost(driver_id, cost_date);
CREATE INDEX idx_fct_cost_vehicle_date ON analytics.fct_cost(vehicle_id, cost_date);

-- ----------------------------------------------------------------------------
-- 3.3. DAILY AGGREGATES (what the app screens read)
-- ----------------------------------------------------------------------------

CREATE TABLE analytics.agg_carrier_kpi_daily (
    kpi_date                  date NOT NULL REFERENCES analytics.dim_date(date_key),
    client_id                 varchar(32) NOT NULL,
    account_id                uuid,
    deliveries_completed      integer NOT NULL DEFAULT 0,
    deliveries_on_time        integer NOT NULL DEFAULT 0,
    revenue_net_eur           numeric(14,2) NOT NULL DEFAULT 0,
    revenue_confirmed_net_eur numeric(14,2) NOT NULL DEFAULT 0,
    distance_km               numeric(12,2) NOT NULL DEFAULT 0,
    fuel_costs_eur            numeric(14,2) NOT NULL DEFAULT 0,
    maintenance_costs_eur     numeric(14,2) NOT NULL DEFAULT 0,
    driver_pay_eur            numeric(14,2) NOT NULL DEFAULT 0,         -- work_reward costs + all driver payouts
    other_costs_eur           numeric(14,2) NOT NULL DEFAULT 0,
    total_costs_eur           numeric(14,2) GENERATED ALWAYS AS
                                  (fuel_costs_eur + maintenance_costs_eur + driver_pay_eur + other_costs_eur) STORED,
    profit_eur                numeric(14,2) GENERATED ALWAYS AS
                                  (revenue_net_eur - fuel_costs_eur - maintenance_costs_eur - driver_pay_eur - other_costs_eur) STORED,
    fuel_liters               numeric(12,2) NOT NULL DEFAULT 0,
    private_expenses_eur      numeric(14,2) NOT NULL DEFAULT 0,         -- solo drivers: shown separately
    refreshed_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (kpi_date, client_id)
);

CREATE INDEX idx_agg_carrier_client_date ON analytics.agg_carrier_kpi_daily(client_id, kpi_date);
CREATE INDEX idx_agg_carrier_account_date ON analytics.agg_carrier_kpi_daily(account_id, kpi_date);

CREATE TABLE analytics.agg_driver_kpi_daily (
    kpi_date                  date NOT NULL REFERENCES analytics.dim_date(date_key),
    driver_id                 varchar(32) NOT NULL,
    client_id                 varchar(32) NOT NULL,                     -- employer / own company
    account_id                uuid,
    deliveries_completed      integer NOT NULL DEFAULT 0,
    deliveries_on_time        integer NOT NULL DEFAULT 0,
    deliveries_driver_liable  integer NOT NULL DEFAULT 0,
    distance_km               numeric(12,2) NOT NULL DEFAULT 0,
    ratings_count             integer NOT NULL DEFAULT 0,
    ratings_sum               numeric(10,1) NOT NULL DEFAULT 0,
    driver_payout_eur         numeric(14,2) NOT NULL DEFAULT 0,         -- visible to the driver
    revenue_net_eur           numeric(14,2) NOT NULL DEFAULT 0,         -- owner only (column grant)
    direct_costs_eur          numeric(14,2) NOT NULL DEFAULT 0,         -- owner only (column grant)
    refreshed_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (kpi_date, driver_id)
);

CREATE INDEX idx_agg_driver_client_date ON analytics.agg_driver_kpi_daily(client_id, kpi_date);

CREATE TABLE analytics.agg_shipper_kpi_daily (
    kpi_date                  date NOT NULL REFERENCES analytics.dim_date(date_key),
    client_id                 varchar(32) NOT NULL,
    account_id                uuid,
    shipments_delivered       integer NOT NULL DEFAULT 0,
    shipments_on_time         integer NOT NULL DEFAULT 0,
    freight_spend_net_eur     numeric(14,2) NOT NULL DEFAULT 0,
    freight_spend_confirmed_net_eur numeric(14,2) NOT NULL DEFAULT 0,
    cargo_weight_kg           numeric(14,2) NOT NULL DEFAULT 0,
    distance_km               numeric(12,2) NOT NULL DEFAULT 0,
    cross_border_shipments    integer NOT NULL DEFAULT 0,
    refreshed_at              timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (kpi_date, client_id)
);

CREATE INDEX idx_agg_shipper_account_date ON analytics.agg_shipper_kpi_daily(account_id, kpi_date);

-- ----------------------------------------------------------------------------
-- 3.4. REFRESH (full window or tenant-scoped)
-- ----------------------------------------------------------------------------

-- Rebuilds facts for completion / cost dates in [p_from, p_to] (Berlin days)
-- and re-aggregates every touched day. Idempotent.
--   p_client_ids        NULL = all tenants (nightly reconciliation);
--                       array = only these carriers / shippers (event queue).
--   p_include_late_costs TRUE = also pick up costs entered since p_from with
--                       another cost_date (nightly); the queue passes FALSE
--                       because every cost change enqueues its own dates.
DROP FUNCTION IF EXISTS analytics.refresh_logistics_star(date, date);   -- earlier 2-argument version

CREATE OR REPLACE FUNCTION analytics.refresh_logistics_star(
    p_from               date,
    p_to                 date DEFAULT CURRENT_DATE,
    p_client_ids         varchar[] DEFAULT NULL,
    p_include_late_costs boolean DEFAULT TRUE
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_from_ts   timestamptz := p_from::timestamp AT TIME ZONE 'Europe/Berlin';
    v_to_ts     timestamptz := (p_to + 1)::timestamp AT TIME ZONE 'Europe/Berlin';
    v_all       boolean := p_client_ids IS NULL;
    v_min_date  date;
    v_max_date  date;
    v_deliv     integer;
    v_costs     integer;
    v_days      integer;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS tmp_touched_days (d date PRIMARY KEY) ON COMMIT DROP;
    CREATE TEMP TABLE IF NOT EXISTS tmp_late_costs (cost_id varchar(32) PRIMARY KEY) ON COMMIT DROP;
    TRUNCATE tmp_touched_days;
    TRUNCATE tmp_late_costs;
    INSERT INTO tmp_touched_days SELECT g::date FROM generate_series(p_from, p_to, INTERVAL '1 day') g;

    IF p_include_late_costs THEN
        -- back- / forward-dated costs entered inside the window
        INSERT INTO tmp_late_costs
        SELECT c.cost_id FROM core.costs c
        WHERE c.created_at >= v_from_ts AND c.cost_date NOT BETWEEN p_from AND p_to
          AND (v_all OR c.client_id = ANY(p_client_ids));
        INSERT INTO tmp_touched_days
        SELECT DISTINCT c.cost_date FROM core.costs c JOIN tmp_late_costs l USING (cost_id)
        ON CONFLICT DO NOTHING;
        -- previous date / owner of costs that were re-dated or moved
        INSERT INTO tmp_touched_days
        SELECT DISTINCT f.cost_date FROM analytics.fct_cost f JOIN core.costs c USING (cost_id)
        WHERE (c.cost_date <> f.cost_date OR c.client_id <> f.client_id)
          AND (c.created_at >= v_from_ts OR c.cost_date BETWEEN p_from AND p_to)
          AND (v_all OR f.client_id = ANY(p_client_ids) OR c.client_id = ANY(p_client_ids))
        ON CONFLICT DO NOTHING;
    END IF;

    SELECT MIN(d), MAX(d) INTO v_min_date, v_max_date FROM tmp_touched_days;
    IF (SELECT COUNT(*) FROM analytics.dim_date WHERE date_key BETWEEN v_min_date AND v_max_date)
       < (v_max_date - v_min_date + 1) THEN
        PERFORM analytics.ensure_dim_date(v_min_date, GREATEST(v_max_date, CURRENT_DATE));
    END IF;

    -- ---------------------------------------------------------------- deliveries: delete + rebuild
    DELETE FROM analytics.fct_delivery f
    WHERE f.completion_date BETWEEN p_from AND p_to
      AND (v_all OR f.carrier_client_id = ANY(p_client_ids) OR f.shipper_client_id = ANY(p_client_ids));

    WITH src_base AS (
        SELECT d.delivery_id, d.order_id, d.driver_id, d.vehicle_id, d.actual_end_time,
               d.planned_distance_km, d.actual_distance_km, d.delay_minutes, d.delay_status,
               d.is_driver_liable, d.incident_type, d.customer_rating_stars,
               COALESCE(dr.linked_client_id,
                        CASE WHEN o.executor_type = 'carrier_company' THEN o.executor_id END) AS carrier_client_id,
               o.client_id AS shipper_client_id, o.status, o.amount_eur, o.vat_rate_pct, o.is_reverse_charge,
               o.cargo_type, o.cargo_weight_kg, o.origin_country, o.origin_postal_code,
               o.destination_country, o.destination_postal_code
        FROM core.deliveries d
        JOIN core.orders o ON o.order_id = d.order_id
        LEFT JOIN core.drivers dr ON dr.driver_id = d.driver_id
        WHERE d.actual_end_time >= v_from_ts AND d.actual_end_time < v_to_ts
          AND d.delivery_status = 'delivered'
          AND o.status IN ('delivered', 'closed')
          AND NOT d.is_test AND NOT o.is_test
    ),
    src_scoped AS (
        SELECT * FROM src_base s
        WHERE v_all OR s.carrier_client_id = ANY(p_client_ids) OR s.shipper_client_id = ANY(p_client_ids)
    ),
    order_split AS (
        SELECT d.order_id, SUM(d.planned_distance_km) AS order_km, COUNT(*) AS order_deliveries
        FROM core.deliveries d
        WHERE d.delivery_status <> 'cancelled' AND d.order_id IN (SELECT order_id FROM src_scoped)
        GROUP BY d.order_id
    ),
    direct AS (
        SELECT c.delivery_id, SUM(c.cost_amount_eur + c.driver_payout_eur) AS amount
        FROM core.costs c
        WHERE c.delivery_id IN (SELECT delivery_id FROM src_scoped)
          AND NOT c.is_private_expense AND NOT c.is_test
        GROUP BY c.delivery_id
    ),
    src AS (
        SELECT s.*,
               (s.actual_end_time AT TIME ZONE 'Europe/Berlin')::date AS completion_date,
               CASE WHEN sp.order_deliveries <= 1 OR COALESCE(sp.order_km, 0) = 0
                    THEN 1.0 / GREATEST(sp.order_deliveries, 1)
                    ELSE s.planned_distance_km / sp.order_km END AS share,
               COALESCE(di.amount, 0) AS direct_costs
        FROM src_scoped s
        LEFT JOIN order_split sp ON sp.order_id = s.order_id
        LEFT JOIN direct di ON di.delivery_id = s.delivery_id
    )
    INSERT INTO analytics.fct_delivery AS f (
        delivery_id, order_id, completion_date, completed_at, carrier_client_id, carrier_account_id,
        shipper_client_id, shipper_account_id, driver_id, vehicle_id, order_status, is_revenue_confirmed,
        revenue_share, revenue_net_eur, vat_rate_pct, is_reverse_charge, cargo_type, cargo_weight_kg,
        origin_country, origin_postal_code, destination_country, destination_postal_code, is_cross_border,
        planned_distance_km, actual_distance_km, distance_km, delay_minutes, is_on_time, is_driver_liable,
        incident_type, customer_rating_stars, direct_costs_eur, refreshed_at)
    SELECT src.delivery_id, src.order_id, src.completion_date, src.actual_end_time,
           src.carrier_client_id, ca.account_id, src.shipper_client_id, sa.account_id,
           src.driver_id, src.vehicle_id, src.status::text, (src.status = 'closed'),
           ROUND(src.share, 6), ROUND(src.amount_eur * src.share, 2), src.vat_rate_pct, src.is_reverse_charge,
           src.cargo_type::text, src.cargo_weight_kg * src.share,
           src.origin_country, src.origin_postal_code, src.destination_country, src.destination_postal_code,
           src.origin_country <> src.destination_country,
           src.planned_distance_km, src.actual_distance_km, COALESCE(src.actual_distance_km, src.planned_distance_km, 0),
           COALESCE(src.delay_minutes, 0), (COALESCE(src.delay_status::text, 'on_time') = 'on_time'),
           src.is_driver_liable, src.incident_type::text, src.customer_rating_stars,
           src.direct_costs, CURRENT_TIMESTAMP
    FROM src
    LEFT JOIN app.accounts ca ON ca.client_id = src.carrier_client_id
    LEFT JOIN app.accounts sa ON sa.client_id = src.shipper_client_id
    ON CONFLICT (delivery_id) DO UPDATE SET                             -- fact moved in from another date
        order_id = EXCLUDED.order_id, completion_date = EXCLUDED.completion_date, completed_at = EXCLUDED.completed_at,
        carrier_client_id = EXCLUDED.carrier_client_id, carrier_account_id = EXCLUDED.carrier_account_id,
        shipper_client_id = EXCLUDED.shipper_client_id, shipper_account_id = EXCLUDED.shipper_account_id,
        driver_id = EXCLUDED.driver_id, vehicle_id = EXCLUDED.vehicle_id, order_status = EXCLUDED.order_status,
        is_revenue_confirmed = EXCLUDED.is_revenue_confirmed, revenue_share = EXCLUDED.revenue_share,
        revenue_net_eur = EXCLUDED.revenue_net_eur, vat_rate_pct = EXCLUDED.vat_rate_pct,
        is_reverse_charge = EXCLUDED.is_reverse_charge, cargo_type = EXCLUDED.cargo_type,
        cargo_weight_kg = EXCLUDED.cargo_weight_kg, origin_country = EXCLUDED.origin_country,
        origin_postal_code = EXCLUDED.origin_postal_code, destination_country = EXCLUDED.destination_country,
        destination_postal_code = EXCLUDED.destination_postal_code, is_cross_border = EXCLUDED.is_cross_border,
        planned_distance_km = EXCLUDED.planned_distance_km, actual_distance_km = EXCLUDED.actual_distance_km,
        distance_km = EXCLUDED.distance_km, delay_minutes = EXCLUDED.delay_minutes, is_on_time = EXCLUDED.is_on_time,
        is_driver_liable = EXCLUDED.is_driver_liable, incident_type = EXCLUDED.incident_type,
        customer_rating_stars = EXCLUDED.customer_rating_stars, direct_costs_eur = EXCLUDED.direct_costs_eur,
        refreshed_at = EXCLUDED.refreshed_at;
    GET DIAGNOSTICS v_deliv = ROW_COUNT;

    -- ---------------------------------------------------------------- costs: delete + rebuild
    DELETE FROM analytics.fct_cost f
    WHERE (f.cost_date BETWEEN p_from AND p_to OR f.cost_id IN (SELECT cost_id FROM tmp_late_costs))
      AND (v_all OR f.client_id = ANY(p_client_ids));

    INSERT INTO analytics.fct_cost AS f (
        cost_id, cost_date, client_id, account_id, cost_type, cost_subtype, is_repair, cost_amount_eur,
        driver_payout_eur, is_private_expense, delivery_id, driver_id, vehicle_id, fuel_liters, refreshed_at)
    SELECT c.cost_id, c.cost_date, c.client_id, a.account_id, c.cost_type::text, c.cost_subtype, c.is_repair,
           c.cost_amount_eur, c.driver_payout_eur, c.is_private_expense, c.delivery_id, c.driver_id, c.vehicle_id,
           c.fuel_liters, CURRENT_TIMESTAMP
    FROM core.costs c
    LEFT JOIN app.accounts a ON a.client_id = c.client_id
    WHERE NOT c.is_test AND c.client_id IS NOT NULL
      AND (c.cost_date BETWEEN p_from AND p_to OR c.cost_id IN (SELECT cost_id FROM tmp_late_costs))
      AND (v_all OR c.client_id = ANY(p_client_ids))
    ON CONFLICT (cost_id) DO UPDATE SET                                 -- cost moved in from another date / owner
        cost_date = EXCLUDED.cost_date, client_id = EXCLUDED.client_id, account_id = EXCLUDED.account_id,
        cost_type = EXCLUDED.cost_type, cost_subtype = EXCLUDED.cost_subtype, is_repair = EXCLUDED.is_repair,
        cost_amount_eur = EXCLUDED.cost_amount_eur, driver_payout_eur = EXCLUDED.driver_payout_eur,
        is_private_expense = EXCLUDED.is_private_expense, delivery_id = EXCLUDED.delivery_id,
        driver_id = EXCLUDED.driver_id, vehicle_id = EXCLUDED.vehicle_id, fuel_liters = EXCLUDED.fuel_liters,
        refreshed_at = EXCLUDED.refreshed_at;
    GET DIAGNOSTICS v_costs = ROW_COUNT;

    -- ---------------------------------------------------------------- aggregates of touched days (scoped)
    SELECT COUNT(*) INTO v_days FROM tmp_touched_days;

    DELETE FROM analytics.agg_carrier_kpi_daily
    WHERE kpi_date IN (SELECT d FROM tmp_touched_days) AND (v_all OR client_id = ANY(p_client_ids));
    DELETE FROM analytics.agg_driver_kpi_daily
    WHERE kpi_date IN (SELECT d FROM tmp_touched_days) AND (v_all OR client_id = ANY(p_client_ids));
    DELETE FROM analytics.agg_shipper_kpi_daily
    WHERE kpi_date IN (SELECT d FROM tmp_touched_days) AND (v_all OR client_id = ANY(p_client_ids));

    INSERT INTO analytics.agg_carrier_kpi_daily (
        kpi_date, client_id, account_id, deliveries_completed, deliveries_on_time, revenue_net_eur,
        revenue_confirmed_net_eur, distance_km, fuel_costs_eur, maintenance_costs_eur, driver_pay_eur,
        other_costs_eur, fuel_liters, private_expenses_eur)
    SELECT kpi_date, client_id, MAX(account_id::text)::uuid,
           SUM(deliveries), SUM(on_time), SUM(revenue), SUM(revenue_confirmed), SUM(km),
           SUM(fuel), SUM(maintenance), SUM(driver_pay), SUM(other), SUM(liters), SUM(private)
    FROM (
        SELECT f.completion_date AS kpi_date, f.carrier_client_id AS client_id, f.carrier_account_id AS account_id,
               1 AS deliveries, f.is_on_time::int AS on_time, f.revenue_net_eur AS revenue,
               CASE WHEN f.is_revenue_confirmed THEN f.revenue_net_eur ELSE 0 END AS revenue_confirmed,
               f.distance_km AS km, 0 AS fuel, 0 AS maintenance, 0 AS driver_pay, 0 AS other, 0 AS liters, 0 AS private
        FROM analytics.fct_delivery f
        WHERE f.completion_date IN (SELECT d FROM tmp_touched_days) AND f.carrier_client_id IS NOT NULL
          AND (v_all OR f.carrier_client_id = ANY(p_client_ids))
        UNION ALL
        SELECT c.cost_date, c.client_id, c.account_id, 0, 0, 0, 0, 0,
               CASE WHEN NOT c.is_private_expense AND c.cost_type = 'fuel'        THEN c.cost_amount_eur ELSE 0 END,
               CASE WHEN NOT c.is_private_expense AND c.cost_type = 'maintenance' THEN c.cost_amount_eur ELSE 0 END,
               CASE WHEN NOT c.is_private_expense THEN
                   c.driver_payout_eur + CASE WHEN c.cost_type = 'work_reward' THEN c.cost_amount_eur ELSE 0 END
                   ELSE 0 END,
               CASE WHEN NOT c.is_private_expense AND c.cost_type NOT IN ('fuel', 'maintenance', 'work_reward')
                    THEN c.cost_amount_eur ELSE 0 END,
               CASE WHEN NOT c.is_private_expense THEN COALESCE(c.fuel_liters, 0) ELSE 0 END,
               CASE WHEN c.is_private_expense THEN c.cost_amount_eur + c.driver_payout_eur ELSE 0 END
        FROM analytics.fct_cost c
        WHERE c.cost_date IN (SELECT d FROM tmp_touched_days)
          AND (v_all OR c.client_id = ANY(p_client_ids))
    ) x
    GROUP BY kpi_date, client_id;

    INSERT INTO analytics.agg_driver_kpi_daily (
        kpi_date, driver_id, client_id, account_id, deliveries_completed, deliveries_on_time,
        deliveries_driver_liable, distance_km, ratings_count, ratings_sum, driver_payout_eur,
        revenue_net_eur, direct_costs_eur)
    SELECT x.kpi_date, x.driver_id, dr.linked_client_id, MAX(a.account_id::text)::uuid,
           SUM(x.deliveries), SUM(x.on_time), SUM(x.liable), SUM(x.km), SUM(x.rated), SUM(x.rating),
           SUM(x.payout), SUM(x.revenue), SUM(x.costs)
    FROM (
        SELECT f.completion_date AS kpi_date, f.driver_id, 1 AS deliveries, f.is_on_time::int AS on_time,
               f.is_driver_liable::int AS liable, f.distance_km AS km,
               (f.customer_rating_stars IS NOT NULL)::int AS rated, COALESCE(f.customer_rating_stars, 0) AS rating,
               0 AS payout, f.revenue_net_eur AS revenue, 0 AS costs
        FROM analytics.fct_delivery f
        WHERE f.completion_date IN (SELECT d FROM tmp_touched_days) AND f.driver_id IS NOT NULL
        UNION ALL
        SELECT c.cost_date, c.driver_id, 0, 0, 0, 0, 0, 0,
               c.driver_payout_eur, 0, c.cost_amount_eur
        FROM analytics.fct_cost c
        WHERE c.cost_date IN (SELECT d FROM tmp_touched_days) AND c.driver_id IS NOT NULL AND NOT c.is_private_expense
    ) x
    JOIN core.drivers dr ON dr.driver_id = x.driver_id
    LEFT JOIN app.accounts a ON a.client_id = dr.linked_client_id
    WHERE v_all OR dr.linked_client_id = ANY(p_client_ids)
    GROUP BY x.kpi_date, x.driver_id, dr.linked_client_id;

    INSERT INTO analytics.agg_shipper_kpi_daily (
        kpi_date, client_id, account_id, shipments_delivered, shipments_on_time, freight_spend_net_eur,
        freight_spend_confirmed_net_eur, cargo_weight_kg, distance_km, cross_border_shipments)
    SELECT f.completion_date, f.shipper_client_id, MAX(f.shipper_account_id::text)::uuid,
           COUNT(*), COUNT(*) FILTER (WHERE f.is_on_time), SUM(f.revenue_net_eur),
           COALESCE(SUM(f.revenue_net_eur) FILTER (WHERE f.is_revenue_confirmed), 0),
           COALESCE(SUM(f.cargo_weight_kg), 0), SUM(f.distance_km), COUNT(*) FILTER (WHERE f.is_cross_border)
    FROM analytics.fct_delivery f
    WHERE f.completion_date IN (SELECT d FROM tmp_touched_days)
      AND (v_all OR f.shipper_client_id = ANY(p_client_ids))
    GROUP BY f.completion_date, f.shipper_client_id;

    RETURN jsonb_build_object('fact_deliveries_upserted', v_deliv, 'fact_costs_upserted', v_costs, 'days_reaggregated', v_days);
END;
$$;

-- ----------------------------------------------------------------------------
-- 3.4A. NEAR-REAL-TIME REFRESH QUEUE (target latency ~1 minute)
-- ----------------------------------------------------------------------------
-- Write path (inside the user's transaction, cheap): triggers on
-- core.deliveries / core.orders / core.costs append (client_id, kpi_date)
-- markers — old AND new values, carrier AND shipper. No aggregation here, so
-- the driver's "Delivered" button is never slowed down and concurrent
-- drivers of one fleet never lock each other (append-only, no unique key).
--
-- Worker (every minute: pg_cron, Celery beat or a systemd timer calling
-- `SELECT analytics.process_refresh_queue()`): takes a batch of distinct
-- keys, recomputes only those tenant-days, deletes the processed markers.
-- A single worker runs at a time (advisory lock); a failing key is logged in
-- analytics.refresh_failures and retried on the next run; the nightly job
-- (ops.run_nightly) reconciles the last 35 days anyway.

CREATE TABLE analytics.refresh_queue (
    queue_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id             varchar(32) NOT NULL,
    kpi_date              date NOT NULL,
    source                varchar(20) NOT NULL,                          -- deliveries | orders | costs
    enqueued_at           timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_refresh_queue_key ON analytics.refresh_queue(client_id, kpi_date, queue_id);

CREATE TABLE analytics.refresh_failures (
    failure_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kpi_date              date NOT NULL,
    client_ids            varchar(32)[] NOT NULL,
    error_message         text NOT NULL,
    failed_at             timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION analytics.enqueue_refresh(p_client_id varchar, p_ts timestamptz, p_source varchar)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO analytics.refresh_queue (client_id, kpi_date, source)
    SELECT p_client_id, (p_ts AT TIME ZONE 'Europe/Berlin')::date, p_source
    WHERE p_client_id IS NOT NULL AND p_ts IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION analytics.enqueue_refresh_for_delivery(
    p_order_id varchar, p_driver_id varchar, p_end_time timestamptz, p_source varchar
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_carrier varchar(32);
    v_shipper varchar(32);
BEGIN
    IF p_end_time IS NULL THEN
        RETURN;                                                          -- not completed: no KPI impact
    END IF;
    SELECT COALESCE((SELECT linked_client_id FROM core.drivers WHERE driver_id = p_driver_id),
                    CASE WHEN o.executor_type = 'carrier_company' THEN o.executor_id END),
           o.client_id
    INTO v_carrier, v_shipper
    FROM core.orders o WHERE o.order_id = p_order_id;

    PERFORM analytics.enqueue_refresh(v_carrier, p_end_time, p_source);
    PERFORM analytics.enqueue_refresh(v_shipper, p_end_time, p_source);
END;
$$;

CREATE OR REPLACE FUNCTION analytics.trg_enqueue_delivery() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM analytics.enqueue_refresh_for_delivery(OLD.order_id, OLD.driver_id, OLD.actual_end_time, 'deliveries');
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        IF TG_OP = 'INSERT' OR OLD.order_id IS DISTINCT FROM NEW.order_id OR OLD.driver_id IS DISTINCT FROM NEW.driver_id
           OR OLD.actual_end_time IS DISTINCT FROM NEW.actual_end_time THEN
            PERFORM analytics.enqueue_refresh_for_delivery(NEW.order_id, NEW.driver_id, NEW.actual_end_time, 'deliveries');
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_after_delivery_enqueue_kpi
    AFTER INSERT OR DELETE OR UPDATE OF order_id, driver_id, vehicle_id, delivery_status, actual_end_time,
        planned_distance_km, actual_distance_km, delay_minutes, delay_status, incident_type, is_driver_liable,
        customer_rating_stars, is_test
    ON core.deliveries
    FOR EACH ROW EXECUTE FUNCTION analytics.trg_enqueue_delivery();

-- Order changes (status 'closed' / 'cancelled', amount, executor, countries ...)
-- affect every completed delivery of the order.
CREATE OR REPLACE FUNCTION analytics.trg_enqueue_order() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_del record;
BEGIN
    FOR v_del IN
        SELECT d.driver_id, d.actual_end_time FROM core.deliveries d
        WHERE d.order_id = NEW.order_id AND d.actual_end_time IS NOT NULL
    LOOP
        PERFORM analytics.enqueue_refresh(COALESCE(
                    (SELECT linked_client_id FROM core.drivers WHERE driver_id = v_del.driver_id),
                    CASE WHEN OLD.executor_type = 'carrier_company' THEN OLD.executor_id END),
                v_del.actual_end_time, 'orders');
        PERFORM analytics.enqueue_refresh(COALESCE(
                    (SELECT linked_client_id FROM core.drivers WHERE driver_id = v_del.driver_id),
                    CASE WHEN NEW.executor_type = 'carrier_company' THEN NEW.executor_id END),
                v_del.actual_end_time, 'orders');
        PERFORM analytics.enqueue_refresh(OLD.client_id, v_del.actual_end_time, 'orders');
        IF NEW.client_id IS DISTINCT FROM OLD.client_id THEN
            PERFORM analytics.enqueue_refresh(NEW.client_id, v_del.actual_end_time, 'orders');
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_after_order_enqueue_kpi
    AFTER UPDATE OF status, amount_eur, vat_rate_pct, is_reverse_charge, client_id, executor_type, executor_id,
        cargo_type, cargo_weight_kg, origin_country, origin_postal_code, destination_country, destination_postal_code, is_test
    ON core.orders
    FOR EACH ROW WHEN (OLD IS DISTINCT FROM NEW)
    EXECUTE FUNCTION analytics.trg_enqueue_order();

-- Costs: the cost day of the owner (old and new), plus the completion day of
-- the linked delivery (its direct_costs_eur lives in fct_delivery).
CREATE OR REPLACE FUNCTION analytics.trg_enqueue_cost() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_rec   record;
    v_end   timestamptz;
    v_order varchar(32);
    v_drv   varchar(32);
BEGIN
    FOR v_rec IN
        SELECT OLD.client_id AS client_id, OLD.cost_date AS cost_date, OLD.delivery_id AS delivery_id WHERE TG_OP IN ('UPDATE', 'DELETE')
        UNION ALL
        SELECT NEW.client_id, NEW.cost_date, NEW.delivery_id WHERE TG_OP IN ('INSERT', 'UPDATE')
    LOOP
        INSERT INTO analytics.refresh_queue (client_id, kpi_date, source)
        SELECT v_rec.client_id, v_rec.cost_date, 'costs' WHERE v_rec.client_id IS NOT NULL;

        IF v_rec.delivery_id IS NOT NULL THEN
            SELECT order_id, driver_id, actual_end_time INTO v_order, v_drv, v_end
            FROM core.deliveries WHERE delivery_id = v_rec.delivery_id;
            PERFORM analytics.enqueue_refresh_for_delivery(v_order, v_drv, v_end, 'costs');
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_after_cost_enqueue_kpi
    AFTER INSERT OR UPDATE OR DELETE ON core.costs
    FOR EACH ROW EXECUTE FUNCTION analytics.trg_enqueue_cost();

-- Worker: process up to p_max_keys (client, day) pairs.
CREATE OR REPLACE FUNCTION analytics.process_refresh_queue(p_max_keys integer DEFAULT 500)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_day      record;
    v_keys     integer := 0;
    v_days     integer := 0;
    v_failed   integer := 0;
    v_lag_sec  numeric;
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('analytics.process_refresh_queue')) THEN
        RETURN jsonb_build_object('status', 'skipped: another worker is running');
    END IF;

    SELECT EXTRACT(EPOCH FROM clock_timestamp() - MIN(enqueued_at)) INTO v_lag_sec FROM analytics.refresh_queue;

    CREATE TEMP TABLE IF NOT EXISTS tmp_refresh_batch (
        client_id varchar(32), kpi_date date, max_queue_id bigint, PRIMARY KEY (client_id, kpi_date)
    ) ON COMMIT DROP;
    TRUNCATE tmp_refresh_batch;

    INSERT INTO tmp_refresh_batch
    SELECT client_id, kpi_date, MAX(queue_id)
    FROM analytics.refresh_queue
    GROUP BY client_id, kpi_date
    ORDER BY MIN(queue_id)
    LIMIT p_max_keys;
    GET DIAGNOSTICS v_keys = ROW_COUNT;

    FOR v_day IN
        SELECT kpi_date, array_agg(client_id ORDER BY client_id) AS clients
        FROM tmp_refresh_batch GROUP BY kpi_date ORDER BY kpi_date
    LOOP
        BEGIN
            PERFORM analytics.refresh_logistics_star(v_day.kpi_date, v_day.kpi_date, v_day.clients, FALSE);

            DELETE FROM analytics.refresh_queue q
            USING tmp_refresh_batch b
            WHERE b.kpi_date = v_day.kpi_date
              AND q.client_id = b.client_id AND q.kpi_date = b.kpi_date
              AND q.queue_id <= b.max_queue_id;                          -- newer markers stay for the next run
            v_days := v_days + 1;
        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed + 1;
            INSERT INTO analytics.refresh_failures (kpi_date, client_ids, error_message)
            VALUES (v_day.kpi_date, v_day.clients, SQLERRM);
        END;
    END LOOP;

    RETURN jsonb_build_object('keys', v_keys, 'days_refreshed', v_days, 'days_failed', v_failed,
                              'oldest_marker_age_sec', ROUND(COALESCE(v_lag_sec, 0), 1));
END;
$$;

-- Monitoring: queue depth and freshness (alert if oldest marker > 5 min).
CREATE OR REPLACE VIEW analytics.v_refresh_queue_status AS
SELECT
    (SELECT COUNT(*) FROM analytics.refresh_queue)                                    AS pending_markers,
    (SELECT COUNT(*) FROM (SELECT DISTINCT client_id, kpi_date FROM analytics.refresh_queue) k) AS pending_keys,
    (SELECT ROUND(EXTRACT(EPOCH FROM clock_timestamp() - MIN(enqueued_at))::numeric, 1)
       FROM analytics.refresh_queue)                                                  AS oldest_marker_age_sec,
    (SELECT COUNT(*) FROM analytics.refresh_failures WHERE failed_at > clock_timestamp() - INTERVAL '1 hour') AS failures_last_hour;

-- Scheduling with pg_cron (if the extension is available):
--   SELECT cron.schedule('smartlog_kpi_refresh_queue', '* * * * *', 'SELECT analytics.process_refresh_queue()');
-- pg_cron >= 1.5 also accepts '30 seconds' for ~30 s latency.

-- ----------------------------------------------------------------------------
-- 3.5. PERIOD VIEWS (star join with dim_date) — what dashboards and the AI read
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_carrier_kpi_monthly WITH (security_invoker = true) AS
SELECT
    a.client_id, a.account_id, dd.month_start,
    SUM(a.deliveries_completed)                                      AS deliveries_completed,
    SUM(a.revenue_net_eur)                                           AS revenue_eur,
    SUM(a.revenue_confirmed_net_eur)                                 AS revenue_confirmed_eur,
    SUM(a.fuel_costs_eur)                                            AS fuel_costs_eur,
    SUM(a.maintenance_costs_eur)                                     AS maintenance_costs_eur,
    SUM(a.driver_pay_eur)                                            AS driver_pay_eur,
    SUM(a.other_costs_eur)                                           AS other_costs_eur,
    SUM(a.total_costs_eur)                                           AS total_costs_eur,
    SUM(a.profit_eur)                                                AS profit_eur,
    ROUND(100.0 * SUM(a.profit_eur) / NULLIF(SUM(a.revenue_net_eur), 0), 2)           AS profit_margin_pct,
    ROUND(SUM(a.total_costs_eur) / NULLIF(SUM(a.deliveries_completed), 0), 2)         AS cost_per_delivery_eur,
    ROUND(SUM(a.revenue_net_eur) / NULLIF(SUM(a.deliveries_completed), 0), 2)         AS revenue_per_delivery_eur,
    SUM(a.distance_km)                                               AS distance_km,
    ROUND(SUM(a.total_costs_eur) / NULLIF(SUM(a.distance_km), 0), 3)                  AS cost_per_km_eur,
    ROUND(100.0 * SUM(a.fuel_liters) / NULLIF(SUM(a.distance_km), 0), 2)              AS fuel_liters_per_100km,
    ROUND(100.0 * SUM(a.deliveries_on_time) / NULLIF(SUM(a.deliveries_completed), 0), 2) AS on_time_rate_pct,
    SUM(a.private_expenses_eur)                                      AS private_expenses_eur,
    SUM(a.profit_eur) - SUM(a.private_expenses_eur)                  AS net_after_private_eur
FROM analytics.agg_carrier_kpi_daily a
JOIN analytics.dim_date dd ON dd.date_key = a.kpi_date
GROUP BY a.client_id, a.account_id, dd.month_start;

CREATE OR REPLACE VIEW analytics.v_carrier_kpi_weekly WITH (security_invoker = true) AS
SELECT
    a.client_id, a.account_id, dd.week_start, dd.iso_year, dd.iso_week,
    SUM(a.deliveries_completed)                                      AS deliveries_completed,
    SUM(a.revenue_net_eur)                                           AS revenue_eur,
    SUM(a.total_costs_eur)                                           AS total_costs_eur,
    SUM(a.profit_eur)                                                AS profit_eur,
    ROUND(100.0 * SUM(a.profit_eur) / NULLIF(SUM(a.revenue_net_eur), 0), 2)           AS profit_margin_pct,
    ROUND(SUM(a.total_costs_eur) / NULLIF(SUM(a.deliveries_completed), 0), 2)         AS cost_per_delivery_eur,
    ROUND(SUM(a.revenue_net_eur) / NULLIF(SUM(a.deliveries_completed), 0), 2)         AS revenue_per_delivery_eur
FROM analytics.agg_carrier_kpi_daily a
JOIN analytics.dim_date dd ON dd.date_key = a.kpi_date
GROUP BY a.client_id, a.account_id, dd.week_start, dd.iso_year, dd.iso_week;

CREATE OR REPLACE VIEW analytics.v_driver_kpi_monthly WITH (security_invoker = true) AS
SELECT
    a.driver_id, a.client_id, a.account_id, dd.month_start,
    SUM(a.deliveries_completed)                                      AS deliveries_completed,
    ROUND(100.0 * SUM(a.deliveries_on_time) / NULLIF(SUM(a.deliveries_completed), 0), 2) AS on_time_rate_pct,
    SUM(a.deliveries_driver_liable)                                  AS deliveries_driver_liable,
    SUM(a.distance_km)                                               AS distance_km,
    ROUND(SUM(a.ratings_sum) / NULLIF(SUM(a.ratings_count), 0), 2)                    AS avg_rating,
    SUM(a.driver_payout_eur)                                         AS driver_payout_eur
FROM analytics.agg_driver_kpi_daily a
JOIN analytics.dim_date dd ON dd.date_key = a.kpi_date
GROUP BY a.driver_id, a.client_id, a.account_id, dd.month_start;

CREATE OR REPLACE VIEW analytics.v_shipper_kpi_monthly WITH (security_invoker = true) AS
SELECT
    a.client_id, a.account_id, dd.month_start,
    SUM(a.shipments_delivered)                                       AS shipments_delivered,
    SUM(a.freight_spend_net_eur)                                     AS freight_spend_eur,
    SUM(a.freight_spend_confirmed_net_eur)                           AS freight_spend_confirmed_eur,
    ROUND(SUM(a.freight_spend_net_eur) / NULLIF(SUM(a.shipments_delivered), 0), 2)    AS spend_per_shipment_eur,
    ROUND(SUM(a.freight_spend_net_eur) / NULLIF(SUM(a.cargo_weight_kg), 0), 4)        AS spend_per_kg_eur,
    ROUND(100.0 * SUM(a.shipments_on_time) / NULLIF(SUM(a.shipments_delivered), 0), 2) AS carrier_on_time_rate_pct,
    SUM(a.cross_border_shipments)                                    AS cross_border_shipments
FROM analytics.agg_shipper_kpi_daily a
JOIN analytics.dim_date dd ON dd.date_key = a.kpi_date
GROUP BY a.client_id, a.account_id, dd.month_start;

-- KPIs of one carrier for any date range (app filter "from - to").
CREATE OR REPLACE FUNCTION analytics.carrier_kpi_period(p_client_id varchar, p_from date, p_to date)
RETURNS TABLE (
    deliveries_completed bigint, revenue_eur numeric, total_costs_eur numeric, profit_eur numeric,
    profit_margin_pct numeric, cost_per_delivery_eur numeric, revenue_per_delivery_eur numeric,
    cost_per_km_eur numeric, on_time_rate_pct numeric)
LANGUAGE sql STABLE AS $$
    SELECT SUM(deliveries_completed), COALESCE(SUM(revenue_net_eur), 0), COALESCE(SUM(total_costs_eur), 0),
           COALESCE(SUM(profit_eur), 0),
           ROUND(100.0 * SUM(profit_eur) / NULLIF(SUM(revenue_net_eur), 0), 2),
           ROUND(SUM(total_costs_eur) / NULLIF(SUM(deliveries_completed), 0), 2),
           ROUND(SUM(revenue_net_eur) / NULLIF(SUM(deliveries_completed), 0), 2),
           ROUND(SUM(total_costs_eur) / NULLIF(SUM(distance_km), 0), 3),
           ROUND(100.0 * SUM(deliveries_on_time) / NULLIF(SUM(deliveries_completed), 0), 2)
    FROM analytics.agg_carrier_kpi_daily
    WHERE client_id = p_client_id AND kpi_date BETWEEN p_from AND p_to;
$$;

-- Shipper's delivered shipments WITHOUT carrier-internal columns (costs,
-- liability). Definer-rights view that filters on the caller's account itself.
CREATE OR REPLACE VIEW analytics.v_shipper_shipments WITH (security_barrier = true) AS
SELECT f.delivery_id, f.order_id, f.completion_date, f.completed_at, f.order_status, f.is_revenue_confirmed,
       f.revenue_net_eur AS freight_net_eur, f.origin_country, f.origin_postal_code,
       f.destination_country, f.destination_postal_code, f.is_cross_border, f.cargo_type, f.cargo_weight_kg,
       f.distance_km, f.delay_minutes, f.is_on_time, f.customer_rating_stars
FROM analytics.fct_delivery f
WHERE f.shipper_account_id = app.current_account_id();

-- ----------------------------------------------------------------------------
-- 3.6. SECURITY
--   smartlog_tenant_reader (owner / dispatcher / accountant screens, AI):
--       only rows of app.current_account_id.
--   smartlog_driver_reader (hired driver screens): only own rows, only
--       non-financial columns + own payouts (column-level GRANT).
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'smartlog_driver_reader') THEN
        CREATE ROLE smartlog_driver_reader NOLOGIN;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION app.current_driver_id() RETURNS varchar
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('app.current_driver_id', true), '');
$$;

GRANT SELECT ON analytics.dim_date, analytics.dim_public_holiday,
                analytics.agg_carrier_kpi_daily, analytics.agg_shipper_kpi_daily, analytics.agg_driver_kpi_daily,
                analytics.fct_delivery, analytics.fct_cost,
                analytics.v_carrier_kpi_monthly, analytics.v_carrier_kpi_weekly,
                analytics.v_driver_kpi_monthly, analytics.v_shipper_kpi_monthly, analytics.v_shipper_shipments
      TO smartlog_tenant_reader;
GRANT EXECUTE ON FUNCTION analytics.carrier_kpi_period(varchar, date, date) TO smartlog_tenant_reader;

GRANT USAGE ON SCHEMA analytics, app TO smartlog_driver_reader;
GRANT EXECUTE ON FUNCTION app.current_driver_id() TO smartlog_driver_reader;
GRANT SELECT ON analytics.dim_date TO smartlog_driver_reader;
GRANT SELECT (kpi_date, driver_id, deliveries_completed, deliveries_on_time, deliveries_driver_liable,
              distance_km, ratings_count, ratings_sum, driver_payout_eur)
      ON analytics.agg_driver_kpi_daily TO smartlog_driver_reader;

GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO smartlog_analyst;

ALTER TABLE analytics.agg_carrier_kpi_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics.agg_shipper_kpi_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics.agg_driver_kpi_daily  ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics.fct_delivery          ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics.fct_cost              ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_tenant ON analytics.agg_carrier_kpi_daily FOR SELECT TO smartlog_tenant_reader USING (account_id = app.current_account_id());
CREATE POLICY p_tenant ON analytics.agg_shipper_kpi_daily FOR SELECT TO smartlog_tenant_reader USING (account_id = app.current_account_id());
CREATE POLICY p_tenant ON analytics.agg_driver_kpi_daily  FOR SELECT TO smartlog_tenant_reader USING (account_id = app.current_account_id());
CREATE POLICY p_tenant ON analytics.fct_delivery          FOR SELECT TO smartlog_tenant_reader USING (carrier_account_id = app.current_account_id());
CREATE POLICY p_tenant ON analytics.fct_cost              FOR SELECT TO smartlog_tenant_reader USING (account_id = app.current_account_id());
CREATE POLICY p_own_driver ON analytics.agg_driver_kpi_daily FOR SELECT TO smartlog_driver_reader USING (driver_id = app.current_driver_id());

DO $$
DECLARE
    v_tbl text;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY['analytics.agg_carrier_kpi_daily', 'analytics.agg_shipper_kpi_daily',
                                 'analytics.agg_driver_kpi_daily', 'analytics.fct_delivery', 'analytics.fct_cost'] LOOP
        EXECUTE format('CREATE POLICY p_analyst_all ON %s FOR SELECT TO smartlog_analyst USING (true)', v_tbl);
    END LOOP;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3.7. NIGHTLY JOB (all refresh steps: logistics KPIs + SaaS KPIs + retention)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.run_nightly(p_business_date date DEFAULT (CURRENT_DATE - 1))
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_result jsonb := '{}'::jsonb;
BEGIN
    PERFORM ops.ensure_monthly_partitions('app.user_activity_daily',       p_business_date - 31, p_business_date + 92);
    PERFORM ops.ensure_monthly_partitions('app.audit_log',                 p_business_date - 31, p_business_date + 92);
    PERFORM ops.ensure_monthly_partitions('analytics.account_usage_daily', p_business_date - 31, p_business_date + 92);
    PERFORM analytics.ensure_dim_date(date_trunc('year', p_business_date)::date,
                                      (date_trunc('year', p_business_date) + INTERVAL '2 years' - INTERVAL '1 day')::date);

    -- customer-facing logistics KPIs: last 35 days (late 'closed', ratings, back-dated costs)
    v_result := v_result || jsonb_build_object('logistics_star', analytics.refresh_logistics_star(p_business_date - 34, p_business_date));

    -- SmartLog SaaS KPIs (from 04)
    v_result := v_result || jsonb_build_object('usage_rows',          analytics.refresh_account_usage_daily(p_business_date));
    v_result := v_result || jsonb_build_object('mrr_rows',            analytics.snapshot_mrr_daily(p_business_date));
    v_result := v_result || jsonb_build_object('cohort_rows',         analytics.refresh_cohort_monthly());
    v_result := v_result || jsonb_build_object('unit_economics_rows', analytics.refresh_unit_economics_monthly(p_business_date));

    DELETE FROM app.auth_challenges WHERE created_at < CURRENT_DATE - 30;
    DELETE FROM billing.webhook_inbox WHERE status IN ('processed', 'ignored') AND received_at < CURRENT_DATE - 90;
    DELETE FROM app.user_sessions WHERE expires_at < CURRENT_DATE - 30;
    v_result := v_result || jsonb_build_object(
        'dropped_activity_partitions', ops.drop_monthly_partitions_older_than('app.user_activity_daily', 25),
        'dropped_audit_partitions',    ops.drop_monthly_partitions_older_than('app.audit_log', 24));

    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3.8. INITIAL LOAD & KPI DICTIONARY
-- ----------------------------------------------------------------------------
SELECT analytics.ensure_dim_date(DATE '2024-01-01', DATE '2027-12-31');
SELECT analytics.refresh_logistics_star(COALESCE(
    (SELECT MIN((actual_end_time AT TIME ZONE 'Europe/Berlin')::date) FROM core.deliveries),
    CURRENT_DATE), CURRENT_DATE);

INSERT INTO analytics.metric_definitions (metric_code, metric_name, description, formula, source_object, grain, unit) VALUES
    ('revenue_eur', 'Revenue (carrier)',
     'Net order amount (without VAT) of deliveries with delivery_status delivered and order status delivered or closed, dated by delivery completion (Europe/Berlin). Split by planned distance if an order has several deliveries.',
     'SUM(fct_delivery.revenue_net_eur)', 'analytics.agg_carrier_kpi_daily.revenue_net_eur', 'day x carrier', 'EUR'),
    ('revenue_confirmed_eur', 'Confirmed Revenue (carrier)',
     'Part of revenue whose order is closed (confirmed by customer / accountant, invoice-ready).',
     'SUM(revenue_net_eur) WHERE order_status = closed', 'analytics.agg_carrier_kpi_daily.revenue_confirmed_net_eur', 'day x carrier', 'EUR'),
    ('total_costs_eur', 'Total Costs (carrier)',
     'Business costs incl. driver payouts; private expenses and test rows excluded.',
     'SUM(cost_amount_eur + driver_payout_eur) WHERE NOT is_private_expense', 'analytics.agg_carrier_kpi_daily.total_costs_eur', 'day x carrier', 'EUR'),
    ('profit_eur', 'Profit (carrier)', 'Revenue minus total costs.',
     'revenue_eur - total_costs_eur', 'analytics.agg_carrier_kpi_daily.profit_eur', 'day x carrier', 'EUR'),
    ('profit_margin_pct', 'Profit Margin', 'Profit as share of revenue (only when revenue > 0).',
     'profit_eur / revenue_eur * 100', 'analytics.v_carrier_kpi_monthly.profit_margin_pct', 'period x carrier', '%'),
    ('cost_per_delivery_eur', 'Cost per Delivery', 'Total costs of the period divided by deliveries completed in the same period (includes overhead).',
     'total_costs_eur / deliveries_completed', 'analytics.v_carrier_kpi_monthly.cost_per_delivery_eur', 'period x carrier', 'EUR'),
    ('revenue_per_delivery_eur', 'Revenue per Delivery', 'Revenue divided by deliveries completed.',
     'revenue_eur / deliveries_completed', 'analytics.v_carrier_kpi_monthly.revenue_per_delivery_eur', 'period x carrier', 'EUR'),
    ('cost_per_km_eur', 'Cost per km', 'Total costs divided by driven km (actual, else planned).',
     'total_costs_eur / distance_km', 'analytics.v_carrier_kpi_monthly.cost_per_km_eur', 'period x carrier', 'EUR/km'),
    ('freight_spend_eur', 'Freight Spend (shipper)', 'Net amount of the shipper''s delivered shipments.',
     'SUM(fct_delivery.revenue_net_eur) by shipper', 'analytics.agg_shipper_kpi_daily.freight_spend_net_eur', 'day x shipper', 'EUR')
ON CONFLICT (metric_code) DO NOTHING;

COMMIT;

-- ============================================================================
-- FUTURE (not created in this release; planned tables)
--   app.gdpr_requests            export / erasure requests with deadlines
--   app.app_releases             minimum supported mobile app version
--   analytics.product_events     batched feature events (partitioned, COPY)
--   app.ai_conversations, app.ai_messages, analytics.ai_usage_daily
--                                AI assistant history, token cost per account
--   billing.billing_entities     second legal entity outside Germany
-- ============================================================================
