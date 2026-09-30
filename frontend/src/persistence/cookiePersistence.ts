/**
 * Persistence layer for browser Cookies.
 * 
 * Provides a clean interface for getting, setting, and removing cookies,
 * abstracting away the raw `document.cookie` string manipulation.
 */
export const CookiePersistence = {
  /**
   * Retrieves the value of a cookie by its name.
   */
  get(name: string): string | null {
    const match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
    if (match) {
      return decodeURIComponent(match[2]);
    }
    return null;
  },

  /**
   * Sets a cookie with an optional expiration time (default is 365 days).
   */
  set(name: string, value: string, days: number = 365): void {
    const date = new Date();
    date.setTime(date.getTime() + days * 24 * 60 * 60 * 1000);
    const expires = `; expires=${date.toUTCString()}`;
    
    // Use Secure flag if running over HTTPS, and SameSite=Lax for standard CSRF protection
    const secure = window.location.protocol === 'https:' ? '; Secure; SameSite=Lax' : '; SameSite=Lax';
    
    document.cookie = `${name}=${encodeURIComponent(value)}${expires}; Path=/${secure}`;
  },

  /**
   * Removes a cookie by immediately expiring it.
   */
  remove(name: string): void {
    document.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 UTC; Path=/;`;
  }
};
