# -*- coding: utf-8 -*-
"""Regresion del motor CLIPS vía clipspy.

Carga el MISMO k8s_expert_advisor.clp que usa el backend y verifica
los 3 escenarios heuristicos + la validacion de entradas.

Uso:
    python tests/test_motor.py        # imprime el detalle de cada escenario
"""
import sys
from pathlib import Path

import clips

# raiz del repo = carpeta padre de /tests
RAIZ = Path(__file__).resolve().parent.parent
CLP = RAIZ / "k8s_expert_advisor.clp"


def nuevo_entorno():
    env = clips.Environment()
    env.load(str(CLP))      # si hay error de sintaxis, revienta aqui
    env.reset()
    return env


def diagnosticos(env):
    return [f for f in env.facts() if f.template.name == "diagnostico"]


def justificaciones(env):
    return [f for f in env.facts() if f.template.name == "justificacion"]


def correr(asserts):
    env = nuevo_entorno()
    for a in asserts:
        env.assert_string(a)
    env.eval("(focus CORRELACION MITIGACION)")
    env.run()
    return env


def escenario(titulo, asserts, tipo_esperado):
    print("\n" + "=" * 60)
    print("ESCENARIO:", titulo)
    print("=" * 60)
    env = correr(asserts)
    diags = diagnosticos(env)
    assert diags, "no se genero ningun diagnostico"
    tipos = [str(d["tipo"]) for d in diags]
    assert tipo_esperado in tipos, f"esperaba {tipo_esperado}, obtuve {tipos}"

    for d in diags:
        print("  DIAGNOSTICO tipo =", d["tipo"], "| severidad =", d["severidad"])
        print("    causa-raiz:", d["causa-raiz"])
        for c in d["comandos"]:
            print("      $", c)
    assert justificaciones(env), "no se genero justificacion (por-que vacio)"
    print("  [PASS]", tipo_esperado)


def test_validacion_rango():
    print("\n" + "=" * 60)
    print("VALIDACION: cpu-pct=150 (fuera de range 0-100)")
    print("=" * 60)
    env = nuevo_entorno()
    try:
        env.assert_string("(contenedor (id mal) (estado Running) (cpu-pct 150))")
    except clips.CLIPSError:
        print("  [PASS] rechazado por la restriccion de slot")
        return
    raise AssertionError("NO rechazo el cpu-pct=150 invalido")


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    escenario("Cascada por OOMKilled", [
        "(contenedor (id api) (estado OOMKilled) (mem-pct 100))",
        "(trafico (servicio checkout) (tasa-5xx 30) (latencia-p99 4500))",
    ], "cascada-oom")

    escenario("Falsa alarma de CPU", [
        "(contenedor (id worker) (estado Running) (cpu-pct 98))",
        "(nodo (id node-1) (estado Ready) (presion MemoryPressure))",
    ], "cpu-falsa-alarma")

    escenario("Fuga de conexiones", [
        "(contenedor (id gateway) (estado CrashLoopBackOff) (cpu-pct 40) (conexiones 8000))",
    ], "fuga-conexiones")

    test_validacion_rango()
    print("\nTODOS LOS ESCENARIOS PASARON.")


if __name__ == "__main__":
    main()
