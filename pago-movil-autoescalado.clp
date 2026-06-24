;;;==========================================================
;;; K8s-ExpertAdvisor - Modulo Pago Movil + Autoescalado
;;; Sistema experto CLIPS
;;;----------------------------------------------------------
;;; Mismo patron arquitectonico que k8s_expert_advisor.clp:
;;;   MAIN        -> base de conocimiento (deftemplates) + export ?ALL
;;;   CAPTURA     -> menu interactivo validado (modo consola en el IDE)
;;;   CORRELACION -> valida pagos, mide carga y DECIDE el escalado
;;;   MITIGACION  -> genera el plan de accion (comandos kubectl)
;;; Cada regla deja una 'justificacion' para el modulo (por-que),
;;; y todo veredicto sale como un 'diagnostico' (igual shape que el
;;; sistema grande) para que el backend lo lea sin logica extra.
;;;
;;; Idea de negocio: si la carga de pagos llega a un TOPE, el motor
;;; decide por si solo cuantas replicas necesita. PERO si detecta un
;;; ataque DDoS en el Ingress, BLOQUEA el autoescalado para no gastar
;;; infraestructura defendiendo trafico basura (requisito del PDF).
;;;==========================================================


;;;----------------------------------------------------------
;;; MODULOS
;;;----------------------------------------------------------
(defmodule MAIN (export ?ALL))


;;;----------------------------------------------------------
;;; BASE DE CONOCIMIENTO (deftemplate en MAIN)
;;;----------------------------------------------------------

(deftemplate MAIN::pago-movil
   "Una transaccion de pago movil entrante"
   (slot id              (type SYMBOL))
   (slot numero-telefono (type STRING) (default ?NONE))
   (slot nombre          (type STRING) (default ?NONE))
   ;; V = persona natural, J = persona juridica
   (slot tipo-documento  (type SYMBOL) (allowed-symbols V J) (default ?NONE))
   (slot documento       (type STRING) (default ?NONE))   ; alfanumerico: "V12345678"
   (slot monto           (type FLOAT)  (default 0.0))
   (slot estado          (type SYMBOL)
                         (allowed-symbols pendiente validado procesado rechazado)
                         (default pendiente)))

(deftemplate MAIN::servicio-pagos
   "Deployment de Kubernetes que procesa los pagos"
   (slot nombre               (type STRING)  (default "pago-movil-svc"))
   (slot replicas             (type INTEGER) (default 1))
   (slot replicas-min         (type INTEGER) (default 1))
   (slot replicas-max         (type INTEGER) (default 10))
   (slot capacidad-por-replica(type INTEGER) (default 50))) ; pagos/min que aguanta 1 replica

(deftemplate MAIN::ventana-carga
   "Metrica agregada de la ventana actual"
   (slot pagos-en-cola (type INTEGER) (default 0))   ; lo calcula medir-carga
   (slot carga-extra   (type INTEGER) (default 0))   ; pico simulado que llega de otras fuentes
   (slot tope          (type INTEGER) (default 100))); TOPE que dispara el autoescalado

(deftemplate MAIN::ingress
   "Telemetria del Ingress Controller (capa de red/trafico)"
   (slot servicio        (type STRING)  (default "pago-movil-svc"))
   (slot requests-por-seg(type INTEGER) (range 0 ?VARIABLE) (default 0))
   (slot tasa-4xx        (type INTEGER) (range 0 100) (default 0)) ; % de 4xx (tipico en DDoS L7)
   (slot ips-distintas   (type INTEGER) (range 0 ?VARIABLE) (default 1)) ; pocas IPs + muchos req = sospechoso
   (slot ataque          (type SYMBOL)  (allowed-symbols si no desconocido) (default desconocido)))

(deftemplate MAIN::accion-escalado
   "Registro de una decision de escalado tomada por el motor"
   (slot servicio        (type STRING))
   (slot replicas-antes  (type INTEGER))
   (slot replicas-despues(type INTEGER))
   (slot direccion       (type SYMBOL) (allowed-symbols arriba abajo bloqueado))
   (slot razon           (type STRING)))

;;; Salida normalizada (mismo shape que k8s_expert_advisor.clp para
;;; que el backend y el front reutilicen el lector tal cual).
(deftemplate MAIN::diagnostico
   (slot tipo       (type SYMBOL)
                    (allowed-symbols indeterminado autoescalado-pagos carga-estable
                                     ddos-bloqueo pagos-rechazados)
                    (default indeterminado))
   (slot causa-raiz (type STRING))
   (slot severidad  (type SYMBOL) (allowed-symbols baja media alta critica) (default media))
   (multislot comandos (type STRING)))

