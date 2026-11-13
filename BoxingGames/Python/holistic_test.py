import cv2
import mediapipe as mp
import socket
import json
import math
import time
import numpy as np

# =====================================
# CONFIGURACION
# =====================================

GODOT_ADDRESS = ("127.0.0.1", 4242)

CAMERA_INDEX = 0
FRAME_WIDTH = 640           # resolucion baja = menos latencia
FRAME_HEIGHT = 480
MODEL_COMPLEXITY = 1        # bajalo a 0 si va con lag

MIN_SHOULDER_VISIBILITY = 0.5
CALIBRATION_FRAMES = 30     # frames promediados para la pose neutra (~1 seg)

# --- Profundidad de los golpes (eje Z) ---
# Largo de los huesos medido en "anchos de hombros" (distancia entre los dos hombros).
# Si tus golpes no llegan a extenderse del todo, sube un poco; si se extienden solos, baja.
UPPER_ARM_LEN = 0.80        # hombro -> codo
FOREARM_LEN = 0.68          # codo -> muneca
# Mezcla con la Z cruda de MediaPipe (0 = solo perspectiva, 1 = solo MediaPipe).
DEPTH_MEDIAPIPE_BLEND = 0.0
# Filtro One Euro sobre la Z: min_cutoff mas bajo = mas suave en reposo,
# beta mas alto = menos lag cuando la mano va rapido (golpe).
Z_MIN_CUTOFF = 1.0
Z_BETA = 1.0
HEAD_HOLD_FRAMES = 150      # frames que se mantiene la cabeza si una mano tapa la cara (~5 s)
HAND_RADIUS = 0.25          # un punto de la cara se descarta si hay una mano a menos de esto (x ancho de cara)
TPOSE_FRAMES = 40          # muestras para calibrar los brazos (tecla T)

# --- Cabeza: puntos individuales + estabilidad ---
MIN_FACE_POINTS = 4         # minimo de puntos libres para estimar la pose (cada punto se descarta por separado)
# Filtro One Euro sobre la cabeza. min_cutoff mas BAJO = mas estable (menos temblor al dar punos).
HEAD_ANGLE_MIN_CUTOFF = 0.5     # yaw / pitch / roll
HEAD_ANGLE_BETA = 0.01          # mas alto = menos lag cuando giras la cabeza rapido
HEAD_POS_MIN_CUTOFF = 0.4       # x / y (esquivar)
HEAD_POS_BETA = 0.002
HEAD_Z_MIN_CUTOFF = 0.25        # z (acercarse/alejarse) es lo mas ruidoso, filtro mas fuerte
# Anti-saltos: si de un frame al otro la cabeza "salta" mas que esto, se ignora ese frame.
MAX_JUMP_ANGLE = 25.0           # grados
MAX_JUMP_POS = 120.0            # mm
MAX_REJECT_STREAK = 6           # tras tantos frames rechazados seguidos se acepta igual (evita quedarse trabado)

# Pulsa T para calibrar brazos Y cabeza (T-pose, brazos abiertos, mirando a la pantalla)
# Pulsa C en la ventana para recalibrar la cabeza (ponte en guardia mirando la pantalla)

# --- Guardia (manos en la cara = Godot te hace invulnerable) ---
GUARD_MAX_DIST = 0.8        # distancia muneca-nariz (en anchos de hombros) para contar como "mano en la cara"
GUARD_ENTER_FRAMES = 3      # frames seguidos en guardia para activarla
GUARD_EXIT_FRAMES = 3       # frames seguidos sin guardia para soltarla

# --- Gesto de pausa: una muneca bien arriba de la cabeza (Godot exige mantenerlo ~1 s) ---
PAUSE_RAISE = 0.8           # cuanto debe estar la muneca POR ENCIMA de la nariz (anchos de hombros)

# --- Cursor con la mano (menu de pausa) ---
CURSOR_HAND = "right"       # mano preferida; si no se ve, usa la otra
CURSOR_REGION = (0.20, 0.80, 0.10, 0.80)   # zona del frame (x0, x1, y0, y1) que cubre TODA la pantalla del juego
CURSOR_MIN_CUTOFF = 1.5     # filtro One Euro del cursor: mas bajo = mas estable
CURSOR_BETA = 4.0           # mas alto = menos lag cuando la mano va rapido
PINCH_ON = 0.30             # pulgar-indice mas juntos que esto (relativo al tamano de la mano) = click
PINCH_OFF = 0.45            # hasta que no se separen mas que esto no se "suelta" el click

