import { motion } from 'framer-motion';
import { LogOut, Shield, Activity } from 'lucide-react';
import { useState, useEffect } from 'react';
import { api } from '../api';
import './TopBar.css';

interface Props {
  username: string;
  isLoggedIn: boolean;
  onLogout: () => void;
}

export default function TopBar({ username, isLoggedIn, onLogout }: Props) {
  const [chunks, setChunks] = useState<number | null>(null);
  

  useEffect(() => {
    const check = async () => {
      try {
        const h = await api.health();
        setChunks(h.chunks);
      } catch {
        setChunks(0);
      }
    };
    check();
    const id = setInterval(() => { check();  }, 5000);
    return () => clearInterval(id);
  }, []);

  return (
    <header className="topbar">
      <div className="topbar-left">
        <Shield size={16} className="topbar-icon" />
        <span className="topbar-brand">
          <span className="topbar-brand-bold">VAULT</span>
          <span className="topbar-brand-sub">_distributed</span>
        </span>
      </div>

      <div className="topbar-center">
        <div className="status-cluster">
          <div className={`status-dot ${chunks === null ? 'status-amber' : chunks > 0 ? 'status-green' : 'status-red'}`} />
          <span className="status-label">
            {chunks === null ? 'checking...' : chunks > 0 ? `${chunks} nodes online` : 'no nodes'}
          </span>
        </div>
      </div>

      <div className="topbar-right">
        {isLoggedIn && (
          <motion.div
            className="topbar-user"
            initial={{ opacity: 0, x: 12 }}
            animate={{ opacity: 1, x: 0 }}
          >
            <Activity size={12} className="user-activity" />
            <span className="user-name">{username}</span>
            <button className="logout-btn" onClick={onLogout} title="Logout">
              <LogOut size={13} />
            </button>
          </motion.div>
        )}
      </div>
    </header>
  );
}
