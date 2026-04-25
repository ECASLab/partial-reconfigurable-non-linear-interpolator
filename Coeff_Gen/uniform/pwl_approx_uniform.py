import os
import sys

import numpy as np

sys.path.append(os.path.dirname(os.path.dirname(__file__)))

from float_format import FloatFormat, quantize

def compute_pwl_uniform_coefficients(
    func,
    num_segments=16,
    x_min=-8.0,
    x_max=0.0,
    format: FloatFormat = None,
):
    """
    Compute piecewise linear approximation coefficients for a given function
    over a specified range, using float32 precision.

    Parameters
    ----------
    func : callable
        Function to approximate (e.g., np.exp, np.tanh, sigmoid).
    num_segments : int
        Number of linear segments.
    x_min, x_max : float
        Domain of approximation.

    Returns
    -------
    xs : np.ndarray (float32)
        Breakpoints.
    slopes : np.ndarray (float32)
        Slopes for each segment.
    intercepts : np.ndarray (float32)
        Offsets per segment, stored as b_over_m so y = m * (x + b_over_m).
    """

    # Breakpoints in float32
    xs = np.linspace(x_min, x_max, num_segments+1, dtype=np.float32)

    slopes = np.zeros(num_segments, dtype=np.float32)
    intercepts = np.zeros(num_segments, dtype=np.float32)

    for i in range(num_segments):
        x0, x1 = xs[i], xs[i+1]
        y0 = float(func(float(x0)))
        y1 = float(func(float(x1)))
        if format is not None: # Clip to format maximum representable value
            y0 = min(y0, format.max_finite)
            y1 = min(y1, format.max_finite)
        
        # Compute slope and intercept values
        slope = (y1 - y0) / (float(x1) - float(x0))   # slope
        b_intercept = y0 - slope * float(x0)                  # intercept
        bias = b_intercept / slope if slope != 0.0 else 0.0
        slopes[i] = np.float32(slope)
        intercepts[i] = np.float32(bias)

    return xs, slopes, intercepts

def evaluate_pwl_uniform(x, xs, slopes, intercepts, format: FloatFormat = None):
    # Find segment index
    x_q = quantize(x, format)
    seg = np.searchsorted(xs, x_q, side='right') - 1
    seg = np.clip(seg, 0, len(slopes)-1)
    slope_q = quantize(slopes[seg], format)
    bias_q = quantize(intercepts[seg], format)
    y = slope_q * (x_q + bias_q)
    return quantize(y, format)

def export_pwl_uniform_header(
    xs,
    slopes,
    intercepts,
    func_name="default_function",
    out_dir="coefficients/default_function",
):
    # Create output directory
    os.makedirs(out_dir, exist_ok=True)
    filename = os.path.join(out_dir,
                            f"pwl_uniform_{func_name}_coefficients.hpp")

    with open(filename, "w") as f:
        f.write("/**\n")
        f.write(" *****************************************************\n")
        f.write(f" * \\file   pwl_uniform_{func_name}_coefficients.hpp\n")
        f.write(f" * \\brief  Auto-generated PWL coefficients for {func_name}.\n")
        f.write(" *****************************************************\n")
        f.write(" */\n")
        f.write("#pragma once\n\n")
        f.write(f"#include \"config.h\"\n\n")   # ensure DataT is defined
        f.write(f"namespace {func_name} {{\n\n")

        f.write(f"constexpr int NUM_SEGMENTS = {len(slopes)};\n")
        f.write(f"static const DataT MIN_X = (DataT){xs[0]:.6f};\n")
        f.write(f"static const DataT MAX_X = (DataT){xs[-1]:.6f};\n\n")

        # Slopes
        f.write("static const DataT slopes[NUM_SEGMENTS] = {\n")
        f.write(", ".join([f"(DataT){val:.6f}" for val in slopes]))
        f.write("\n};\n\n")

        f.write("static const DataT intercepts[NUM_SEGMENTS] = {\n")
        f.write(", ".join([f"(DataT){val:.6f}" for val in intercepts]))
        f.write("\n};\n\n")

        f.write(f"}} // namespace {func_name}\n")

    print(f"Header file {filename} generated.")


def run_uniform_generation(
    func,
    func_label: str,
    formats,
    input_range,
    num_segments: int,
    num_evaluation_points: int,
    plot: bool,
    output_dir: str = "coefficients",
):
    from pwl_results_helpers import compute_error_metrics, plot_pwl_results

    x_min, x_max = input_range
    for fmt in formats:
        fmt_tag = fmt.name.lower()
        xs, slopes, intercepts = compute_pwl_uniform_coefficients(
            func,
            num_segments=num_segments,
            x_min=x_min,
            x_max=x_max,
            format=fmt,
        )

        x_dense = np.linspace(x_min, x_max, num_evaluation_points, dtype=np.float64)
        y_true = func(x_dense)
        y_pred = np.array(
            [evaluate_pwl_uniform(x, xs, slopes, intercepts, format=fmt) for x in x_dense],
            dtype=np.float64,
        )
        error_metrics = compute_error_metrics(y_true, y_pred)
        print(
            f"[uniform {func_label}] {fmt.name} metrics: "
            f"max_abs={error_metrics['max_abs_error']:.6g}, "
            f"mean_abs={error_metrics['mean_abs_error']:.6g}, "
            f"rmse={error_metrics['rmse']:.6g}"
        )

        if plot:
            plot_pwl_results(
                x_dense,
                y_true,
                y_pred,
                fmt,
                title=f"Uniform {func_label} ({fmt.name})",
                error_metrics=error_metrics,
                breakpoints=xs,
            )

        export_pwl_uniform_header(
            xs,
            slopes,
            intercepts,
            func_name=f"{func_label}_{fmt_tag}",
            out_dir=os.path.join(output_dir, fmt_tag),
        )

        print(f"[{func_label}] {fmt.name}: range=({x_min:.6f},{x_max:.6f})")
