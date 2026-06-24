import { useState } from 'react'
import { diagnosticarPagos, porQuePagos } from './api'

// dominios (coinciden con allowed-symbols del .clp)
const TIPO_DOC = ['V', 'J']
const ATAQUE = ['desconocido', 'no', 'si']

const SEV_COLOR = { critica: '#ef4444', alta: '#f59e0b', media: '#3b82f6', baja: '#10b981', indeterminado: '#6b7280' }
const DIR_COLOR = { arriba: '#10b981', abajo: '#38bdf8', bloqueado: '#f59e0b' }

const pagoVacio = () => ({ id: '', telefono: '', nombre: '', tipo_documento: 'V', documento: '', monto: 0 })

// escenarios de demostracion (uno por veredicto del motor)
const PRESETS = {
  'Día normal': {
    pagos: [
      { id: 'pg1', telefono: '04141234567', nombre: 'Juan Pérez', tipo_documento: 'V', documento: 'V12345678', monto: 150 },
      { id: 'pg2', telefono: '04241112233', nombre: 'Inversiones C.A.', tipo_documento: 'J', documento: 'J402015558', monto: 980 },
    ],
    ventana: { tope: 100, carga_extra: 0 },
    ingress: { ataque: 'no', requests_por_seg: 0, tasa_4xx: 0, ips_distintas: 50 },
  },
  'Pico de pagos': {
    pagos: [{ id: 'pg1', telefono: '04141234567', nombre: 'Cliente Demo', tipo_documento: 'V', documento: 'V11111111', monto: 100 }],
    ventana: { tope: 100, carga_extra: 130 },
    ingress: { ataque: 'no', requests_por_seg: 0, tasa_4xx: 0, ips_distintas: 50 },
  },
  'Ataque DDoS': {
    pagos: [{ id: 'pg1', telefono: '04141234567', nombre: 'Cliente Demo', tipo_documento: 'V', documento: 'V11111111', monto: 100 }],
    ventana: { tope: 100, carga_extra: 130 },
    ingress: { ataque: 'si', requests_por_seg: 9000, tasa_4xx: 70, ips_distintas: 3 },
  },
  'Datos inválidos': {
    pagos: [
      { id: 'pg1', telefono: '123', nombre: 'Telef Malo', tipo_documento: 'V', documento: 'V1', monto: 50 },
      { id: 'pg2', telefono: '05001234567', nombre: 'Sin Prefijo', tipo_documento: 'J', documento: 'J9', monto: 20 },
    ],
    ventana: { tope: 100, carga_extra: 0 },
    ingress: { ataque: 'no', requests_por_seg: 0, tasa_4xx: 0, ips_distintas: 50 },
  },
}

