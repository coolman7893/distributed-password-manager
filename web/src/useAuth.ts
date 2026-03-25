import { useState, useCallback } from 'react';
import { api } from './api';

export type AuthState = 'idle' | 'loading' | 'logged-in' | 'logged-out';

export function useAuth() {
  const [state, setState] = useState<AuthState>('logged-out');
  const [username, setUsername] = useState('');
  const [error, setError] = useState('');

  const login = useCallback(async (user: string, pass: string) => {
    setState('loading');
    setError('');
    try {
      const res = await api.login(user, pass);
      setUsername(res.username);
      setState('logged-in');
    } catch (e) {
      setError((e as Error).message);
      setState('logged-out');
    }
  }, []);

  const register = useCallback(async (user: string, pass: string) => {
    setState('loading');
    setError('');
    try {
      await api.register(user, pass);
      // Auto-login after register
      await api.login(user, pass);
      setUsername(user);
      setState('logged-in');
    } catch (e) {
      setError((e as Error).message);
      setState('logged-out');
    }
  }, []);

  const logout = useCallback(async () => {
    await api.logout().catch(() => {});
    setUsername('');
    setState('logged-out');
  }, []);

  const clearError = useCallback(() => setError(''), []);

  return { state, username, error, login, register, logout, clearError };
}
