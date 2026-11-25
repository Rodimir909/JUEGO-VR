"""Seguimiento independiente de cámara: filtros, calibración y protocolo UDP.

Las coordenadas de entrada usan la imagen original (sin espejo). MediaPipe
mantiene así la identidad anatómica aunque se crucen los brazos.
"""
import math
import statistics


def clamp(value, low, high):
    return max(low, min(high, value))


class OneEuro:
    def __init__(self, min_cutoff=1.5, beta=0.5):
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.reset()

    def reset(self):
        self.value = self.raw = self.time = None
        self.derivative = 0.0

    @staticmethod
    def alpha(cutoff, dt):
        return 1.0 / (1.0 + 1.0 / (2.0 * math.pi * cutoff * dt))

    def __call__(self, value, timestamp):
        if not math.isfinite(value) or not math.isfinite(timestamp):
            raise ValueError("Muestra no finita")
        if self.time is None or timestamp - self.time > 0.3:
            self.value = self.raw = value
            self.time = timestamp
            self.derivative = 0.0
            return value
        dt = timestamp - self.time
        if dt <= 0:
            return self.value
        derivative = (value - self.raw) / dt
        alpha = self.alpha(1.0, dt)
        self.derivative += alpha * (derivative - self.derivative)
        alpha = self.alpha(self.min_cutoff + self.beta * abs(self.derivative), dt)
        self.value += alpha * (value - self.value)
        self.raw, self.time = value, timestamp
        return self.value


