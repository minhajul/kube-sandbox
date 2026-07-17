'use client';

import { useEffect, useState } from 'react';

type ServiceStatus = {
  name: string;
  status: 'online' | 'offline';
  detail?: string;
};

const SERVICES = [
  { name: 'auth-service', path: '/api/auth/health' },
  { name: 'profile-service', path: '/api/profile/health' },
];

export default function Home() {
  const [services, setServices] = useState<ServiceStatus[]>(() =>
    SERVICES.map((s) => ({ name: s.name, status: 'offline' })),
  );
  const [loading, setLoading] = useState(false);
  const [lastChecked, setLastChecked] = useState<string | null>(null);

  const checkHealth = async () => {
    setLoading(true);
    const results = await Promise.all(
      SERVICES.map(async (service) => {
        try {
          const res = await fetch(service.path, {
            cache: 'no-store',
            signal: AbortSignal.timeout(5000),
          });
          if (res.ok) {
            const data = await res.json();
            return {
              name: service.name,
              status: 'online' as const,
              detail: data?.status || 'ok',
            };
          }
          return { name: service.name, status: 'offline' as const };
        } catch (e) {
          return { name: service.name, status: 'offline' as const, detail: String(e) };
        }
      }),
    );
    setServices(results);
    setLastChecked(new Date().toLocaleTimeString());
    setLoading(false);
  };

  useEffect(() => {
    checkHealth();
    const interval = setInterval(checkHealth, 10000);
    return () => clearInterval(interval);
  }, []);

  return (
    <main className="container">
      <h1>Kube Sandbox Dashboard</h1>
      <p className="subtitle">GitOps-driven microservices health monitor</p>

      {services.map((svc) => (
        <div key={svc.name} className="service-card">
          <span className="service-name">{svc.name}</span>
          <span className={`status ${svc.status}`}>
            <span className="dot" />
            {svc.status}
          </span>
        </div>
      ))}

      <button className="refresh-btn" onClick={checkHealth} disabled={loading}>
        {loading ? 'Checking...' : 'Refresh now'}
      </button>

      {lastChecked && (
        <p className="timestamp">Last check: {lastChecked}</p>
      )}
    </main>
  );
}
