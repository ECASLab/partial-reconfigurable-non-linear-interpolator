from __future__ import annotations

from typing import Dict

import numpy as np


def compute_error_metrics(y_true: np.ndarray, y_pred: np.ndarray) -> Dict[str, np.ndarray | float]:
    y_true = np.asarray(y_true, dtype=np.float64)
    y_pred = np.asarray(y_pred, dtype=np.float64)
    err = y_pred - y_true
    abs_err = np.abs(err)
    return {
        "error": err,
        "abs_error": abs_err,
        "max_abs_error": float(np.max(abs_err)),
        "mean_abs_error": float(np.mean(abs_err)),
        "rmse": float(np.sqrt(np.mean(err ** 2))),
    }

def plot_pwl_results(
    x_values: np.ndarray,
    y_true: np.ndarray,
    y_pred: np.ndarray,
    format,
    title: str,
    error_metrics: Dict[str, np.ndarray | float],
    breakpoints: np.ndarray | None = None,
    weights: np.ndarray | None = None,
) -> None:
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("[WARN] matplotlib not available, skipping plots.")
        return

    # Create np_arrays for input data
    x_values = np.asarray(x_values, dtype=np.float64)
    y_true = np.asarray(y_true, dtype=np.float64)
    y_pred = np.asarray(y_pred, dtype=np.float64)

    # Adjust subplots layout
    has_weights = weights is not None
    if has_weights:
        fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(9, 8), sharex=True)
    else:
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(9, 7), sharex=True)

    # Plot true and approximation functions
    ax1.plot(x_values, y_true, label="True", color="blue")
    ax1.plot(x_values, y_pred, label="PWL", color="red", linestyle="--")
    ax1.set_ylabel("Value")
    ax1.set_title(title)
    ax1.legend()
    ax1.grid(True)

    # Plot Error
    if "abs_error" not in error_metrics:
        raise ValueError("error_metrics must include 'abs_error'.")
    ax2.plot(x_values, error_metrics["abs_error"], color="green")
    ax2.set_ylabel("Absolute Error")
    ax2.grid(True)

    # Plot weight function if provided
    if has_weights:
        weights = np.asarray(weights, dtype=np.float64)
        ax3.plot(x_values, weights, color="brown")
        ax3.set_xlabel("x")
        ax3.set_ylabel("Weight")
        ax3.grid(True)

    plt.tight_layout()
    plt.show()
