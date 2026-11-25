# Contexto para agentes de IA — ÑAPI / JUEGO-VR

## Proyecto y preferencias del usuario

- Juego de boxeo en primera persona, en Godot, controlado por webcam o teclado y mouse.
- Repositorio: `https://github.com/Rodimir909/JUEGO-VR.git`.
- Rama de trabajo y destino del último pedido de push: `qa`.
- Base funcional de esta documentación: commit `2b965ac` (`feat: improve tracking and add three-level boxing campaign`). Revisar siempre el estado real de Git antes de trabajar.
- El usuario ejecuta y prueba el juego en otra computadora. No instalar programas ni dependencias globalmente en esta PC. Para compilar, usar herramientas portables temporales y no incorporarlas al repositorio.
- Conservar cambios locales de otros trabajos. La divergencia entre `qa` y `main` no es una instrucción para fusionarlas.
- Responder en español y completar las tareas autorizadas sin pedir confirmaciones rutinarias.

## Ejecución y dependencias

- Motor verificado: **Godot 4.5.1**, renderer `gl_compatibility` y físicas Jolt. `project.godot` declara compatibilidad con Godot 4.5.
- Abrir `project.godot` y ejecutar con F5. El menú inicial ya está configurado.
- Webcam: **Python 3.11**, con las versiones de `BoxingGames/Python/requirements.txt`.
- MediaPipe está fijado en **0.10.21** porque se usa `mp.solutions.holistic`. No actualizarlo sin adaptar y verificar la integración.
- Se usa `opencv-contrib-python`, no instalar además `opencv-python` en el mismo entorno.
- El juego con teclado funciona sin iniciar Python. La webcam requiere ejecutar el proceso de seguimiento aparte.
- `README.md` contiene las instrucciones para preparar el entorno en la computadora donde se vaya a jugar.

## Campaña implementada

| Nivel | Escena | Escenario | Rival |
| --- | --- | --- | --- |
| 1 | `escenario_4.tscn` | Gimnasio | El Torpe |
| 2 | `escenario_2.tscn` | Club | El Retador |
| 3 | `escenario_3.tscn` | Estadio | El Estratega |

- Jugar comienza una campaña desde el nivel 1.
- Cada pelea se gana con dos rounds. Cada round dura 60 segundos o termina por KO.
- Al agotarse el tiempo gana quien tenga más vida. Los empates no suman puntos y se juega otro round.
- Vida restaurada entre rounds y niveles; marcador restaurado al pasar de nivel.
- Avance automático tras superar los niveles 1 y 2; final del campeonato tras ganar el tercero.
- Reintentar una derrota conserva el nivel actual. Volver a jugar tras el campeonato comienza desde el primero.
- La dificultad aumenta mediante daño, anticipación, recuperación, defensa y longitud de combos. Modificar los parámetros que consume el rival, no asumir que todos los campos del perfil están conectados a su comportamiento.

## Arquitectura: archivos que importan

- `global.gd`: autoload `Global`; fuente única de vida, daño, fase, rondas y campaña. Contiene `LEVELS`, señales y transiciones. Fases: `MENU`, `INTRO`, `FIGHTING`, `ROUND_END`, `MATCH_END`.
- `interfaz_inicial.gd` y `elementos de hud/interfaz inicial.tscn`: menú y botón Jugar.
- `scripts/arena.gd`: identifica el nivel incluso con F6, coloca al jugador y al rival, configura ambiente y llama a `Global.level_ready()`.
- `player/player.gd` y `player/player.tscn`: jugador compartido por los tres niveles; webcam, teclado, cámara, guantes, colisiones, guardia, gestos y pausa.
- `scripts/enemy.gd` y `scenes/enemy.tscn`: IA con aproximación, movimiento lateral, anticipación, golpe, recuperación, bloqueo y esquiva; carga los modelos según el nivel.
- `scripts/hud.gd` y `scenes/hud.tscn`: barras de vida, cronómetro, resultados, reintento y estado del seguimiento.
- `elementos de hud/pause_menu.gd`: pausa, reanudación, menú y cursor con pellizco.
- `BoxingGames/Python/holistic_test.py`: captura reciente de webcam en un hilo, inferencia Holistic y envío UDP. Importa dependencias de cámara dentro de `main()`.
- `BoxingGames/Python/tracking_core.py`: lógica de seguimiento sin dependencias externas; filtros One Euro, fusión de muñeca/mano, calibración, profundidad, cuerpo, guardia y cursor.
- `scripts/player ishma.gd` y `scenes/player ishma.tscn`: controlador anterior. La campaña usa `player/player.tscn`; no confundirlos al hacer ajustes.

## Contrato del seguimiento y reglas de combate