# --- Orientacion de las manos (los guantes rotan como tus manos) ---
ORIENT_MIN_CUTOFF = 1.0     # filtro One Euro de los ejes de la mano: mas bajo = mas estable
ORIENT_BETA = 2.0           # mas alto = menos lag cuando giras la mano rapido

# =====================================
# CONEXION CON GODOT
# =====================================

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# =====================================
# MEDIAPIPE
# =====================================

mp_holistic = mp.solutions.holistic
mp_drawing = mp.solutions.drawing_utils

cap = cv2.VideoCapture(CAMERA_INDEX)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_WIDTH)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_HEIGHT)
cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)     # evita acumular frames viejos

window_name = "Boxing - Tracking"

# =====================================
# MODELO 3D DE LA CARA (convencion OpenCV)
# x = derecha, y = ABAJO, z = hacia adentro (lejos de la camara), en mm.
# El modelo original tenia Y hacia arriba y Z hacia la camara, mientras que
# OpenCV usa Y hacia abajo y Z hacia adelante: por eso los angulos salian raros.
# =====================================

# Cada punto se descarta POR SEPARADO si una mano lo tapa; la pose se calcula con los
# que queden libres (minimo MIN_FACE_POINTS). Son todos de la mitad superior de la cara
# (frente, cejas, ojos, sienes) porque la guardia tapa primero nariz, boca y menton.
# Los primeros 5 no se tocan de orden: [3] y [4] se usan para medir el ancho de cara.
FACE_POINTS = [
    # (indice MediaPipe, (x, y, z) en mm)
    (10,  (0.0, -78.0, 32.0)),      # frente
    (33,  (-43.3, -32.7, 26.0)),    # ojo exterior (izq. imagen)
    (263, (43.3, -32.7, 26.0)),     # ojo exterior (der. imagen)
    (234, (-70.0, 0.0, 78.0)),      # lateral cara / pomulo (izq. imagen)
    (454, (70.0, 0.0, 78.0)),       # lateral cara / pomulo (der. imagen)
    (67,  (-38.0, -68.0, 40.0)),    # frente lateral (izq.)
    (297, (38.0, -68.0, 40.0)),     # frente lateral (der.)
    (133, (-15.0, -32.7, 16.0)),    # ojo interior (izq.)
    (362, (15.0, -32.7, 16.0)),     # ojo interior (der.)
    (70,  (-48.0, -47.0, 30.0)),    # ceja exterior (izq.)
    (300, (48.0, -47.0, 30.0)),     # ceja exterior (der.)
    (127, (-67.0, -18.0, 68.0)),    # sien (izq.)
    (356, (67.0, -18.0, 68.0)),     # sien (der.)
]

FACE_INDICES = [i for i, _ in FACE_POINTS]
FACE_MODEL_POINTS = np.array([p for _, p in FACE_POINTS], dtype=np.float64)

DIST_COEFFS = np.zeros((4, 1))

# Estado de la cabeza
last_rvec = None
last_tvec = None
last_used = set()     # indices (dentro de FACE_INDICES) de los puntos usados en el ultimo frame
calib_samples = []
calib_ref = None


def reset_calibration():
    global calib_samples, calib_ref
    calib_samples = []
    calib_ref = None
    reset_head_filter()


