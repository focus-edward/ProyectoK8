# -*- coding: utf-8 -*-
"""Prueba de los endpoints FastAPI sin levantar el servidor (TestClient)."""
import sys
from pathlib import Path

# el backend importa 'motor' como modulo hermano
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

from fastapi.testclient import TestClient
from main import app

cli = TestClient(app)


def main():
    sys.stdout.reconfigure(encoding="utf-8")

    # salud
    r = cli.get("/salud")
    assert r.status_code == 200 and r.json()["estado"] == "ok"
    print("[PASS] /salud")

    # diagnostico: cascada OOM
    payload = {
        "contenedores": [{"id": "api", "estado": "OOMKilled", "mem_pct": 100}],
        "traficos": [{"servicio": "checkout", "tasa_5xx": 30, "latencia_p99": 4500}],
    }
    r = cli.post("/diagnosticar", json=payload)
    assert r.status_code == 200, r.text
    data = r.json()
    tipos = [d["tipo"] for d in data["diagnosticos"]]
    assert "cascada-oom" in tipos, tipos
    assert data["justificaciones"], "sin justificaciones"
    print("[PASS] POST /diagnosticar -> cascada-oom")
    print("       comandos:", data["diagnosticos"][0]["comandos"][0])

    # por-que refleja el ultimo diagnostico
    r = cli.get("/por-que")
    assert r.status_code == 200
    assert any(j["regla"] == "cascada-oom" for j in r.json()["justificaciones"])
    print("[PASS] GET /por-que")

    # autoescalado por demanda legitima (HPA)
    r = cli.post("/diagnosticar", json={
        "hpas": [{"objetivo": "pago-movil-api", "escalando": "no", "replicas_actuales": 2,
                  "replicas_min": 1, "replicas_max": 10, "cpu_actual": 92, "cpu_objetivo": 70}]
    })
    assert r.status_code == 200, r.text
    assert "autoescalado-demanda" in [d["tipo"] for d in r.json()["diagnosticos"]]
    print("[PASS] POST /diagnosticar -> autoescalado-demanda")

    # DDoS en el Ingress bloquea el autoescalado
    r = cli.post("/diagnosticar", json={
        "ingress": [{"servicio": "pago-movil-api", "requests_por_seg": 9000, "tasa_4xx": 70, "ips_distintas": 3, "ataque": "si"}],
        "hpas": [{"objetivo": "pago-movil-api", "escalando": "no", "replicas_actuales": 2,
                  "replicas_min": 1, "replicas_max": 10, "cpu_actual": 95, "cpu_objetivo": 70}]
    })
    assert r.status_code == 200, r.text
    tipos = [d["tipo"] for d in r.json()["diagnosticos"]]
    assert "ddos-bloqueo" in tipos and "autoescalado-demanda" not in tipos, tipos
    print("[PASS] POST /diagnosticar -> ddos-bloqueo (autoescalado bloqueado)")

    # validacion: cpu fuera de rango -> 422
    r = cli.post("/diagnosticar", json={
        "contenedores": [{"id": "mal", "estado": "Running", "cpu_pct": 150}]
    })
    assert r.status_code == 422, f"esperaba 422, fue {r.status_code}"
    print("[PASS] POST /diagnosticar cpu=150 -> 422 (validacion)")

    print("\nAPI OK.")


if __name__ == "__main__":
    main()
