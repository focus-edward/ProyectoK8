# K8s-ExpertAdvisor

Sistema experto en **CLIPS** que diagnostica la causa raíz de crisis en clústeres
de Kubernetes y genera un plan de acción (`kubectl`). Sobre el motor hay un backend
**FastAPI + clipspy** y un front **React (Vite)**.

## Arquitectura

```
k8s_expert_advisor.clp        # motor CLIPS K8s: CAPTURA -> CORRELACION -> MITIGACION + (por-que)
pago-movil-autoescalado.clp   # motor CLIPS pago movil + autoescalado por tope + bloqueo DDoS
clips-assert.js               # builder de asserts + espejo de las reglas (demo client-only)
pago-movil-autoescalado.html  # demo standalone (sin backend) del modulo de pagos
backend/                      # FastAPI + clipspy: traduce JSON <-> hechos CLIPS (ambos motores)
frontend/                     # React: pestanas "Diagnostico K8s" y "Pago Movil"
tests/                        # regresion de los motores y de la API
render.yaml                   # despliegue (backend Python + front estatico)
```

El motor **no** se reimplementa en Python: clipspy ejecuta el mismo `.clp` del IDE.
Ambos `.clp` comparten el patron modular (MAIN/CAPTURA/CORRELACION/MITIGACION),
dejan una `justificacion` por regla disparada (modulo `(por-que)`) y emiten un
`diagnostico` con su plan de accion en comandos `kubectl`.

## Correr en local

```bash
# Backend  (http://127.0.0.1:8000  ·  docs en /docs)
cd backend
pip install -r requirements.txt
uvicorn main:app --reload

# Frontend (http://localhost:5173)
cd frontend
npm install
npm run dev
```

## Pruebas

```bash
python tests/test_motor.py   # 3 escenarios heuristicos + validacion de entradas
python tests/test_api.py     # endpoints /diagnosticar, /por-que, /salud
python tests/test_pagos.py   # pago movil: estable / autoescalado / DDoS / validacion
```

## Heurísticas de correlación (sistema K8s)

| Tipo | Detecta | Causa raíz |
|------|---------|------------|
| `cpu-falsa-alarma` | CPU≥90% + nodo con presión | El nodo, no el pod (no escalar) |
| `cascada-oom` | OOMKilled + 5xx altos | Límite de memoria insuficiente (no la red) |
| `fuga-conexiones` | Conexiones altas + CPU baja + crashes | Bug de código (escalar no resuelve) |

## Módulo Pago Móvil + Autoescalado

Mismo motor experto aplicado a un servicio de pagos: valida cada pago móvil
(prefijo y longitud del teléfono), mide la carga en cola y **decide por sí solo
cuántas réplicas necesita** cuando se alcanza un tope. La pieza clave (requisito
de "modificación en vivo" del enunciado) es que ante un **DDoS** en el Ingress
**bloquea el autoescalado** para no gastar infraestructura sirviendo tráfico de ataque.

| Veredicto | Dispara cuando | Acción |
|-----------|----------------|--------|
| `carga-estable` | carga bajo el tope y dentro de capacidad | Sin cambios |
| `autoescalado-pagos` | carga ≥ tope (o supera capacidad) y **no hay DDoS** | `kubectl scale` ↑/↓ |
| `ddos-bloqueo` | `ataque=si` o firma L7 (req/s altos, 4xx≥40%, pocas IPs) | Rate-limit + congelar HPA |

Endpoints: `POST /pago-movil/diagnosticar` y `GET /pago-movil/por-que`.
Demo sin backend: abrir `pago-movil-autoescalado.html` (usa `clips-assert.js`,
que replica las mismas reglas en el navegador). En el front React es la pestaña
**"Pago Móvil + Autoescalado"**.

## Despliegue

Blueprint en `render.yaml`. Tras el primer deploy del backend, definir
`VITE_API_URL` (en el servicio del front) con la URL pública del backend.
Cada push a la rama conectada redespliega automáticamente.