(deftemplate MAIN::justificacion
   (slot regla      (type SYMBOL))
   (slot premisa    (type STRING))
   (slot conclusion (type STRING)))

;;; Hechos de control de la fase CAPTURA (modo consola)
(deftemplate MAIN::modo
   (slot tipo (type SYMBOL) (allowed-symbols consola hechos) (default consola)))
(deftemplate MAIN::menu-captura)
(deftemplate MAIN::captura-finalizada)


;;;----------------------------------------------------------
;;; Resto de modulos (importan todo lo de MAIN)
;;;----------------------------------------------------------
(defmodule CAPTURA     (import MAIN ?ALL) (export ?ALL))
(defmodule CORRELACION (import MAIN ?ALL) (export ?ALL))
(defmodule MITIGACION  (import MAIN ?ALL) (export ?ALL))


;;;==========================================================
;;; FUNCIONES DE APOYO (validacion + utilidades)
;;;==========================================================

;; Prefijos validos de pago movil en Venezuela
(deffunction MAIN::prefijo-valido (?tel)
   (or (eq 1 (str-index "0412" ?tel))
       (eq 1 (str-index "0414" ?tel))
       (eq 1 (str-index "0416" ?tel))
       (eq 1 (str-index "0424" ?tel))
       (eq 1 (str-index "0426" ?tel))))

;; Telefono valido: 11 digitos y prefijo conocido
(deffunction MAIN::telefono-valido (?tel)
   (and (= (str-length ?tel) 11)
        (prefijo-valido ?tel)))

;; Division entera con redondeo hacia arriba (replicas necesarias)
(deffunction MAIN::replicas-necesarias (?carga ?cap)
   (max 1 (div (+ ?carga ?cap -1) ?cap)))

;; Generador de carga para simular un pico de pagos (modo consola)
(deffunction MAIN::simular-carga (?n)
   (loop-for-count (?i 1 ?n) do
      (assert (pago-movil (id (sym-cat p ?i))
                          (numero-telefono "04141234567")
                          (nombre "Cliente Demo")
                          (tipo-documento V)
                          (documento (str-cat "V" ?i))
                          (monto 100.0))))
   (printout t "Inyectados " ?n " pagos en cola." crlf))


;;;==========================================================
;;; FASE CAPTURA  (menu interactivo - solo modo consola en el IDE)
;;; En modo web el backend asserta los hechos y NO asserta
;;; (modo consola), por lo que estas reglas nunca se disparan.
;;;==========================================================

;; Lectura validada de un entero en rango (reintenta).
(deffunction MAIN::leer-rango (?prompt ?min ?max)
   (bind ?v nil)
   (while (or (not (integerp ?v)) (< ?v ?min) (> ?v ?max)) do
      (printout t ?prompt " [" ?min "-" ?max "]: ")
      (bind ?v (read))
      (if (not (integerp ?v))
         then (printout t "   [!] Se esperaba un ENTERO. Reintente." crlf)
         else (if (or (< ?v ?min) (> ?v ?max))
                  then (printout t "   [!] Fuera de rango. Reintente." crlf))))
   ?v)

;; Captura de un pago por consola, con validacion de telefono.
(deffunction MAIN::capturar-pago ()
   (printout t "--- Pago movil ---" crlf)
   (printout t "Numero de telefono (04XXXXXXXXX): ")
   (bind ?tel (readline))
   (printout t "Nombre del titular: ")
   (bind ?nom (readline))
   (printout t "Tipo de documento (V/J): ")
   (bind ?td (read))
   (printout t "Documento (ej. V12345678): ")
   (bind ?doc (readline))
   (bind ?monto (leer-rango "Monto" 0 1000000))
   (bind ?id (gensym*))
   (assert (pago-movil (id ?id) (numero-telefono ?tel) (nombre ?nom)
                       (tipo-documento ?td) (documento ?doc)
                       (monto (float ?monto))))
   (printout t "   [ok] pago " ?id " registrado (se validara al diagnosticar)." crlf))

(defrule CAPTURA::iniciar-consola
   (declare (salience 100))
   (modo (tipo consola))
   (not (menu-captura))
   (not (captura-finalizada))
   =>
   (printout t crlf "=== K8s-ExpertAdvisor : Pago movil + Autoescalado ===" crlf)
   (assert (menu-captura)))

