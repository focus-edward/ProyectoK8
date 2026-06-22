# Guía de código — K8s-ExpertAdvisor

Documento para **analizar qué hace cada parte** del backend y del front, y
**cómo probar el backend** sin depender de la terminal.

> Regla de oro del proyecto: la inteligencia vive 100% en el `.clp`.
> El backend **no razona**, solo traduce datos; el front **no razona**, solo
> presenta. Si algo del diagnóstico te parece raro, el origen está en el `.clp`,
> no en Python ni en React.

---

## 1. Visión general — el flujo de una petición

```
┌─────────────┐   JSON telemetría    ┌──────────────────────┐   asserts    ┌───────────────┐
│   FRONT     │  ───────────────►    │   BACKEND (FastAPI)  │  ─────────►  │  MOTOR CLIPS  │
│  React/Vite │   POST /diagnosticar │   main.py + motor.py │   (clipspy)  │     .clp      │
│             │  ◄───────────────    │                      │  ◄─────────  │               │
└─────────────┘   diagnóstico+por-qué└──────────────────────┘   hechos     └───────────────┘
```

Paso a paso, cuando das clic en **Diagnosticar**:

1. **Front** (`App.jsx`) arma un objeto con las 3 capas (contenedores, nodos,
   tráfico, red) y lo manda como JSON a `POST /diagnosticar` (`api.js`).
2. **Backend** (`main.py`) valida la forma del JSON con Pydantic y se lo pasa a
   `motor.diagnosticar(...)`.
3. **`motor.py`** crea un entorno CLIPS nuevo, carga el `.clp`, convierte el JSON
   en hechos `(assert ...)`, dispara `CORRELACION` → `MITIGACION` y lee los
   hechos `diagnostico` y `justificacion` resultantes.
4. **Backend** devuelve eso como JSON; **front** lo pinta (causa raíz + comandos).
5. Al pulsar **¿Por qué?**, el front pide `GET /por-que` y muestra el árbol de
   deducción (los hechos `justificacion` que dejó cada regla al dispararse).

---

## 2. Backend

### 2.1 `backend/motor.py` — la capa que habla con CLIPS

Es el único archivo que toca clipspy. Responsabilidades:

| Función | Qué hace |
|---|---|
| `_entorno()` | Crea un `clips.Environment` **nuevo**, carga el `.clp` y hace `reset()`. Se crea uno por petición porque el motor es *stateful* (no queremos arrastrar hechos de un diagnóstico al siguiente). |
| `construir_asserts(tele)` | Traduce el dict de telemetría a una lista de strings `(assert (contenedor ...))`. Aquí ocurre el **mapeo snake_case → guion** (`cpu_pct` → `cpu-pct`). Los campos `None` se omiten para que apliquen los *defaults* del `deftemplate`. |
| `_leer_diagnosticos(env)` | Recorre los hechos y extrae los `diagnostico` (tipo, severidad, causa_raiz, comandos[]). |
| `_leer_justificaciones(env)` | Igual pero con los hechos `justificacion` (regla, premisa, conclusion). |
| `diagnosticar(tele)` | Orquesta todo: asserts → `(focus CORRELACION MITIGACION)` → `run()` → leer resultados. |
| `ErrorTelemetria` | Excepción propia: si un `assert` viola un `range`/`allowed-symbols`, clipspy lanza `CLIPSError` y la reempaquetamos para que `main.py` responda HTTP 422. |

**Punto clave de diseño:** `motor.py` no decide nada sobre Kubernetes. Solo mueve
datos hacia/desde el `.clp`. Por eso `RAIZ = Path(__file__).resolve().parent.parent`
apunta al `.clp` en la raíz del repo, sin importar desde dónde se ejecute.

### 2.2 `backend/main.py` — la API HTTP

