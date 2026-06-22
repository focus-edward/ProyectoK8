# K8s-ExpertAdvisor — Contexto del proyecto

Sistema experto en **CLIPS** que actúa como un ingeniero DevOps/SRE senior:
recibe telemetría de un clúster de Kubernetes con microservicios dockerizados,
diagnostica la causa raíz de una crisis de infraestructura y genera un plan de
acción (comandos `kubectl` / cambios al `deployment.yaml`).

Encima del motor CLIPS se construye una **app web** (backend Python + front React)
para visualizar las consultas y respuestas del sistema corriendo en vivo.

---

## Orden de construcción (importante)

El motor CLIPS es el núcleo y va PRIMERO. La web es una cáscara de presentación
por encima; no tiene nada que mostrar hasta que el `.clp` razone. El orden es:

1. **Sistema CLIPS** (`.clp`) — el cerebro. **EN PROGRESO.**
2. **Backend Python** (FastAPI + clipspy) que carga el `.clp` y lo expone por HTTP.
3. **Front React** que envía telemetría y muestra diagnóstico + explicación.
4. **Despliegue**: push a GitHub → Render redespliega automáticamente.

> El IDE de escritorio de CLIPS (CLIPS 6.4) se queda en local y es donde se prueba
> el `.clp` directamente. clipspy ejecuta el MISMO `.clp` desde Python; no se
> reescribe la lógica, solo cambia cómo entran los datos (consola vs. HTTP).

---

## Requisitos técnicos OBLIGATORIOS del sistema CLIPS

Estos son condiciones del enunciado, no opcionales:

- **Modularidad estricta** con `defmodule`: fases `CAPTURA` → `CORRELACION` → `MITIGACION`.
- **`salience` (prioridades)** para controlar el flujo entre fases.
- **Validación exhaustiva de entradas**: el sistema NO debe romperse ante datos
  inválidos; debe forzar reintentos.
- **Módulo de explicación "por-qué"**: al teclear `(por-que)` el sistema lista el
  árbol de deducción (qué reglas se activaron y bajo qué premisas).
- **Patrones avanzados**: `deftemplate` multi-slot, `deffunction` personalizadas,
  y restricciones de ranura (`allowed-symbols`, `type`, `range`).
- **Salida de mitigación**: imprimir causa raíz + generar dinámicamente los
  comandos exactos de recuperación (`kubectl patch...`, `kubectl scale...`, etc.).

---

## Estado actual

Ya existe el archivo base **`k8s_expert_advisor.clp`** (ponerlo en la raíz del repo).
Contiene los 3 módulos y los deftemplates de las tres capas:

- **Capa contenedor (Docker)**: `contenedor` — estado (Running/CrashLoopBackOff/
  OOMKilled/Error/Pending), cpu-pct, mem-pct, liveness, readiness.
- **Capa orquestación (K8s)**: `nodo` (estado, presion: DiskPressure/MemoryPressure/
  PIDPressure), `pod`, `hpa` (escalando, replicas), `volumen` (PV/PVC), `control-plane`.
- **Capa red/tráfico**: `trafico` (latencia-p95/p99, tasa-5xx, tasa-4xx), `red`
  (coredns-saturado, saturacion-pct).
- **Salida**: `diagnostico` (causa-raiz, severidad, `multislot comandos`) y
  `justificacion` (regla, premisa, conclusion).

Patrón clave del "por-qué": cada regla, al dispararse, hace `assert` de un hecho
`justificacion`. El comando `(por-que)` solo lee esos hechos en orden — no se
reconstruye nada a mano.

---

## Próximos pasos en el `.clp`

1. **Fase CAPTURA**: `deffunction` de lectura validada que fuerza reintentos ante
   entradas fuera de los `allowed-symbols` / `range`. Asertar los hechos de telemetría.
2. **Fase CORRELACION** (reglas heurísticas, el corazón del proyecto):
   - **Falsa alarma de CPU**: si un Pod está al 98% de CPU pero el nodo tiene
     `DiskPressure`/`MemoryPressure`, NO recomendar escalar el Pod; recomendar
     desalojar pods no críticos (eviction) o activar el Cluster Autoscaler.
   - **Cascada por OOMKilled**: contenedor muere por memoria → revive → genera
     latencia/HTTP 504 → pods adyacentes fallan readiness. Causa raíz = límite de
     memoria insuficiente del contenedor original, NO la red.
   - **Fuga de conexiones**: correlacionar incremento de hilos/conexiones con el
     colapso del contenedor para distinguir bug de código vs. config de infra.
3. **Fase MITIGACION**: generar los comandos `kubectl` según la causa raíz.
4. **Módulo por-qué**: leer y mostrar los hechos `justificacion`.

Considerar **dos modos de entrada** sobre la misma lógica: modo consola (lectura
interactiva con validación/reintentos, para el IDE) y modo hechos (la telemetría
llega pre-asertada desde el backend web).

---

## Backend (fase 2)

- **Python + FastAPI + clipspy** (clipspy ejecuta CLIPS 6.4 real).
- Carga `k8s_expert_advisor.clp` al iniciar.
- Endpoints sugeridos:
  - `POST /diagnosticar` — recibe telemetría JSON, la asierta como hechos, hace
    `run`, devuelve diagnóstico + comandos.
  - `GET /por-que` — devuelve la lista de hechos `justificacion` (árbol de deducción).
- Nota: clipspy tiene dependencias nativas (CLIPS está en C), por eso se despliega
  en un contenedor Linux (Render), no en serverless tipo Vercel.

## Front (fase 3)

- **React**. Formulario para la telemetría de las 3 capas, botón "Diagnosticar",
  panel con causa raíz + comandos `kubectl`, y un botón "¿Por qué?" que despliega
  la cadena de reglas.

## Despliegue (fase 4)

- Repo en **GitHub**. **Render** conectado al repo: cada push redespliega solo.
- NO Vercel (compilación nativa de clipspy + el motor debe mantenerse vivo).

---

## Stack / entorno

- CLIPS 6.4 (IDE de escritorio para pruebas locales)
- Python 3.x, clipspy, FastAPI, uvicorn
- React (Vite recomendado)
- Git + GitHub + Render
- Trabajo en español
