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
   (slot readiness (type SYMBOL)  (allowed-symbols ok fallida) (default ok))
   ;; conexiones/hilos abiertos: clave para detectar fugas (leaks)
   (slot conexiones (type INTEGER) (range 0 ?VARIABLE) (default 0)))


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
   (slot replicas-min      (type INTEGER) (range 1 ?VARIABLE) (default 1))
   (slot replicas-max      (type INTEGER) (range 0 ?VARIABLE) (default 1))
   ;; uso de CPU agregado del deployment vs el umbral objetivo del HPA:
   ;; si cpu-actual supera cpu-objetivo, el HPA querra anadir replicas.
   (slot cpu-actual        (type INTEGER) (range 0 100) (default 0))
   (slot cpu-objetivo      (type INTEGER) (range 1 100) (default 70)))

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

;; Ingress Controller: punto de entrada del trafico al cluster. Aqui se
;; mide la firma de un DDoS L7 (muchos req/s desde pocas IPs con 4xx alto).
(deftemplate MAIN::ingress
   (slot servicio         (type SYMBOL))
   (slot requests-por-seg (type INTEGER) (range 0 ?VARIABLE) (default 0))
   (slot tasa-4xx         (type INTEGER) (range 0 100) (default 0)) ; % de 4xx
   (slot ips-distintas    (type INTEGER) (range 0 ?VARIABLE) (default 1))
   (slot ataque           (type SYMBOL)  (allowed-symbols si no desconocido) (default desconocido)))


;;;----------------------------------------------------------
;;; SALIDA: DIAGNOSTICO Y JUSTIFICACION
;;; 'diagnostico' usa un MULTISLOT para la lista de comandos
;;; (requisito de patrones avanzados).
;;; 'justificacion' es la clave del modulo "por-que": cada regla
;;; que se dispara deja aqui su huella, y luego solo la leemos.
;;;----------------------------------------------------------
(deftemplate MAIN::diagnostico
   ;; 'tipo' es la llave interna: CORRELACION lo fija y MITIGACION
   ;; enruta los comandos por este simbolo (no por el string libre).
   (slot tipo       (type SYMBOL)
                    (allowed-symbols indeterminado cpu-falsa-alarma cascada-oom fuga-conexiones
                                     autoescalado-demanda ddos-bloqueo)
                    (default indeterminado))
   (slot causa-raiz (type STRING))
   (slot severidad  (type SYMBOL) (allowed-symbols baja media alta critica) (default media))
   (multislot comandos (type STRING)))

(deftemplate MAIN::justificacion
   (slot regla      (type SYMBOL))
   (slot premisa    (type STRING))
   (slot conclusion (type STRING)))


;;;----------------------------------------------------------
;;; HECHOS DE CONTROL (flujo de la fase CAPTURA)
;;; Declarados explicitamente en MAIN: si se dejaran como hechos
;;; ordenados, CLIPS crearia 'implied deftemplates' dentro de un
;;; modulo con import/export ?ALL y daria conflicto de dueno.
;;;----------------------------------------------------------
(deftemplate MAIN::modo
   (slot tipo (type SYMBOL) (allowed-symbols consola hechos) (default consola)))
(deftemplate MAIN::menu-captura)        ; senal: reabrir el menu
(deftemplate MAIN::captura-finalizada)  ; senal: cerrar la fase CAPTURA


;;;----------------------------------------------------------
;;; Resto de modulos (importan todo lo de MAIN)
;;;----------------------------------------------------------
(defmodule CAPTURA     (import MAIN ?ALL) (export ?ALL))
(defmodule CORRELACION (import MAIN ?ALL) (export ?ALL))
(defmodule MITIGACION  (import MAIN ?ALL) (export ?ALL))


;;;==========================================================
;;; FASE CAPTURA
;;; (1) deffunctions de LECTURA VALIDADA con reintentos
;;; (2) reglas que ASERTAN la telemetria (modo consola)
;;;
;;; Dos modos de entrada sobre la MISMA logica:
;;;   - modo consola : se asserta (modo consola) y el menu guia
;;;                    una captura interactiva validada (IDE CLIPS).
;;;   - modo hechos  : el backend web asserta los hechos de
;;;                    telemetria directamente; NO asserta
;;;                    (modo consola), asi el menu nunca se dispara.
;;;==========================================================


