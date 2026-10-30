"""
stealth_pcg.visualization.curve_viz
====================================
Tension curve comparison plots: actual trace vs designer target,
multi-agent overlay, fitness convergence history.
"""

from __future__ import annotations

from typing import Sequence

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.simulation.agent import SimulationResult
from stealth_pcg.evolution.optimizer import EvolutionResult


def draw_curve_comparison(
    target_curve: TensionCurve,
    simulation_results: list[SimulationResult],
    agent_names: list[str] | None = None,
    *,
    ax: plt.Axes | None = None,
    title: str = "Tension Curve Comparison",
    figsize: tuple[float, float] = (12, 5),
) -> plt.Figure:
    """Plot target curve overlaid with actual simulation traces.

    Parameters
    ----------
    target_curve : TensionCurve
        Designer-defined target.
    simulation_results : list of SimulationResult
        One per agent type.
    agent_names : list of str, optional
        Labels for each agent trace.
    """
    if ax is None:
        fig, ax = plt.subplots(1, 1, figsize=figsize)
    else:
        fig = ax.figure

    # ── Draw target curve (smooth, high-res) ──
    target_x = np.linspace(0, 1, 200)
    target_y = [target_curve.evaluate(t) for t in target_x]
    ax.fill_between(target_x, target_y, alpha=0.1, color="#1976D2")
    ax.plot(target_x, target_y, color="#1976D2", linewidth=2.5,
            linestyle="--", label=f"Target: {target_curve.name}", zorder=3)

    # ── Draw control points ──
    cp_x = [p.x for p in target_curve.points]
    cp_y = [p.y for p in target_curve.points]
    ax.scatter(cp_x, cp_y, color="#1976D2", s=40, zorder=4,
               edgecolors="white", linewidths=1.5)

    # ── Draw simulation traces ──
    agent_colors = ["#E53935", "#43A047", "#FB8C00", "#8E24AA", "#00ACC1"]
    agent_markers = ["o", "s", "^", "D", "v"]

    if agent_names is None:
        agent_names = [f"Agent {i+1}" for i in range(len(simulation_results))]

    for i, (result, name) in enumerate(zip(simulation_results, agent_names)):
        if not result.tension_trace:
            continue

        n = len(result.tension_trace)
        if n < 2:
            continue

        x_vals = [j / (n - 1) for j in range(n)]
        color = agent_colors[i % len(agent_colors)]
        marker = agent_markers[i % len(agent_markers)]

        ax.plot(x_vals, result.tension_trace, color=color, linewidth=1.8,
                alpha=0.85, label=f"{name} ({'✓' if result.reached_exit else '✗'})",
                zorder=2)
        ax.scatter(x_vals, result.tension_trace, color=color, s=25,
                   marker=marker, alpha=0.7, zorder=2)

    ax.set_xlim(-0.02, 1.02)
    ax.set_ylim(-0.05, 1.05)
    ax.set_xlabel("Normalised Progress (ENTRY → EXIT)", fontsize=10)
    ax.set_ylabel("Tension", fontsize=10)
    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.legend(fontsize=8, loc="upper left", framealpha=0.9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    return fig


def draw_all_presets(
    *,
    figsize: tuple[float, float] = (14, 8),
) -> plt.Figure:
    """Draw all preset tension curve templates in a grid."""
    presets = TensionCurve.all_presets()
    n = len(presets)
    cols = 4
    rows = (n + cols - 1) // cols

    fig, axes = plt.subplots(rows, cols, figsize=figsize)
    axes = axes.flatten() if hasattr(axes, 'flatten') else [axes]

    for i, (name, curve) in enumerate(presets.items()):
        ax = axes[i]
        x = np.linspace(0, 1, 100)
        y = [curve.evaluate(t) for t in x]
        ax.fill_between(x, y, alpha=0.2, color="#1976D2")
        ax.plot(x, y, color="#1976D2", linewidth=2)

        # Control points
        cp_x = [p.x for p in curve.points]
        cp_y = [p.y for p in curve.points]
        ax.scatter(cp_x, cp_y, color="#E53935", s=30, zorder=4)

        ax.set_title(name, fontsize=10, fontweight="bold")
        ax.set_xlim(-0.02, 1.02)
        ax.set_ylim(-0.05, 1.05)
        ax.grid(True, alpha=0.3)
        ax.set_xticks([0, 0.5, 1])
        ax.set_yticks([0, 0.5, 1])

    # Hide unused axes
    for i in range(n, len(axes)):
        axes[i].set_visible(False)

    fig.suptitle("Preset Tension Curve Templates", fontsize=14, fontweight="bold")
    fig.tight_layout()
    return fig


def draw_fitness_history(
    result: EvolutionResult,
    *,
    ax: plt.Axes | None = None,
    title: str = "Evolution Fitness History",
    figsize: tuple[float, float] = (10, 4),
) -> plt.Figure:
    """Plot fitness convergence over generations."""
    if ax is None:
        fig, ax = plt.subplots(1, 1, figsize=figsize)
    else:
        fig = ax.figure

    gens = list(range(len(result.fitness_history)))
    ax.plot(gens, result.fitness_history, color="#E53935", linewidth=2,
            label="Best fitness")
    ax.plot(gens, result.avg_fitness_history[:len(gens)], color="#90A4AE",
            linewidth=1.2, alpha=0.7, label="Population avg")

    ax.axhline(y=result.best_fitness, color="#4CAF50", linestyle=":",
               alpha=0.5, label=f"Final best: {result.best_fitness:.4f}")

    if result.converged:
        ax.axvline(x=result.total_generations - 1, color="#FF9800",
                   linestyle="--", alpha=0.5, label="Converged (early stop)")

    ax.set_xlabel("Generation", fontsize=10)
    ax.set_ylabel("Fitness (lower = better)", fontsize=10)
    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    return fig


def draw_combined_report(
    target_curve: TensionCurve,
    simulation_results: list[SimulationResult],
    agent_names: list[str],
    evolution_result: EvolutionResult | None = None,
    *,
    figsize: tuple[float, float] = (14, 10),
) -> plt.Figure:
    """Generate a combined 2-panel (or 3-panel) report figure."""
    n_panels = 3 if evolution_result else 2
    fig, axes = plt.subplots(n_panels, 1, figsize=figsize)

    # Panel 1: curve comparison
    draw_curve_comparison(
        target_curve, simulation_results, agent_names,
        ax=axes[0], title="Tension Curves: Target vs Simulated"
    )

    # Panel 2: target only (smooth)
    ax2 = axes[1]
    x = np.linspace(0, 1, 200)
    y = [target_curve.evaluate(t) for t in x]
    ax2.fill_between(x, y, alpha=0.15, color="#1976D2")
    ax2.plot(x, y, color="#1976D2", linewidth=2)
    cp_x = [p.x for p in target_curve.points]
    cp_y = [p.y for p in target_curve.points]
    ax2.scatter(cp_x, cp_y, color="#E53935", s=50, zorder=4, edgecolors="white")
    ax2.set_title(f"Target Curve: {target_curve.name}", fontsize=12, fontweight="bold")
    ax2.set_xlim(-0.02, 1.02)
    ax2.set_ylim(-0.05, 1.05)
    ax2.set_xlabel("Progress")
    ax2.set_ylabel("Tension")
    ax2.grid(True, alpha=0.3)

    # Panel 3: fitness history
    if evolution_result and n_panels == 3:
        draw_fitness_history(evolution_result, ax=axes[2])

    fig.tight_layout()
    return fig