(defrule CAPTURA::menu
   (declare (salience 50))
   ?m <- (menu-captura)
   ?v <- (ventana-carga)
   ?s <- (servicio-pagos)
   ?g <- (ingress)
   =>
   (retract ?m)
   (printout t crlf
      "Accion:" crlf
      "  1) Registrar un pago movil" crlf
      "  2) Simular pico (inyectar N pagos validos)" crlf
      "  3) Fijar TOPE de la ventana" crlf
      "  4) Fijar replicas actuales / maximas" crlf
      "  5) Simular ataque DDoS en el Ingress (si/no)" crlf
      "  0) Diagnosticar" crlf)
   (bind ?op (leer-rango "Opcion" 0 5))
   (switch ?op
      (case 1 then (capturar-pago) (assert (menu-captura)))
      (case 2 then (simular-carga (leer-rango "Cuantos pagos" 0 100000))
                   (assert (menu-captura)))
      (case 3 then (modify ?v (tope (leer-rango "Nuevo tope" 1 1000000)))
                   (assert (menu-captura)))
      (case 4 then (modify ?s (replicas    (leer-rango "Replicas actuales" 1 1000))
                              (replicas-max (leer-rango "Replicas maximas"  1 1000)))
                   (assert (menu-captura)))
      (case 5 then (modify ?g (ataque (if (= 1 (leer-rango "DDoS activo (1=si 0=no)" 0 1))
                                          then si else no)))
                   (assert (menu-captura)))
      (default (assert (captura-finalizada))
               (printout t crlf "Diagnosticando..." crlf))))


;;;==========================================================
;;; PUNTOS DE ENTRADA
;;;==========================================================

;; Modo consola (IDE): captura interactiva + las 3 fases.
(deffunction MAIN::consola ()
   (reset)
   (assert (modo (tipo consola)))
   (focus CAPTURA CORRELACION MITIGACION)
   (run))

;; Modo hechos (backend web): el backend ya hizo (reset) y asserto
;; los hechos; esto solo dispara el razonamiento. Mismo focus que
;; usa motor.py para el sistema grande -> el backend se reutiliza.
(deffunction MAIN::diagnosticar ()
   (focus CORRELACION MITIGACION)
   (run))


;;;==========================================================
;;; FASE CORRELACION
;;; valida pagos -> mide carga -> detecta DDoS -> decide escalado
;;;==========================================================

;;;----------------------------------------------------------
;;; VALIDACION (salience alta = corre primero)
;;;----------------------------------------------------------
(defrule CORRELACION::validar-telefono-invalido
   (declare (salience 100))
   ?p <- (pago-movil (id ?id) (numero-telefono ?tel) (estado pendiente))
   (test (not (telefono-valido ?tel)))
   =>
   (modify ?p (estado rechazado))
   (assert (justificacion
      (regla validar-telefono-invalido)
      (premisa (str-cat "Pago " ?id " con telefono \"" ?tel "\" (no son 11 digitos o prefijo no es 0412/0414/0416/0424/0426)"))
      (conclusion "El pago se rechaza: no entra en la cola ni cuenta para la carga.")))
   (printout t "[RECHAZADO] " ?id ": telefono invalido (" ?tel ")" crlf))

(defrule CORRELACION::validar-pago-ok
   (declare (salience 90))
   ?p <- (pago-movil (id ?id) (numero-telefono ?tel) (tipo-documento ?td) (estado pendiente))
   (test (telefono-valido ?tel))
   =>
   (modify ?p (estado validado))
   (printout t "[OK] " ?id " validado (doc " ?td ")" crlf))

;;;----------------------------------------------------------
;;; MEDICION DE CARGA (salience media)
;;; carga = pagos validados + carga-extra (pico simulado)
;;;----------------------------------------------------------
(defrule CORRELACION::medir-carga
   (declare (salience 50))
   ?v <- (ventana-carga (pagos-en-cola ?old) (carga-extra ?extra))
   =>
   (bind ?validos (length$ (find-all-facts ((?p pago-movil)) (eq ?p:estado validado))))
   (bind ?carga (+ ?validos ?extra))
   (if (<> ?carga ?old) then
      (modify ?v (pagos-en-cola ?carga))
      (printout t "[METRICA] carga = " ?carga " (validados " ?validos " + extra " ?extra ")" crlf)))

