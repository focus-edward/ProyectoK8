/* ==========================================================
 * clips-assert.js
 * Builder de asserts CLIPS + espejo de las reglas del motor
 * (pago-movil-autoescalado.clp), compartido por:
 *   - pago-movil-autoescalado.html  (demo client-only, sin backend)
 *   - cualquier otro front que quiera previsualizar los hechos
 *
 * NO reimplementa el sistema experto: replica la MISMA logica del
 * .clp para mostrar, sin servidor, que hechos se enviarian y que
 * decidiria el motor. La verdad ultima la tiene el backend CLIPS.
 *
 * Se carga como <script src="clips-assert.js"></script> (script
 * clasico) para que el HTML siga abriendose con file:// sin choques
 * de CORS de modulos ES. Expone window.ClipsAssert; y si corre bajo
 * CommonJS (Node/tests) tambien hace module.exports.
 * ========================================================== */
(function (root) {
  'use strict';

  /* ---------- escape / render de slots ---------- */
  function clipsStr(v) {
    return '"' + String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  }

  // Render de un FLOAT de CLIPS: el slot 'monto' exige decimal.
  function clipsFloat(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n.toFixed(1) : '0.0';
  }

  function slot(name, value, opts) {
    opts = opts || {};
    const empty = value === undefined || value === null || String(value).trim() === '';
    if (empty) {
      if (opts.required) throw new Error('Campo requerido vacio: ' + name);
      return '';
    }
    let render = value;
    if (opts.quote) render = clipsStr(value);
    else if (opts.float) render = clipsFloat(value);
    return '(' + name + ' ' + render + ')';
  }

  // (pago-movil ...) tal cual lo asserta el backend / la consola.
  function buildPagoMovil(p) {
    const s = [
      slot('id', p.id, { required: true }),
      slot('numero-telefono', p.telefono, { quote: true, required: true }),
      slot('nombre', p.nombre, { quote: true, required: true }),
      slot('tipo-documento', p.tipoDoc || p.tipo_documento, { required: true }),
      slot('documento', p.documento, { quote: true, required: true }),
      slot('monto', p.monto || 0, { float: true }),
    ].filter(Boolean).join(' ');
    return '(pago-movil ' + s + ')';
  }

  /* ---------- espejo de las reglas del .clp ---------- */

  // CORRELACION::validar-telefono-invalido / validar-pago-ok
  function telefonoValido(t) {
    return /^(0412|0414|0416|0424|0426)\d{7}$/.test(String(t).trim());
  }

  // deffunction replicas-necesarias: ceil(carga/cap), minimo 1
  function replicasNecesarias(carga, cap) {
    return Math.max(1, Math.ceil(carga / cap));
  }

  // CORRELACION::detectar-ddos
  // Dispara por bandera explicita (ataque === 'si') o por la firma
  // clasica de un DDoS L7: req/s > 5*(replicas*cap), 4xx alto, pocas IPs.
  function detectarDDoS(ingress, svc) {
    if (!ingress) return { ddos: false };
    const rps = +ingress.requests_por_seg || 0;
    const e4 = +ingress.tasa_4xx || 0;
    const ips = +ingress.ips_distintas || 1;
    const explicito = ingress.ataque === 'si';
    const firma = rps > 5 * svc.replicas * svc.cap && e4 >= 40 && ips <= 5;
    if (explicito || firma) {
      return {
        ddos: true,
        razon: `ataque=${ingress.ataque}, ${rps} req/s desde ${ips} IP(s) con ${e4}% de 4xx`,
      };
    }
    return { ddos: false };
  }

  // CORRELACION: detectar-ddos -> autoescalar-arriba/abajo -> carga-estable
  // Devuelve el veredicto normalizado (mismo 'tipo' que el diagnostico CLIPS).
  function decidir(carga, svc, ingress) {
    const r = svc.replicas, max = svc.max, cap = svc.cap, tope = svc.tope;

    const d = detectarDDoS(ingress, svc);
    if (d.ddos) {
      return { tipo: 'ddos-bloqueo', nuevas: r, dir: 'bloqueado', razon: d.razon };
    }
    // autoescalar-arriba
    if (r < max && (carga >= tope || carga > r * cap)) {
      const n = Math.min(max, replicasNecesarias(carga, cap));
      if (n > r) return { tipo: 'autoescalado-pagos', nuevas: n, dir: 'arriba', razon: `carga=${carga} tope=${tope}` };
    }
    // autoescalar-abajo
    if (r > (svc.min || 1) && carga < tope && carga <= (r - 1) * cap) {
      const n = Math.max(svc.min || 1, replicasNecesarias(carga, cap));
      if (n < r) return { tipo: 'autoescalado-pagos', nuevas: n, dir: 'abajo', razon: `carga=${carga} bajo tope ${tope}` };
    }
    // carga-estable
    return { tipo: 'carga-estable', nuevas: r, dir: null, razon: `carga=${carga} dentro de capacidad (tope ${tope})` };
  }

  const api = {
    clipsStr, clipsFloat, slot, buildPagoMovil,
    telefonoValido, replicasNecesarias, detectarDDoS, decidir,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.ClipsAssert = api;
})(typeof window !== 'undefined' ? window : globalThis);