def estimate_head(face, width, height, hand_pts=()):
    """
    Devuelve (yaw, pitch, roll, tx, ty, tz) o None.
    yaw   + = giras la cabeza hacia TU derecha
    pitch + = miras arriba
    roll  + = inclinas la cabeza hacia TU hombro derecho
    tx/ty/tz en mm (camara: x derecha, y abajo, z lejos)
    """
    global last_rvec, last_tvec, last_used

    pts = [(face[i].x * width, face[i].y * height) for i in FACE_INDICES]
    face_w = math.hypot(pts[3][0] - pts[4][0], pts[3][1] - pts[4][1])

    # Descartar los puntos que tienen una mano encima
    keep = [
        k for k, (px, py) in enumerate(pts)
        if all(math.hypot(px - hx, py - hy) > HAND_RADIUS * face_w for hx, hy in hand_pts)
    ]
    last_used = set(keep)
    if len(keep) < MIN_FACE_POINTS:
        return None     # demasiado tapado: el que llama mantiene la ultima cabeza

    model_pts = FACE_MODEL_POINTS[keep]
    image_points = np.array([pts[k] for k in keep], dtype=np.float64)

    focal = float(width)
    camera_matrix = np.array([
        [focal, 0, width / 2],
        [0, focal, height / 2],
        [0, 0, 1]
    ], dtype=np.float64)

    if last_rvec is None:
        # ITERATIVE sin guess usa DLT y pide 6+ puntos; con menos arrancamos con EPNP
        ok, rvec, tvec = cv2.solvePnP(
            model_pts, image_points, camera_matrix, DIST_COEFFS,
            flags=cv2.SOLVEPNP_EPNP
        )
        if ok:
            ok, rvec, tvec = cv2.solvePnP(
                model_pts, image_points, camera_matrix, DIST_COEFFS,
                rvec=rvec, tvec=tvec, useExtrinsicGuess=True,
                flags=cv2.SOLVEPNP_ITERATIVE
            )
    else:
        # Usar el frame anterior como punto de partida evita saltos/flips
        ok, rvec, tvec = cv2.solvePnP(
            model_pts, image_points, camera_matrix, DIST_COEFFS,
            rvec=last_rvec.copy(), tvec=last_tvec.copy(),
            useExtrinsicGuess=True, flags=cv2.SOLVEPNP_ITERATIVE
        )

    if not ok or tvec[2][0] <= 0:
        last_rvec = None
        last_tvec = None
        return None

    last_rvec, last_tvec = rvec, tvec

    rot, _ = cv2.Rodrigues(rvec)
    forward = rot @ np.array([0.0, 0.0, -1.0])   # hacia donde mira la nariz
    up = rot @ np.array([0.0, -1.0, 0.0])        # hacia donde apunta la coronilla

    yaw = math.degrees(math.atan2(forward[0], -forward[2]))
    pitch = math.degrees(math.atan2(-forward[1], math.hypot(forward[0], forward[2])))
    roll = math.degrees(math.atan2(up[0], -up[1]))

    t = tvec.flatten()
    return (yaw, pitch, roll, float(t[0]), float(t[1]), float(t[2]))


last_head_data = None
occ_frames = 0


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


class OneEuro:
    """Filtro adaptativo: suaviza el temblor en reposo sin atrasar los movimientos rapidos."""

    def __init__(self, min_cutoff=1.0, beta=1.0, d_cutoff=1.0):
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.d_cutoff = d_cutoff
        self.reset()

    def reset(self):
        self.x_prev = None
        self.dx_prev = 0.0
        self.t_prev = None

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x, t):
        if self.x_prev is None:
            self.x_prev, self.t_prev = x, t
            return x

        dt = max(t - self.t_prev, 1e-3)
        dx = (x - self.x_prev) / dt
        a_d = self._alpha(self.d_cutoff, dt)
        dx_hat = a_d * dx + (1.0 - a_d) * self.dx_prev
        cutoff = self.min_cutoff + self.beta * abs(dx_hat)
        a = self._alpha(cutoff, dt)
        x_hat = a * x + (1.0 - a) * self.x_prev

        self.x_prev, self.dx_prev, self.t_prev = x_hat, dx_hat, t
        return x_hat


z_filters = {
    "left": OneEuro(Z_MIN_CUTOFF, Z_BETA),
    "right": OneEuro(Z_MIN_CUTOFF, Z_BETA)
}

head_filters = [
    OneEuro(HEAD_ANGLE_MIN_CUTOFF, HEAD_ANGLE_BETA),   # yaw
    OneEuro(HEAD_ANGLE_MIN_CUTOFF, HEAD_ANGLE_BETA),   # pitch
    OneEuro(HEAD_ANGLE_MIN_CUTOFF, HEAD_ANGLE_BETA),   # roll
    OneEuro(HEAD_POS_MIN_CUTOFF, HEAD_POS_BETA),       # x
    OneEuro(HEAD_POS_MIN_CUTOFF, HEAD_POS_BETA),       # y
    OneEuro(HEAD_Z_MIN_CUTOFF, HEAD_POS_BETA),         # z
]
prev_head = None
reject_streak = 0