;;;----------------------------------------------------------
;;; DETECCION DE DDoS (salience > autoescalado: bloquea antes de escalar)
;;; Dispara por bandera explicita (ataque si) o por la firma clasica
;;; de un DDoS L7: muchisimos requests desde pocas IPs con alta 4xx.
;;;----------------------------------------------------------
(defrule CORRELACION::detectar-ddos
   (declare (salience 30))
   (ingress (servicio ?svc) (requests-por-seg ?rps) (tasa-4xx ?e4)
            (ips-distintas ?ips) (ataque ?atk))
   (servicio-pagos (replicas ?r) (capacidad-por-replica ?cap))
   (not (diagnostico (tipo ddos-bloqueo)))
   (test (or (eq ?atk si)
             (and (> ?rps (* 5 ?r ?cap)) (>= ?e4 40) (<= ?ips 5))))
   =>
   (assert (justificacion
      (regla detectar-ddos)
      (premisa (str-cat "Ingress de " ?svc ": ataque=" ?atk ", " ?rps " req/s desde "
                        ?ips " IP(s) con " ?e4 "% de 4xx"))
      (conclusion "Patron de DDoS L7: escalar solo gastaria infraestructura sirviendo trafico basura. Se BLOQUEA el autoescalado.")))
   (assert (accion-escalado (servicio ?svc) (replicas-antes ?r) (replicas-despues ?r)
                            (direccion bloqueado)
                            (razon (str-cat "DDoS detectado (" ?rps " req/s, " ?e4 "% 4xx)"))))
   (assert (diagnostico
      (tipo ddos-bloqueo)
      (causa-raiz (str-cat "Ataque DDoS en el Ingress de " ?svc ": el pico NO es demanda "
                           "legitima. Autoescalado bloqueado para evitar gasto masivo."))
      (severidad alta))))

;;;----------------------------------------------------------
;;; AUTOESCALADO ARRIBA (salience baja = decide al final)
;;; Guarda: NO escalar si hay DDoS en curso.
;;;----------------------------------------------------------
(defrule CORRELACION::autoescalar-arriba
   (declare (salience 10))
   (ventana-carga (pagos-en-cola ?carga) (tope ?tope))
   ?s <- (servicio-pagos (nombre ?nom) (replicas ?r)
                         (replicas-max ?max) (capacidad-por-replica ?cap))
   (not (diagnostico (tipo ddos-bloqueo)))
   (test (and (< ?r ?max)
              (or (>= ?carga ?tope)
                  (> ?carga (* ?r ?cap)))))
   =>
   (bind ?nuevas (min ?max (replicas-necesarias ?carga ?cap)))
   (if (> ?nuevas ?r) then
      (modify ?s (replicas ?nuevas))
      (assert (accion-escalado (servicio ?nom) (replicas-antes ?r)
                               (replicas-despues ?nuevas) (direccion arriba)
                               (razon (str-cat "carga=" ?carga " tope=" ?tope))))
      (assert (justificacion
         (regla autoescalar-arriba)
         (premisa (str-cat "Carga " ?carga " alcanza el tope " ?tope
                           " (o supera la capacidad " (* ?r ?cap) " de " ?r " replica(s))"))
         (conclusion (str-cat "Demanda legitima por encima de capacidad: escalar de " ?r
                              " a " ?nuevas " replica(s)."))))
      (assert (diagnostico
         (tipo autoescalado-pagos)
         (causa-raiz (str-cat "La carga de pagos (" ?carga ") alcanzo el tope (" ?tope
                              "); el servicio " ?nom " necesita " ?nuevas " replica(s)."))
         (severidad media)))))

;;;----------------------------------------------------------
;;; AUTOESCALADO ABAJO (libera replicas si la carga bajo)
;;;----------------------------------------------------------
(defrule CORRELACION::autoescalar-abajo
   (declare (salience 10))
   (ventana-carga (pagos-en-cola ?carga) (tope ?tope))
   ?s <- (servicio-pagos (nombre ?nom) (replicas ?r)
                         (replicas-min ?min) (capacidad-por-replica ?cap))
   (not (diagnostico (tipo ddos-bloqueo)))
   (test (and (> ?r ?min)
              (< ?carga ?tope)
              (<= ?carga (* (- ?r 1) ?cap))))
   =>
   (bind ?nuevas (max ?min (replicas-necesarias ?carga ?cap)))
   (if (< ?nuevas ?r) then
      (modify ?s (replicas ?nuevas))
      (assert (accion-escalado (servicio ?nom) (replicas-antes ?r)
                               (replicas-despues ?nuevas) (direccion abajo)
                               (razon (str-cat "carga=" ?carga " bajo tope " ?tope))))
      (assert (justificacion
         (regla autoescalar-abajo)
         (premisa (str-cat "Carga " ?carga " por debajo de la capacidad de " (- ?r 1) " replica(s)"))
         (conclusion (str-cat "Sobra capacidad: reducir de " ?r " a " ?nuevas " replica(s) para ahorrar."))))
      (assert (diagnostico
         (tipo autoescalado-pagos)
         (causa-raiz (str-cat "La carga (" ?carga ") cabe en menos replicas; " ?nom
                              " baja de " ?r " a " ?nuevas "."))
         (severidad baja)))))