;;;----------------------------------------------------------
;;; PRIMITIVAS DE LECTURA VALIDADA
;;; Nunca devuelven un valor invalido: repiten la pregunta
;;; hasta que la entrada respeta tipo / rango / dominio.
;;; Asi los slots con (range ...) y (allowed-symbols ...)
;;; jamas reciben un dato que rompa el deftemplate.
;;;----------------------------------------------------------

;; Lee un ENTERO dentro de [?min, ?max]. Reintenta ante
;; no-enteros o valores fuera de rango.
(deffunction MAIN::leer-rango (?prompt ?min ?max)
   (bind ?v nil)                          ; sentinela: nil no es integerp
   (while (or (not (integerp ?v)) (< ?v ?min) (> ?v ?max)) do
      (printout t ?prompt " [" ?min "-" ?max "]: ")
      (bind ?v (read))
      (if (not (integerp ?v))
         then (printout t "   [!] Se esperaba un ENTERO. Reintente." crlf)
         else (if (or (< ?v ?min) (> ?v ?max))
                  then (printout t "   [!] Fuera de rango [" ?min "-" ?max "]. Reintente." crlf))))
   ?v)

;; Lee un SIMBOLO que debe pertenecer al dominio ?permitidos.
;; Reintenta ante cualquier opcion no listada.
(deffunction MAIN::leer-simbolo (?prompt $?permitidos)
   (bind ?v 0)                            ; sentinela: 0 no es miembro (es entero)
   (while (not (member$ ?v ?permitidos)) do
      (printout t ?prompt " " ?permitidos ": ")
      (bind ?v (read))
      (if (not (member$ ?v ?permitidos))
         then (printout t "   [!] Opcion invalida. Use una de: " ?permitidos crlf)))
   ?v)

;; Lee un IDENTIFICADOR (simbolo no numerico, sin comillas).
(deffunction MAIN::leer-id (?prompt)
   (bind ?v 0)                            ; sentinela: 0 no es symbolp
   (while (not (symbolp ?v)) do
      (printout t ?prompt ": ")
      (bind ?v (read))
      (if (not (symbolp ?v))
         then (printout t "   [!] El ID debe ser un simbolo (sin comillas ni numero)." crlf)))
   ?v)


;;;----------------------------------------------------------
;;; CAPTURA POR CAPA
;;; Cada deffunction lee con validacion y ASERTA el hecho.
;;; El valor ya viene saneado por las primitivas de arriba.
;;;----------------------------------------------------------

(deffunction MAIN::capturar-contenedor ()
   (printout t "--- Contenedor (Docker) ---" crlf)
   (bind ?id     (leer-id      "ID del contenedor"))
   (bind ?estado (leer-simbolo "Estado" Running CrashLoopBackOff OOMKilled Error Pending))
   (bind ?cpu    (leer-rango   "CPU% (uso vs limit asignado)" 0 100))
   (bind ?mem    (leer-rango   "MEM% (uso vs limit asignado)" 0 100))
   (bind ?liv    (leer-simbolo "Liveness"  ok fallida))
   (bind ?rdy    (leer-simbolo "Readiness" ok fallida))
   (bind ?conx   (leer-rango   "Conexiones/hilos abiertos" 0 1000000))
   (assert (contenedor (id ?id) (estado ?estado) (cpu-pct ?cpu)
                       (mem-pct ?mem) (liveness ?liv) (readiness ?rdy)
                       (conexiones ?conx)))
   (printout t "   [ok] contenedor " ?id " registrado." crlf))

(deffunction MAIN::capturar-nodo ()
   (printout t "--- Nodo (Kubernetes) ---" crlf)
   (bind ?id      (leer-id      "ID del nodo"))
   (bind ?estado  (leer-simbolo "Estado" Ready NotReady))
   (bind ?presion (leer-simbolo "Presion" ninguna DiskPressure MemoryPressure PIDPressure))
   (assert (nodo (id ?id) (estado ?estado) (presion ?presion)))
   (printout t "   [ok] nodo " ?id " registrado." crlf))

