import { useState } from 'react'
import { diagnosticar, porQue } from './api'

// --- dominios (deben coincidir con los allowed-symbols del .clp) ---
const EST_CONT = ['Running', 'CrashLoopBackOff', 'OOMKilled', 'Error', 'Pending']
const OK_FALLIDA = ['ok', 'fallida']
const EST_NODO = ['Ready', 'NotReady']
const PRESION = ['ninguna', 'DiskPressure', 'MemoryPressure', 'PIDPressure']
const SI_NO = ['no', 'si']
const ATAQUE = ['desconocido', 'no', 'si']

// --- escenarios de demostracion: plataforma bancaria sobre Kubernetes ---
// (un microservicio del banco por escenario, una heuristica del motor por cada uno)
const PRESETS = {
  'Cascada OOMKilled': {
    contenedores: [{ id: 'pago-movil-api', estado: 'OOMKilled', cpu_pct: 60, mem_pct: 100, liveness: 'fallida', readiness: 'fallida', conexiones: 0 }],
    nodos: [],
    hpas: [],
    ingress: [],
    traficos: [{ servicio: 'checkout', latencia_p95: 1200, latencia_p99: 4500, tasa_5xx: 30, tasa_4xx: 2 }],
    red: { coredns_saturado: 'no', saturacion_pct: 10 },
  },
  'Falsa alarma CPU': {
    contenedores: [{ id: 'liquidacion-batch', estado: 'Running', cpu_pct: 98, mem_pct: 40, liveness: 'ok', readiness: 'ok', conexiones: 0 }],
    nodos: [{ id: 'node-pagos-1', estado: 'Ready', presion: 'MemoryPressure' }],
    hpas: [],
    ingress: [],
    traficos: [],
    red: { coredns_saturado: 'no', saturacion_pct: 0 },
  },
  'Fuga de conexiones': {
    contenedores: [{ id: 'gateway-pagos', estado: 'CrashLoopBackOff', cpu_pct: 40, mem_pct: 70, liveness: 'fallida', readiness: 'fallida', conexiones: 8000 }],
    nodos: [],
    hpas: [],
    ingress: [],
    traficos: [],
    red: { coredns_saturado: 'no', saturacion_pct: 0 },
  },
  'Autoescalado por demanda': {
    contenedores: [],
    nodos: [],
    hpas: [{ objetivo: 'pago-movil-api', escalando: 'no', replicas_actuales: 2, replicas_min: 1, replicas_max: 10, cpu_actual: 92, cpu_objetivo: 70 }],
    ingress: [],
    traficos: [{ servicio: 'pago-movil-api', latencia_p95: 350, latencia_p99: 700, tasa_5xx: 1, tasa_4xx: 1 }],
    red: { coredns_saturado: 'no', saturacion_pct: 0 },
  },
  'Ataque DDoS': {
    contenedores: [],
    nodos: [],
    hpas: [{ objetivo: 'pago-movil-api', escalando: 'no', replicas_actuales: 2, replicas_min: 1, replicas_max: 10, cpu_actual: 95, cpu_objetivo: 70 }],
    ingress: [{ servicio: 'pago-movil-api', requests_por_seg: 9000, tasa_4xx: 70, ips_distintas: 3, ataque: 'si' }],
    traficos: [],
    red: { coredns_saturado: 'no', saturacion_pct: 0 },
  },
}

const contenedorVacio = () => ({ id: '', estado: 'Running', cpu_pct: 0, mem_pct: 0, liveness: 'ok', readiness: 'ok', conexiones: 0 })
const nodoVacio = () => ({ id: '', estado: 'Ready', presion: 'ninguna' })
const traficoVacio = () => ({ servicio: '', latencia_p95: 0, latencia_p99: 0, tasa_5xx: 0, tasa_4xx: 0 })
const hpaVacio = () => ({ objetivo: '', escalando: 'no', replicas_actuales: 1, replicas_min: 1, replicas_max: 10, cpu_actual: 0, cpu_objetivo: 70 })
const ingressVacio = () => ({ servicio: '', requests_por_seg: 0, tasa_4xx: 0, ips_distintas: 1, ataque: 'desconocido' })

const SEV_COLOR = { critica: '#d92d20', alta: '#f59e0b', media: '#0093d0', baja: '#5a9216', indeterminado: '#6b7280' }

