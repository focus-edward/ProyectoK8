;;;==========================================================
;;; K8s-ExpertAdvisor
;;; Sistema Experto para Diagnostico y Resiliencia de Clusteres
;;; Topicos Avanzados I
;;;----------------------------------------------------------
;;; ARCHIVO 1 de N: Modulos y base de conocimiento (templates)
;;;==========================================================


;;;----------------------------------------------------------
;;; MODULOS
;;; Separan el flujo en 3 fases, como exige el enunciado:
;;;   CAPTURA      -> recoge y valida la telemetria
;;;   CORRELACION  -> cruza variables y deduce la causa raiz
;;;   MITIGACION   -> genera el plan de accion (comandos)
;;; MAIN exporta todo para que los demas modulos vean los hechos.
;;;----------------------------------------------------------
(defmodule MAIN (export ?ALL))


;;;----------------------------------------------------------
;;; CAPA 1: CONTENEDOR (Docker)
;;;----------------------------------------------------------
(deftemplate MAIN::contenedor
   (slot id        (type SYMBOL))
   (slot estado    (type SYMBOL)
                   (allowed-symbols Running CrashLoopBackOff OOMKilled Error Pending))
   ;; uso relativo al limit asignado: 100 = tocando el techo
   (slot cpu-pct   (type INTEGER) (range 0 100) (default 0))
   (slot mem-pct   (type INTEGER) (range 0 100) (default 0))
   (slot liveness  (type SYMBOL)  (allowed-symbols ok fallida) (default ok))
   (slot readiness (type SYMBOL)  (allowed-symbols ok fallida) (default ok)))


;;;----------------------------------------------------------
;;; CAPA 2: ORQUESTACION (Kubernetes)
;;;----------------------------------------------------------
(deftemplate MAIN::nodo
   (slot id      (type SYMBOL))
   (slot estado  (type SYMBOL) (allowed-symbols Ready NotReady))
   (slot presion (type SYMBOL)
                 (allowed-symbols ninguna DiskPressure MemoryPressure PIDPressure)
                 (default ninguna)))

(deftemplate MAIN::pod
   (slot id     (type SYMBOL))
   (slot estado (type SYMBOL) (allowed-symbols Running Pending Failed CrashLoopBackOff))
   (slot nodo   (type SYMBOL)))

(deftemplate MAIN::hpa
   (slot objetivo          (type SYMBOL))
   (slot escalando         (type SYMBOL) (allowed-symbols si no) (default no))
   (slot replicas-actuales (type INTEGER) (range 0 ?VARIABLE) (default 1))
   (slot replicas-max      (type INTEGER) (range 0 ?VARIABLE) (default 1)))

(deftemplate MAIN::volumen
   (slot id      (type SYMBOL))
   (slot estado  (type SYMBOL) (allowed-symbols Bound Pending Lost))
   (slot uso-pct (type INTEGER) (range 0 100) (default 0)))

(deftemplate MAIN::control-plane
   (slot saturado (type SYMBOL) (allowed-symbols si no) (default no)))


;;;----------------------------------------------------------
;;; CAPA 3: RED Y TRAFICO
;;;----------------------------------------------------------
(deftemplate MAIN::trafico
   (slot servicio     (type SYMBOL))
   (slot latencia-p95 (type INTEGER) (range 0 ?VARIABLE) (default 0))  ; ms
   (slot latencia-p99 (type INTEGER) (range 0 ?VARIABLE) (default 0))  ; ms
   (slot tasa-5xx     (type INTEGER) (range 0 100) (default 0))        ; %
   (slot tasa-4xx     (type INTEGER) (range 0 100) (default 0)))       ; %

(deftemplate MAIN::red
   (slot coredns-saturado (type SYMBOL)  (allowed-symbols si no) (default no))
   (slot saturacion-pct   (type INTEGER) (range 0 100) (default 0)))


;;;----------------------------------------------------------
;;; SALIDA: DIAGNOSTICO Y JUSTIFICACION
;;; 'diagnostico' usa un MULTISLOT para la lista de comandos
;;; (requisito de patrones avanzados).
;;; 'justificacion' es la clave del modulo "por-que": cada regla
;;; que se dispara deja aqui su huella, y luego solo la leemos.
;;;----------------------------------------------------------
(deftemplate MAIN::diagnostico
   (slot causa-raiz (type STRING))
   (slot severidad  (type SYMBOL) (allowed-symbols baja media alta critica) (default media))
   (multislot comandos (type STRING)))

(deftemplate MAIN::justificacion
   (slot regla      (type SYMBOL))
   (slot premisa    (type STRING))
   (slot conclusion (type STRING)))


;;;----------------------------------------------------------
;;; Resto de modulos (importan todo lo de MAIN)
;;;----------------------------------------------------------
(defmodule CAPTURA     (import MAIN ?ALL) (export ?ALL))
(defmodule CORRELACION (import MAIN ?ALL) (export ?ALL))
(defmodule MITIGACION  (import MAIN ?ALL) (export ?ALL))
