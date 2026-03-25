import { useState, useEffect, useCallback } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Plus, Search, RefreshCw, Trash2, Eye, EyeOff, Copy, Check, Globe, X } from 'lucide-react';
import { api } from '../api';
import type { PasswordEntry } from '../api';
import './VaultScreen.css';

interface Props { username?: string; }

type Panel = 'list' | 'add' | 'view';

export default function VaultScreen({ }: Props) {
  const [sites, setSites] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState('');
  const [panel, setPanel] = useState<Panel>('list');
  const [selected, setSelected] = useState<PasswordEntry | null>(null);
  const [error, setError] = useState('');

  const loadSites = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const res = await api.listSites();
      setSites(res.sites || []);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { loadSites(); }, [loadSites]);

  const filteredSites = sites.filter(s =>
    s.toLowerCase().includes(filter.toLowerCase())
  );

  const openSite = async (site: string) => {
    try {
      const entry = await api.getEntry(site);
      setSelected(entry);
      setPanel('view');
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const deleteSite = async (site: string) => {
    if (!confirm(`Delete entry for ${site}?`)) return;
    try {
      await api.deleteEntry(site);
      setSites(prev => prev.filter(s => s !== site));
      if (selected?.site === site) { setSelected(null); setPanel('list'); }
    } catch (e) {
      setError((e as Error).message);
    }
  };

  return (
    <div className="vault-screen">
      <div className="vault-sidebar">
        <div className="sidebar-header">
          <div className="sidebar-title">
            <span className="sidebar-count">{sites.length}</span>
            <span>CREDENTIALS</span>
          </div>
          <div className="sidebar-actions">
            <button className="icon-btn" onClick={loadSites} title="Refresh">
              <RefreshCw size={13} className={loading ? 'spin' : ''} />
            </button>
            <button
              className={`icon-btn icon-btn-accent ${panel === 'add' ? 'icon-btn-active' : ''}`}
              onClick={() => setPanel(panel === 'add' ? 'list' : 'add')}
              title="Add new"
            >
              <Plus size={13} />
            </button>
          </div>
        </div>

        <div className="sidebar-search">
          <Search size={12} className="search-icon" />
          <input
            className="search-input"
            placeholder="filter sites..."
            value={filter}
            onChange={e => setFilter(e.target.value)}
          />
          {filter && (
            <button className="search-clear" onClick={() => setFilter('')}>
              <X size={11} />
            </button>
          )}
        </div>

        <AnimatePresence>
          {error && (
            <motion.div
              className="vault-error"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
            >
              {error}
            </motion.div>
          )}
        </AnimatePresence>

        <div className="site-list">
          {loading ? (
            <div className="list-loading">
              {[...Array(4)].map((_, i) => (
                <div key={i} className="skeleton" style={{ animationDelay: `${i * 0.1}s` }} />
              ))}
            </div>
          ) : filteredSites.length === 0 ? (
            <div className="list-empty">
              {filter ? `no results for "${filter}"` : '// no credentials stored'}
            </div>
          ) : (
            filteredSites.map((site, i) => (
              <motion.div
                key={site}
                className={`site-item ${selected?.site === site ? 'site-item-active' : ''}`}
                initial={{ opacity: 0, x: -8 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ delay: i * 0.04 }}
                onClick={() => openSite(site)}
              >
                <div className="site-favicon">
                  <Globe size={12} />
                </div>
                <span className="site-name">{site}</span>
                <button
                  className="site-delete"
                  onClick={e => { e.stopPropagation(); deleteSite(site); }}
                  title="Delete"
                >
                  <Trash2 size={11} />
                </button>
              </motion.div>
            ))
          )}
        </div>
      </div>

      <div className="vault-main">
        <AnimatePresence mode="wait">
          {panel === 'add' && (
            <motion.div
              key="add"
              initial={{ opacity: 0, x: 16 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: 16 }}
              transition={{ duration: 0.2 }}
            >
              <AddPanel
                onSave={async (entry) => {
                  await api.saveEntry(entry);
                  await loadSites();
                  setPanel('list');
                }}
                onCancel={() => setPanel('list')}
              />
            </motion.div>
          )}
          {panel === 'view' && selected && (
            <motion.div
              key={selected.site}
              initial={{ opacity: 0, x: 16 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: 16 }}
              transition={{ duration: 0.2 }}
            >
              <ViewPanel
                entry={selected}
                onClose={() => { setSelected(null); setPanel('list'); }}
                onDelete={() => deleteSite(selected.site)}
              />
            </motion.div>
          )}
          {panel === 'list' && !selected && (
            <motion.div
              key="empty"
              className="vault-empty"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
            >
              <div className="empty-glyph">◈</div>
              <p>Select a credential to view</p>
              <p className="empty-sub">or press <span className="kbd">+</span> to add new</p>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

function AddPanel({ onSave, onCancel }: { onSave: (e: PasswordEntry) => Promise<void>; onCancel: () => void }) {
  const [site, setSite] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [showPass, setShowPass] = useState(false);

  const save = async () => {
    if (!site.trim() || !username.trim() || !password.trim()) {
      setError('all fields required');
      return;
    }
    setSaving(true);
    setError('');
    try {
      await onSave({ site: site.trim(), username: username.trim(), password });
    } catch (e) {
      setError((e as Error).message);
      setSaving(false);
    }
  };

  return (
    <div className="detail-panel">
      <div className="detail-header">
        <h2 className="detail-title">// ADD CREDENTIAL</h2>
        <button className="icon-btn" onClick={onCancel}><X size={14} /></button>
      </div>

      <div className="detail-fields">
        <DetailField label="SITE / SERVICE" value={site} onChange={setSite} placeholder="e.g. github.com" />
        <DetailField label="USERNAME / EMAIL" value={username} onChange={setUsername} placeholder="e.g. alice@example.com" />
        <div className="field-row">
          <label className="detail-label">PASSWORD</label>
          <div className="field-input-wrap">
            <input
              className="detail-input"
              type={showPass ? 'text' : 'password'}
              value={password}
              onChange={e => setPassword(e.target.value)}
              placeholder="enter password"
            />
            <button className="icon-btn input-suffix" onClick={() => setShowPass(v => !v)}>
              {showPass ? <EyeOff size={13} /> : <Eye size={13} />}
            </button>
          </div>
        </div>

        {error && <div className="panel-error">{error}</div>}
      </div>

      <div className="detail-actions">
        <button className="btn-secondary" onClick={onCancel}>CANCEL</button>
        <button className="btn-primary" onClick={save} disabled={saving}>
          {saving ? 'SAVING...' : 'SAVE ENTRY'}
        </button>
      </div>
    </div>
  );
}

function ViewPanel({ entry, onClose, onDelete }: { entry: PasswordEntry; onClose: () => void; onDelete: () => void }) {
  const [showPass, setShowPass] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);

  const copy = async (text: string, field: string) => {
    await navigator.clipboard.writeText(text);
    setCopied(field);
    setTimeout(() => setCopied(null), 1800);
  };

  return (
    <div className="detail-panel">
      <div className="detail-header">
        <div className="detail-site-header">
          <div className="detail-favicon"><Globe size={16} /></div>
          <h2 className="detail-title">{entry.site}</h2>
        </div>
        <div style={{ display: 'flex', gap: 6 }}>
          <button className="icon-btn icon-btn-danger" onClick={onDelete} title="Delete"><Trash2 size={14} /></button>
          <button className="icon-btn" onClick={onClose}><X size={14} /></button>
        </div>
      </div>

      <div className="detail-fields">
        <div className="field-row">
          <label className="detail-label">USERNAME</label>
          <div className="field-value-wrap">
            <span className="field-value">{entry.username}</span>
            <button className="icon-btn" onClick={() => copy(entry.username, 'user')} title="Copy">
              {copied === 'user' ? <Check size={12} className="copy-done" /> : <Copy size={12} />}
            </button>
          </div>
        </div>

        <div className="field-row">
          <label className="detail-label">PASSWORD</label>
          <div className="field-value-wrap">
            <span className="field-value field-password">
              {showPass ? entry.password : '••••••••••••'}
            </span>
            <button className="icon-btn" onClick={() => setShowPass(v => !v)}>
              {showPass ? <EyeOff size={12} /> : <Eye size={12} />}
            </button>
            <button className="icon-btn" onClick={() => copy(entry.password, 'pass')} title="Copy">
              {copied === 'pass' ? <Check size={12} className="copy-done" /> : <Copy size={12} />}
            </button>
          </div>
        </div>
      </div>

      <div className="detail-enc-badge">
        <span className="enc-dot" />
        <span>stored encrypted · AES-256-GCM · replicated across 3 nodes</span>
      </div>
    </div>
  );
}

function DetailField({ label, value, onChange, placeholder }: {
  label: string; value: string; onChange: (v: string) => void; placeholder?: string;
}) {
  return (
    <div className="field-row">
      <label className="detail-label">{label}</label>
      <input
        className="detail-input"
        value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder}
      />
    </div>
  );
}
