import { httpClient } from './httpClient';
import type { FreightOrder, User, Notice, Invitation } from '../model/types';

/**
 * Clean API Methods
 * 
 * Maps business operations to specific backend endpoints.
 * Interactors (Business Logic) call these pure functions.
 */
export const API = {
  
  // ==========================================
  // AUTHENTICATION & PROFILE
  // ==========================================
  
  register: (payload: Record<string, any>) => 
    httpClient.request('/auth/register', 'POST', payload),
    
  verify: (verificationToken: string, code: string) => 
    httpClient.request('/auth/verify', 'POST', { verification_token: verificationToken, code }),
    
  login: (payload: Record<string, any>) => 
    httpClient.request('/auth/login', 'POST', payload),
    
  logout: () => 
    httpClient.request('/auth/logout', 'POST'),

  getProfile: (): Promise<User> => 
    httpClient.request<User>('/me'),
    
  changePassword: (payload: Record<string, any>) => 
    httpClient.request('/me/password', 'POST', payload),

  // ==========================================
  // MARKETPLACE & ORDERS
  // ==========================================

  getMarketOrders: (city: string, cargoType: string, scope: string = 'market'): Promise<FreightOrder[]> => {
    const query = `?scope=${scope}&city=${encodeURIComponent(city)}&cargo_type=${encodeURIComponent(cargoType)}`;
    return httpClient.request<FreightOrder[]>(`/orders${query}`);
  },

  getOrderDetails: (orderId: string): Promise<FreightOrder> => 
    httpClient.request<FreightOrder>(`/orders/${orderId}`),

  publishOrder: (payload: Record<string, any>): Promise<FreightOrder> => 
    httpClient.request<FreightOrder>('/orders', 'POST', { ...payload, command_id: crypto.randomUUID() }),

  // ==========================================
  // TRIP WORKFLOW (CQRS Commands)
  // ==========================================

  applyForOrder: (orderId: string, expectedVersion: number): Promise<FreightOrder> => 
    httpClient.request<FreightOrder>(`/orders/${orderId}/commands/take`, 'POST', {
      command_id: crypto.randomUUID(),
      expected_version: expectedVersion,
      data: { declaration_accepted: true }
    }),

  approveCarrier: (orderId: string, expectedVersion: number, offerId: string): Promise<FreightOrder> => 
    httpClient.request<FreightOrder>(`/orders/${orderId}/commands/approve`, 'POST', {
      command_id: crypto.randomUUID(),
      expected_version: expectedVersion,
      data: { offer_id: offerId }
    }),

  updateTripStatus: (orderId: string, action: 'depart' | 'arrive' | 'complete', expectedVersion: number, data: Record<string, any>): Promise<FreightOrder> => 
    httpClient.request<FreightOrder>(`/orders/${orderId}/commands/${action}`, 'POST', {
      command_id: crypto.randomUUID(),
      expected_version: expectedVersion,
      data
    }),

  uploadTripDocument: (orderId: string, expectedVersion: number, photoBase64: string): Promise<FreightOrder> => 
    httpClient.request<FreightOrder>(`/orders/${orderId}/commands/document`, 'POST', {
      command_id: crypto.randomUUID(),
      expected_version: expectedVersion,
      data: { photo: photoBase64 }
    }),

  submitReview: (orderId: string, expectedVersion: number, payload: Record<string, any>): Promise<FreightOrder> => 
    httpClient.request<FreightOrder>(`/orders/${orderId}/commands/review`, 'POST', {
      command_id: crypto.randomUUID(),
      expected_version: expectedVersion,
      data: payload
    }),

  // ==========================================
  // FLEET (Transport Companies)
  // ==========================================

  inviteEmployee: (payload: Record<string, any>): Promise<Invitation> => 
    httpClient.request<Invitation>('/fleet', 'POST', payload),

  getCouriers: (): Promise<any[]> => 
    httpClient.request<any[]>('/couriers'),

  // ==========================================
  // NOTIFICATIONS
  // ==========================================

  getNotifications: (): Promise<Notice[]> => 
    httpClient.request<Notice[]>('/notifications'),

  markNotificationsRead: () => 
    httpClient.request('/notifications/read', 'POST'),

  // ==========================================
  // ADMINISTRATION
  // ==========================================

  getUsers: (): Promise<User[]> => 
    httpClient.request<User[]>('/admin/users'),

  createUser: (payload: Record<string, any>) => 
    httpClient.request('/admin/users', 'POST', payload),

  setUserStatus: (userId: string, blocked: boolean) => 
    httpClient.request(`/admin/users/${userId}/status`, 'POST', { blocked }),

  rebuildProjections: (): Promise<{ rebuilt: number }> => 
    httpClient.request<{ rebuilt: number }>('/projections/rebuild', 'POST')
};
