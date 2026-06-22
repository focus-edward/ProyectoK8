# K8s-ExpertAdvisor

Sistema experto en **CLIPS** que diagnostica la causa raíz de crisis en clústeres
de Kubernetes y genera un plan de acción (`kubectl`). Sobre el motor hay un backend
**FastAPI + clipspy** y un front **React (Vite)**.

## Arquitectura

```
k8s_expert_advisor.clp   # motor CLIPS: CAPTURA -> CORRELACION -> MITIGACION + (por-que)
backend/                 # FastAPI + clipspy: traduce telemetria JSON <-> hechos CLIPS
frontend/                # React: formulario 3 capas, diagnostico y "¿Por qué?"
tests/                   # regresion del motor y de la API
render.yaml              # despliegue (backend Python + front estatico)
```

El motor **no** se reimplementa en Python: clipspy ejecuta el mismo `.clp` del IDE.

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
```

## Heurísticas de correlación

| Tipo | Detecta | Causa raíz |
|------|---------|------------|
| `cpu-falsa-alarma` | CPU≥90% + nodo con presión | El nodo, no el pod (no escalar) |
| `cascada-oom` | OOMKilled + 5xx altos | Límite de memoria insuficiente (no la red) |
| `fuga-conexiones` | Conexiones altas + CPU baja + crashes | Bug de código (escalar no resuelve) |

## Despliegue

Blueprint en `render.yaml`. Tras el primer deploy del backend, definir
`VITE_API_URL` (en el servicio del front) con la URL pública del backend.
Cada push a la rama conectada redespliega automáticamente.
