from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Callable


def format_duration(seconds: float) -> str:
    total_seconds = max(0, int(round(seconds)))
    hours, remainder = divmod(total_seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours > 0:
        return f"{hours}h {minutes:02d}m {secs:02d}s"
    if minutes > 0:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


@dataclass
class ProgressTracker:
    name: str
    total_units: int
    window_size: int = 20
    bar_width: int = 24
    _now_fn: Callable[[], datetime] = datetime.now
    _clock_fn: Callable[[], float] = time.perf_counter
    completed_units: int = 0
    start_ts: float = field(init=False)
    last_durations: deque[float] = field(init=False)

    def __post_init__(self) -> None:
        self.total_units = max(0, int(self.total_units))
        self.window_size = max(1, int(self.window_size))
        self.bar_width = max(5, int(self.bar_width))
        self.start_ts = self._clock_fn()
        self.last_durations = deque(maxlen=self.window_size)

    def elapsed_seconds(self) -> float:
        return max(0.0, self._clock_fn() - self.start_ts)

    def record_step(self, duration_sec: float, label: str, success: bool = True) -> None:
        _ = (label, success)
        if self.total_units <= 0:
            return
        self.completed_units = min(self.total_units, self.completed_units + 1)
        self.last_durations.append(max(0.0, float(duration_sec)))

    def rolling_average_seconds(self) -> float | None:
        if not self.last_durations:
            return None
        return sum(self.last_durations) / len(self.last_durations)

    def eta_seconds(self) -> float | None:
        if self.total_units <= 0 or self.completed_units <= 0:
            return None
        remaining = max(0, self.total_units - self.completed_units)
        if remaining == 0:
            return 0.0
        avg = self.rolling_average_seconds()
        if avg is None:
            return None
        return avg * remaining

    def finish_time(self) -> datetime | None:
        eta = self.eta_seconds()
        if eta is None:
            return None
        return self._now_fn() + timedelta(seconds=eta)

    def format_start_line(self) -> str:
        if self.total_units <= 0:
            return f"[{self.name}] nothing to do (0 items planned)."
        bar = "-" * self.bar_width
        return (
            f"[{self.name}] [{bar}] 0/{self.total_units} (0.0%) "
            f"avg({self.window_size})=-- ETA -- fertig ca. -- status=start"
        )

    def format_line(self, label: str, success: bool = True) -> str:
        total = max(0, self.total_units)
        completed = min(total, self.completed_units)
        percent = 100.0 if total == 0 else (completed / total) * 100.0
        filled = 0 if total == 0 else int(round((completed / total) * self.bar_width))
        filled = max(0, min(self.bar_width, filled))
        bar = ("#" * filled) + ("-" * (self.bar_width - filled))

        avg = self.rolling_average_seconds()
        avg_text = "--" if avg is None else f"{avg:.1f}s"
        eta = self.eta_seconds()
        eta_text = "--" if eta is None else format_duration(eta)
        finish_at = self.finish_time()
        finish_text = "--" if finish_at is None else finish_at.strftime("%H:%M:%S")
        status = "ok" if success else "error"

        return (
            f"[{self.name}] [{bar}] {completed}/{total} ({percent:.1f}%) "
            f"avg({self.window_size})={avg_text} ETA {eta_text} fertig ca. {finish_text} "
            f"status={status} {label}"
        )

    def format_finish_line(self) -> str:
        elapsed = format_duration(self.elapsed_seconds())
        if self.total_units <= 0:
            return f"[{self.name}] complete 0/0 elapsed={elapsed}"
        return f"[{self.name}] complete {self.completed_units}/{self.total_units} elapsed={elapsed}"
