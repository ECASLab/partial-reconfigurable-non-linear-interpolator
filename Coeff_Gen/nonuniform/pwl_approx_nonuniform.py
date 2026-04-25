import os
import sys

import numpy as np

sys.path.append(os.path.dirname(os.path.dirname(__file__)))

from float_format import FloatFormat, quantize

def pwl_approx_nonuniform(
    func,
    func_dd,
    num_segments=16,
    x_min=-8.0,
    x_max=0.0,
    format: FloatFormat = None,
):
    """
    Piecewise linear approximation using non-uniform breakpoints guided
    by the second derivative function.

    Parameters
    ----------
    func : callable
        Function to approximate (e.g., np.exp).
    func_dd : callable
        Second derivative of the function (e.g., np.exp for exp(x)).
    num_segments : int
        Number of linear segments.
    x_min, x_max : float
        Domain of approximation.

    Returns
    -------
    xs : np.ndarray (float32)
        Non-uniform breakpoints.
    slopes : np.ndarray (float32)
        Slopes for each segment.
    intercepts : np.ndarray (float32)
        Offsets per segment, stored as b_over_m so y = m * (x + b_over_m).
    """

    ########################################################################
    # Compute cumulative weight function based on second derivative
    # w(x) = |f''(x)|, normalized to [0,1]
    # P(x) = (∫_a^x w(t) dt) / (∫_a^b w(t) dt)

    # For generality, approximate integrals numerically (trapezoidal rule).
    #######################################################################
    grid_size = 1000*num_segments # use a finer grid
    grid = np.linspace(x_min, x_max, grid_size, dtype=np.float64)
    dx = grid[1] - grid[0]

    # Compute grid values
    w_vals = np.abs(func_dd(grid)).astype(np.float64)

    # Integrate / Compute the CDF
    trapezoids = 0.5 * (w_vals[1:] + w_vals[:-1]) * dx
    cumulative = np.concatenate(([0.0], np.cumsum(trapezoids)))
    total = cumulative[-1]

    # Normalize
    if total == 0.0:
        cumulative = np.linspace(0.0, 1.0, len(cumulative))
    else:
        cumulative /= total  # normalize to [0,1]

    # Inverse mapping: for each p_i, find x_i such that P(x_i) ≈ p_i -> Interpolate the CDF with the expected number of segments
    ps = np.linspace(0.0, 1.0, num_segments+1)
    xs = np.interp(ps, cumulative, grid)
    xs[0] = x_min
    xs[-1] = x_max
    
    # Enforce monotonicity and avoid duplicate breakpoints in flat regions
    adjustments = []
    for i in range(1, len(xs)):
        if xs[i] <= xs[i - 1]:
            before = float(xs[i])
            xs[i] = np.nextafter(xs[i - 1], x_max)
            adjustments.append((i, before, float(xs[i])))
    if xs[-1] <= xs[-2]:
        before = float(xs[-1])
        xs[-1] = np.nextafter(xs[-2], x_max)
        adjustments.append((len(xs) - 1, before, float(xs[-1])))
    if adjustments:
        details = ", ".join(
            [f"i={idx} {before:.9g}->{after:.9g}" for idx, before, after in adjustments]
        )
        print(
            "[WARN] Non-uniform breakpoints adjusted for monotonicity: "
            f"{details}"
        )
    
    # Compute the coefficients
    xs = xs.astype(np.float32)
    slopes = np.zeros(num_segments, dtype=np.float32)
    intercepts = np.zeros(num_segments, dtype=np.float32)
    for i in range(num_segments):
        x0, x1 = xs[i], xs[i+1]
        y0 = float(func(float(x0)))
        y1 = float(func(float(x1)))
        if format is not None:
            limit = float(format.max_finite)
            y0 = float(np.clip(y0, -limit, limit))
            y1 = float(np.clip(y1, -limit, limit))
        dx = float(x1) - float(x0)
        if dx == 0.0:
            print(
                "[WARN] Non-uniform segment has zero width: "
                f"i={i} x0={x0:.9g} x1={x1:.9g}"
            )
            slope = 0.0
            bias = 0.0
            slopes[i] = np.float32(slope)
            intercepts[i] = np.float32(bias)
            continue
        slope = (y1 - y0) / dx   # slope
        intercept = y0 - slope * float(x0)
        bias = intercept / slope if slope != 0.0 else 0.0
        slopes[i] = np.float32(slope)
        intercepts[i] = np.float32(bias)

    return xs, slopes, intercepts


