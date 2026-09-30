import pytest
from datetime import datetime
from uuid import uuid4

# Junior Developers: You will need to implement these domain models to make the tests pass!
# The models should enforce the business logic of the logistics platform independently of the database or HTTP layer.

try:
    from app.domain.shipment.shipment import Shipment, ShipmentStatus
    from app.domain.shipment.events import (
        OrderPublished, CarrierApplied, CarrierApproved, 
        TripDeparted, TripArrived, DocumentUploaded, TripCompleted
    )
    from app.domain.fleet.carrier import Carrier
    from app.domain.ratings.review import Review
    from app.domain.errors import DomainError
except ImportError:
    # If imports fail during early TDD phases, don't crash the whole test suite discovery
    pass


def test_shipment_initial_state_from_event():
    """A newly published order should be in the LOOKING_FOR_CARRIER state."""
    event = OrderPublished(
        shipment_id=uuid4(),
        customer_id=uuid4(),
        origin="Würzburg",
        destination="Frankfurt",
        cargo_type="Pallets",
        price=250.0,
        timestamp=datetime.utcnow()
    )
    shipment = Shipment(events=[event])
    assert shipment.status == ShipmentStatus.LOOKING_FOR_CARRIER
    assert shipment.price == 250.0


def test_shipment_carrier_application():
    """A carrier applying to the shipment should be recorded in the applicants list."""
    shipment_id = uuid4()
    carrier_id = uuid4()
    events = [
        OrderPublished(shipment_id=shipment_id, customer_id=uuid4(), origin="W", destination="F", cargo_type="Pallets", price=250.0, timestamp=datetime.utcnow()),
        CarrierApplied(shipment_id=shipment_id, carrier_id=carrier_id, timestamp=datetime.utcnow())
    ]
    shipment = Shipment(events=events)
    
    assert shipment.status == ShipmentStatus.LOOKING_FOR_CARRIER
    assert carrier_id in shipment.applicants


def test_shipment_workflow_transitions():
    """Test the complete successful "happy path" of a shipment through the event stream."""
    shipment_id = uuid4()
    carrier_id = uuid4()
    
    events = [
        OrderPublished(shipment_id=shipment_id, customer_id=uuid4(), origin="A", destination="B", cargo_type="Pallets", price=100.0, timestamp=datetime.utcnow()),
        CarrierApplied(shipment_id=shipment_id, carrier_id=carrier_id, timestamp=datetime.utcnow()),
        CarrierApproved(shipment_id=shipment_id, carrier_id=carrier_id, timestamp=datetime.utcnow()),
    ]
    shipment = Shipment(events=events)
    assert shipment.status == ShipmentStatus.AWAITING_DEPARTURE
    assert shipment.assigned_carrier == carrier_id

    # Depart
    events.append(TripDeparted(shipment_id=shipment_id, carrier_id=carrier_id, timestamp=datetime.utcnow()))
    shipment = Shipment(events=events)
    assert shipment.status == ShipmentStatus.IN_TRANSIT
    
    # Arrive
    events.append(TripArrived(shipment_id=shipment_id, carrier_id=carrier_id, timestamp=datetime.utcnow()))
    shipment = Shipment(events=events)
    assert shipment.status == ShipmentStatus.AT_PICKUP

    # Document upload
    doc_id = uuid4()
    events.append(DocumentUploaded(shipment_id=shipment_id, carrier_id=carrier_id, document_id=doc_id, timestamp=datetime.utcnow()))
    shipment = Shipment(events=events)
    assert doc_id in shipment.documents

    # Complete
    events.append(TripCompleted(shipment_id=shipment_id, carrier_id=carrier_id, timestamp=datetime.utcnow()))
    shipment = Shipment(events=events)
    assert shipment.status == ShipmentStatus.DELIVERED


def test_shipment_invalid_transitions_should_raise_domain_error():
    """Business invariants must be protected. A shipment cannot depart before a carrier is approved."""
    shipment_id = uuid4()
    events = [
        OrderPublished(shipment_id=shipment_id, customer_id=uuid4(), origin="A", destination="B", cargo_type="Pallets", price=100.0, timestamp=datetime.utcnow()),
    ]
    shipment = Shipment(events=events)
    
    with pytest.raises(DomainError):
        # The apply_event method (or similar) should reject invalid transitions
        invalid_event = TripDeparted(shipment_id=shipment_id, carrier_id=uuid4(), timestamp=datetime.utcnow())
        shipment.apply_event(invalid_event)


def test_carrier_auto_block_logic_on_low_rating():
    """A carrier's average rating falling below 3.2 should automatically block their account."""
    carrier = Carrier(id=uuid4(), status="ACTIVE", rating=5.0, total_reviews=1)
    
    # Process a new 1-star review
    review = Review(carrier_id=carrier.id, rating=1.0)
    carrier.add_review(review)
    
    # New average is (5.0 + 1.0) / 2 = 3.0
    assert carrier.rating == 3.0
    assert carrier.status == "BLOCKED"


def test_carrier_auto_block_logic_on_fraud():
    """Two consecutive fraud reports by different customers should block the carrier."""
    carrier = Carrier(id=uuid4(), status="ACTIVE", rating=5.0, total_reviews=5)
    
    customer_1 = uuid4()
    customer_2 = uuid4()
    
    carrier.add_review(Review(carrier_id=carrier.id, rating=4.0, fraud_reported=True, customer_id=customer_1))
    assert carrier.status == "ACTIVE"
    
    carrier.add_review(Review(carrier_id=carrier.id, rating=4.0, fraud_reported=True, customer_id=customer_2))
    assert carrier.status == "BLOCKED"
