// Cliente del backend FastAPI.
const BASE = import.meta.env.VITE_API_URL || 'http://127.0.0.1:8000'

export async function diagnosticar(telemetria) {
  const res = await fetch(`${BASE}/diagnosticar`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(telemetria),
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) {
    // 422 = telemetria rechazada por el motor (range / allowed-symbols)
    const detalle = data.detail || `Error ${res.status}`
    throw new Error(typeof detalle === 'string' ? detalle : JSON.stringify(detalle))
  }
  return data
}

export async function porQue() {
  const res = await fetch(`${BASE}/por-que`)
  if (!res.ok) throw new Error(`Error ${res.status}`)
  return res.json()
}

// --- Pago Movil + Autoescalado ---
export async function diagnosticarPagos(entrada) {
  const res = await fetch(`${BASE}/pago-movil/diagnosticar`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(entrada),
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) {
    const detalle = data.detail || `Error ${res.status}`
    throw new Error(typeof detalle === 'string' ? detalle : JSON.stringify(detalle))
  }
  return data
}

export async function porQuePagos() {
  const res = await fetch(`${BASE}/pago-movil/por-que`)
  if (!res.ok) throw new Error(`Error ${res.status}`)
  return res.json()
}