def pwl_eval_nonuniform(x, xs, slopes, intercepts, format: FloatFormat = None):
    x_q = quantize(x, format)
    seg = np.searchsorted(xs, x_q, side='right') - 1
    seg = np.clip(seg, 0, len(slopes)-1)
    slope_q = quantize(slopes[seg], format)
    bias_q = quantize(intercepts[seg], format)
    y = slope_q * (x_q + bias_q)
    return quantize(y, format)


def export_to_header_nonuniform(xs, slopes, intercepts,
                                func_name="exponential",
                                out_dir="HW/exponential"):
    import os
    os.makedirs(out_dir, exist_ok=True)
    filename = os.path.join(out_dir,
                            f"pwl_nonuniform_{func_name}_coefficients.hpp")

    with open(filename, "w") as f:
        f.write("/**\n")
        f.write(" *****************************************************\n")
        f.write(f" * \\file   pwl_nonuniform_{func_name}_coefficients.hpp\n")
        f.write(f" * \\brief  Auto-generated PWL coefficients for {func_name}.\n")
        f.write(" *****************************************************\n")
        f.write(" */\n")
        f.write("#pragma once\n\n")
        f.write("#include \"../common/config.h\"\n\n")
        f.write(f"namespace {func_name} {{\n\n")

        def fmt_val(val: float) -> str:
            return f"(DataT){float(val):.9g}"

        f.write(f"constexpr int NUM_SEGMENTS = {len(slopes)};\n")
        f.write(f"static const DataT MIN_X = {fmt_val(xs[0])};\n")
        f.write(f"static const DataT MAX_X = {fmt_val(xs[-1])};\n\n")

        # Breakpoints
        f.write("static const DataT breakpoints[NUM_SEGMENTS + 1] = {\n")
        f.write(", ".join([fmt_val(val) for val in xs]))
        f.write("\n};\n\n")

        # Slopes
        f.write("static const DataT slopes[NUM_SEGMENTS] = {\n")
        f.write(", ".join([fmt_val(val) for val in slopes]))
        f.write("\n};\n\n")

        # Intercepts
        f.write("static const DataT intercepts[NUM_SEGMENTS] = {\n")
        f.write(", ".join([fmt_val(val) for val in intercepts]))
        f.write("\n};\n\n")

        f.write(f"}} // namespace {func_name}\n")

    print(f"Header file {filename} generated.")


def run_nonuniform_generation(
    func,
    weight_func,
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
    for format in formats:
        fmt_tag = format.name.lower()
        xs, slopes, intercepts = pwl_approx_nonuniform(
            func,
            weight_func,
            num_segments=num_segments,
            x_min=x_min,
            x_max=x_max,
            format=format,
        )

        x_dense = np.linspace(x_min, x_max, num_evaluation_points, dtype=np.float64)
        y_true = func(x_dense)
        y_pred = np.array(
            [pwl_eval_nonuniform(x, xs, slopes, intercepts, format=format) for x in x_dense],
            dtype=np.float64,
        )
        error_metrics = compute_error_metrics(y_true, y_pred)
        print(
            f"[nonuniform {func_label}] {format.name} metrics: "
            f"max_abs={error_metrics['max_abs_error']:.6g}, "
            f"mean_abs={error_metrics['mean_abs_error']:.6g}, "
            f"rmse={error_metrics['rmse']:.6g}"
        )

        if plot:
            weights = weight_func(x_dense)
            plot_pwl_results(
                x_dense,
                y_true,
                y_pred,
                format,
                title=f"Nonuniform {func_label} ({format.name})",
                error_metrics=error_metrics,
                breakpoints=xs,
                weights=weights,
            )

        export_to_header_nonuniform(
            xs,
            slopes,
            intercepts,
            func_name=f"{func_label}_{fmt_tag}",
            out_dir=os.path.join(output_dir, fmt_tag),
        )

        print(f"[nonuniform {func_label}] {format.name}: range=({x_min:.6f},{x_max:.6f})")

