import React, { useState } from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'
import PagoMovil from './PagoMovil.jsx'
import './styles.css'

const VISTAS = {
  k8s: { label: 'Diagnóstico K8s', sub: 'Sistema experto CLIPS · diagnóstico de causa raíz en Kubernetes', comp: App },
  pagos: { label: 'Pago Móvil + Autoescalado', sub: 'Sistema experto CLIPS · pago móvil con autoescalado por tope y bloqueo ante DDoS', comp: PagoMovil },
}

function Root() {
  const [vista, setVista] = useState('k8s')
  const Vista = VISTAS[vista].comp
  return (
    <div className="app">
      <header>
        <h1>K8s-ExpertAdvisor</h1>
        <p className="sub">{VISTAS[vista].sub}</p>
      </header>
      <nav className="tabs">
        {Object.entries(VISTAS).map(([k, v]) => (
          <button key={k} className={'tab' + (k === vista ? ' active' : '')} onClick={() => setVista(k)}>
            {v.label}
          </button>
        ))}
      </nav>
      <Vista />
    </div>
  )
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
)
