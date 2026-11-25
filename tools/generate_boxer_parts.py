"""Separa los brazos de los OBJ originales conservando índices y materiales.
Ejecutar desde cualquier directorio: python tools/generate_boxer_parts.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Texturas"
ARM_PARTS = {"hombro", "brazo", "codo", "antebrazo", "muneca", "guante", "pulgar"}


def split(model):
    source = ROOT / ("boxeador_" + model + ".obj")
    geometry = []
    objects = {"body": [], "left_arm": [], "right_arm": []}
    current = "body"
    for line in source.read_text(encoding="utf-8").splitlines():
        if line.startswith(("v ", "vt ", "vn ")):
            geometry.append(line)
        elif line.startswith("o "):
            name = line[2:]
            pieces = name.rsplit("_", 1)
            current = "body"
            if len(pieces) == 2 and pieces[0] in ARM_PARTS:
                current = "left_arm" if pieces[1] == "L" else "right_arm"
            objects[current].append(line)
        elif line.startswith(("f ", "usemtl ", "s ")):
            objects[current].append(line)
    for part, faces in objects.items():
        output = ["# Generado desde " + source.name, "mtllib boxeador_" + model + ".mtl"] + geometry + faces
        (ROOT / ("boxeador_" + model + "_" + part + ".obj")).write_text("\n".join(output) + "\n", encoding="utf-8")


if __name__ == "__main__":
    for model in ("torpe", "estratega"):
        split(model)
