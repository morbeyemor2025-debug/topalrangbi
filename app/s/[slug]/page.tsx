'use client'

import { useEffect, useState } from 'react'

interface Salon {
  id: string
  name: string
  plan: string
}

interface QueueEntry {
  id: string
  client_name: string
  position: number
  status: string
  service_type: string
  joined_at: string
}

const SERVICES = [
  { id: 'coupe', label: 'Coupe', price: 1500, duration: 20 },
  { id: 'barbe', label: 'Barbe', price: 1000, duration: 15 },
  { id: 'coupe_barbe', label: 'Coupe + Barbe', price: 2500, duration: 35 },
]

export default function ClientPage({ params }: { params: { slug: string } }) {
  const { slug } = params

  const [salon, setSalon] = useState<Salon | null>(null)
  const [queue, setQueue] = useState<QueueEntry[]>([])
  const [loading, setLoading] = useState(true)
  const [joining, setJoining] = useState(false)
  const [joined, setJoined] = useState<QueueEntry | null>(null)
  const [error, setError] = useState('')
  const [form, setForm] = useState({ name: '', phone: '', service: 'coupe' })

  const fetchQueue = async () => {
    try {
      const res = await fetch(`/api/queue?salon=${slug}`)
      const data = await res.json()
      if (data.salon) setSalon(data.salon)
      if (data.queue) setQueue(data.queue)
    } catch (e) {
      setError('Impossible de charger la file')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    fetchQueue()
    const interval = setInterval(fetchQueue, 10000)
    return () => clearInterval(interval)
  }, [slug])

  const handleJoin = async () => {
    if (!form.name.trim()) { setError('Entrez votre prénom'); return }
    setJoining(true)
    setError('')
    try {
      const res = await fetch('/api/queue', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          salonSlug: slug,
          clientName: form.name,
          clientPhone: form.phone || undefined,
          serviceType: form.service,
        }),
      })
      const data = await res.json()
      if (!res.ok) { setError(data.error || 'Erreur'); return }
      setJoined(data.entry)
      fetchQueue()
    } catch {
      setError('Erreur réseau')
    } finally {
      setJoining(false)
    }
  }

  const waitMin = (position: number) => {
    const svc = SERVICES.find(s => s.id === form.service)
    return position * (svc?.duration ?? 20)
  }

  if (loading) return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#0D0D0D', color: '#fff', fontFamily: 'system-ui' }}>
      <p>Chargement...</p>
    </div>
  )

  return (
    <div style={{ minHeight: '100vh', background: '#0D0D0D', color: '#fff', fontFamily: 'system-ui', padding: '24px 16px' }}>
      <div style={{ maxWidth: 480, margin: '0 auto' }}>

        {/* Header */}
        <div style={{ textAlign: 'center', marginBottom: 32 }}>
          <h1 style={{ fontSize: 28, fontWeight: 700, margin: 0, color: '#fff' }}>
            {salon?.name ?? slug}
          </h1>
          <p style={{ color: '#888', marginTop: 8 }}>File d'attente digitale</p>
        </div>

        {/* File actuelle */}
        <div style={{ background: '#1a1a1a', borderRadius: 12, padding: 20, marginBottom: 24 }}>
          <h2 style={{ fontSize: 16, color: '#888', margin: '0 0 12px' }}>
            FILE D'ATTENTE — {queue.filter(e => e.status === 'waiting').length} en attente
          </h2>
          {queue.length === 0 ? (
            <p style={{ color: '#555', textAlign: 'center', padding: '16px 0' }}>Aucun client en attente — soyez le premier !</p>
          ) : (
            queue.filter(e => ['waiting', 'called', 'serving'].includes(e.status)).map((entry, i) => (
              <div key={entry.id} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 0', borderBottom: i < queue.length - 1 ? '1px solid #222' : 'none' }}>
                <div style={{ width: 36, height: 36, borderRadius: '50%', background: entry.status === 'called' ? '#22c55e' : '#333', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 700, fontSize: 14, flexShrink: 0 }}>
                  {entry.position}
                </div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 600 }}>{entry.client_name}</div>
                  <div style={{ fontSize: 12, color: '#666' }}>{entry.service_type}</div>
                </div>
                <div style={{ fontSize: 12, color: entry.status === 'called' ? '#22c55e' : '#555' }}>
                  {entry.status === 'called' ? '🔔 Appelé' : entry.status === 'serving' ? '✂️ En cours' : `~${waitMin(entry.position)} min`}
                </div>
              </div>
            ))
          )}
        </div>

        {/* Mon ticket */}
        {joined ? (
          <div style={{ background: '#0f2a1a', border: '1px solid #22c55e', borderRadius: 12, padding: 24, textAlign: 'center' }}>
            <div style={{ fontSize: 48, fontWeight: 800, color: '#22c55e' }}>#{joined.position}</div>
            <div style={{ fontSize: 20, fontWeight: 600, marginTop: 8 }}>{joined.client_name}</div>
            <div style={{ color: '#888', marginTop: 4 }}>Vous êtes dans la file ✓</div>
            <div style={{ color: '#555', fontSize: 13, marginTop: 12 }}>Attente estimée : ~{waitMin(joined.position)} min</div>
          </div>
        ) : (
          /* Formulaire rejoindre */
          <div style={{ background: '#1a1a1a', borderRadius: 12, padding: 20 }}>
            <h2 style={{ fontSize: 16, fontWeight: 700, margin: '0 0 16px' }}>Rejoindre la file</h2>

            {error && <div style={{ background: '#2a1010', border: '1px solid #ef4444', borderRadius: 8, padding: 12, marginBottom: 16, color: '#ef4444', fontSize: 14 }}>{error}</div>}

            <div style={{ marginBottom: 12 }}>
              <label style={{ fontSize: 13, color: '#888', display: 'block', marginBottom: 6 }}>Prénom *</label>
              <input
                value={form.name}
                onChange={e => setForm(f => ({ ...f, name: e.target.value }))}
                placeholder="Votre prénom"
                style={{ width: '100%', padding: '12px 14px', background: '#222', border: '1px solid #333', borderRadius: 8, color: '#fff', fontSize: 16, boxSizing: 'border-box' }}
              />
            </div>

            <div style={{ marginBottom: 12 }}>
              <label style={{ fontSize: 13, color: '#888', display: 'block', marginBottom: 6 }}>Téléphone (optionnel)</label>
              <input
                value={form.phone}
                onChange={e => setForm(f => ({ ...f, phone: e.target.value }))}
                placeholder="+221 77 000 00 00"
                type="tel"
                style={{ width: '100%', padding: '12px 14px', background: '#222', border: '1px solid #333', borderRadius: 8, color: '#fff', fontSize: 16, boxSizing: 'border-box' }}
              />
            </div>

            <div style={{ marginBottom: 20 }}>
              <label style={{ fontSize: 13, color: '#888', display: 'block', marginBottom: 6 }}>Service</label>
              <div style={{ display: 'flex', gap: 8 }}>
                {SERVICES.map(s => (
                  <button
                    key={s.id}
                    onClick={() => setForm(f => ({ ...f, service: s.id }))}
                    style={{ flex: 1, padding: '10px 8px', background: form.service === s.id ? '#22c55e' : '#222', border: `1px solid ${form.service === s.id ? '#22c55e' : '#333'}`, borderRadius: 8, color: form.service === s.id ? '#000' : '#fff', fontSize: 12, fontWeight: 600, cursor: 'pointer' }}
                  >
                    {s.label}<br />
                    <span style={{ fontWeight: 400, opacity: 0.8 }}>{s.price} F</span>
                  </button>
                ))}
              </div>
            </div>

            <button
              onClick={handleJoin}
              disabled={joining}
              style={{ width: '100%', padding: '14px', background: joining ? '#555' : '#22c55e', border: 'none', borderRadius: 10, color: joining ? '#888' : '#000', fontSize: 16, fontWeight: 700, cursor: joining ? 'not-allowed' : 'pointer' }}
            >
              {joining ? 'Enregistrement...' : 'Rejoindre la file →'}
            </button>
          </div>
        )}
      </div>
    </div>
  )
}