export default function App() {
  const [contenedores, setContenedores] = useState(PRESETS['Cascada OOMKilled'].contenedores.map((c) => ({ ...c })))
  const [nodos, setNodos] = useState([])
  const [hpas, setHpas] = useState([])
  const [ingress, setIngress] = useState([])
  const [traficos, setTraficos] = useState(PRESETS['Cascada OOMKilled'].traficos.map((t) => ({ ...t })))
  const [red, setRed] = useState({ coredns_saturado: 'no', saturacion_pct: 10 })

  const [resultado, setResultado] = useState(null)
  const [justificaciones, setJustificaciones] = useState(null)
  const [error, setError] = useState(null)
  const [cargando, setCargando] = useState(false)

  function cargarPreset(nombre) {
    const p = PRESETS[nombre]
    setContenedores(p.contenedores.map((c) => ({ ...c })))
    setNodos(p.nodos.map((n) => ({ ...n })))
    setHpas(p.hpas.map((h) => ({ ...h })))
    setIngress(p.ingress.map((g) => ({ ...g })))
    setTraficos(p.traficos.map((t) => ({ ...t })))
    setRed({ ...p.red })
    setResultado(null); setJustificaciones(null); setError(null)
  }

  // edicion generica de un item de una lista
  const editar = (setter) => (i, campo, valor) =>
    setter((prev) => prev.map((it, j) => (j === i ? { ...it, [campo]: valor } : it)))

  async function onDiagnosticar() {
    setCargando(true); setError(null); setJustificaciones(null); setResultado(null)
    try {
      const tele = { contenedores, nodos, hpas, ingress, traficos, red }
      const data = await diagnosticar(tele)
      setResultado(data)
    } catch (e) {
      setError(e.message)
    } finally {
      setCargando(false)
    }
  }

  async function onPorQue() {
    try {
      const data = await porQue()
      setJustificaciones(data.justificaciones)
    } catch (e) {
      setError(e.message)
    }
  }

  return (
    <div className="app">
      <header>
        <div className="brand">
          <span className="brand-dot">K8</span>
          <h1>K8s-ExpertAdvisor</h1>
        </div>
        <p className="sub">
          Ingeniero DevOps/SRE virtual en CLIPS para la plataforma bancaria sobre Kubernetes:
          diagnostica la causa raíz de crisis de infraestructura, decide el autoescalado y
          bloquea el escalado ante ataques DDoS.
        </p>
        <span className="tagline">● Banca digital · pago móvil · diagnóstico autónomo</span>
      </header>

      <div className="content">
        <section className="presets">
          <span>Escenarios de ejemplo:</span>
          {Object.keys(PRESETS).map((n) => (
            <button key={n} className="chip" onClick={() => cargarPreset(n)}>{n}</button>
          ))}
        </section>

        <div className="grid">
          {/* ----------- FORMULARIO ----------- */}
          <div className="col">
            <Capa titulo="Contenedores (Docker)" onAdd={() => setContenedores((p) => [...p, contenedorVacio()])}>
              {contenedores.map((c, i) => (
                <Fila key={i} onDel={() => setContenedores((p) => p.filter((_, j) => j !== i))}>
                  <Txt label="id" value={c.id} onChange={(v) => editar(setContenedores)(i, 'id', v)} />
                  <Sel label="estado" value={c.estado} opts={EST_CONT} onChange={(v) => editar(setContenedores)(i, 'estado', v)} />
                  <Num label="cpu %" value={c.cpu_pct} onChange={(v) => editar(setContenedores)(i, 'cpu_pct', v)} />
                  <Num label="mem %" value={c.mem_pct} onChange={(v) => editar(setContenedores)(i, 'mem_pct', v)} />
                  <Sel label="liveness" value={c.liveness} opts={OK_FALLIDA} onChange={(v) => editar(setContenedores)(i, 'liveness', v)} />
                  <Sel label="readiness" value={c.readiness} opts={OK_FALLIDA} onChange={(v) => editar(setContenedores)(i, 'readiness', v)} />
                  <Num label="conexiones" value={c.conexiones} onChange={(v) => editar(setContenedores)(i, 'conexiones', v)} />
                </Fila>
              ))}
            </Capa>

            <Capa titulo="Nodos (Kubernetes)" onAdd={() => setNodos((p) => [...p, nodoVacio()])}>
              {nodos.map((n, i) => (
                <Fila key={i} onDel={() => setNodos((p) => p.filter((_, j) => j !== i))}>
                  <Txt label="id" value={n.id} onChange={(v) => editar(setNodos)(i, 'id', v)} />
                  <Sel label="estado" value={n.estado} opts={EST_NODO} onChange={(v) => editar(setNodos)(i, 'estado', v)} />
                  <Sel label="presión" value={n.presion} opts={PRESION} onChange={(v) => editar(setNodos)(i, 'presion', v)} />
                </Fila>
              ))}
            </Capa>

            <Capa titulo="HPA (autoescalado)" onAdd={() => setHpas((p) => [...p, hpaVacio()])}>
              {hpas.map((h, i) => (
                <Fila key={i} onDel={() => setHpas((p) => p.filter((_, j) => j !== i))}>
                  <Txt label="objetivo" value={h.objetivo} onChange={(v) => editar(setHpas)(i, 'objetivo', v)} />
                  <Sel label="escalando" value={h.escalando} opts={SI_NO} onChange={(v) => editar(setHpas)(i, 'escalando', v)} />
                  <Num label="réplicas" value={h.replicas_actuales} onChange={(v) => editar(setHpas)(i, 'replicas_actuales', v)} />
                  <Num label="rép. mín" value={h.replicas_min} onChange={(v) => editar(setHpas)(i, 'replicas_min', v)} />
                  <Num label="rép. máx" value={h.replicas_max} onChange={(v) => editar(setHpas)(i, 'replicas_max', v)} />
                  <Num label="cpu %" value={h.cpu_actual} onChange={(v) => editar(setHpas)(i, 'cpu_actual', v)} />
                  <Num label="cpu objetivo %" value={h.cpu_objetivo} onChange={(v) => editar(setHpas)(i, 'cpu_objetivo', v)} />
                </Fila>
              ))}
            </Capa>

            <Capa titulo="Ingress / DDoS" onAdd={() => setIngress((p) => [...p, ingressVacio()])}>
              {ingress.map((g, i) => (
                <Fila key={i} onDel={() => setIngress((p) => p.filter((_, j) => j !== i))}>
                  <Txt label="servicio" value={g.servicio} onChange={(v) => editar(setIngress)(i, 'servicio', v)} />
                  <Num label="req/seg" value={g.requests_por_seg} onChange={(v) => editar(setIngress)(i, 'requests_por_seg', v)} />
                  <Num label="4xx %" value={g.tasa_4xx} onChange={(v) => editar(setIngress)(i, 'tasa_4xx', v)} />
                  <Num label="IPs distintas" value={g.ips_distintas} onChange={(v) => editar(setIngress)(i, 'ips_distintas', v)} />
                  <Sel label="ataque" value={g.ataque} opts={ATAQUE} onChange={(v) => editar(setIngress)(i, 'ataque', v)} />
                </Fila>
              ))}
            </Capa>

            <Capa titulo="Tráfico (servicios)" onAdd={() => setTraficos((p) => [...p, traficoVacio()])}>
              {traficos.map((t, i) => (
                <Fila key={i} onDel={() => setTraficos((p) => p.filter((_, j) => j !== i))}>
                  <Txt label="servicio" value={t.servicio} onChange={(v) => editar(setTraficos)(i, 'servicio', v)} />
                  <Num label="p95 ms" value={t.latencia_p95} onChange={(v) => editar(setTraficos)(i, 'latencia_p95', v)} />
                  <Num label="p99 ms" value={t.latencia_p99} onChange={(v) => editar(setTraficos)(i, 'latencia_p99', v)} />
                  <Num label="5xx %" value={t.tasa_5xx} onChange={(v) => editar(setTraficos)(i, 'tasa_5xx', v)} />
                  <Num label="4xx %" value={t.tasa_4xx} onChange={(v) => editar(setTraficos)(i, 'tasa_4xx', v)} />
                </Fila>
              ))}
            </Capa>

            <div className="card">
              <h3>Red / CoreDNS</h3>
              <div className="fila">
                <Sel label="CoreDNS saturado" value={red.coredns_saturado} opts={SI_NO} onChange={(v) => setRed({ ...red, coredns_saturado: v })} />
                <Num label="saturación %" value={red.saturacion_pct} onChange={(v) => setRed({ ...red, saturacion_pct: v })} />
              </div>
            </div>

            <button className="diagnosticar" onClick={onDiagnosticar} disabled={cargando}>
              {cargando ? 'Diagnosticando…' : 'Diagnosticar'}
            </button>
          </div>

          {/* ----------- RESULTADOS ----------- */}
          <div className="col">
            {error && <div className="error">⚠ {error}</div>}

            {!resultado && !error && (
              <div className="card"><p className="placeholder">Carga un escenario o define la telemetría y pulsa <strong>Diagnosticar</strong>.</p></div>
            )}

            {resultado && resultado.diagnosticos.length === 0 && (
              <div className="card">Sin diagnóstico. Revisa la telemetría enviada.</div>
            )}

            {resultado && resultado.diagnosticos.map((d, i) => (
              <div className={`card diag sev-${d.severidad}`} key={i}>
                <div className="diag-head">
                  <span className="badge" style={{ background: SEV_COLOR[d.severidad] || '#6b7280' }}>{d.severidad}</span>
                  <span className="tipo">{d.tipo}</span>
                </div>
                <p className="causa">{d.causa_raiz}</p>
                <h4>Plan de acción</h4>
                <ul className="cmds">
                  {d.comandos.map((c, j) => (
                    <li key={j}><code>{c}</code></li>
                  ))}
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
      </div>
    </div>
  )
}

// --- componentes auxiliares ---
function Capa({ titulo, onAdd, children }) {
  return (
    <div className="card">
      <div className="capa-head">
        <h3>{titulo}</h3>
        <button className="add" onClick={onAdd}>+ añadir</button>
      </div>
      {children}
    </div>
  )
}

function Fila({ children, onDel }) {
  return (
    <div className="fila">
      {children}
      <button className="del" onClick={onDel} title="eliminar">×</button>
    </div>
  )
}

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
