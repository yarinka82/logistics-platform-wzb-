import { useSyncExternalStore } from 'react';
import german from './de.json';

export type Language = 'en' | 'de';

let language: Language = localStorage.getItem('wzb-language') === 'de' ? 'de' : 'en';
document.documentElement.lang = language;

const listeners = new Set<() => void>();
const translations: Record<string, string> = german;

const english: Record<string, string> = {
  CUSTOMER: 'Customer',
  DRIVER: 'Independent driver',
  COMPANY: 'Transport company',
  EMPLOYEE: 'Company driver',
  MODERATOR: 'Moderator',
  ADMIN: 'Administrator',
  ACTIVE: 'Active',
  PENDING: 'Pending',
  BLOCKED: 'Blocked',
  APPROVED: 'Approved',
  REJECTED: 'Rejected',
  PUBLISHED: 'Looking for a carrier',
  ASSIGNED: 'Awaiting departure',
  IN_TRANSIT: 'On the road',
  ARRIVED: 'At pickup',
  DELIVERED: 'Delivered'
};

export function t(text: string, values: Record<string, string | number> = {}): string {
  if (!text) return '';

  // Clean up generic domain error formats
  if (text.startsWith('Cannot ') && text.includes(' an order in ')) {
    text = 'Trip action is not available in its current state.';
  }

  // Resolve translation
  let result = language === 'de' ? translations[text] : english[text];
  
  if (!result) {
    if (language === 'en' && /^(OrderPublished|CarrierApplied|DriverApproved|TripDeparted|PickupArrived|DeliveryDocumentUploaded|TripCompleted|DriverReviewed)$/.test(text)) {
      result = text.replace(/([A-Z])/g, ' $1').trim();
    } else {
      result = text;
    }
  }

  // Simple string interpolation for templates (e.g. {count})
  for (const [key, value] of Object.entries(values)) {
    result = result.replaceAll(`{${key}}`, String(value));
  }
  
  return result;
}

export function locale(): string {
  return language === 'de' ? 'de-DE' : 'en-GB';
}

export function setLanguage(value: Language): void {
  language = value;
  localStorage.setItem('wzb-language', value);
  document.documentElement.lang = value;
  listeners.forEach(notify => notify());
}

export function useLanguage(): Language {
  return useSyncExternalStore(
    (notify) => {
      listeners.add(notify);
      return () => listeners.delete(notify);
    },
    () => language,
    () => language
  );
}
