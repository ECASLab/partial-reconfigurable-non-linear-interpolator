import os
import sys

import numpy as np

sys.path.append(os.path.dirname(os.path.dirname(__file__)))

from float_format import builtin_formats
from pwl_approx_uniform import run_uniform_generation


if __name__ == "__main__":
    plot = False
    input_range_override = (-8.0, 8.0)
    formats = builtin_formats()
    selected = [formats["FP32"], formats["FP16"]]

    sigmoid = lambda x: 1.0 / (1.0 + np.exp(-x))

    num_segments = 256
    run_uniform_generation(
        func=sigmoid,
        func_label="sigmoid",
        formats=selected,
        input_range=input_range_override,
        num_segments=num_segments,
        num_evaluation_points=2000,
        plot=plot,
        output_dir="coefficients",
    )