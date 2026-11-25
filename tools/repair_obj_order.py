"""Ordena datos de vértices antes de las caras para el importador OBJ de Godot.
Conserva geometría, grupos y materiales. Convierte índices negativos a absolutos.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Texturas"


def repair(path):
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    counts = [0, 0, 0]
    geometry = []
    objects = []
    header = []
    for line in lines:
        kind = line.split(" ", 1)[0]
        if kind in ("v", "vt", "vn"):
            counts[("v", "vt", "vn").index(kind)] += 1
            geometry.append(line)
        elif kind == "mtllib" or line.startswith("#"):
            header.append(line)
        elif kind == "f":
            face = []
            for vertex in line.split()[1:]:
                indices = vertex.split("/")
                for i, value in enumerate(indices):
                    if value and int(value) < 0:
                        indices[i] = str(counts[i] + int(value) + 1)
                face.append("/".join(indices))
            objects.append("f " + " ".join(face))
        else:
            objects.append(line)
    for line in objects:
        if line.startswith("f "):
            for vertex in line.split()[1:]:
                for i, value in enumerate(vertex.split("/")):
                    if value and not 1 <= int(value) <= counts[i]:
                        raise ValueError(f"Índice fuera de rango en {path.name}: {vertex}")
    path.write_text("\n".join(header + geometry + objects) + "\n", encoding="utf-8")
    print(path.name, counts[0], "vértices verificados")


if __name__ == "__main__":
    for model in ("torpe", "retador", "estratega"):
        repair(ROOT / ("boxeador_" + model + ".obj"))