(deffunction MAIN::capturar-pod ()
   (printout t "--- Pod ---" crlf)
   (bind ?id     (leer-id      "ID del pod"))
   (bind ?estado (leer-simbolo "Estado" Running Pending Failed CrashLoopBackOff))
   (bind ?nodo   (leer-id      "Nodo donde corre"))
   (assert (pod (id ?id) (estado ?estado) (nodo ?nodo)))
   (printout t "   [ok] pod " ?id " registrado." crlf))

(deffunction MAIN::capturar-hpa ()
   (printout t "--- HPA (autoscaler) ---" crlf)
   (bind ?obj  (leer-id      "Objetivo (deployment)"))
   (bind ?esc  (leer-simbolo "Escalando" si no))
   (bind ?ract (leer-rango   "Replicas actuales" 0 1000))
   (bind ?rmin (leer-rango   "Replicas minimas"  1 1000))
   (bind ?rmax (leer-rango   "Replicas maximas"  1 1000))
   (bind ?cpu  (leer-rango   "CPU actual del deployment (%)" 0 100))
   (bind ?obj% (leer-rango   "CPU objetivo del HPA (%)" 1 100))
   (assert (hpa (objetivo ?obj) (escalando ?esc)
                (replicas-actuales ?ract) (replicas-min ?rmin) (replicas-max ?rmax)
                (cpu-actual ?cpu) (cpu-objetivo ?obj%)))
   (printout t "   [ok] hpa de " ?obj " registrado." crlf))

(deffunction MAIN::capturar-ingress ()
   (printout t "--- Ingress (trafico entrante) ---" crlf)
   (bind ?srv (leer-id      "Servicio detras del Ingress"))
   (bind ?rps (leer-rango   "Requests por segundo" 0 10000000))
   (bind ?e4  (leer-rango   "Tasa 4xx (%)" 0 100))
   (bind ?ips (leer-rango   "IPs distintas observadas" 0 10000000))
   (bind ?atk (leer-simbolo "Ataque marcado" si no desconocido))
   (assert (ingress (servicio ?srv) (requests-por-seg ?rps) (tasa-4xx ?e4)
                    (ips-distintas ?ips) (ataque ?atk)))
   (printout t "   [ok] ingress de " ?srv " registrado." crlf))

(deffunction MAIN::capturar-volumen ()
   (printout t "--- Volumen (PV/PVC) ---" crlf)
   (bind ?id     (leer-id      "ID del volumen"))
   (bind ?estado (leer-simbolo "Estado" Bound Pending Lost))
   (bind ?uso    (leer-rango   "Uso%" 0 100))
   (assert (volumen (id ?id) (estado ?estado) (uso-pct ?uso)))
   (printout t "   [ok] volumen " ?id " registrado." crlf))

(deffunction MAIN::capturar-control-plane ()
   (printout t "--- Control-plane ---" crlf)
   (bind ?sat (leer-simbolo "Saturado" si no))
   (assert (control-plane (saturado ?sat)))
   (printout t "   [ok] control-plane registrado." crlf))

(deffunction MAIN::capturar-trafico ()
   (printout t "--- Trafico (servicio) ---" crlf)
   (bind ?srv (leer-id    "Servicio"))
   (bind ?p95 (leer-rango "Latencia p95 (ms)" 0 60000))
   (bind ?p99 (leer-rango "Latencia p99 (ms)" 0 60000))
   (bind ?e5  (leer-rango "Tasa 5xx (%)" 0 100))
   (bind ?e4  (leer-rango "Tasa 4xx (%)" 0 100))
   (assert (trafico (servicio ?srv) (latencia-p95 ?p95) (latencia-p99 ?p99)
                    (tasa-5xx ?e5) (tasa-4xx ?e4)))
   (printout t "   [ok] trafico de " ?srv " registrado." crlf))

