// API client for the Distributed Password Manager HTTP gateway

// In dev, default to same-origin so Vite proxy can forward API calls.
const BASE = import.meta.env.VITE_API_URL || '';

export interface PasswordEntry {
  site: string;
  username: string;
  password: string;
}

export interface ApiError {
  error: string;
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    ...options,
  });
  const data = await res.json();
  if (!res.ok) throw new Error((data as ApiError).error || 'Request failed');
  return data as T;
}

export const api = {
  register: (username: string, password: string) =>
    request<{ message: string }>('/auth/register', {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    }),

  login: (username: string, password: string) =>
    request<{ message: string; username: string }>('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    }),

  logout: () =>
    request<{ message: string }>('/auth/logout', { method: 'POST' }),

  listSites: () =>
    request<{ sites: string[] }>('/vault/list'),

  getEntry: (site: string) =>
    request<PasswordEntry>(`/vault/get?site=${encodeURIComponent(site)}`),

  saveEntry: (entry: PasswordEntry) =>
    request<{ message: string }>('/vault/save', {
      method: 'POST',
      body: JSON.stringify(entry),
    }),

  deleteEntry: (site: string) =>
    request<{ message: string }>('/vault/delete', {
      method: 'DELETE',
      body: JSON.stringify({ site }),
    }),

  health: () =>
    request<{ status: string; chunks: number }>('/health'),
};
