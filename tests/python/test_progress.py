from __future__ import annotations

import unittest
from datetime import datetime, timezone

from wardrobe_gen.progress import ProgressTracker, format_duration


class _FakeClock:
    def __init__(self) -> None:
        self.current = 0.0

    def __call__(self) -> float:
        return self.current

    def advance(self, seconds: float) -> None:
        self.current += seconds


class ProgressTrackerTest(unittest.TestCase):
    def test_rolling_average_uses_window(self) -> None:
        clock = _FakeClock()
        def now() -> datetime:
            return datetime(2026, 2, 21, 10, 0, 0, tzinfo=timezone.utc)
        tracker = ProgressTracker(
            name="render",
            total_units=5,
            window_size=3,
            _clock_fn=clock,
            _now_fn=now,
        )

        tracker.record_step(1.0, label="a", success=True)
        tracker.record_step(2.0, label="b", success=True)
        tracker.record_step(3.0, label="c", success=True)
        tracker.record_step(10.0, label="d", success=True)

        self.assertAlmostEqual(tracker.rolling_average_seconds() or 0.0, 5.0, places=6)
        self.assertAlmostEqual(tracker.eta_seconds() or 0.0, 5.0, places=6)

    def test_eta_after_first_step(self) -> None:
        clock = _FakeClock()
        def now() -> datetime:
            return datetime(2026, 2, 21, 10, 0, 0, tzinfo=timezone.utc)
        tracker = ProgressTracker(
            name="classify",
            total_units=5,
            _clock_fn=clock,
            _now_fn=now,
        )

        tracker.record_step(2.0, label="item=pending-1", success=True)
        self.assertAlmostEqual(tracker.eta_seconds() or 0.0, 8.0, places=6)
        self.assertEqual(tracker.finish_time().strftime("%H:%M:%S"), "10:00:08")

    def test_format_helpers(self) -> None:
        self.assertEqual(format_duration(14), "14s")
        self.assertEqual(format_duration(125), "2m 05s")
        self.assertEqual(format_duration(3723), "1h 02m 03s")

    def test_format_line_contains_status_eta_and_label(self) -> None:
        clock = _FakeClock()
        def now() -> datetime:
            return datetime(2026, 2, 21, 10, 0, 0, tzinfo=timezone.utc)
        tracker = ProgressTracker(
            name="classify",
            total_units=2,
            _clock_fn=clock,
            _now_fn=now,
        )
        tracker.record_step(4.0, label="item=pending-1", success=True)

        ok_line = tracker.format_line(label="item=pending-1", success=True)
        self.assertIn("[classify]", ok_line)
        self.assertIn("1/2", ok_line)
        self.assertIn("ETA", ok_line)
        self.assertIn("status=ok", ok_line)
        self.assertIn("item=pending-1", ok_line)

        error_line = tracker.format_line(label="item=pending-2", success=False)
        self.assertIn("status=error", error_line)


if __name__ == "__main__":
    unittest.main()