(deffunction MAIN::capturar-red ()
   (printout t "--- Red / CoreDNS ---" crlf)
   (bind ?dns (leer-simbolo "CoreDNS saturado" si no))
   (bind ?sat (leer-rango   "Saturacion de red (%)" 0 100))
   (assert (red (coredns-saturado ?dns) (saturacion-pct ?sat)))
   (printout t "   [ok] red registrada." crlf))


;;;----------------------------------------------------------
;;; REGLAS DE CAPTURA (modo consola)
;;; Orquestan el menu interactivo. Solo se activan si existe
;;; el hecho (modo consola); en modo web no se disparan.
;;;----------------------------------------------------------

;; Arranque: imprime cabecera y abre el menu. Salience alta
;; para que sea lo primero dentro del foco CAPTURA.
(defrule CAPTURA::iniciar-consola
   (declare (salience 100))
   (modo (tipo consola))
   (not (menu-captura))
   (not (captura-finalizada))
   =>
   (printout t crlf "=== K8s-ExpertAdvisor : CAPTURA de telemetria ===" crlf)
   (assert (menu-captura)))

;; Bucle del menu: cada eleccion captura una capa y reabre el
;; menu (re-asertando menu-captura). La opcion 0 cierra la fase.
(defrule CAPTURA::menu
   (declare (salience 50))
   ?m <- (menu-captura)
   =>
   (retract ?m)
   (printout t crlf
      "Capa a registrar:" crlf
      "  1) Contenedor (Docker)   6) Control-plane"      crlf
      "  2) Nodo (Kubernetes)     7) Trafico (servicio)" crlf
      "  3) Pod                   8) Red / CoreDNS"      crlf
      "  4) HPA (autoscaler)      9) Ingress (DDoS)"     crlf
      "  5) Volumen (PV/PVC)"                            crlf
      "  0) Terminar captura y diagnosticar"            crlf)
   (bind ?op (leer-rango "Opcion" 0 9))
   (switch ?op
      (case 1 then (capturar-contenedor)    (assert (menu-captura)))
      (case 2 then (capturar-nodo)          (assert (menu-captura)))
      (case 3 then (capturar-pod)           (assert (menu-captura)))
      (case 4 then (capturar-hpa)           (assert (menu-captura)))
      (case 5 then (capturar-volumen)       (assert (menu-captura)))
      (case 6 then (capturar-control-plane) (assert (menu-captura)))
      (case 7 then (capturar-trafico)       (assert (menu-captura)))
      (case 8 then (capturar-red)           (assert (menu-captura)))
      (case 9 then (capturar-ingress)       (assert (menu-captura)))
      (default (assert (captura-finalizada))
               (printout t crlf "Captura finalizada. Correlacionando..." crlf))))


;;;----------------------------------------------------------
;;; PUNTOS DE ENTRADA
;;;----------------------------------------------------------

;; Modo consola (IDE): reinicia, marca el modo y ejecuta las
;; 3 fases en orden mediante el foco de modulos.
(deffunction MAIN::consola ()
   (reset)
   (assert (modo (tipo consola)))
   (focus CAPTURA CORRELACION MITIGACION)
   (run))

;; Modo hechos (backend web): el backend ya hizo (reset) y
;; asertado la telemetria via clipspy; esto solo dispara el
;; razonamiento. Se omite CAPTURA porque no hay (modo consola).
(deffunction MAIN::diagnosticar ()
   (focus CORRELACION MITIGACION)
   (run))


;;;==========================================================
;;; FASE CORRELACION
;;; El corazon del sistema: cruza variables de las 3 capas y
;;; deduce la CAUSA RAIZ (no el sintoma). Cada regla:
;;;   (1) asserta un hecho 'justificacion' (huella para por-que)
;;;   (2) asserta un 'diagnostico' con su 'tipo' (llave de mitigacion)
;;; Las guardas (not (diagnostico (tipo X))) evitan duplicados.
;;;==========================================================


