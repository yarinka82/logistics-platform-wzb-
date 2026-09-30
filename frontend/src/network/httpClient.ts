import { t } from '../i18n/i18n';

export class ApiError extends Error {
  constructor(message: string, public status: number) {
    super(message);
  }
}

/**
 * HttpClient (Network Core)
 * 
 * Handles ONLY the low-level transport logic:
 * - fetch() execution
 * - Headers and credentials
 * - Global error parsing
 */
class HttpClient {
  public async request<T>(path: string, method = 'GET', body?: unknown): Promise<T> {
    const options: RequestInit = {
      method,
      credentials: 'include',
    };

    if (body !== undefined) {
      options.headers = { 'Content-Type': 'application/json' };
      options.body = JSON.stringify(body);
    }

    const response = await fetch('/api' + path, options);
    const text = await response.text();
    let data;

    try {
      data = JSON.parse(text);
    } catch {
      throw new ApiError('The server is unavailable. Check your connection.', response.status);
    }

    if (!response.ok) {
      const errorMsg = typeof data.detail === 'string' ? data.detail : 'Please check the form fields.';
      throw new ApiError(t(errorMsg), response.status);
    }

    return data as T;
  }
}

export const httpClient = new HttpClient();
