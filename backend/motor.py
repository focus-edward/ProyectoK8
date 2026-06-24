# -*- coding: utf-8 -*-
"""Capa de acceso al motor CLIPS (clipspy).

Ejecuta el MISMO k8s_expert_advisor.clp del IDE. No reimplementa
logica: solo aserta la telemetria como hechos, dispara las fases
CORRELACION -> MITIGACION y lee los hechos resultantes.

Se crea un Environment NUEVO por cada diagnostico para no arrastrar
estado entre peticiones (el motor CLIPS es stateful).
"""
from pathlib import Path
from typing import Any

import clips

# raiz del repo = carpeta padre de /backend
RAIZ = Path(__file__).resolve().parent.parent
CLP = RAIZ / "k8s_expert_advisor.clp"


class ErrorTelemetria(Exception):
    """Telemetria que el motor rechaza (viola range / allowed-symbols)."""


def _entorno() -> clips.Environment:
    env = clips.Environment()
    env.load(str(CLP))
    env.reset()
    return env


def _slot(nombre: str, valor: Any) -> str:
    """Render de un slot CLIPS. Los valores ya son simbolos/enteros
    validos; el deftemplate hace la validacion final al asertar."""
    return f"({nombre} {valor})"


def _hecho(template: str, slots: dict[str, Any]) -> str:
    partes = [_slot(k, v) for k, v in slots.items() if v is not None]
    return f"({template} {' '.join(partes)})"


def construir_asserts(tele: dict[str, Any]) -> list[str]:
    """Convierte el dict de telemetria (3 capas) en strings (assert ...).

    Mapea snake_case del JSON a los nombres de slot con guion del .clp.
    Cada entidad puede venir como lista; los slots ausentes usan el
    default del deftemplate.
    """
    asserts: list[str] = []

    for c in tele.get("contenedores", []):
        asserts.append(_hecho("contenedor", {
            "id": c.get("id"),
            "estado": c.get("estado"),
            "cpu-pct": c.get("cpu_pct"),
            "mem-pct": c.get("mem_pct"),
            "liveness": c.get("liveness"),
            "readiness": c.get("readiness"),
            "conexiones": c.get("conexiones"),
        }))

    for n in tele.get("nodos", []):
        asserts.append(_hecho("nodo", {
            "id": n.get("id"),
            "estado": n.get("estado"),
            "presion": n.get("presion"),
        }))

    for p in tele.get("pods", []):
        asserts.append(_hecho("pod", {
            "id": p.get("id"),
            "estado": p.get("estado"),
            "nodo": p.get("nodo"),
        }))

    for h in tele.get("hpas", []):
        asserts.append(_hecho("hpa", {
            "objetivo": h.get("objetivo"),
            "escalando": h.get("escalando"),
            "replicas-actuales": h.get("replicas_actuales"),
            "replicas-min": h.get("replicas_min"),
            "replicas-max": h.get("replicas_max"),
            "cpu-actual": h.get("cpu_actual"),
            "cpu-objetivo": h.get("cpu_objetivo"),
        }))

    for v in tele.get("volumenes", []):
        asserts.append(_hecho("volumen", {
            "id": v.get("id"),
            "estado": v.get("estado"),
            "uso-pct": v.get("uso_pct"),
        }))

    cp = tele.get("control_plane")
    if cp is not None:
        asserts.append(_hecho("control-plane", {"saturado": cp.get("saturado")}))

    for t in tele.get("traficos", []):
        asserts.append(_hecho("trafico", {
            "servicio": t.get("servicio"),
            "latencia-p95": t.get("latencia_p95"),
            "latencia-p99": t.get("latencia_p99"),
            "tasa-5xx": t.get("tasa_5xx"),
            "tasa-4xx": t.get("tasa_4xx"),
        }))

    r = tele.get("red")
    if r is not None:
        asserts.append(_hecho("red", {
            "coredns-saturado": r.get("coredns_saturado"),
            "saturacion-pct": r.get("saturacion_pct"),
        }))

    for g in tele.get("ingress", []):
        asserts.append(_hecho("ingress", {
            "servicio": g.get("servicio"),
            "requests-por-seg": g.get("requests_por_seg"),
            "tasa-4xx": g.get("tasa_4xx"),
            "ips-distintas": g.get("ips_distintas"),
            "ataque": g.get("ataque"),
        }))

    return asserts


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


def diagnosticar(tele: dict[str, Any]) -> dict[str, Any]:
    """Punto de entrada: telemetria -> diagnostico + arbol de deduccion."""
    env = _entorno()
    for a in construir_asserts(tele):
        try:
            env.assert_string(a)
        except clips.CLIPSError as e:
            raise ErrorTelemetria(f"Hecho rechazado por el motor: {a} -> {e}")

    env.eval("(focus CORRELACION MITIGACION)")
    env.run()

    return {
        "diagnosticos": _leer_diagnosticos(env),
        "justificaciones": _leer_justificaciones(env),
    }
