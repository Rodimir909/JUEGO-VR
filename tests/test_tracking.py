"""Pruebas del seguimiento sin cámara ni paquetes externos."""
import copy
import json
import math
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "BoxingGames" / "Python"))
from tracking_core import OneEuro, TrackingCore


def guard_pose():
    points = [{"x": 0.5, "y": 0.5, "z": 0.0, "visibility": 1.0} for _ in range(33)]
    for index, x, y, z in ((11, 0.65, 0.55, 0), (12, 0.35, 0.55, 0),
                           (13, 0.72, 0.7, -0.1), (14, 0.28, 0.7, -0.1),
                           (15, 0.58, 0.36, -0.12), (16, 0.42, 0.36, -0.12),
                           (2, 0.54, 0.25, 0), (5, 0.46, 0.25, 0)):
        points[index].update(x=x, y=y, z=z)
    return points


class TrackingTests(unittest.TestCase):
    def setUp(self):
        self.core = TrackingCore()
        self.pose = guard_pose()
        self.t = 100.0

    def update(self, pose=None, hands=None):
        self.t += 1 / 30
        return self.core.update(self.pose if pose is None else pose, None, hands or {}, self.t)

    def calibrate(self):
        for _ in range(40):
            packet = self.update()
        self.assertTrue(packet["calibrated"])
        return packet

    def test_calibration_requires_both_arms_and_stable_guard(self):
        missing = copy.deepcopy(self.pose)
        missing[15]["visibility"] = 0.1
        for _ in range(50):
            self.assertFalse(self.update(missing)["calibrated"])
        self.calibrate()

    def test_guard_is_not_an_extended_punch(self):
        packet = self.calibrate()
        self.assertTrue(packet["guard"])
        self.assertAlmostEqual(packet["left"]["rel"]["z"], -0.45, places=4)
        extension = copy.deepcopy(self.pose)
        extension[15]["z"] = -0.65
        for _ in range(8):
            packet = self.update(extension)
        self.assertLess(packet["left"]["rel"]["z"], -1.0)
        self.assertFalse(packet["guard"])

    def test_crossed_hands_keep_anatomical_identity(self):
        self.calibrate()
        crossed = copy.deepcopy(self.pose)
        crossed[15]["x"], crossed[16]["x"] = 0.4, 0.6
        for _ in range(12):
            packet = self.update(crossed)
        self.assertGreater(packet["left"]["rel"]["x"], 0)
        self.assertLess(packet["right"]["rel"]["x"], 0)

    def test_visibility_loss_removes_guard_and_old_hands(self):
        self.calibrate()
        lost = copy.deepcopy(self.pose)
        lost[15]["visibility"] = 0.1
        packet = self.update(lost)
        self.assertEqual(packet["left"], {})
        self.assertFalse(packet["guard"])
        packet = self.core.update(None, None, {}, self.t + 1)
        self.assertFalse(packet["calibrated"])
        self.assertFalse(packet["head"]["valid"])
        self.assertFalse(packet["cursor"]["visible"])

    def test_body_duck_moves_head_without_rotating_camera(self):
        self.calibrate()
        duck = copy.deepcopy(self.pose)
        for point in duck:
            point["y"] += 0.25
        for _ in range(12):
            packet = self.update(duck)
        self.assertLess(packet["head"]["y"], -0.2)
        self.assertEqual(packet["head"]["yaw"], 0)

    def test_depth_change_does_not_create_false_sideways_dodge(self):
        self.calibrate()
        approaching = copy.deepcopy(self.pose)
        for point in approaching:
            point["x"] = 0.5 + (point["x"] - 0.5) * 1.3
        for _ in range(20):
            packet = self.update(approaching)
        self.assertAlmostEqual(packet["head"]["x"], 0.0, places=5)

    def test_guard_survives_face_occlusion_using_torso_reference(self):
        self.calibrate()
        occluded = copy.deepcopy(self.pose)
        occluded[2]["visibility"] = occluded[5]["visibility"] = 0.1
        for _ in range(8):
            packet = self.update(occluded)
        self.assertTrue(packet["guard"])

    def test_recalibrate_clears_previous_reference(self):
        self.calibrate()
        self.core.calibrate()
        self.assertFalse(self.update()["calibrated"])
        self.calibrate()

    def test_packet_has_real_timestamp_and_serializes_without_nan(self):
        packet = self.calibrate()
        self.assertEqual(packet["t"], self.t)
        self.assertEqual(packet["version"], 2)
        self.assertEqual(packet["frame"], 40)
        self.assertEqual(json.loads(json.dumps(packet, allow_nan=False))["frame"], 40)

    def test_corrupt_landmarks_do_not_reach_game(self):
        self.pose[11]["x"] = math.nan
        packet = self.update()
        self.assertEqual(packet["left"], {})
        json.dumps(packet, allow_nan=False)

    def test_occluded_hand_falls_back_to_pose(self):
        packet = self.calibrate()
        self.assertTrue(packet["left"])
        self.assertTrue(packet["right"])
        self.assertFalse(packet["cursor"]["visible"])

    def test_detailed_hand_rescues_occluded_pose_wrist(self):
        self.calibrate()
        occluded = copy.deepcopy(self.pose)
        occluded[15]["visibility"] = 0.2
        hand = [dict(occluded[15], visibility=1.0) for _ in range(21)]
        packet = self.update(occluded, {"left": hand})
        self.assertTrue(packet["left"])
        self.assertGreaterEqual(packet["left"]["wrist"]["visibility"], 0.5)

    def test_filter_damps_jitter_and_resets_after_gap(self):
        f = OneEuro()
        values = [f(0.01 * (-1) ** i, i / 30) for i in range(60)]
        self.assertLess(max(values[10:]) - min(values[10:]), 0.01)
        self.assertEqual(f(1, 10), 1)
        self.assertEqual(f(2, 9), 1)
        with self.assertRaises(ValueError):
            f(math.nan, 11)


if __name__ == "__main__":
    unittest.main()
