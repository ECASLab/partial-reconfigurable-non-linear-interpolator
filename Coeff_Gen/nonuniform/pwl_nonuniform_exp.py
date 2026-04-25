import os
import sys

import numpy as np

sys.path.append(os.path.dirname(os.path.dirname(__file__)))

from float_format import builtin_formats
from pwl_approx_nonuniform import run_nonuniform_generation


def test_nonuniform_exponential():
    # Function and its second derivative
    func = np.exp
    func_dd = lambda x: np.exp(x)

    num_segments = 256
    input_range_override = (-8.0, 8.0)
    plot = False

    formats = builtin_formats()
    selected = [formats["FP32"], formats["FP16"]]
    def weight_func(x):
        x = np.asarray(x, dtype=np.float64)
        return np.abs(func_dd(x)) ** 0.4

    run_nonuniform_generation(
        func=func,
        weight_func=weight_func,
        func_label="exponential",
        formats=selected,
        input_range=input_range_override,
        num_segments=num_segments,
        num_evaluation_points=2000,
        plot=plot,
        output_dir="coefficients",
    )


if __name__ == "__main__":
    test_nonuniform_exponential()