# K8s-ExpertAdvisor

Sistema experto en **CLIPS** que actúa como un Ingeniero DevOps/SRE virtual para una
**plataforma bancaria sobre Kubernetes** (pago móvil, checkout, core bancario…):
diagnostica la causa raíz de crisis de infraestructura, decide el autoescalado y
**bloquea el escalado ante ataques DDoS**. Sobre el motor hay un backend
**FastAPI + clipspy** y un front **React (Vite)** con tema Banesco.

## Arquitectura

```
k8s_expert_advisor.clp   # motor CLIPS: CAPTURA -> CORRELACION -> MITIGACION + (por-que)
backend/                 # FastAPI + clipspy: traduce telemetria JSON <-> hechos CLIPS
frontend/                # React: formulario de telemetria, diagnostico y "¿Por qué?"
tests/                   # regresion del motor y de la API
render.yaml              # despliegue (backend Python + front estatico)
```

El motor **no** se reimplementa en Python: clipspy ejecuta el mismo `.clp` del IDE.
El `.clp` separa el flujo en módulos (MAIN/CAPTURA/CORRELACION/MITIGACION), deja una
`justificacion` por cada regla disparada (módulo `(por-que)`) y emite un `diagnostico`
con su plan de acción en comandos `kubectl`.

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
python tests/test_motor.py   # 5 escenarios heuristicos + validacion de entradas
python tests/test_api.py     # endpoints /diagnosticar, /por-que, /salud
```

## Heurísticas de correlación

| Tipo | Detecta | Causa raíz / acción |
|------|---------|---------------------|
| `cpu-falsa-alarma` | CPU≥90% + nodo con presión | El nodo, no el pod (no escalar) |
| `cascada-oom` | OOMKilled + 5xx altos | Límite de memoria insuficiente (no la red) |
| `fuga-conexiones` | Conexiones altas + CPU baja + crashes | Bug de código (escalar no resuelve) |
| `autoescalado-demanda` | HPA con CPU > objetivo y réplicas < máx, **sin DDoS** | Demanda legítima: escalar vía HPA |
| `ddos-bloqueo` | Ingress con `ataque=si` o firma L7 (req/s altos, 4xx≥40%, pocas IPs) | DDoS: **bloquear autoescalado**, rate-limit + congelar HPA |

Las dos últimas implementan la **autoescalado + "modificación en vivo"** del enunciado:
ante un DDoS en el Ingress el motor **frena el escalado** para no gastar infraestructura
sirviendo tráfico de ataque (la regla `ddos-bloquea-autoescalado` tiene salience mayor y
guarda la regla de autoescalado).

## Despliegue

Blueprint en `render.yaml`. Tras el primer deploy del backend, definir
`VITE_API_URL` (en el servicio del front) con la URL pública del backend.
Cada push a la rama conectada redespliega automáticamente.