- **Modelos Pydantic** (`Contenedor`, `Nodo`, `Pod`, `Hpa`, `Volumen`,
  `ControlPlane`, `Trafico`, `Red`, `Telemetria`): definen el contrato del JSON.
  Los campos opcionales son `Optional[...] = None` para que el motor use sus
  defaults. **Esta es la primera barrera de validación** (forma/tipos); la
  segunda es el propio motor (dominios/rangos).
- **CORS** abierto (`allow_origins=["*"]`): necesario porque el front corre en
  otro origen. En producción real se restringiría a la URL del front.
- **`_ultimo`**: cache en memoria del último resultado. Sirve para que
  `GET /por-que` devuelva las justificaciones del diagnóstico más reciente sin
  re-ejecutar el motor.

| Endpoint | Método | Qué hace |
|---|---|---|
| `/salud` | GET | Healthcheck (Render lo usa para saber si el servicio está vivo). Devuelve `{"estado":"ok"}`. |
| `/diagnosticar` | POST | Recibe `Telemetria`, llama a `motor.diagnosticar`, cachea y devuelve `{diagnosticos, justificaciones}`. Si la telemetría es inválida → **HTTP 422**. |
| `/por-que` | GET | Devuelve `{justificaciones}` del último diagnóstico. |

### 2.3 `backend/requirements.txt`

`fastapi`, `uvicorn` (servidor ASGI) y `clipspy` (CLIPS en C). En Linux/Render,
`pip` instala el wheel precompilado de clipspy; no hay que compilar nada a mano.

---

## 3. Frontend

### 3.1 `frontend/src/api.js` — cliente HTTP

Dos funciones: `diagnosticar(telemetria)` (POST) y `porQue()` (GET). La URL base
sale de `import.meta.env.VITE_API_URL` (la variable que configuraste en Render);
si no existe, usa `http://127.0.0.1:8000` para desarrollo local. Si el backend
responde 422, lanza un `Error` con el detalle para mostrarlo en rojo.

### 3.2 `frontend/src/App.jsx` — toda la UI

- **Constantes de dominio** (`EST_CONT`, `PRESION`, etc.): **copian** los
  `allowed-symbols` del `.clp`. Por eso los `<select>` solo ofrecen valores
  válidos: es imposible mandar un estado inexistente desde la UI.
- **`PRESETS`**: tres escenarios precargados (uno por heurística). Un clic llena
  el formulario completo — ideal para la demo.
- **Estado React** (`useState`): `contenedores`, `nodos`, `traficos`, `red` son
  el formulario; `resultado`, `justificaciones`, `error`, `cargando` son la salida.
- **`onDiagnosticar()`**: arma `{contenedores, nodos, traficos, red}` y llama a la
  API. **`onPorQue()`**: pide el árbol de deducción.
- **Componentes auxiliares** (`Capa`, `Fila`, `Txt`, `Num`, `Sel`): pequeños
  bloques reutilizables para no repetir markup de formulario.
- **Render de resultados**: cada `diagnostico` se pinta con un *badge* de
  severidad por color, la causa raíz y la lista de comandos `kubectl`.

El resto (`main.jsx`, `index.html`, `styles.css`, `vite.config.js`) es el
andamiaje estándar de Vite + el tema visual.

---

## 4. Cómo probar el backend (fuera de la terminal)

### 4.1 Swagger UI — la forma más fácil (cero instalación)

FastAPI genera documentación interactiva automática:

- Local: <http://127.0.0.1:8000/docs>
- Render: `https://<tu-backend>.onrender.com/docs`

Ahí ves cada endpoint, el esquema exacto de la telemetría y un botón
**"Try it out"** para ejecutar peticiones reales desde el navegador. También hay
`/redoc` (misma info, formato lectura).

### 4.2 Payloads de prueba (pégalos en "Try it out" de `/diagnosticar`)

**Cascada por OOMKilled** → espera `tipo: cascada-oom`, severidad crítica:
```json
{
  "contenedores": [{ "id": "api", "estado": "OOMKilled", "mem_pct": 100 }],
  "traficos": [{ "servicio": "checkout", "tasa_5xx": 30, "latencia_p99": 4500 }]
}
```