def reset_head_filter():
    global prev_head, reject_streak
    for f in head_filters:
        f.reset()
    prev_head = None
    reject_streak = 0


def filter_head(head):
    """Rechaza saltos bruscos (landmarks locos cuando pasa un punio) y suaviza el resto."""
    global prev_head, reject_streak, last_rvec, last_tvec

    if prev_head is not None and reject_streak < MAX_REJECT_STREAK:
        angle_jump = max(abs(head[k] - prev_head[k]) for k in range(3))
        pos_jump = max(abs(head[k] - prev_head[k]) for k in range(3, 6))
        if angle_jump > MAX_JUMP_ANGLE or pos_jump > MAX_JUMP_POS:
            reject_streak += 1
            last_rvec = None        # no arrastrar una pose mala como punto de partida
            last_tvec = None
            return None

    reject_streak = 0
    now = time.perf_counter()
    out = tuple(f(v, now) for f, v in zip(head_filters, head))
    prev_head = out
    return out


# Ancho de hombros "de referencia": sube rapido, baja lento. Al golpear giras el torso
# y los hombros se ven mas juntos; sin esto, todo se escalaria de golpe.
shoulder_ref = None

# Largos de hueso adaptativos (se corrigen si ves el brazo extendido de lado)
arm_len = {"upper": UPPER_ARM_LEN, "fore": FOREARM_LEN}
base_len = dict(arm_len)      # valor base al que vuelve; la T-pose lo reemplaza
tpose = None                  # None = no calibrando; dict = juntando muestras


def finish_tpose():
    global tpose
    for k in ("upper", "fore"):
        v = float(np.median(tpose[k]))
        base_len[k] = arm_len[k] = clamp(v, 0.4, 1.3)
    tpose = None



def update_shoulder_ref(raw_px):
    global shoulder_ref
    if shoulder_ref is None or raw_px > shoulder_ref:
        shoulder_ref = raw_px
    else:
        shoulder_ref += (raw_px - shoulder_ref) * 0.02
    return shoulder_ref


def update_arm_len(key, observed, prior):
    cur = arm_len[key]
    if observed > cur:
        cur += (observed - cur) * 0.3
    else:
        cur += (prior - cur) * 0.002          # vuelve lento al valor base
    arm_len[key] = clamp(cur, prior * 0.8, prior * 1.3)


def foreshortening_depth(length, seen):
    """Cuanto apunta un hueso hacia la camara, a partir de cuanto se ve acortado."""
    return math.sqrt(max(0.0, length * length - seen * seen))


class Debounce:
    """Un booleano que solo cambia tras N frames seguidos con el valor nuevo (anti-parpadeo)."""

    def __init__(self, on_frames, off_frames):
        self.on_frames = on_frames
        self.off_frames = off_frames
        self.state = False
        self.count = 0

    def update(self, value):
        if value == self.state:
            self.count = 0
        else:
            self.count += 1
            if self.count >= (self.on_frames if value else self.off_frames):
                self.state = value
                self.count = 0
        return self.state


guard_deb = Debounce(GUARD_ENTER_FRAMES, GUARD_EXIT_FRAMES)
pause_deb = Debounce(3, 3)
cursor_fx = OneEuro(CURSOR_MIN_CUTOFF, CURSOR_BETA)
cursor_fy = OneEuro(CURSOR_MIN_CUTOFF, CURSOR_BETA)
pinching = False


def hand_at_face(w, nose, mid_shoulder_y, shoulder_px, width, height):
    """True si la muneca esta cerca de la nariz y por encima de la linea de hombros."""
    if w.visibility < 0.5 or w.y > mid_shoulder_y:
        return False
    d = math.hypot((w.x - nose.x) * width, (w.y - nose.y) * height) / shoulder_px
    return d < GUARD_MAX_DIST


