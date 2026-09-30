import { useState, useCallback } from 'react';
import { API } from '../network/api';
import type { FreightOrder, User } from '../model/types';

/**
 * Interactor: Freight Exchange (Use Case)
 * 
 * Implements pure business logic on the frontend. 
 * Relies on the `API` layer for concrete backend endpoint calls.
 */
export function useFreightExchange(currentUser: User | null) {
  const [orders, setOrders] = useState<FreightOrder[]>([]);
  const [error, setError] = useState<string | null>(null);

  // Business Logic Condition: Only active carriers/drivers can see prices
  const canSeePrices = currentUser?.role !== 'CUSTOMER' && currentUser?.status === 'ACTIVE';

  /**
   * Load orders and apply local business rules.
   */
  const loadOrders = useCallback(async (city: string = '', cargoType: string = '') => {
    try {
      // 1. Delegate strictly to the API method
      let data = await API.getMarketOrders(city, cargoType);

      // 2. Business Logic: Sort by loading date (closest deadlines first)
      data.sort((a, b) => new Date(a.loading_at).getTime() - new Date(b.loading_at).getTime());

      // 3. Business Logic: Redact prices if the user lacks permissions 
      // (Even if the backend sends it, we enforce view constraints here)
      if (!canSeePrices) {
        data = data.map(order => ({ ...order, price: undefined }));
      }

      setOrders(data);
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
  }, [canSeePrices]);

  /**
   * Apply for an order, performing business validations BEFORE hitting the network.
   */
  const applyForTrip = useCallback(async (order: FreightOrder) => {
    // 1. Pure Business Pre-flight Checks (Fail fast without hitting the server)
    if (!currentUser) {
      throw new Error("You must be signed in to apply for a trip.");
    }
    if (currentUser.role === 'CUSTOMER') {
      throw new Error("Customers cannot apply for trips.");
    }
    if (currentUser.status === 'BLOCKED') {
      throw new Error("Your account is blocked. You cannot apply for new trips.");
    }
    if (new Date(order.loading_at) < new Date()) {
      throw new Error("This order's loading time has already passed.");
    }

    // 2. Delegate to the API method only after business rules pass
    await API.applyForOrder(order.id, order.version);
    
    // 3. Optimistic UI update: instantly remove the order from the local list
    // (A business UX decision to not wait for a full refetch)
    setOrders(prev => prev.filter(o => o.id !== order.id));
    
  }, [currentUser]);

  return {
    orders,
    error,
    canSeePrices,
    loadOrders,
    applyForTrip
  };
}