;;;----------------------------------------------------------
;;; HEURISTICA 1: FALSA ALARMA DE CPU
;;; Un contenedor al tope de CPU PARECE pedir escalado, pero si
;;; el nodo sufre DiskPressure/MemoryPressure el cuello de botella
;;; es el NODO. Escalar el pod ahi empeora la presion. La causa
;;; raiz es la presion de recursos del nodo.
;;;----------------------------------------------------------
(defrule CORRELACION::cpu-falsa-alarma
   (declare (salience 80))
   (contenedor (id ?c) (cpu-pct ?cpu&:(>= ?cpu 90)))
   (nodo (id ?n) (presion ?p&DiskPressure|MemoryPressure))
   (not (diagnostico (tipo cpu-falsa-alarma)))
   =>
   (assert (justificacion
      (regla cpu-falsa-alarma)
      (premisa (str-cat "Contenedor " ?c " con CPU " ?cpu "% (>=90) y nodo "
                        ?n " bajo " ?p))
      (conclusion "La saturacion de CPU es un sintoma; el cuello de botella real es la presion de recursos del nodo. NO escalar el pod.")))
   (assert (diagnostico
      (tipo cpu-falsa-alarma)
      (causa-raiz (str-cat "Presion de recursos en el nodo " ?n " (" ?p
                           "); el alto consumo de CPU del contenedor " ?c
                           " es consecuencia, no causa."))
      (severidad alta))))


;;;----------------------------------------------------------
;;; HEURISTICA 2: CASCADA POR OOMKilled
;;; Un contenedor muere por memoria (OOMKilled), revive, y durante
;;; el ciclo genera latencia y errores 5xx (504) que arrastran a
;;; servicios vecinos (readiness fallida). El sintoma se ve en la
;;; RED, pero la causa raiz es el LIMITE DE MEMORIA insuficiente
;;; del contenedor original.
;;;----------------------------------------------------------
(defrule CORRELACION::cascada-oom
   (declare (salience 80))
   (contenedor (id ?c) (estado OOMKilled))
   (trafico (servicio ?s) (tasa-5xx ?e&:(>= ?e 5)) (latencia-p99 ?l))
   (not (diagnostico (tipo cascada-oom)))
   =>
   (assert (justificacion
      (regla cascada-oom)
      (premisa (str-cat "Contenedor " ?c " en OOMKilled mientras el servicio "
                        ?s " presenta " ?e "% de 5xx y latencia p99 " ?l "ms"))
      (conclusion "Los errores 5xx/504 y la latencia son efecto del reinicio ciclico por memoria, NO un problema de red.")))
   (assert (diagnostico
      (tipo cascada-oom)
      (causa-raiz (str-cat "Limite de memoria insuficiente en el contenedor "
                           ?c " (OOMKilled): su reinicio ciclico provoca la "
                           "cascada de 5xx y latencia en " ?s "."))
      (severidad critica))))


;;;----------------------------------------------------------
;;; HEURISTICA 3: FUGA DE CONEXIONES (leak)
;;; Conexiones/hilos crecen sin control y el contenedor colapsa
;;; (CrashLoopBackOff/Error o liveness fallida) AUNQUE la CPU no
;;; sea el limite. Eso distingue un BUG DE CODIGO (pool/fd leak)
;;; de un problema de capacidad de infraestructura: escalar o
;;; subir limites solo retrasa el colapso.
;;;----------------------------------------------------------
(defrule CORRELACION::fuga-conexiones
   (declare (salience 80))
   (contenedor (id ?c)
               (conexiones ?x&:(>= ?x 1000))
               (cpu-pct ?cpu&:(< ?cpu 90))
               (estado ?st&CrashLoopBackOff|Error))
   (not (diagnostico (tipo fuga-conexiones)))
   =>
   (assert (justificacion
      (regla fuga-conexiones)
      (premisa (str-cat "Contenedor " ?c " con " ?x " conexiones abiertas, CPU "
                        ?cpu "% (<90) y estado " ?st))
      (conclusion "Conexiones altas sin saturacion de CPU + colapso ciclico apuntan a una fuga de recursos en el codigo, no a falta de capacidad.")))
   (assert (diagnostico
      (tipo fuga-conexiones)
      (causa-raiz (str-cat "Fuga de conexiones/hilos en el contenedor " ?c
                           " (bug de codigo): el pool no se libera y agota los "
                           "recursos. Escalar o reiniciar es paliativo."))
      (severidad alta))))