def unit_vec(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    if n < 1e-6:
        return None
    return (v[0] / n, v[1] / n, v[2] / n)


# 6 filtros por mano: componentes (x, y, z) de "f" (hacia donde apuntan los dedos) y "s" (a lo ancho de los nudillos)
orient_filters = {
    side: [OneEuro(ORIENT_MIN_CUTOFF, ORIENT_BETA) for _ in range(6)]
    for side in ("left", "right")
}


def pick_hand(results, wrist, width, height, max_dist_px):
    """Elige la mano de Holistic mas cercana a una muneca de pose (no depende de las etiquetas left/right)."""
    best, best_d = None, max_dist_px
    for hand in (results.left_hand_landmarks, results.right_hand_landmarks):
        if hand:
            h0 = hand.landmark[0]
            d = math.hypot((h0.x - wrist.x) * width, (h0.y - wrist.y) * height)
            if d < best_d:
                best, best_d = hand, d
    return best


try:
    with mp_holistic.Holistic(
        static_image_mode=False,
        model_complexity=MODEL_COMPLEXITY,
        smooth_landmarks=True,
        refine_face_landmarks=False,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5
    ) as holistic:

        while cap.isOpened():

            ok_frame, frame = cap.read()

            if not ok_frame:
                break

            frame_t = time.perf_counter()   # momento en que llego el frame (Godot lo usa para medir velocidad)
            frame = cv2.flip(frame, 1)   # vista espejo
            height, width, _ = frame.shape

            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = holistic.process(rgb)

            # =====================================
            # BRAZOS
            # =====================================
            # Se manda la posicion de la muñeca RELATIVA al hombro, medida en
            # "anchos de hombros". Asi funciona igual si estas cerca o lejos de la
            # camara, o si te mueves a un lado.
            #
            #   rel.x : + = hacia tu derecha
            #   rel.y : + = hacia arriba
            #   rel.z : - = hacia la pantalla (golpe), + = hacia tu cuerpo

            arm_data = {}
            guard_now = False
            pause_pose = False
            orient_data = {}
            cursor_data = {"x": 0.5, "y": 0.5, "visible": False, "pinch": False}

            if results.pose_landmarks:

                lm = results.pose_landmarks.landmark

                ls, rs = lm[11], lm[12]
                raw_shoulder_px = math.hypot(
                    (ls.x - rs.x) * width,
                    (ls.y - rs.y) * height
                )

                shoulders_ok = (
                    ls.visibility > MIN_SHOULDER_VISIBILITY
                    and rs.visibility > MIN_SHOULDER_VISIBILITY
                    and raw_shoulder_px > 20
                )

                if shoulders_ok:

                    shoulder_px = update_shoulder_ref(raw_shoulder_px)
                    now = time.perf_counter()

                    # En la imagen espejada, TU izquierda queda a la izquierda
                    # de la imagen (x menor). No dependemos de las etiquetas
                    # left/right de MediaPipe, que se confunden con imagen espejada.
                    if ls.x < rs.x:
                        sides = {"left": [11, 13, 15], "right": [12, 14, 16]}
                    else:
                        sides = {"left": [12, 14, 16], "right": [11, 13, 15]}

                    for side, indices in sides.items():

                        s = lm[indices[0]]
                        e = lm[indices[1]]
                        w = lm[indices[2]]

                        # Largo VISTO de cada hueso (en anchos de hombros)
                        upper_seen = math.hypot(
                            (e.x - s.x) * width, (e.y - s.y) * height
                        ) / shoulder_px
                        fore_seen = math.hypot(
                            (w.x - e.x) * width, (w.y - e.y) * height
                        ) / shoulder_px

                        # T-pose: brazos extendidos de lado (en el plano de la imagen)
                        # => el largo visto es el largo real del hueso
                        if (tpose is not None and e.visibility > 0.5 and w.visibility > 0.5
                                and abs(e.y - s.y) * height / shoulder_px < 0.3
                                and abs(w.y - s.y) * height / shoulder_px < 0.3):
                            tpose["upper"].append(upper_seen)
                            tpose["fore"].append(fore_seen)
                            if len(tpose["upper"]) >= TPOSE_FRAMES * 2:
                                finish_tpose()

                        if e.visibility > 0.5 and w.visibility > 0.5:
                            update_arm_len("upper", upper_seen, base_len["upper"])
                            update_arm_len("fore", fore_seen, base_len["fore"])

                        # Profundidad por perspectiva: si el brazo apunta a la camara
                        # se ve corto. En boxeo el brazo siempre va hacia adelante,
                        # asi que el signo es siempre "hacia la pantalla" (negativo).
                        depth = (
                            foreshortening_depth(arm_len["upper"], upper_seen)
                            + foreshortening_depth(arm_len["fore"], fore_seen)
                        )

                        mp_z = (w.z - s.z) * width / shoulder_px

                        z_raw = (
                            -(1.0 - DEPTH_MEDIAPIPE_BLEND) * depth
                            + DEPTH_MEDIAPIPE_BLEND * mp_z
                        )
                        z_val = z_filters[side](z_raw, now)

                        arm_data[side] = {
                            "shoulder": {"x": round(s.x, 4), "y": round(s.y, 4)},
                            "elbow": {"x": round(e.x, 4), "y": round(e.y, 4)},
                            "wrist": {
                                "x": round(w.x, 4),
                                "y": round(w.y, 4),
                                "z": round(w.z, 4),
                                "visibility": round(float(w.visibility), 3)
                            },
                            "rel": {
                                "x": round((w.x - s.x) * width / shoulder_px, 4),
                                "y": round(-(w.y - s.y) * height / shoulder_px, 4),
                                "z": round(z_val, 4)
                            }
                        }

                    # --- GUARDIA / PAUSA (nariz vs munecas) ---
                    nose = lm[0]
                    if nose.visibility > 0.5:
                        mid_sh_y = (ls.y + rs.y) / 2.0
                        guard_now = (
                            hand_at_face(lm[15], nose, mid_sh_y, shoulder_px, width, height)
                            and hand_at_face(lm[16], nose, mid_sh_y, shoulder_px, width, height)
                        )
                        for wrist_lm in (lm[15], lm[16]):
                            if wrist_lm.visibility > 0.3 and (nose.y - wrist_lm.y) * height / shoulder_px > PAUSE_RAISE:
                                pause_pose = True

                    # --- CURSOR: palma de la mano preferida (o la muneca si no se detecta la mano) ---
                    other_hand = "left" if CURSOR_HAND == "right" else "right"
                    for cside in (CURSOR_HAND, other_hand):
                        pw = lm[sides[cside][2]]
                        if pw.visibility < 0.5:
                            continue
                        hand = pick_hand(results, pw, width, height, shoulder_px * 0.6)
                        if hand is not None:
                            hl = hand.landmark
                            cx, cy = hl[9].x, hl[9].y       # base del dedo medio: estable al pellizcar
                            palm = max(math.hypot((hl[9].x - hl[0].x) * width, (hl[9].y - hl[0].y) * height), 1.0)
                            pinch_d = math.hypot((hl[4].x - hl[8].x) * width, (hl[4].y - hl[8].y) * height) / palm
                            pinching = pinch_d < (PINCH_OFF if pinching else PINCH_ON)
                        else:
                            cx, cy = pw.x, pw.y
                            pinching = False
                        nx = clamp((cx - CURSOR_REGION[0]) / (CURSOR_REGION[1] - CURSOR_REGION[0]), 0.0, 1.0)
                        ny = clamp((cy - CURSOR_REGION[2]) / (CURSOR_REGION[3] - CURSOR_REGION[2]), 0.0, 1.0)
                        cursor_data = {
                            "x": round(cursor_fx(nx, frame_t), 4),
                            "y": round(cursor_fy(ny, frame_t), 4),
                            "visible": True,
                            "pinch": pinching
                        }
                        break

                    # --- ORIENTACION DE CADA MANO ---
                    # Ejes en espacio de juego: x = tu derecha, y = arriba, z = hacia tu cuerpo
                    # (igual que "rel"). f = muneca -> base del dedo medio, s = indice -> menique.
                    for oside in ("left", "right"):
                        pw = lm[sides[oside][2]]
                        if pw.visibility < 0.5:
                            continue
                        ohand = pick_hand(results, pw, width, height, shoulder_px * 0.6)
                        if ohand is None:
                            continue
                        hl = ohand.landmark

                        def axis(a, b):
                            return unit_vec((
                                (hl[b].x - hl[a].x) * width,
                                -(hl[b].y - hl[a].y) * height,
                                (hl[b].z - hl[a].z) * width
                            ))

                        f_vec, s_vec = axis(0, 9), axis(5, 17)
                        if f_vec is None or s_vec is None:
                            continue
                        fl = orient_filters[oside]
                        orient_data[oside] = {
                            "f": [round(fl[i](f_vec[i], frame_t), 4) for i in range(3)],
                            "s": [round(fl[3 + i](s_vec[i], frame_t), 4) for i in range(3)]
                        }

                # Dibujar solamente los brazos
                connections = [(11, 13), (13, 15), (12, 14), (14, 16)]

                for start, end in connections:

                    p1 = lm[start]
                    p2 = lm[end]

                    cv2.line(
                        frame,
                        (int(p1.x * width), int(p1.y * height)),
                        (int(p2.x * width), int(p2.y * height)),
                        (0, 255, 0),
                        3
                    )

            for oside, ofl in orient_filters.items():
                if oside not in orient_data:
                    for fil in ofl:
                        fil.reset()

            guard_state = guard_deb.update(guard_now)
            pause_state = pause_deb.update(pause_pose)

            if not cursor_data["visible"]:
                cursor_fx.reset()
                cursor_fy.reset()
                pinching = False

            for side, f in z_filters.items():
                if side not in arm_data:
                    f.reset()

            if tpose is not None:
                cv2.putText(
                    frame, "T-POSE: abre los brazos a los costados %d/%d" % (
                        len(tpose["upper"]) // 2, TPOSE_FRAMES),
                    (10, 75), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 165, 255), 2
                )

            if arm_data:
                cv2.putText(
                    frame,
                    "Z  L %+.2f  R %+.2f" % (
                        arm_data.get("left", {}).get("rel", {}).get("z", 0.0),
                        arm_data.get("right", {}).get("rel", {}).get("z", 0.0)
                    ),
                    (10, 50), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2
                )

            # =====================================
            # MANOS (por si luego quieren detectar puño cerrado)
            # =====================================

            hand_data = {"left": [], "right": []}

            if results.left_hand_landmarks:
                mp_drawing.draw_landmarks(
                    frame, results.left_hand_landmarks, mp_holistic.HAND_CONNECTIONS
                )
                hand_data["left"] = [
                    {"x": round(p.x, 4), "y": round(p.y, 4), "z": round(p.z, 4)}
                    for p in results.left_hand_landmarks.landmark
                ]

            if results.right_hand_landmarks:
                mp_drawing.draw_landmarks(
                    frame, results.right_hand_landmarks, mp_holistic.HAND_CONNECTIONS
                )
                hand_data["right"] = [
                    {"x": round(p.x, 4), "y": round(p.y, 4), "z": round(p.z, 4)}
                    for p in results.right_hand_landmarks.landmark
                ]

            # =====================================
            # CABEZA: rotacion + movimiento (esquivar / agacharse)
            # =====================================
            # yaw / pitch / roll en grados, relativos a la pose neutra calibrada.
            # x / y / z en METROS relativos a la pose neutra:
            #   x: + = te mueves a tu derecha
            #   y: + = subes (si te agachas es negativo)
            #   z: + = te inclinas hacia la pantalla

            head_data = {
                "yaw": 0.0, "pitch": 0.0, "roll": 0.0,
                "x": 0.0, "y": 0.0, "z": 0.0,
                "valid": False
            }

            status_text = "Sin cara"

            # Puntos de manos/munecas para saber que puntos de la cara estan tapados
            hand_pts = []
            if results.pose_landmarks:
                plm = results.pose_landmarks.landmark
                hand_pts += [
                    (plm[i].x * width, plm[i].y * height)
                    for i in range(15, 23) if plm[i].visibility > 0.3
                ]
            for hand in (results.left_hand_landmarks, results.right_hand_landmarks):
                if hand:
                    hand_pts += [(q.x * width, q.y * height) for q in hand.landmark]

            head = None

            if results.face_landmarks:

                head = estimate_head(results.face_landmarks.landmark, width, height, hand_pts)

                # Cada punto por separado: verde = se usa, rojo = tapado por una mano
                for k, i in enumerate(FACE_INDICES):
                    q = results.face_landmarks.landmark[i]
                    cv2.circle(
                        frame, (int(q.x * width), int(q.y * height)),
                        4, (0, 255, 0) if k in last_used else (0, 0, 255), -1
                    )

                if head is not None:
                    head = filter_head(head)

                if head is not None:

                    if calib_ref is None:

                        calib_samples.append(head)
                        status_text = "Calibrando... mira a la pantalla %d/%d" % (
                            len(calib_samples), CALIBRATION_FRAMES
                        )

                        if len(calib_samples) >= CALIBRATION_FRAMES:
                            calib_ref = np.mean(calib_samples, axis=0)

                    else:

                        yaw, pitch, roll, tx, ty, tz = head

                        head_data = {
                            "yaw": round(clamp(yaw - calib_ref[0], -60, 60), 2),
                            "pitch": round(clamp(pitch - calib_ref[1], -45, 45), 2),
                            "roll": round(clamp(roll - calib_ref[2], -30, 30), 2),
                            "x": round((tx - calib_ref[3]) / 1000.0, 4),
                            "y": round(-(ty - calib_ref[4]) / 1000.0, 4),
                            "z": round((calib_ref[5] - tz) / 1000.0, 4),
                            "valid": True
                        }
                        last_head_data = head_data

                        status_text = "yaw %+.0f pitch %+.0f roll %+.0f | pts %d/%d | C = recalibrar" % (
                            head_data["yaw"], head_data["pitch"], head_data["roll"],
                            len(last_used), len(FACE_INDICES)
                        )

            # Si no hay cabeza fiable (cara muy tapada) se mantiene la ultima buena
            if head is None:
                occ_frames += 1
                if occ_frames == 15:
                    reset_head_filter()     # tapada mucho rato: que el filtro arranque limpio al volver
                if calib_ref is not None and last_head_data is not None and occ_frames <= HEAD_HOLD_FRAMES:
                    head_data = last_head_data
                    status_text = "Cara tapada: manteniendo cabeza"
            else:
                occ_frames = 0

            cv2.putText(
                frame, status_text, (10, 25),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 0), 2
            )

            # Overlay: zona del cursor, guardia y gesto de pausa
            cv2.rectangle(
                frame,
                (int(CURSOR_REGION[0] * width), int(CURSOR_REGION[2] * height)),
                (int(CURSOR_REGION[1] * width), int(CURSOR_REGION[3] * height)),
                (90, 90, 90), 1
            )
            if cursor_data["visible"]:
                cpx = int((CURSOR_REGION[0] + cursor_data["x"] * (CURSOR_REGION[1] - CURSOR_REGION[0])) * width)
                cpy = int((CURSOR_REGION[2] + cursor_data["y"] * (CURSOR_REGION[3] - CURSOR_REGION[2])) * height)
                cv2.circle(frame, (cpx, cpy), 10, (0, 255, 255), -1 if cursor_data["pinch"] else 2)
            if guard_state:
                cv2.putText(frame, "GUARDIA", (10, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
            if pause_state:
                cv2.putText(frame, "MANO ARRIBA (pausa)", (10, 125), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 165, 255), 2)

            # =====================================
            # ENVIAR DATOS A GODOT
            # =====================================

            packet = {
                "t": round(frame_t, 4),          # segundos (reloj de Python): Godot calcula velocidades con esto
                "left": arm_data.get("left", {}),
                "right": arm_data.get("right", {}),
                "hands": hand_data,
                "head": head_data,
                "orient": orient_data,
                "guard": guard_state,
                "pause_pose": pause_state,
                "cursor": cursor_data
            }

            sock.sendto(
                json.dumps(packet).encode("utf-8"),
                GODOT_ADDRESS
            )

            # =====================================
            # CAMARA
            # =====================================

            cv2.imshow(window_name, frame)

            key = cv2.waitKey(1) & 0xFF

            if key == 27:
                break

            if key in (ord("t"), ord("T")):
                tpose = {"upper": [], "fore": []}
                reset_calibration()     # la cabeza se calibra a la vez, mirando a la pantalla

            if key in (ord("c"), ord("C")):
                reset_calibration()

            if cv2.getWindowProperty(window_name, cv2.WND_PROP_VISIBLE) < 1:
                break

finally:
    cap.release()
    sock.close()
    cv2.destroyAllWindows()