class TrackingCore:
    CALIBRATION_SAMPLES = 35
    SIDES = {"left": (11, 13, 15), "right": (12, 14, 16)}

    def __init__(self):
        self.frame = 0
        self.filters = {}
        self.last_arm = {}
        self.guard = False
        self.guard_since = None
        self.pinch = False
        self.calibrate()

    def calibrate(self):
        self.samples = []
        self.reference = None
        self.filters.clear()
        self.last_arm.clear()
        self.guard = False
        self.guard_since = None
        self.pinch = False
        self.last_body = None
        self.shoulder_width = None

    def filtered(self, key, value, timestamp, cutoff=1.8, beta=0.6):
        if key not in self.filters:
            self.filters[key] = OneEuro(cutoff, beta)
        return self.filters[key](value, timestamp)

    @staticmethod
    def axis(points, start, end, aspect):
        a, b = points[start], points[end]
        vector = ((b["x"] - a["x"]) * aspect, -(b["y"] - a["y"]), (b["z"] - a["z"]) * aspect)
        length = math.sqrt(sum(component * component for component in vector))
        return tuple(component / length for component in vector) if length > 1e-6 else None

    @staticmethod
    def valid(point, confidence=0.5):
        return (point is not None and point.get("visibility", 1.0) >= confidence
                and all(math.isfinite(point.get(k, 0.0)) for k in ("x", "y", "z")))

    def reset_arm(self, side):
        self.last_arm.pop(side, None)
        for key in list(self.filters):
            if key.startswith(side + "."):
                del self.filters[key]

    def update(self, pose, world, hands, timestamp, aspect=4 / 3):
        self.frame += 1
        packet = {"version": 2, "frame": self.frame, "t": timestamp,
                  "calibrated": False, "left": {}, "right": {},
                  "head": {"valid": False}, "guard": False,
                  "pause_pose": False, "cursor": {"visible": False}, "orient": {}}
        if not pose or len(pose) < 33 or not all(self.valid(pose[i], 0.6) for i in (11, 12)):
            self.reset_arm("left")
            self.reset_arm("right")
            self.guard = False
            self.guard_since = None
            self.pinch = False
            self.last_body = None
            return packet

        left, right = pose[11], pose[12]
        width = math.hypot((left["x"] - right["x"]) * aspect, left["y"] - right["y"])
        if width < 0.06:
            return packet
        # Límite de variación: al rotar el torso no se agrandan de golpe los guantes.
        if self.shoulder_width is None:
            self.shoulder_width = width
        self.shoulder_width += clamp(width - self.shoulder_width, -0.005, 0.005) * 0.18
        width = self.shoulder_width
        center = ((left["x"] + right["x"]) / 2, (left["y"] + right["y"]) / 2)
        # Centro del rostro en pose; cae al centro de hombros si la cara está ocluida.
        eyes_ok = all(self.valid(pose[i], 0.65) for i in (2, 5))
        face_center = ((pose[2]["x"] + pose[5]["x"]) / 2,
                       (pose[2]["y"] + pose[5]["y"]) / 2) if eyes_ok else None
        # Traslación del cuerpo independiente de la orientación de la cara.
        body = (-center[0] * aspect, -center[1])
        observed = {}
        for side, (s_idx, e_idx, w_idx) in self.SIDES.items():
            shoulder, elbow, wrist = pose[s_idx], pose[e_idx], pose[w_idx]
            hand = hands.get(side) or []
            hand_matches = (len(hand) == 21 and self.valid(hand[0])
                            and self.valid(wrist, 0.0)
                            and math.hypot((hand[0]["x"] - wrist["x"]) * aspect,
                                           hand[0]["y"] - wrist["y"]) < width * 0.45)
            if not self.valid(elbow, 0.45) or not (self.valid(wrist, 0.45) or hand_matches):
                self.reset_arm(side)
                continue
            wx, wy = wrist["x"], wrist["y"]
            confidence = wrist["visibility"]
            # La mano detallada rescata una muñeca ocluida si coincide con su brazo.
            if hand_matches:
                wx = wx * 0.25 + hand[0]["x"] * 0.75
                wy = wy * 0.25 + hand[0]["y"] * 0.75
                confidence = max(confidence, 0.8)
            x = -(wx - shoulder["x"]) * aspect / width
            y = -(wy - shoulder["y"]) / width
            upper = math.hypot((elbow["x"] - shoulder["x"]) * aspect, elbow["y"] - shoulder["y"]) / width
            fore = math.hypot((wx - elbow["x"]) * aspect, wy - elbow["y"]) / width
            # La perspectiva sola confunde el antebrazo vertical de guardia con
            # un brazo extendido. Combinarla con Z del esqueleto evita ese salto.
            perspective = math.sqrt(max(0, 0.78 ** 2 - upper ** 2)) + math.sqrt(max(0, 0.68 ** 2 - fore ** 2))
            depth = -(wrist["z"] - shoulder["z"]) * aspect / width
            if world and len(world) >= 33:
                world_width = math.dist([world[11][k] for k in ("x", "y", "z")], [world[12][k] for k in ("x", "y", "z")])
                if world_width > 0.15:
                    depth = -(world[w_idx]["z"] - world[s_idx]["z"]) / world_width
            depth = clamp(depth * 0.8 + perspective * 0.2, -0.3, 2.0)
            observed[side] = (x, y, depth, wx, wy, confidence)

        if self.reference is None:
            # Exigir manos visibles, levantadas y una pose estable para calibrar.
            good_guard = (len(observed) == 2 and face_center is not None
                          and all(v[1] > 0.02 for v in observed.values()))
            sample = (body[0], body[1], width,
                      observed.get("left", (0, 0, 0))[2],
                      observed.get("right", (0, 0, 0))[2])
            if good_guard:
                if self.samples and math.dist(sample[:2], self.samples[-1][:2]) > 0.025:
                    self.samples.clear()
                self.samples.append(sample)
                if len(self.samples) >= self.CALIBRATION_SAMPLES:
                    self.reference = tuple(statistics.median(s[i] for s in self.samples) for i in range(5))
            else:
                self.samples.clear()
            packet["calibration_progress"] = len(self.samples) / self.CALIBRATION_SAMPLES
        packet["calibrated"] = self.reference is not None

        for side, values in observed.items():
            x, y, depth, wx, wy, visibility = values
            neutral = self.reference[3 if side == "left" else 4] if self.reference else depth
            z = -clamp(0.45 + (depth - neutral) * 1.5, 0.15, 1.5)
            raw = (x, y, z)
            previous = self.last_arm.get(side)
            if previous:
                dt = timestamp - previous[1]
                if 0 < dt < 0.2 and math.dist(raw, previous[0]) > max(0.5, dt * 15):
                    self.reset_arm(side)
                    continue
            self.last_arm[side] = (raw, timestamp)
            filtered = [self.filtered(side + "." + key, value, timestamp) for key, value in zip("xyz", raw)]
            packet[side] = {"rel": dict(zip("xyz", filtered)),
                            "wrist": {"x": 1 - wx, "y": wy, "visibility": visibility}}

        for side in observed:
            hand = hands.get(side) or []
            if len(hand) != 21 or not all(self.valid(hand[index]) for index in (0, 5, 9, 17)):
                continue
            forward = self.axis(hand, 0, 9, aspect)
            across = self.axis(hand, 5, 17, aspect)
            if forward is None or across is None:
                continue
            packet["orient"][side] = {
                "f": [round(self.filtered(f"{side}.orient.f.{i}", value, timestamp, 1.0, 2.0), 4)
                      for i, value in enumerate(forward)],
                "s": [round(self.filtered(f"{side}.orient.s.{i}", value, timestamp, 1.0, 2.0), 4)
                      for i, value in enumerate(across)],
            }

        if self.reference:
            x = clamp((body[0] - self.reference[0]) / self.reference[2] * 0.4, -0.4, 0.4)
            y = clamp((body[1] - self.reference[1]) / self.reference[2] * 0.4, -0.5, 0.2)
            z = clamp((width / self.reference[2] - 1) * 0.5, -0.2, 0.2)
            # No mantener una esquiva antigua durante una pérdida de pose.
            if self.last_body and timestamp - self.last_body > 0.3:
                for key in ("head.x", "head.y", "head.z"):
                    self.filters.pop(key, None)
            self.last_body = timestamp
            packet["head"] = {"valid": True, "yaw": 0, "pitch": 0, "roll": 0,
                              "x": self.filtered("head.x", x, timestamp, 2.0, 1.0),
                              "y": self.filtered("head.y", y, timestamp, 2.0, 1.0),
                              "z": self.filtered("head.z", z, timestamp, 0.8, 0.2)}

        if face_center is None and self.reference:
            face_center = (center[0], center[1] - width * 0.65)
        both = all(packet[side] for side in self.SIDES)
        if both and face_center:
            tolerance = 0.12 if self.guard else 0
            near_face = all(v[4] < center[1] - width * (0.05 - tolerance)
                            and abs(v[3] - face_center[0]) * aspect < width * (0.8 + tolerance)
                            and -packet[side]["rel"]["z"] < 0.85 + tolerance
                            for side, v in observed.items())
            if near_face:
                if self.guard_since is None:
                    self.guard_since = timestamp
                self.guard = timestamp - self.guard_since > 0.10
            else:
                self.guard = False
                self.guard_since = None
            # Pausa con mano sobre la cabeza, suficientemente lejos de la guardia.
            packet["pause_pose"] = any(v[4] < face_center[1] - width * 0.65 for v in observed.values())
        else:
            self.guard = False
            self.guard_since = None
        packet["guard"] = self.guard and packet["calibrated"]

        for side in ("right", "left"):
            hand = hands.get(side) or []
            if len(hand) != 21 or side not in observed:
                continue
            palm = math.hypot((hand[5]["x"] - hand[17]["x"]) * aspect, hand[5]["y"] - hand[17]["y"])
            if palm < 0.015:
                continue
            pinch = math.hypot((hand[4]["x"] - hand[8]["x"]) * aspect, hand[4]["y"] - hand[8]["y"])
            self.pinch = pinch < palm * (0.55 if self.pinch else 0.38)
            packet["cursor"] = {"visible": True,
                                "x": clamp((1 - hand[8]["x"] - 0.15) / 0.7, 0, 1),
                                "y": clamp((hand[8]["y"] - 0.1) / 0.7, 0, 1),
                                "pinch": self.pinch}
            break
        else:
            self.pinch = False
        return packet
