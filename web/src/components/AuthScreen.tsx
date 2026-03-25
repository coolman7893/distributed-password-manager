import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Lock, User, ChevronRight, AlertTriangle, KeyRound } from 'lucide-react';
import './AuthScreen.css';

interface Props {
  onLogin: (user: string, pass: string) => void;
  onRegister: (user: string, pass: string) => void;
  loading: boolean;
  error: string;
  clearError: () => void;
}

type Mode = 'login' | 'register';

export default function AuthScreen({ onLogin, onRegister, loading, error, clearError }: Props) {
  const [mode, setMode] = useState<Mode>('login');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [localErr, setLocalErr] = useState('');

  const submit = () => {
    setLocalErr('');
    clearError();
    if (!username.trim() || !password.trim()) {
      setLocalErr('username and password required');
      return;
    }
    if (mode === 'register') {
      if (password !== confirm) {
        setLocalErr('passwords do not match');
        return;
      }
      if (password.length < 8) {
        setLocalErr('password must be at least 8 characters');
        return;
      }
      onRegister(username.trim(), password);
    } else {
      onLogin(username.trim(), password);
    }
  };

  const switchMode = (m: Mode) => {
    setMode(m);
    setLocalErr('');
    clearError();
    setPassword('');
    setConfirm('');
  };

  const displayError = localErr || error;

  return (
    <div className="auth-screen">
      <div className="auth-bg-grid" />
      <div className="auth-container">
        <div className="auth-header">
          <div className="auth-glyph">
            <KeyRound size={28} strokeWidth={1.5} />
          </div>
          <h1 className="auth-title">
            {mode === 'login' ? 'AUTHENTICATE' : 'CREATE VAULT'}
          </h1>
          <p className="auth-subtitle">
            {mode === 'login'
              ? 'Enter credentials to access your encrypted vault'
              : 'Register a new account on the distributed vault'}
          </p>
        </div>

        <div className="auth-tabs">
          {(['login', 'register'] as Mode[]).map(m => (
            <button
              key={m}
              className={`auth-tab ${mode === m ? 'auth-tab-active' : ''}`}
              onClick={() => switchMode(m)}
            >
              {m === 'login' ? '// LOGIN' : '// REGISTER'}
            </button>
          ))}
        </div>

        <AnimatePresence mode="wait">
          <motion.form
            key={mode}
            className="auth-form"
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -8 }}
            transition={{ duration: 0.2 }}
            onSubmit={e => { e.preventDefault(); submit(); }}
          >
            <div className="field-group">
              <label className="field-label">USERNAME</label>
              <div className="field-wrap">
                <User size={13} className="field-icon" />
                <input
                  className="field-input"
                  type="text"
                  placeholder="enter username"
                  value={username}
                  onChange={e => setUsername(e.target.value)}
                  autoComplete="username"
                  disabled={loading}
                />
              </div>
            </div>

            <div className="field-group">
              <label className="field-label">MASTER PASSWORD</label>
              <div className="field-wrap">
                <Lock size={13} className="field-icon" />
                <input
                  className="field-input"
                  type="password"
                  placeholder="enter master password"
                  value={password}
                  onChange={e => setPassword(e.target.value)}
                  autoComplete={mode === 'register' ? 'new-password' : 'current-password'}
                  disabled={loading}
                />
              </div>
            </div>

            {mode === 'register' && (
              <motion.div
                className="field-group"
                initial={{ opacity: 0, height: 0 }}
                animate={{ opacity: 1, height: 'auto' }}
                exit={{ opacity: 0, height: 0 }}
              >
                <label className="field-label">CONFIRM PASSWORD</label>
                <div className="field-wrap">
                  <Lock size={13} className="field-icon" />
                  <input
                    className="field-input"
                    type="password"
                    placeholder="confirm master password"
                    value={confirm}
                    onChange={e => setConfirm(e.target.value)}
                    autoComplete="new-password"
                    disabled={loading}
                  />
                </div>
              </motion.div>
            )}

            <AnimatePresence>
              {displayError && (
                <motion.div
                  className="auth-error"
                  initial={{ opacity: 0, y: -4 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0 }}
                >
                  <AlertTriangle size={12} />
                  <span>{displayError}</span>
                </motion.div>
              )}
            </AnimatePresence>

            <button
              type="submit"
              className={`auth-submit ${loading ? 'auth-submit-loading' : ''}`}
              disabled={loading}
            >
              {loading ? (
                <span className="loading-dots">
                  <span />
                  <span />
                  <span />
                </span>
              ) : (
                <>
                  <span>{mode === 'login' ? 'ACCESS VAULT' : 'REGISTER'}</span>
                  <ChevronRight size={16} />
                </>
              )}
            </button>
          </motion.form>
        </AnimatePresence>

        <div className="auth-note">
          <span className="note-label">ZERO-KNOWLEDGE</span>
          &nbsp;— your master password never leaves this device
        </div>
      </div>
    </div>
  );
}
