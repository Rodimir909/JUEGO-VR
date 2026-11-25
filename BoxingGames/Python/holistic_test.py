"""Webcam -> MediaPipe Holistic -> UDP local para ÑAPI.
Python 3.11, dependencias en requirements.txt. C recalibra, ESC cierra.
"""
import argparse
import json
import socket
import threading
import time
from tracking_core import TrackingCore


def landmarks(result):
    if result is None:
        return None
    return [{"x": p.x, "y": p.y, "z": p.z,
             "visibility": (p.visibility if p.HasField("visibility") else 1.0)} for p in result.landmark]


class LatestCamera:
    """Captura continua: la inferencia siempre recibe la imagen más reciente."""
    def __init__(self, capture):
        self.capture = capture
        self.lock = threading.Lock()
        self.latest = None
        self.running = True
        self.failed = False
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        failures = 0
        while self.running:
            ok, frame = self.capture.read()
            if not ok:
                failures += 1
                if failures >= 10:
                    self.failed = True
                    return
                time.sleep(0.02)
                continue
            failures = 0
            with self.lock:
                self.latest = (time.perf_counter(), frame)

    def get(self):
        with self.lock:
            return self.latest

    def close(self):
        self.running = False
        self.thread.join(timeout=1)
        self.capture.release()


def main():
    parser = argparse.ArgumentParser(description="Seguimiento de boxeo para Godot")
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--port", type=int, default=4242)
    parser.add_argument("--model-complexity", type=int, choices=(0, 1, 2), default=1)
    parser.add_argument("--no-preview", action="store_true")
    args = parser.parse_args()
    try:
        import cv2
        import mediapipe as mp
    except ImportError as error:
        raise SystemExit("Faltan dependencias. Usá Python 3.11 y ejecutá: pip install -r requirements.txt") from error
    if not hasattr(mp, "solutions"):
        raise SystemExit("Esta integración requiere mediapipe==0.10.21. Instalá requirements.txt con Python 3.11.")
    capture = cv2.VideoCapture(args.camera)
    if not capture.isOpened():
        capture.release()
        raise SystemExit("No se pudo abrir la cámara. Cerrá otras aplicaciones o probá --camera 1.")
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    camera = LatestCamera(capture)
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    commands = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    commands.setblocking(False)
    core = TrackingCore()
    window = "NAPI - Webcam | C: calibrar | ESC: cerrar"
    try:
        commands.bind(("127.0.0.1", args.port + 1))
        with mp.solutions.holistic.Holistic(
            model_complexity=args.model_complexity, smooth_landmarks=True,
            min_detection_confidence=0.65, min_tracking_confidence=0.65
        ) as holistic:
            last_timestamp = -1
            while not camera.failed:
                while True:
                    try:
                        command, _ = commands.recvfrom(256)
                    except BlockingIOError:
                        break
                    if command == b"calibrate":
                        core.calibrate()
                latest = camera.get()
                if latest is None or latest[0] <= last_timestamp:
                    time.sleep(0.002)
                    continue
                timestamp, frame = latest
                last_timestamp = timestamp
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                rgb.flags.writeable = False
                results = holistic.process(rgb)
                height, width = frame.shape[:2]
                hands = {"left": landmarks(results.left_hand_landmarks),
                         "right": landmarks(results.right_hand_landmarks)}
                packet = core.update(landmarks(results.pose_landmarks),
                                     landmarks(results.pose_world_landmarks),
                                     hands, timestamp, width / height)
                # Un frame que tardó demasiado no debe generar golpes tardíos.
                if time.perf_counter() - timestamp > 0.45:
                    continue
                sender.sendto(json.dumps(packet, allow_nan=False, separators=(",", ":")).encode(),
                              ("127.0.0.1", args.port))
                if args.no_preview:
                    continue
                mp.solutions.drawing_utils.draw_landmarks(
                    frame, results.pose_landmarks, mp.solutions.holistic.POSE_CONNECTIONS)
                for hand in (results.left_hand_landmarks, results.right_hand_landmarks):
                    mp.solutions.drawing_utils.draw_landmarks(frame, hand, mp.solutions.holistic.HAND_CONNECTIONS)
                preview = cv2.flip(frame, 1)
                status = ("LISTO | Guardia: " + ("SI" if packet["guard"] else "NO")) if packet["calibrated"] else (
                    "Mira al frente, manos en guardia: %d%%" % (packet.get("calibration_progress", 0) * 100))
                cv2.putText(preview, status, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
                cv2.putText(preview, "C: recalibrar | ESC: cerrar | Mano arriba: pausa", (12, height - 15),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
                cv2.imshow(window, preview)
                key = cv2.waitKey(1) & 0xFF
                if key == 27 or cv2.getWindowProperty(window, cv2.WND_PROP_VISIBLE) < 1:
                    break
                if key in (ord("c"), ord("C"), ord("t"), ord("T")):
                    core.calibrate()
    except KeyboardInterrupt:
        pass
    finally:
        camera.close()
        sender.close()
        commands.close()
        cv2.destroyAllWindows()
    if camera.failed:
        raise SystemExit("Se perdió la cámara. Revisá la conexión y volvé a ejecutar el seguimiento.")


if __name__ == "__main__":
    main()
