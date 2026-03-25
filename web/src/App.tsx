import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { useAuth } from './useAuth';
import AuthScreen from './components/AuthScreen';
import VaultScreen from './components/VaultScreen';
import TopBar from './components/TopBar';
import './App.css';

export default function App() {
  const auth = useAuth();
  const [bootDone, setBootDone] = useState(false);

  return (
    <div className="app-root">
      <AnimatePresence mode="wait">
        {!bootDone && (
          <BootSequence key="boot" onDone={() => setBootDone(true)} />
        )}
        {bootDone && (
          <motion.div
            key="main"
            className="main-layout"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.6 }}
          >
            <TopBar
              username={auth.username}
              isLoggedIn={auth.state === 'logged-in'}
              onLogout={auth.logout}
            />
            <main className="main-content">
              <AnimatePresence mode="wait">
                {auth.state === 'logged-in' ? (
                  <motion.div
                    key="vault"
                    initial={{ opacity: 0, y: 12 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -12 }}
                    transition={{ duration: 0.3 }}
                  >
                    <VaultScreen username={auth.username} />
                  </motion.div>
                ) : (
                  <motion.div
                    key="auth"
                    initial={{ opacity: 0, y: 12 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -12 }}
                    transition={{ duration: 0.3 }}
                  >
                    <AuthScreen
                      onLogin={auth.login}
                      onRegister={auth.register}
                      loading={auth.state === 'loading'}
                      error={auth.error}
                      clearError={auth.clearError}
                    />
                  </motion.div>
                )}
              </AnimatePresence>
            </main>
            <footer className="app-footer">
              <span className="footer-tag">CMPT 756</span>
              <span className="footer-sep">·</span>
              <span>GFS-inspired distributed vault</span>
              <span className="footer-sep">·</span>
              <span>AES-256-GCM · mTLS 1.3</span>
            </footer>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

function BootSequence({ onDone }: { onDone: () => void }) {
  const lines = [
    '> initializing distributed vault...',
    '> loading TLS certificates...',
    '> connecting to master node [:9000]...',
    '> chunk servers: [chunk1] [chunk2] [chunk3]',
    '> AES-256-GCM cipher ready',
    '> SYSTEM READY',
  ];
  const [visibleLines, setVisibleLines] = useState<number[]>([]);

  useState(() => {
    lines.forEach((_, i) => {
      setTimeout(() => {
        setVisibleLines(prev => [...prev, i]);
        if (i === lines.length - 1) {
          setTimeout(onDone, 500);
        }
      }, i * 260 + 100);
    });
  });

  return (
    <motion.div
      className="boot-screen"
      exit={{ opacity: 0 }}
      transition={{ duration: 0.4 }}
    >
      <div className="boot-logo">
        <span className="boot-logo-symbol">◈</span>
        <span className="boot-logo-text">VAULT</span>
      </div>
      <div className="boot-lines">
        {lines.map((line, i) => (
          <AnimatePresence key={i}>
            {visibleLines.includes(i) && (
              <motion.div
                className={`boot-line ${i === lines.length - 1 ? 'boot-line-final' : ''}`}
                initial={{ opacity: 0, x: -8 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ duration: 0.2 }}
              >
                {line}
              </motion.div>
            )}
          </AnimatePresence>
        ))}
      </div>
    </motion.div>
  );
}
