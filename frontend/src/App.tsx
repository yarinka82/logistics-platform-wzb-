import { useState } from 'react';
import { t } from './i18n/i18n';
import Auth from './components/Auth';
import type { User } from './model/types';

// TODO: Import and route your components here (e.g., Order, AdminPanel, Profile)

export default function App() {
  const [user, setUser] = useState<User | null>(null);
  const [authMode, setAuthMode] = useState('');

  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="/">LOGISTICS / WZB</a>
        <div className="header-actions">
          {user ? (
            <button className="header-link" onClick={() => setUser(null)}>
              {t("Sign out")}
            </button>
          ) : (
            <button className="primary" onClick={() => setAuthMode('login')}>
              {t("Sign in")}
            </button>
          )}
        </div>
      </header>

      <main style={{ padding: '2rem' }}>
        <div className="card">
          <h2>{t("Welcome to the Logistics Platform")}</h2>
          <p>
            <strong>TODO for Junior Developers:</strong>
          </p>
          <ul>
            <li>Implement React Router or state-based navigation</li>
            <li>Build the Freight Exchange marketplace view</li>
            <li>Build the "My Trips" dashboard for carriers</li>
            <li>Connect to the FastAPI backend using <code>request()</code> from <code>api.ts</code></li>
          </ul>
        </div>
      </main>

      {authMode && (
        <Auth 
          mode={authMode} 
          onClose={() => setAuthMode('')} 
          onLogin={(u: User) => { 
            setUser(u); 
            setAuthMode(''); 
          }} 
        />
      )}
    </div>
  );
}
