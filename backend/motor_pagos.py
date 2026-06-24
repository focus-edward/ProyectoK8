# -*- coding: utf-8 -*-
"""Capa de acceso al motor CLIPS de Pago Movil + Autoescalado.

Ejecuta el MISMO pago-movil-autoescalado.clp del IDE (igual que motor.py
hace con k8s_expert_advisor.clp). No reimplementa logica: asserta los
hechos, dispara CORRELACION -> MITIGACION y lee los hechos resultantes.

A diferencia del sistema grande, este .clp trae un (deffacts) con los
singletons servicio-pagos / ventana-carga / ingress (para correr en el
IDE). En modo web reemplazamos esos singletons por la config del request
para que no haya hechos duplicados.

Se crea un Environment NUEVO por diagnostico. Los hechos se leen SIEMPRE
a datos planos dentro de la funcion: devolver objetos Fact que apunten a
un Environment ya recolectado hace segfault a clipspy.
"""
from pathlib import Path
from typing import Any

import clips

RAIZ = Path(__file__).resolve().parent.parent
CLP = RAIZ / "pago-movil-autoescalado.clp"

SINGLETONS = ("servicio-pagos", "ventana-carga", "ingress")


class ErrorTelemetria(Exception):
    """Hecho que el motor rechaza (viola range / allowed-symbols)."""


def _entorno() -> clips.Environment:
    env = clips.Environment()
    env.load(str(CLP))
    env.reset()  # crea los singletons del (deffacts)
    return env


def _clips_str(v: Any) -> str:
    """Escapa un valor como STRING de CLIPS: \"...\"."""
    s = str(v).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'


def _float(v: Any) -> str:
    """Render de un FLOAT de CLIPS (el slot monto es FLOAT, exige decimal)."""
    try:
        return repr(float(v))
    except (TypeError, ValueError):
        return "0.0"


def _reemplazar(env: clips.Environment, template: str, assert_str: str) -> None:
    """Retracta el singleton del deffacts y asserta el del request."""
    for f in list(env.facts()):
        if f.template.name == template:
            f.retract()
    env.assert_string(assert_str)


def _assert_pago(env: clips.Environment, p: dict[str, Any]) -> None:
    partes = [
        f"(id {p['id']})",
        f"(numero-telefono {_clips_str(p.get('telefono', ''))})",
        f"(nombre {_clips_str(p.get('nombre', ''))})",
        f"(tipo-documento {p.get('tipo_documento', 'V')})",
        f"(documento {_clips_str(p.get('documento', ''))})",
        f"(monto {_float(p.get('monto', 0))})",
    ]
    env.assert_string(f"(pago-movil {' '.join(partes)})")


def _construir(env: clips.Environment, datos: dict[str, Any]) -> None:
    """Vuelca el request (config + pagos) en hechos CLIPS."""
    s = datos.get("servicio") or {}
    _reemplazar(env, "servicio-pagos",
        f'(servicio-pagos (nombre {_clips_str(s.get("nombre", "pago-movil-svc"))}) '
        f'(replicas {int(s.get("replicas", 1))}) '
        f'(replicas-min {int(s.get("replicas_min", 1))}) '
        f'(replicas-max {int(s.get("replicas_max", 10))}) '
        f'(capacidad-por-replica {int(s.get("capacidad_por_replica", 50))}))')

    v = datos.get("ventana") or {}
    _reemplazar(env, "ventana-carga",
        f'(ventana-carga (pagos-en-cola 0) '
        f'(carga-extra {int(v.get("carga_extra", 0))}) '
        f'(tope {int(v.get("tope", 100))}))')

    g = datos.get("ingress") or {}
    _reemplazar(env, "ingress",
        f'(ingress (servicio {_clips_str(g.get("servicio", "pago-movil-svc"))}) '
        f'(requests-por-seg {int(g.get("requests_por_seg", 0))}) '
        f'(tasa-4xx {int(g.get("tasa_4xx", 0))}) '
        f'(ips-distintas {int(g.get("ips_distintas", 1))}) '
        f'(ataque {g.get("ataque", "desconocido")}))')

    for p in datos.get("pagos", []):
        _assert_pago(env, p)


def _leer_diagnosticos(env: clips.Environment) -> list[dict[str, Any]]:
    out = []
    for f in env.facts():
        if f.template.name == "diagnostico":
            out.append({
                "tipo": str(f["tipo"]),
                "severidad": str(f["severidad"]),
                "causa_raiz": str(f["causa-raiz"]),
                "comandos": [str(c) for c in f["comandos"]],
            })
    return out


def _leer_acciones(env: clips.Environment) -> list[dict[str, Any]]:
    out = []
    for f in env.facts():
        if f.template.name == "accion-escalado":
            out.append({
                "servicio": str(f["servicio"]),
                "replicas_antes": int(f["replicas-antes"]),
                "replicas_despues": int(f["replicas-despues"]),
                "direccion": str(f["direccion"]),
                "razon": str(f["razon"]),
            })
    return out


def _leer_pagos(env: clips.Environment) -> dict[str, int]:
    validos = rechazados = 0
    for f in env.facts():
        if f.template.name == "pago-movil":
            est = str(f["estado"])
            if est == "validado":
                validos += 1
            elif est == "rechazado":
                rechazados += 1
    return {"validos": validos, "rechazados": rechazados}


def _leer_carga(env: clips.Environment) -> dict[str, int]:
    for f in env.facts():
        if f.template.name == "ventana-carga":
            return {"pagos_en_cola": int(f["pagos-en-cola"]), "tope": int(f["tope"])}
    return {"pagos_en_cola": 0, "tope": 0}


def _leer_justificaciones(env: clips.Environment) -> list[dict[str, Any]]:
    out = []
    for f in env.facts():
        if f.template.name == "justificacion":
            out.append({
                "regla": str(f["regla"]),
                "premisa": str(f["premisa"]),
                "conclusion": str(f["conclusion"]),
            })
    return out


def diagnosticar(datos: dict[str, Any]) -> dict[str, Any]:
    """Punto de entrada: config + pagos -> diagnostico + accion + por-que."""
    env = _entorno()
    try:
        _construir(env, datos)
    except clips.CLIPSError as e:
        raise ErrorTelemetria(f"Hecho rechazado por el motor: {e}")

    env.eval("(focus CORRELACION MITIGACION)")
    env.run()

    return {
        "diagnosticos": _leer_diagnosticos(env),
        "acciones": _leer_acciones(env),
        "pagos": _leer_pagos(env),
        "carga": _leer_carga(env),
        "justificaciones": _leer_justificaciones(env),
    }