- UDP local a `127.0.0.1:4242`; comandos de recalibración a `127.0.0.1:4243`.
- Paquete versión 2: `version`, `frame`, `t`, `calibrated`, `left`, `right`, `head`, `guard`, `pause_pose`, `cursor`.
- `t` es el tiempo monotónico de captura en segundos. No calcular velocidades usando tiempos de recepción o FPS de renderizado.
- Cada brazo contiene `rel` con `x/y/z` y `wrist.visibility`. En Godot el avance del guante es hacia **-Z**.
- Procesar la imagen sin espejo y espejar solo la previsualización. La identidad anatómica de las manos debe sobrevivir al cruce de brazos.
- Calibrar con ambas manos visibles en guardia y el cuerpo quieto. No usar solamente el acortamiento aparente del antebrazo para inferir un puño extendido.
- La traslación del cuerpo se calcula respecto a una referencia fija; variar el ancho aparente de hombros no debe generar una esquiva lateral falsa.
- El jugador descarta paquetes anteriores y consume el más reciente para evitar latencia acumulada.
- Reiniciar velocidad, golpe pendiente y ventana de impacto al perder una mano o pausar. Reconectar no debe generar golpes fantasma.
- Resolver impactos en física mediante barrido de la trayectoria del guante. Cada golpe de cada mano daña una sola vez.
- Capas: 1 arena, 2 rival, 3 jugador. En máscaras numéricas: rival `2`, jugador `4`.
- La guardia reduce daño; no hace inmortal. Los golpes pesados dejan pasar más daño y pueden castigar al jugador agachado.
- El rival recuerda la posición de la cabeza al preparar el ataque. Mantener una inclinación fija no debe dar invulnerabilidad permanente.
- No aplicar daño después de la campana ni fuera de `FIGHTING`.
- La pérdida sostenida de un seguimiento en uso pausa el combate. El jugador puede recuperar la cámara o continuar con teclado.

## Controles

- WASD: movimiento; clic izquierdo/derecho: puños; E: guardia; Espacio: agacharse.
- Esc: pausa; K: alternar teclado/webcam automática, conservando la elección entre niveles.
- C: recalibrar. En webcam, manos junto a la cara: guardia; torso: esquivar.
- Mantener una mano por encima de la cabeza durante 1,2 segundos: pausa.
- En pausa, índice para apuntar y pellizco de pulgar/índice para elegir.
- R: reintentar en la pantalla de resultado habilitada.

## Modelos y recursos

- Conservar el arte de los tres boxeadores y escenarios existentes, incluido el trabajo de `f533f95`.
- El rival usa tres mallas por modelo: `boxeador_<modelo>_body.obj`, `left_arm.obj` y `right_arm.obj`.
- `tools/repair_obj_order.py` coloca los vértices antes de las caras y convierte índices negativos; evita errores de importación por referencias adelantadas sin cambiar la geometría.
- `tools/generate_boxer_parts.py` regenera cuerpo y brazos separados de Torpe y Estratega, conservando grupos y materiales.
- Si se modifica un OBJ completo, reparar/verificar índices y regenerar sus partes antes de importar y probar.
- No versionar `.godot`, entornos Python, herramientas descargadas ni capturas temporales. Los archivos `.uid` y `.obj.import` del proyecto sí se versionan cuando corresponden.
- No incluir cambios incidentales de importación de recursos ajenos a la tarea; Godot puede reescribir opciones de `.glb.import` al cambiar de versión.

## Verificación

Desde la raíz del repositorio:

```powershell
python -m unittest discover -s tests -v
godot --headless --fixed-fps 60 --path . res://tests/gameplay_test.tscn
godot --headless --fixed-fps 60 --path . res://tests/udp_test.tscn
godot --headless --fixed-fps 60 --path . res://tests/ai_test.tscn
git diff --check
```

- `test_tracking.py`: 13 pruebas sin cámara ni MediaPipe; requieren solo la biblioteca estándar de Python.
- `gameplay_test.tscn`: campaña completa, recursos, impactos, daño único, KOs, guardia, esquivas, derrota, reintento y retorno al menú.
- `udp_test.tscn`: paquetes UDP reales locales, golpes, mano perdida, mensajes inválidos, desconexión, pausa y recuperación.
- `ai_test.tscn`: combate simulado, aproximación y daño del rival, y golpes mediante los controles.
- `visual_test.tscn`: capturas con renderizado real. No ejecutar en modo headless si se necesitan imágenes.
- Estas suites pasaron sobre la base funcional indicada. También se importaron los tres escenarios y se procesó un frame vacío con MediaPipe real.
- **No se verificó el seguimiento con una persona y la webcam de la computadora de destino.** Distinguir simulaciones de pruebas físicas y no dar por realizada esa calibración.

## Pendiente solicitado: ejecutable para probar

- El usuario pidió un **EXE de Windows para probar en otra computadora**.
- A la fecha de este contexto, no hay un EXE exportado y validado entregado ni un `export_presets.cfg` versionado. El pedido sigue pendiente.
- Generar una exportación Windows x64 con las plantillas de la misma versión que el editor; no entregar el EXE del editor como si fuera el juego.
- Incluir todos los modelos cargados dinámicamente y las tres escenas de niveles; probar el binario exportado.
- El EXE de Godot no incluye automáticamente Python ni MediaPipe. Acompañarlo con las instrucciones y scripts de webcam; no afirmar que la cámara funciona sola si sigue requiriendo el proceso de Python.
- Hay una preparación temporal fuera del repositorio, en `C:/Users/Mateo/Documents/ChatGPT/boxeo/.build-tools/windows-4.5.1`, solo en la PC de esta sesión. Se descargó el editor portable oficial; la descarga selectiva de plantillas falló con HTTP 501. Verificar su contenido antes de reusarlo; no asumir que existe en otra máquina.
- Cuando se complete la exportación, actualizar esta sección con el resultado verificado y la ubicación del artefacto, sin versionar herramientas temporales ni binarios grandes innecesariamente.
