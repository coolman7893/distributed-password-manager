// API client for the Distributed Password Manager HTTP gateway

const BASE = import.meta.env.VITE_API_URL || '';
let preferredBaseIdx = 0;

export interface PasswordEntry {
  site: string;
  username: string;
  password: string;
}

export interface ApiError {
  error: string;
}

function getCandidateBases(): string[] {
  if (BASE) return [BASE];
  if (import.meta.env.DEV) {
    return ['/m1', '/m2'];
  }
  return [''];
}

function isRetryableStatus(status: number): boolean {
  return status === 502 || status === 503 || status === 504;
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const candidates = getCandidateBases();
  const ordered = candidates
    .map((_, idx) => (preferredBaseIdx + idx) % candidates.length)
    .map((idx) => candidates[idx]);

  let lastErr: Error | null = null;

  for (let i = 0; i < ordered.length; i++) {
    const base = ordered[i];
    try {
      const res = await fetch(`${base}${path}`, {
        headers: { 'Content-Type': 'application/json' },
        credentials: 'include',
        ...options,
      });

      let data: unknown = null;
      try {
        data = await res.json();
      } catch {
        data = null;
      }

      if (!res.ok) {
        if (isRetryableStatus(res.status) && i < ordered.length - 1) {
          continue;
        }
        throw new Error((data as ApiError | null)?.error || `Request failed (${res.status})`);
      }

      const winningIdx = candidates.indexOf(base);
      if (winningIdx >= 0) {
        preferredBaseIdx = winningIdx;
      }
      return data as T;
    } catch (e) {
      lastErr = e as Error;
      if (i === ordered.length - 1) {
        break;
      }
    }
  }

  throw lastErr || new Error('Request failed');
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