;;;----------------------------------------------------------
;;; HEURISTICA 4: DDoS EN EL INGRESS  -> BLOQUEAR AUTOESCALADO
;;; (modificacion en vivo exigida por el enunciado)
;;; Un pico de trafico puede parecer demanda legitima y disparar
;;; el HPA. Pero si la firma es de DDoS L7 (muchos req/s desde muy
;;; pocas IPs con 4xx alto), escalar solo gasta infraestructura
;;; sirviendo trafico de ataque. Salience ALTA: corre antes que la
;;; regla de autoescalado para bloquearla.
;;;----------------------------------------------------------
(defrule CORRELACION::ddos-bloquea-autoescalado
   (declare (salience 85))
   (ingress (servicio ?s) (requests-por-seg ?rps) (tasa-4xx ?e4)
            (ips-distintas ?ips) (ataque ?atk))
   (not (diagnostico (tipo ddos-bloqueo)))
   (test (or (eq ?atk si)
             (and (> ?rps 2000) (>= ?e4 40) (<= ?ips 10))))
   =>
   (assert (justificacion
      (regla ddos-bloquea-autoescalado)
      (premisa (str-cat "Ingress de " ?s ": ataque=" ?atk ", " ?rps " req/s desde "
                        ?ips " IP(s) con " ?e4 "% de 4xx"))
      (conclusion "Firma de DDoS L7: el pico NO es demanda legitima. Escalar gastaria infraestructura sirviendo trafico de ataque. Se BLOQUEA el autoescalado.")))
   (assert (diagnostico
      (tipo ddos-bloqueo)
      (causa-raiz (str-cat "Ataque DDoS contra el Ingress de " ?s
                           "; autoescalado bloqueado para evitar gasto masivo de infraestructura."))
      (severidad alta))))


;;;----------------------------------------------------------
;;; HEURISTICA 5: AUTOESCALADO POR DEMANDA LEGITIMA
;;; El HPA del servicio esta por debajo del maximo y la CPU agregada
;;; supera el umbral objetivo. Si NO hay DDoS ni falsa alarma de CPU
;;; (presion de nodo), la demanda es real: anadir replicas.
;;;----------------------------------------------------------
(defrule CORRELACION::autoescalado-demanda
   (declare (salience 70))
   (hpa (objetivo ?s) (replicas-actuales ?r) (replicas-max ?max)
        (cpu-actual ?cpu) (cpu-objetivo ?obj))
   (not (diagnostico (tipo ddos-bloqueo)))
   (not (diagnostico (tipo cpu-falsa-alarma)))
   (test (and (> ?cpu ?obj) (< ?r ?max)))
   =>
   (bind ?des (min ?max (max (+ ?r 1) (div (+ (* ?r ?cpu) ?obj -1) ?obj))))
   (assert (justificacion
      (regla autoescalado-demanda)
      (premisa (str-cat "HPA de " ?s ": CPU " ?cpu "% supera el objetivo " ?obj
                        "% con " ?r "/" ?max " replicas y sin presion de nodo ni DDoS"))
      (conclusion (str-cat "Demanda legitima por encima de capacidad: el HPA debe escalar de "
                           ?r " a " ?des " replicas."))))
   (assert (diagnostico
      (tipo autoescalado-demanda)
      (causa-raiz (str-cat "Saturacion legitima de " ?s " (CPU " ?cpu "% > objetivo " ?obj
                           "%): escalar de " ?r " a " ?des " replicas via HPA."))
      (severidad media))))


;;;----------------------------------------------------------
;;; FALLBACK: sin causa raiz concluyente
;;; Salience baja: solo se dispara si ninguna heuristica produjo
;;; un diagnostico. Evita "silencio" ante telemetria no cubierta.
;;;----------------------------------------------------------
(defrule CORRELACION::sin-diagnostico
   (declare (salience 10))
   (not (diagnostico))
   =>
   (assert (justificacion
      (regla sin-diagnostico)
      (premisa "Ninguna heuristica de correlacion encontro un patron conocido.")
      (conclusion "Se requiere mas telemetria o una regla nueva para este escenario.")))
   (assert (diagnostico
      (tipo indeterminado)
      (causa-raiz "No fue posible determinar una causa raiz con la telemetria disponible.")
      (severidad baja))))


