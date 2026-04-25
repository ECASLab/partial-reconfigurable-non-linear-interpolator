from __future__ import annotations

from dataclasses import dataclass
from typing import Dict

import numpy as np


@dataclass(frozen=True)
class FloatFormat:
    name: str
    exp_bits: int
    mant_bits: int
    bias: int

    @property
    def exp_max(self) -> int:
        return (2 ** self.exp_bits - 2) - self.bias

    @property
    def max_finite(self) -> float:
        # Largest finite value (all-ones exponent reserved for inf/NaN).
        return (2 - 2 ** (-self.mant_bits)) * 2 ** self.exp_max


def builtin_formats() -> Dict[str, FloatFormat]:
    return {
        "FP32": FloatFormat("FP32", 8, 23, 127),
        "FP16": FloatFormat("FP16", 5, 10, 15),
        "FP8_E5M2": FloatFormat("FP8_E5M2", 5, 2, 15),
        "FP4_E2M1": FloatFormat("FP4_E2M1", 2, 1, 1),
    }


def quantize(value, fmt: FloatFormat):
    if fmt is None:
        return value
    if fmt.name == "FP16":
        return np.asarray(value, dtype=np.float16).astype(np.float64)
    if fmt.name == "FP32":
        return np.asarray(value, dtype=np.float32).astype(np.float64)
    return value
