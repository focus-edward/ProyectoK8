# -*- coding: utf-8 -*-
"""Regresion del modulo Pago Movil + Autoescalado.

Prueba los endpoints /pago-movil/* (que ejecutan pago-movil-autoescalado.clp
via clipspy) cubriendo los 4 veredictos del motor:
    carga-estable | autoescalado-pagos | ddos-bloqueo | (validacion)

Uso:
    python tests/test_pagos.py
"""
import sys
from pathlib import Path

# el backend importa 'motor'/'motor_pagos' como modulos hermanos
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

from fastapi.testclient import TestClient
from main import app

cli = TestClient(app)

SVC = {"replicas": 1, "replicas_min": 1, "replicas_max": 10, "capacidad_por_replica": 50}


def diag(payload):
    r = cli.post("/pago-movil/diagnosticar", json=payload)
    assert r.status_code == 200, r.text
    return r.json()


def main():
    sys.stdout.reconfigure(encoding="utf-8")

    # 1) dia normal -> carga-estable (2 validos, sin tope)
    d = diag({
        "pagos": [
            {"id": "pg1", "telefono": "04141234567", "nombre": "Juan", "tipo_documento": "V", "documento": "V12345678", "monto": 150},
            {"id": "pg2", "telefono": "04241112233", "nombre": "Inv CA", "tipo_documento": "J", "documento": "J402015558", "monto": 980},
        ],
        "servicio": SVC, "ventana": {"tope": 100, "carga_extra": 0},
    })
    tipos = [x["tipo"] for x in d["diagnosticos"]]
    assert "carga-estable" in tipos, tipos
    assert d["pagos"]["validos"] == 2 and d["pagos"]["rechazados"] == 0
    print("[PASS] dia normal -> carga-estable")

    # 2) pico -> autoescalado-pagos (1 valido + 130 extra = 131 >= tope)
    d = diag({
        "pagos": [{"id": "pg1", "telefono": "04141234567", "nombre": "Demo", "tipo_documento": "V", "documento": "V1", "monto": 100}],
        "servicio": SVC, "ventana": {"tope": 100, "carga_extra": 130},
    })
    assert "autoescalado-pagos" in [x["tipo"] for x in d["diagnosticos"]]
    acc = d["acciones"][0]
    assert acc["direccion"] == "arriba" and acc["replicas_despues"] == 3, acc
    print("[PASS] pico -> autoescalado-pagos (1 -> 3 replicas)")

    # 3) DDoS -> ddos-bloqueo (misma carga, pero ataque: NO escala)
    d = diag({
        "pagos": [{"id": "pg1", "telefono": "04141234567", "nombre": "Demo", "tipo_documento": "V", "documento": "V1", "monto": 100}],
        "servicio": SVC, "ventana": {"tope": 100, "carga_extra": 130},
        "ingress": {"ataque": "si", "requests_por_seg": 9000, "tasa_4xx": 70, "ips_distintas": 3},
    })
    tipos = [x["tipo"] for x in d["diagnosticos"]]
    assert "ddos-bloqueo" in tipos and "autoescalado-pagos" not in tipos, tipos
    assert d["acciones"][0]["direccion"] == "bloqueado"
    print("[PASS] DDoS -> ddos-bloqueo (autoescalado bloqueado)")

    # 4) DDoS por firma (sin bandera explicita: req/s, 4xx, pocas IPs)
    d = diag({
        "pagos": [{"id": "pg1", "telefono": "04141234567", "nombre": "Demo", "tipo_documento": "V", "documento": "V1", "monto": 100}],
        "servicio": SVC, "ventana": {"tope": 100, "carga_extra": 130},
        "ingress": {"ataque": "desconocido", "requests_por_seg": 9000, "tasa_4xx": 70, "ips_distintas": 3},
    })
    assert "ddos-bloqueo" in [x["tipo"] for x in d["diagnosticos"]]
    print("[PASS] DDoS por firma -> ddos-bloqueo")

    # 5) validacion: telefonos invalidos -> rechazados, carga 0
    d = diag({
        "pagos": [
            {"id": "pg1", "telefono": "123", "nombre": "Malo", "tipo_documento": "V", "documento": "V1"},
            {"id": "pg2", "telefono": "05001234567", "nombre": "SinPrefijo", "tipo_documento": "J", "documento": "J9"},
        ],
        "servicio": SVC, "ventana": {"tope": 100, "carga_extra": 0},
    })
    assert d["pagos"]["rechazados"] == 2 and d["pagos"]["validos"] == 0, d["pagos"]
    assert any(j["regla"] == "validar-telefono-invalido" for j in d["justificaciones"])
    print("[PASS] validacion -> 2 telefonos rechazados")

    # 6) por-que refleja el ultimo diagnostico
    r = cli.get("/pago-movil/por-que")
    assert r.status_code == 200 and r.json()["justificaciones"], r.text
    print("[PASS] GET /pago-movil/por-que")

    print("\nPAGO MOVIL OK.")


if __name__ == "__main__":
    main()
