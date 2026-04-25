import os
import sys

import numpy as np

sys.path.append(os.path.dirname(os.path.dirname(__file__)))

from float_format import builtin_formats
from pwl_approx_uniform import run_uniform_generation

if __name__ == "__main__":
    plot = False
    num_segments = 256
    num_evaluation_points = 10_000
    input_range_override = (-8.0, 8.0)

    formats = builtin_formats()
    selected = [formats["FP32"], formats["FP16"]]
    func = np.exp

    run_uniform_generation(
        func=func,
        func_label="exponential",
        formats=selected,
        input_range=input_range_override,
        num_segments=num_segments,
        num_evaluation_points=num_evaluation_points,
        plot=plot,
        output_dir="coefficients",
    )