;;;==========================================================
;;; FASE MITIGACION
;;; Convierte cada causa raiz en un PLAN DE ACCION concreto:
;;; genera dinamicamente los comandos kubectl y los guarda en el
;;; multislot 'comandos' del diagnostico (via modify).
;;;
;;; Patron de cada regla:
;;;   - matchea el diagnostico por 'tipo' con (comandos) VACIO
;;;     (la guarda de multislot vacio evita re-disparos tras modify)
;;;   - re-matchea la telemetria para extraer los IDs reales
;;;   - construye los comandos con str-cat y hace modify
;;;==========================================================


;;;----------------------------------------------------------
;;; MITIGACION 1: falsa alarma de CPU
;;; No escalar el pod: aliviar la presion del NODO (cordon +
;;; desalojo de pods no criticos) o activar el Cluster Autoscaler.
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-cpu-falsa-alarma
   ?d <- (diagnostico (tipo cpu-falsa-alarma) (comandos))
   (nodo (id ?n) (presion ?p&DiskPressure|MemoryPressure))
   =>
   (modify ?d (comandos
      (str-cat "kubectl describe node " ?n "   # confirmar la condicion " ?p)
      (str-cat "kubectl cordon " ?n "          # no admitir mas pods en el nodo")
      (str-cat "kubectl drain " ?n " --ignore-daemonsets --delete-emptydir-data --pod-selector=priority!=critical")
      "kubectl -n kube-system scale deployment/cluster-autoscaler --replicas=1   # o sumar un nodo al pool")))


;;;----------------------------------------------------------
;;; MITIGACION 2: cascada por OOMKilled
;;; Subir el limite de memoria del contenedor original y reiniciar
;;; el rollout. NO tocar la red: era un efecto, no la causa.
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-cascada-oom
   ?d <- (diagnostico (tipo cascada-oom) (comandos))
   (contenedor (id ?c) (estado OOMKilled))
   =>
   (modify ?d (comandos
      (str-cat "kubectl set resources deployment/" ?c " --limits=memory=1Gi --requests=memory=512Mi")
      (str-cat "kubectl rollout restart deployment/" ?c)
      (str-cat "kubectl rollout status deployment/" ?c "   # esperar a que estabilice")
      (str-cat "kubectl get events --field-selector reason=OOMKilling   # verificar que cesa"))))


;;;----------------------------------------------------------
;;; MITIGACION 3: fuga de conexiones (bug de codigo)
;;; El reinicio es PALIATIVO. La accion de fondo es corregir el
;;; pool/cierre de descriptores en el codigo de la aplicacion.
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-fuga-conexiones
   ?d <- (diagnostico (tipo fuga-conexiones) (comandos))
   (contenedor (id ?c)
               (conexiones ?x&:(>= ?x 1000))
               (estado CrashLoopBackOff|Error))
   =>
   (modify ?d (comandos
      (str-cat "kubectl logs deployment/" ?c " --previous | grep -i 'too many\\|connection'   # evidencia del leak")
      (str-cat "kubectl rollout restart deployment/" ?c "   # PALIATIVO: libera conexiones temporalmente")
      "# ACCION DE FONDO: corregir el cierre de conexiones/fds en el codigo (pool con leak)."
      "# Escalar o subir limites NO resuelve una fuga: solo retrasa el colapso.")))


