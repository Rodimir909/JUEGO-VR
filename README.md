# ÑAPI · Camino al campeonato

Abrí `project.godot` con Godot 4.5 o posterior y presioná **F5**. La escena inicial ya está configurada. El proyecto no incluye instalaciones ni entornos de Python: usá el motor y el entorno de la computadora donde vayas a jugar.

## Campaña

| Nivel | Escenario existente | Rival | Ritmo |
| --- | --- | --- | --- |
| 1 | Gimnasio (`escenario_4.tscn`) | El Torpe | Golpes lentos, mucho tiempo de recuperación |
| 2 | Club (`escenario_2.tscn`) | El Retador | Más daño, bloqueos, esquivas y combos de hasta dos golpes |
| 3 | Estadio (`escenario_3.tscn`) | El Estratega | Menos anticipación, defensa más frecuente y combos de hasta tres golpes |

Cada pelea se gana con dos rounds. Cada round dura 60 segundos o termina por KO. Al agotarse el tiempo gana quien tenga más vida; un empate no otorga puntos y se juega otro round. La vida se recupera entre rounds y niveles. Los niveles avanzan automáticamente después de una victoria. Si perdés, **Reintentar** o **R** conserva el nivel actual. Ganar el tercero muestra el final del campeonato. **Volver a jugar** empieza una campaña desde el primero.

## Jugar con webcam en Windows

1. En la carpeta `BoxingGames/Python`, usá un entorno con **Python 3.11** e instalá `requirements.txt` (comandos más abajo).
2. Ejecutá `python holistic_test.py` con ese entorno activo, o usá `iniciar_webcam.cmd` si tu entorno se llama `.venv` o `venv311`.
3. Mirá a la cámara, con los dos hombros y brazos visibles, las manos junto a la cara y el torso quieto. La ventana indica **LISTO** cuando termina la calibración.
4. Ejecutá el juego en Godot y elegí **Jugar**. El jugador detecta automáticamente el seguimiento. Si todavía se está calibrando, espera antes de empezar el primer round.

Conservá una distancia que permita ver de la cabeza a la cintura y dejá luz de frente. No hace falta una pose en T. Si cambiaste de posición, presioná **C** en la ventana del juego o del seguimiento y repetí la guardia neutra. Para otra cámara: `python holistic_test.py --camera 1`. Si tu equipo tarda mucho en procesar: `python holistic_test.py --model-complexity 0`.

- **Golpes:** adelantá un puño y volvé a la guardia. El daño depende de su velocidad. Cada golpe puede conectar una sola vez; retirar la mano no inicia otro golpe.
- **Guardia:** ambas manos cerca de la cara. Reduce el daño; un golpe pesado deja pasar más daño.
- **Esquivas:** mové el torso a un costado o agachate. Agacharse evita jabs; los golpes pesados también castigan el cuerpo, así que alejate o movete de costado. El rival apunta a tu posición al preparar el golpe: mantener una inclinación fija no da invulnerabilidad.
- **Movimiento en el ring:** WASD, también mientras usás webcam.
- **Pausa:** Esc o mantené una mano claramente por encima de la cabeza durante 1,2 segundos. En pausa, apuntá con el índice y juntá pulgar e índice para seleccionar.
- **K:** alterna entre teclado y webcam automática. La elección se conserva entre niveles.
- Si se interrumpe un seguimiento que estaba en uso, el combate se pausa. Podés recuperar la cámara o continuar con teclado. La pérdida de una muñeca cancela sus golpes y baja la guardia, evitando impactos falsos.

Preparación del entorno en la computadora donde se vaya a usar la webcam:

```powershell
cd BoxingGames/Python
py -3.11 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python holistic_test.py
```

Se fija `mediapipe==0.10.21` porque el código usa Holistic Solutions. No instales simultáneamente opencv-python y opencv-contrib-python en ese entorno; requirements ya incluye la variante necesaria.

## Teclado y mouse

Podés ejecutar el juego sin Python ni webcam. WASD mueve al jugador, clic izquierdo/derecho golpea con cada mano, E mantiene la guardia, Espacio agacha y Esc pausa. La cámara sigue al rival. El mouse queda disponible para los menús.

## Verificación y ajustes

```powershell
python -m unittest discover -s tests -v
godot --headless --path . res://tests/gameplay_test.tscn
```

Las pruebas de seguimiento usan datos simulados y no requieren MediaPipe ni cámara. Las de Godot recorren la campaña, colisiones, KOs, bloqueo, esquivas, derrota, reintento y vuelta al menú. `tests/ai_test.tscn` simula el combate y comprueba que los rivales se acercan y que los controles permiten devolver los golpes. `tests/udp_test.tscn` comprueba los paquetes UDP locales, pérdida de conexión, guardia y pausa. `tests/visual_test.tscn` genera capturas de los escenarios y el menú usando renderizado real.

El ajuste final a una persona y cámara reales requiere probar la webcam. La detección monocular estima la profundidad: iluminación, encuadre y oclusiones influyen. El código mantiene una alternativa de teclado para poder jugar sin seguimiento.

Los valores de cada rival se ajustan en `global.gd`, en `LEVELS`. Sensibilidad, velocidad mínima de golpe y suavizado están exportados en `player/player.gd`. El seguimiento y su calibración están en `BoxingGames/Python/tracking_core.py`.

Los tres rivales conservan los modelos originales. Los brazos separados de Torpe y Estratega se regeneran con `python tools/generate_boxer_parts.py`; se incluyen los OBJ generados para que Godot pueda importarlos directamente.

`tools/repair_obj_order.py` corrige el orden de los vértices de los OBJ completos sin cambiar su geometría, para que Godot acepte las caras que usan índices adelantados.