**Falsa alarma de CPU** → espera `tipo: cpu-falsa-alarma`:
```json
{
  "contenedores": [{ "id": "worker", "estado": "Running", "cpu_pct": 98 }],
  "nodos": [{ "id": "node-1", "estado": "Ready", "presion": "MemoryPressure" }]
}
```

**Fuga de conexiones** → espera `tipo: fuga-conexiones`:
```json
{
  "contenedores": [{ "id": "gateway", "estado": "CrashLoopBackOff", "cpu_pct": 40, "conexiones": 8000 }]
}
```

**Validación (debe FALLAR con 422)** — `cpu_pct` fuera de rango:
```json
{ "contenedores": [{ "id": "mal", "estado": "Running", "cpu_pct": 150 }] }
```

### 4.3 Tests automáticos (regresión)

```bash
python tests/test_motor.py   # prueba el .clp directo vía clipspy
python tests/test_api.py     # prueba los endpoints con TestClient (sin levantar servidor)
```

---

## 5. Mapa de telemetría: JSON (front/API) ↔ slot CLIPS (`.clp`)

| Entidad | Campo JSON | Slot CLIPS | Dominio / rango |
|---|---|---|---|
| contenedor | `id` | `id` | símbolo |
| | `estado` | `estado` | Running / CrashLoopBackOff / OOMKilled / Error / Pending |
| | `cpu_pct` | `cpu-pct` | 0–100 |
| | `mem_pct` | `mem-pct` | 0–100 |
| | `liveness` | `liveness` | ok / fallida |
| | `readiness` | `readiness` | ok / fallida |
| | `conexiones` | `conexiones` | ≥ 0 |
| nodo | `id` | `id` | símbolo |
| | `estado` | `estado` | Ready / NotReady |
| | `presion` | `presion` | ninguna / DiskPressure / MemoryPressure / PIDPressure |
| pod | `id`,`estado`,`nodo` | `id`,`estado`,`nodo` | — |
| hpa | `objetivo`,`escalando`,`replicas_actuales`,`replicas_max` | `objetivo`,`escalando`,`replicas-actuales`,`replicas-max` | escalando: si/no |
| volumen | `id`,`estado`,`uso_pct` | `id`,`estado`,`uso-pct` | estado: Bound/Pending/Lost |
| control_plane | `saturado` | `saturado` | si / no |
| trafico | `servicio`,`latencia_p95`,`latencia_p99`,`tasa_5xx`,`tasa_4xx` | `servicio`,`latencia-p95`,`latencia-p99`,`tasa-5xx`,`tasa-4xx` | tasas: 0–100 |
| red | `coredns_saturado`,`saturacion_pct` | `coredns-saturado`,`saturacion-pct` | dns: si/no; pct: 0–100 |

> Regla mnemotécnica: en el JSON los campos van con **guion bajo** (`cpu_pct`),
> en CLIPS con **guion** (`cpu-pct`). La traducción la hace `construir_asserts`.

---

## 6. Las 3 heurísticas (resumen del razonamiento)

| Tipo | Se dispara cuando… | Causa raíz que concluye | Por qué no es lo obvio |
|---|---|---|---|
| `cpu-falsa-alarma` | CPU ≥ 90% **y** nodo con `DiskPressure`/`MemoryPressure` | Presión de recursos del **nodo** | El pod parece pedir escalado, pero escalarlo empeora la presión del nodo |
| `cascada-oom` | Contenedor `OOMKilled` **y** 5xx ≥ 5% | **Límite de memoria** insuficiente | Los 5xx/latencia parecen un problema de red, pero son efecto del reinicio cíclico |
| `fuga-conexiones` | Conexiones ≥ 1000 **y** CPU < 90% **y** estado de crash | **Bug de código** (leak) | Escalar/subir límites solo retrasa el colapso; no es falta de capacidad |

Cuando ninguna aplica, la regla `sin-diagnostico` (salience baja) evita que el
sistema quede mudo.