export default function PagoMovil() {
  const [pagos, setPagos] = useState(PRESETS['Día normal'].pagos.map((p) => ({ ...p })))
  const [servicio, setServicio] = useState({ nombre: 'pago-movil-svc', replicas: 1, replicas_min: 1, replicas_max: 10, capacidad_por_replica: 50 })
  const [ventana, setVentana] = useState({ tope: 100, carga_extra: 0 })
  const [ingress, setIngress] = useState({ servicio: 'pago-movil-svc', ataque: 'no', requests_por_seg: 0, tasa_4xx: 0, ips_distintas: 50 })

  const [resultado, setResultado] = useState(null)
  const [justificaciones, setJustificaciones] = useState(null)
  const [error, setError] = useState(null)
  const [cargando, setCargando] = useState(false)

  let nextId = pagos.length + 1
  const nuevoPago = () => ({ ...pagoVacio(), id: 'pg' + nextId++ })

  function cargarPreset(nombre) {
    const p = PRESETS[nombre]
    setPagos(p.pagos.map((x) => ({ ...x })))
    setVentana({ ...p.ventana })
    setIngress({ servicio: 'pago-movil-svc', ...p.ingress })
    setServicio({ nombre: 'pago-movil-svc', replicas: 1, replicas_min: 1, replicas_max: 10, capacidad_por_replica: 50 })
    setResultado(null); setJustificaciones(null); setError(null)
  }

  const editarPago = (i, campo, valor) =>
    setPagos((prev) => prev.map((it, j) => (j === i ? { ...it, [campo]: valor } : it)))

  async function onDiagnosticar() {
    setCargando(true); setError(null); setJustificaciones(null); setResultado(null)
    try {
      const data = await diagnosticarPagos({ pagos, servicio, ventana, ingress })
      setResultado(data)
    } catch (e) {
      setError(e.message)
    } finally {
      setCargando(false)
    }
  }

  async function onPorQue() {
    try {
      const data = await porQuePagos()
      setJustificaciones(data.justificaciones)
    } catch (e) {
      setError(e.message)
    }
  }

  const carga = resultado?.carga
  const pct = carga ? Math.min(100, Math.round((carga.pagos_en_cola / carga.tope) * 100)) : 0

  return (
    <>
      <section className="presets">
        <span>Escenarios de ejemplo:</span>
        {Object.keys(PRESETS).map((n) => (
          <button key={n} className="chip" onClick={() => cargarPreset(n)}>{n}</button>
        ))}
      </section>

      <div className="grid">
        {/* ----------- FORMULARIO ----------- */}
        <div className="col">
          <div className="card">
            <div className="capa-head">
              <h3>Pagos móviles</h3>
              <button className="add" onClick={() => setPagos((p) => [...p, nuevoPago()])}>+ añadir</button>
            </div>
            {pagos.map((p, i) => (
              <div className="fila" key={i}>
                <Txt label="nombre" value={p.nombre} onChange={(v) => editarPago(i, 'nombre', v)} />
                <Txt label="teléfono" value={p.telefono} onChange={(v) => editarPago(i, 'telefono', v)} />
                <Sel label="tipo doc" value={p.tipo_documento} opts={TIPO_DOC} onChange={(v) => editarPago(i, 'tipo_documento', v)} />
                <Txt label="documento" value={p.documento} onChange={(v) => editarPago(i, 'documento', v)} />
                <Num label="monto" value={p.monto} onChange={(v) => editarPago(i, 'monto', v)} />
                <button className="del" title="eliminar" onClick={() => setPagos((p) => p.filter((_, j) => j !== i))}>×</button>
              </div>
            ))}
          </div>

          <div className="card">
            <h3>Autoescalado</h3>
            <div className="fila">
              <Num label="réplicas" value={servicio.replicas} onChange={(v) => setServicio({ ...servicio, replicas: v })} />
              <Num label="capacidad/réplica" value={servicio.capacidad_por_replica} onChange={(v) => setServicio({ ...servicio, capacidad_por_replica: v })} />
              <Num label="réplicas máx" value={servicio.replicas_max} onChange={(v) => setServicio({ ...servicio, replicas_max: v })} />
              <Num label="tope" value={ventana.tope} onChange={(v) => setVentana({ ...ventana, tope: v })} />
              <Num label="pico extra" value={ventana.carga_extra} onChange={(v) => setVentana({ ...ventana, carga_extra: v })} />
            </div>
          </div>

          <div className="card">
            <h3>Ingress / DDoS</h3>
            <div className="fila">
              <Sel label="ataque" value={ingress.ataque} opts={ATAQUE} onChange={(v) => setIngress({ ...ingress, ataque: v })} />
              <Num label="req/seg" value={ingress.requests_por_seg} onChange={(v) => setIngress({ ...ingress, requests_por_seg: v })} />
              <Num label="4xx %" value={ingress.tasa_4xx} onChange={(v) => setIngress({ ...ingress, tasa_4xx: v })} />
              <Num label="IPs distintas" value={ingress.ips_distintas} onChange={(v) => setIngress({ ...ingress, ips_distintas: v })} />
            </div>
          </div>

          <button className="diagnosticar" onClick={onDiagnosticar} disabled={cargando}>
            {cargando ? 'Diagnosticando…' : 'Diagnosticar'}
          </button>
        </div>

        {/* ----------- RESULTADOS ----------- */}
        <div className="col">
          {error && <div className="error">⚠ {error}</div>}

          {carga && (
            <div className="card">
              <h3>Estado del servicio</h3>
              <p className="causa">
                Carga en cola: <strong>{carga.pagos_en_cola}</strong> / tope {carga.tope}
                {resultado.pagos && <> · válidos {resultado.pagos.validos} · rechazados {resultado.pagos.rechazados}</>}
              </p>
              <div style={{ height: 10, background: '#0b1220', border: '1px solid var(--border)', borderRadius: 6, overflow: 'hidden' }}>
                <div style={{ height: '100%', width: pct + '%', background: carga.pagos_en_cola >= carga.tope ? '#ef4444' : 'var(--accent)' }} />
              </div>
            </div>
          )}

          {resultado && resultado.diagnosticos.map((d, i) => (
            <div className="card diag" key={i}>
              <div className="diag-head">
                <span className="badge" style={{ background: SEV_COLOR[d.severidad] || '#6b7280' }}>{d.severidad}</span>
                <span className="tipo">{d.tipo}</span>
              </div>
              <p className="causa">{d.causa_raiz}</p>
              {resultado.acciones?.map((a, k) => (
                <p className="causa" key={k}>
                  <span className="badge" style={{ background: DIR_COLOR[a.direccion] || '#6b7280' }}>{a.direccion}</span>{' '}
                  réplicas <strong>{a.replicas_antes} → {a.replicas_despues}</strong> · {a.razon}
                </p>
              ))}
              <h4>Plan de acción</h4>
              <ul className="cmds">
                {d.comandos.map((c, j) => <li key={j}><code>{c}</code></li>)}
              </ul>
            </div>
          ))}

          {resultado && resultado.diagnosticos.length > 0 && (
            <button className="porque" onClick={onPorQue}>¿Por qué?</button>
          )}

          {justificaciones && (
            <div className="card arbol">
              <h3>Árbol de deducción</h3>
              {justificaciones.length === 0 && <p>Sin justificaciones.</p>}
              <ol>
                {justificaciones.map((j, i) => (
                  <li key={i}>
                    <span className="regla">{j.regla}</span>
                    <div className="premisa"><strong>Premisa:</strong> {j.premisa}</div>
                    <div className="concl"><strong>⇒</strong> {j.conclusion}</div>
                  </li>
                ))}
              </ol>
            </div>
          )}
        </div>
      </div>
    </>
  )
}

// --- componentes auxiliares (mismas clases CSS que App.jsx) ---
function Txt({ label, value, onChange }) {
  return (
    <label className="field">
      <span>{label}</span>
      <input value={value} onChange={(e) => onChange(e.target.value)} />
    </label>
  )
}

function Num({ label, value, onChange }) {
  return (
    <label className="field">
      <span>{label}</span>
      <input type="number" value={value} onChange={(e) => onChange(e.target.value === '' ? 0 : Number(e.target.value))} />
    </label>
  )
}

function Sel({ label, value, opts, onChange }) {
  return (
    <label className="field">
      <span>{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {opts.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </label>
  )
}
