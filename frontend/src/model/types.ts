export type Role = 'CUSTOMER' | 'DRIVER' | 'COMPANY' | 'EMPLOYEE' | 'ADMIN' | 'MODERATOR';

export interface User {
  id: string;
  username: string;
  role: Role;
  name: string;
  phone: string;
  email: string;
  city: string;
  company_id: string | null;
  vehicle_plate: string;
  vehicle_type: string;
  tax_id: string;
  contact_name: string;
  status: string;
  verification: string;
  rating: number | null;
  must_change_password: boolean;
  created_at: string;
  block_reason: string | null;
  documents?: { id: string; purpose: string }[];
}

export interface Offer {
  id: string;
  carrier_id: string;
  driver_id: string;
  status: string;
  name?: string;
  driver_name?: string;
  vehicle_plate?: string;
  vehicle_type?: string;
  rating?: number | null;
  avatar?: string | null;
}

export interface FreightOrder {
  id: string;
  origin: string;
  destination: string;
  city: string;
  cargo: string;
  cargo_type: string;
  price?: number;
  loading_at: string;
  status: string;
  version: number;
  created_at: string;
  is_owner?: boolean;
  my_offer?: Offer | null;
  offers?: Offer[];
  driver_id?: string | null;
  customer_id?: string;
  carrier_id?: string | null;
  documents?: string[];
  timeline?: {
    event: string;
    version: number;
    at: string;
    coordinates?: { latitude: number; longitude: number } | null;
  }[];
  contacts?: {
    id: string;
    name: string;
    phone: string;
    vehicle_plate: string;
  }[];
  review?: {
    rating: number;
    note: string;
    fraud: boolean;
  } | null;
}

export interface Notice {
  id: string;
  shipment_id: string | null;
  message: string;
  read: boolean;
  created_at: string;
}

export interface Session {
  user?: User;
  verification_token?: string;
  mock_sms?: boolean;
}

export interface Invitation {
  user: User;
  invitation: {
    username: string;
    temporary_password: string;
    verification_token: string;
    mock_sms: boolean;
  };
}