;;;----------------------------------------------------------
;;; MITIGACION 4: DDoS -> NO escalar, contener en el Ingress
;;; Rate-limit en el Ingress + congelar el HPA para que el ataque
;;; no dispare gasto de infraestructura.
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-ddos-bloqueo
   ?d <- (diagnostico (tipo ddos-bloqueo) (comandos))
   (ingress (servicio ?s))
   =>
   (modify ?d (comandos
      (str-cat "kubectl annotate ingress " ?s " nginx.ingress.kubernetes.io/limit-rps=\"20\" --overwrite   # rate-limit L7")
      (str-cat "kubectl annotate ingress " ?s " nginx.ingress.kubernetes.io/limit-connections=\"10\" --overwrite")
      (str-cat "kubectl patch hpa " ?s " --type=merge -p '{\"spec\":{\"maxReplicas\":1}}'   # congelar el autoescalado")
      "# NO escalar el deployment: el pico es trafico de ataque, no demanda real.")))


;;;----------------------------------------------------------
;;; MITIGACION 5: autoescalado por demanda legitima
;;; Subir el techo del HPA (o escalar) para absorber la demanda real.
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-autoescalado-demanda
   ?d <- (diagnostico (tipo autoescalado-demanda) (comandos))
   (hpa (objetivo ?s) (replicas-actuales ?r) (replicas-max ?max)
        (cpu-actual ?cpu) (cpu-objetivo ?obj))
   =>
   (bind ?des (min ?max (max (+ ?r 1) (div (+ (* ?r ?cpu) ?obj -1) ?obj))))
   (modify ?d (comandos
      (str-cat "kubectl scale deployment/" ?s " --replicas=" ?des "   # " ?r " -> " ?des " (demanda legitima)")
      (str-cat "kubectl get hpa " ?s " -w        # confirmar que el HPA converge")
      (str-cat "kubectl get deployment/" ?s " -o wide   # verificar replicas listas"))))


;;;----------------------------------------------------------
;;; MITIGACION 0: indeterminado
;;; Sin causa raiz: recolectar mas telemetria, no actuar a ciegas.
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-indeterminado
   ?d <- (diagnostico (tipo indeterminado) (comandos))
   =>
   (modify ?d (comandos
      "kubectl get pods,nodes -A          # ampliar la captura de telemetria"
      "kubectl top pods -A                # CPU/memoria reales"
      "# No se aplican cambios: causa raiz no concluyente.")))


;;;----------------------------------------------------------
;;; REPORTE FINAL
;;; Salience muy baja: corre tras llenarse los comandos via modify.
;;; La refraction de CLIPS asegura que dispare una sola vez por
;;; cada diagnostico ya completo (no necesita marca explicita).
;;;----------------------------------------------------------
(defrule MITIGACION::reporte
   (declare (salience -100))
   (diagnostico (tipo ?t) (causa-raiz ?cr) (severidad ?sev) (comandos $?cmds))
   =>
   (printout t crlf "================ DIAGNOSTICO ================" crlf
               "Tipo      : " ?t   crlf
               "Severidad : " ?sev crlf
               "Causa raiz: " ?cr  crlf
               "--- Plan de accion (kubectl) ---" crlf)
   (if (= (length$ ?cmds) 0)
      then (printout t "  (sin comandos generados)" crlf)
      else (progn$ (?c ?cmds) (printout t "  $ " ?c crlf)))
   (printout t "Escriba  (por-que)  para ver el arbol de deduccion." crlf
               "=============================================" crlf))


;;;==========================================================
;;; MODULO "POR-QUE" (explicacion)
;;; No reconstruye nada: solo recorre en orden los hechos
;;; 'justificacion' que cada regla dejo al dispararse, y los
;;; presenta como el arbol de deduccion (regla -> premisa ->
;;; conclusion). Se invoca tecleando (por-que).
;;;==========================================================
(deffunction MAIN::por-que ()
   (printout t crlf "========== ARBOL DE DEDUCCION (por-que) ==========" crlf)
   (bind ?n 0)
   (do-for-all-facts ((?j justificacion)) TRUE
      (bind ?n (+ ?n 1))
      (printout t ?n ") regla: " (fact-slot-value ?j regla) crlf
                  "   premisa   : " (fact-slot-value ?j premisa)    crlf
                  "   conclusion: " (fact-slot-value ?j conclusion) crlf))
   (if (= ?n 0)
      then (printout t "(aun no hay deducciones; ejecute un diagnostico primero)" crlf))
   (printout t "==================================================" crlf))