;;;----------------------------------------------------------
;;; CARGA ESTABLE (fallback: ni DDoS ni escalado)
;;; Garantiza que SIEMPRE haya un diagnostico que leer.
;;;----------------------------------------------------------
(defrule CORRELACION::carga-estable
   (declare (salience 5))
   (ventana-carga (pagos-en-cola ?carga) (tope ?tope))
   (servicio-pagos (nombre ?nom) (replicas ?r))
   (not (accion-escalado))
   (not (diagnostico))
   =>
   (assert (justificacion
      (regla carga-estable)
      (premisa (str-cat "Carga " ?carga " dentro de capacidad y sin tope alcanzado (tope " ?tope ")"))
      (conclusion "No se requiere accion de escalado: el servicio esta dimensionado para la carga actual.")))
   (assert (diagnostico
      (tipo carga-estable)
      (causa-raiz (str-cat "Carga " ?carga " estable bajo el tope " ?tope "; " ?nom
                           " se mantiene en " ?r " replica(s)."))
      (severidad baja))))


;;;==========================================================
;;; FASE MITIGACION
;;; Convierte cada veredicto en un plan de accion (comandos kubectl).
;;;==========================================================

;;;----------------------------------------------------------
;;; MITIGACION: autoescalado (arriba o abajo)
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-autoescalado
   ?d <- (diagnostico (tipo autoescalado-pagos) (comandos))
   (accion-escalado (servicio ?svc) (replicas-antes ?r) (replicas-despues ?n) (direccion ?dir))
   =>
   (modify ?d (comandos
      (str-cat "kubectl scale deployment/" ?svc " --replicas=" ?n "   # " ?dir ": " ?r " -> " ?n)
      (str-cat "kubectl get hpa " ?svc " -w        # observar la convergencia del autoscaler")
      (str-cat "kubectl get deployment/" ?svc " -o wide   # confirmar replicas listas"))))

;;;----------------------------------------------------------
;;; MITIGACION: DDoS -> NO escalar, contener en el Ingress
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-ddos
   ?d <- (diagnostico (tipo ddos-bloqueo) (comandos))
   (ingress (servicio ?svc))
   =>
   (modify ?d (comandos
      (str-cat "kubectl annotate ingress " ?svc " nginx.ingress.kubernetes.io/limit-rps=\"20\" --overwrite   # rate-limit L7")
      (str-cat "kubectl annotate ingress " ?svc " nginx.ingress.kubernetes.io/limit-connections=\"10\" --overwrite")
      (str-cat "kubectl patch hpa " ?svc " -p '{\"spec\":{\"maxReplicas\":1}}'   # congelar el autoescalado")
      "# NO escalar el deployment: el pico es trafico de ataque, no demanda real.")))

;;;----------------------------------------------------------
;;; MITIGACION: carga estable -> sin accion
;;;----------------------------------------------------------
(defrule MITIGACION::mitigar-carga-estable
   ?d <- (diagnostico (tipo carga-estable) (comandos))
   =>
   (modify ?d (comandos
      "kubectl get deployment/pago-movil-svc -o wide   # estado actual, sin cambios"
      "# Sin accion: la capacidad cubre la carga; seguir monitoreando la ventana.")))

;;;----------------------------------------------------------
;;; REPORTE FINAL (salience muy baja: corre tras llenar comandos)
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
;;; Recorre los hechos 'justificacion' que cada regla dejo y los
;;; presenta como arbol de deduccion (regla -> premisa -> conclusion).
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


;;;==========================================================
;;; ESTADO INICIAL
;;;==========================================================
(deffacts MAIN::estado-inicial
   (servicio-pagos (nombre "pago-movil-svc") (replicas 1)
                   (replicas-min 1) (replicas-max 10) (capacidad-por-replica 50))
   (ventana-carga (pagos-en-cola 0) (carga-extra 0) (tope 100))
   (ingress (servicio "pago-movil-svc") (requests-por-seg 0) (tasa-4xx 0)
            (ips-distintas 1) (ataque desconocido)))
