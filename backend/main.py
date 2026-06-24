# -*- coding: utf-8 -*-
"""API FastAPI sobre el motor CLIPS K8s-ExpertAdvisor.

Endpoints:
    POST /diagnosticar          -> telemetria de las 3 capas (sistema K8s).
    GET  /por-que               -> arbol de deduccion del ultimo diagnostico K8s.
    POST /pago-movil/diagnosticar -> pagos + config de autoescalado.
    GET  /pago-movil/por-que    -> arbol de deduccion del ultimo diagnostico de pagos.
    GET  /salud                 -> healthcheck (para Render).
"""
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from motor import diagnosticar, ErrorTelemetria
from motor_pagos import (
    diagnosticar as diagnosticar_pagos,
    ErrorTelemetria as ErrorTelemetriaPagos,
)

app = FastAPI(
    title="K8s-ExpertAdvisor",
    description="Sistema experto CLIPS para diagnostico de crisis en Kubernetes.",
    version="1.0.0",
)

# El front (React) corre en otro origen; habilitamos CORS abierto
# (es una demo academica; en produccion se restringe a la URL del front).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Cache del ultimo resultado para servir GET /por-que sin re-ejecutar.
_ultimo: dict = {"diagnosticos": [], "justificaciones": []}
_ultimo_pagos: dict = {"diagnosticos": [], "justificaciones": []}


# ----- Modelos de telemetria (3 capas) -----
class Contenedor(BaseModel):
    id: str
    estado: str
    cpu_pct: Optional[int] = None
    mem_pct: Optional[int] = None
    liveness: Optional[str] = None
    readiness: Optional[str] = None
    conexiones: Optional[int] = None


class Nodo(BaseModel):
    id: str
    estado: str
    presion: Optional[str] = None


class Pod(BaseModel):
    id: str
    estado: str
    nodo: Optional[str] = None


class Hpa(BaseModel):
    objetivo: str
    escalando: Optional[str] = None
    replicas_actuales: Optional[int] = None
    replicas_max: Optional[int] = None


class Volumen(BaseModel):
    id: str
    estado: str
    uso_pct: Optional[int] = None


class ControlPlane(BaseModel):
    saturado: str


class Trafico(BaseModel):
    servicio: str
    latencia_p95: Optional[int] = None
    latencia_p99: Optional[int] = None
    tasa_5xx: Optional[int] = None
    tasa_4xx: Optional[int] = None


class Red(BaseModel):
    coredns_saturado: Optional[str] = None
    saturacion_pct: Optional[int] = None


class Telemetria(BaseModel):
    contenedores: list[Contenedor] = Field(default_factory=list)
    nodos: list[Nodo] = Field(default_factory=list)
    pods: list[Pod] = Field(default_factory=list)
    hpas: list[Hpa] = Field(default_factory=list)
    volumenes: list[Volumen] = Field(default_factory=list)
    control_plane: Optional[ControlPlane] = None
    traficos: list[Trafico] = Field(default_factory=list)
    red: Optional[Red] = None


@app.get("/salud")
def salud():
    return {"estado": "ok"}


@app.post("/diagnosticar")
def post_diagnosticar(tele: Telemetria):
    global _ultimo
    try:
        resultado = diagnosticar(tele.model_dump())
    except ErrorTelemetria as e:
        # Telemetria invalida: el motor la rechazo (range/allowed-symbols).
        raise HTTPException(status_code=422, detail=str(e))
    _ultimo = resultado
    return resultado


@app.get("/por-que")
def get_por_que():
    return {"justificaciones": _ultimo["justificaciones"]}


# ----- Modelos de Pago Movil + Autoescalado -----
class Pago(BaseModel):
    id: str
    telefono: str = ""
    nombre: str = ""
    tipo_documento: str = "V"
    documento: str = ""
    monto: float = 0.0


class Servicio(BaseModel):
    nombre: str = "pago-movil-svc"
    replicas: int = 1
    replicas_min: int = 1
    replicas_max: int = 10
    capacidad_por_replica: int = 50


class Ventana(BaseModel):
    tope: int = 100
    carga_extra: int = 0  # pico simulado adicional en cola


class Ingress(BaseModel):
    servicio: str = "pago-movil-svc"
    requests_por_seg: int = 0
    tasa_4xx: int = 0
    ips_distintas: int = 1
    ataque: str = "desconocido"  # si | no | desconocido


class EntradaPagos(BaseModel):
    pagos: list[Pago] = Field(default_factory=list)
    servicio: Servicio = Field(default_factory=Servicio)
    ventana: Ventana = Field(default_factory=Ventana)
    ingress: Ingress = Field(default_factory=Ingress)


@app.post("/pago-movil/diagnosticar")
def post_diagnosticar_pagos(entrada: EntradaPagos):
    global _ultimo_pagos
    try:
        resultado = diagnosticar_pagos(entrada.model_dump())
    except ErrorTelemetriaPagos as e:
        raise HTTPException(status_code=422, detail=str(e))
    _ultimo_pagos = resultado
    return resultado


@app.get("/pago-movil/por-que")
def get_por_que_pagos():
    return {"justificaciones": _ultimo_pagos["justificaciones"]}
