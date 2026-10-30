"""
stealth_pcg.gui
================
Tkinter GUI for parameter input and pipeline execution.

Inputs parameters → runs the Python pipeline → saves results as PNG + HTML →
opens the output folder automatically.

Run:  python -m stealth_pcg.gui
"""

from __future__ import annotations

import os
import sys
import time
import threading
import webbrowser
from pathlib import Path

import tkinter as tk
from tkinter import ttk

# ── Ensure matplotlib uses non-interactive backend ──
import matplotlib
matplotlib.use("Agg")

from stealth_pcg.grammar.generator import LevelGenerator, GenerationConfig
from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.simulation.agent import (
    LevelSimulator, ShortestPathAgent, CautiousAgent, ExplorerAgent,
)
from stealth_pcg.simulation.tension import TensionWeights
from stealth_pcg.evolution.optimizer import Optimizer, EvolutionConfig
from stealth_pcg.evolution.fitness import FitnessEvaluator
from stealth_pcg.visualization.graph_viz import draw_graph, draw_proximity
from stealth_pcg.visualization.curve_viz import (
    draw_curve_comparison,
    draw_all_presets,
    draw_fitness_history,
)
from stealth_pcg.layout import (
    solve_layout, LayoutConfig, from_level_graph, layout_to_json,
)
from stealth_pcg.layout.refine import refine as refine_layout
from stealth_pcg.grammar.adjacency import (
    derive_shared_walls, AdjacencyConfig, adjacency_summary,
)
from stealth_pcg.evolution.wall_tuner import WallTuner, TunerConfig
from stealth_pcg.layout.render_html import render_report_fragment
from stealth_pcg.export.serializer import LevelSerializer, simulation_block

OUTPUT_DIR = Path("pcg_output")


class PipelineGUI:
    """Main GUI window."""

    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("Stealth PCG — Pipeline Launcher")
        self.root.configure(bg="#1a1a2e")
        self.root.geometry("520x820")
        self.root.resizable(False, True)

        self._build_ui()

    def _build_ui(self) -> None:
        r = self.root
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TLabel", background="#1a1a2e", foreground="#c9d1d9", font=("Consolas", 9))
        style.configure("Header.TLabel", background="#1a1a2e", foreground="#ffa657", font=("Consolas", 10, "bold"))
        style.configure("TButton", font=("Consolas", 11, "bold"))
        style.configure("TCombobox", font=("Consolas", 9))

        main = tk.Frame(r, bg="#1a1a2e", padx=20, pady=10)
        main.pack(fill="both", expand=True)

        # Title
        tk.Label(main, text="STEALTH PCG", bg="#1a1a2e", fg="#ffa657",
                 font=("Consolas", 16, "bold")).pack(pady=(0, 4))
        tk.Label(main, text="Pipeline Launcher", bg="#1a1a2e", fg="#6e7681",
                 font=("Consolas", 9)).pack(pady=(0, 12))

        # ── Generation Parameters ──
        self._section(main, "GENERATION")
        gen_frame = tk.Frame(main, bg="#161b22", bd=1, relief="solid", padx=12, pady=8)
        gen_frame.pack(fill="x", pady=(0, 8))

        self.seed = self._slider(gen_frame, "Seed", 0, 999, 42)
        self.num_extra_obj = self._slider(gen_frame, "Extra Objectives", 0, 3, 1)
        self.num_key_locks = self._slider(gen_frame, "Key-Locks", 0, 4, 2)
        self.num_chokes = self._slider(gen_frame, "Choke Points", 0, 3, 1)
        self.num_corridors = self._slider(gen_frame, "Corridors", 0, 6, 3)
        self.corridor_len = self._slider(gen_frame, "Corridor Length", 1, 4, 2)
        self.alt_prob = self._slider(gen_frame, "Alt Path %", 0, 100, 50)
        self.side_prob = self._slider(gen_frame, "Side Obj %", 0, 100, 50)
        self.prox_rate = self._slider(gen_frame, "Proximity %", 0, 100, 15)

        # ── Evolution Parameters ──
        self._section(main, "EVOLUTION")
        evo_frame = tk.Frame(main, bg="#161b22", bd=1, relief="solid", padx=12, pady=8)
        evo_frame.pack(fill="x", pady=(0, 8))

        self.pop_size = self._slider(evo_frame, "Population", 10, 100, 50)
        self.num_gens = self._slider(evo_frame, "Generations", 10, 150, 60)
        self.evo_seed = self._slider(evo_frame, "Evo Seed", 0, 999, 42)

        # ── Target Curve ──
        self._section(main, "TARGET CURVE")
        curve_frame = tk.Frame(main, bg="#161b22", bd=1, relief="solid", padx=12, pady=8)
        curve_frame.pack(fill="x", pady=(0, 12))

        preset_names = list(TensionCurve.all_presets().keys())
        row = tk.Frame(curve_frame, bg="#161b22")
        row.pack(fill="x")
        tk.Label(row, text="Preset:", bg="#161b22", fg="#8b949e",
                 font=("Consolas", 9), width=14, anchor="e").pack(side="left")
        self.preset_var = tk.StringVar(value="double_peak")
        combo = ttk.Combobox(row, textvariable=self.preset_var,
                             values=preset_names, state="readonly", width=18)
        combo.pack(side="left", padx=(8, 0))

        # ── Run Button ──
        self.run_btn = tk.Button(
            main, text="▶  RUN PIPELINE", bg="#ffa657", fg="#0d1117",
            font=("Consolas", 13, "bold"), bd=0, padx=20, pady=10,
            activebackground="#f76d47", cursor="hand2",
            command=self._on_run,
        )
        self.run_btn.pack(fill="x", pady=(4, 8))

        # ── Log Area ──
        self.log_text = tk.Text(main, bg="#0d1117", fg="#8b949e",
                                font=("Consolas", 8), height=8,
                                bd=1, relief="solid", wrap="word")
        self.log_text.pack(fill="x")

    def _section(self, parent: tk.Frame, text: str) -> None:
        tk.Label(parent, text=text, bg="#1a1a2e", fg="#58a6ff",
                 font=("Consolas", 9, "bold")).pack(anchor="w", pady=(6, 2))

    def _slider(self, parent: tk.Frame, label: str,
                min_val: int, max_val: int, default: int) -> tk.IntVar:
        var = tk.IntVar(value=default)
        row = tk.Frame(parent, bg="#161b22")
        row.pack(fill="x", pady=0)

        tk.Label(row, text=f"{label}:", bg="#161b22", fg="#8b949e",
                 font=("Consolas", 9), width=14, anchor="e").pack(side="left")
        scale = tk.Scale(row, from_=min_val, to=max_val, orient="horizontal",
                         variable=var, bg="#161b22", fg="#c9d1d9",
                         troughcolor="#21262d", highlightthickness=0,
                         sliderrelief="flat", font=("Consolas", 8),
                         length=200, showvalue=False)
        scale.pack(side="left", padx=(4, 0))
        val_label = tk.Label(row, textvariable=var, bg="#161b22", fg="#ffa657",
                             font=("Consolas", 10, "bold"), width=4)
        val_label.pack(side="left")

        return var

    def _log(self, msg: str) -> None:
        self.log_text.insert("end", msg + "\n")
        self.log_text.see("end")
        self.root.update_idletasks()

    def _on_run(self) -> None:
        self.run_btn.config(state="disabled", bg="#21262d", text="RUNNING...")
        self.log_text.delete("1.0", "end")
        thread = threading.Thread(target=self._run_pipeline, daemon=True)
        thread.start()

    def _run_pipeline(self) -> None:
        try:
            OUTPUT_DIR.mkdir(exist_ok=True)
            self._log("Starting pipeline...")

            # ── 1. Generate ──
            self._log("\n[1/7] Generating level structure...")
            gen_config = GenerationConfig(
                num_extra_objectives=self.num_extra_obj.get(),
                num_key_locks=self.num_key_locks.get(),
                num_choke_points=self.num_chokes.get(),
                num_corridor_expansions=self.num_corridors.get(),
                corridor_length=self.corridor_len.get(),
                path_diversity_prob=self.alt_prob.get() / 100,
                side_objective_prob=self.side_prob.get() / 100,
                leak_rate=self.prox_rate.get() / 100,
                seed=self.seed.get(),
            )
            gen = LevelGenerator(gen_config)
            graph = gen.generate()
            self._log(f"  {graph.summary()}")
            for line in gen.generation_log:
                self._log(f"  {line}")

            # ── 2. Simulate (before) ──
            # ── 2. 공간 배치 ──
            # 관선 재편: 배치가 경험 최적화보다 **앞**에 온다. 공유벽은
            # 무작위 지정이 아니라 이 배치 결과에서 읽어내는 기하적 사실이다.
            self._log("\n[2/7] Solving spatial layout...")
            layout_cfg = LayoutConfig(seed=self.seed.get())
            coarse = solve_layout(graph, layout_cfg)[1]
            self._log(f"  Rooms {int(coarse.stats['rooms'])}, "
                      f"doors {int(coarse.stats['doors'])}, "
                      f"corridors {int(coarse.stats['corridors_routed'])}")
            if coarse.stats["essential_unrouted"]:
                self._log(f"  WARNING: {int(coarse.stats['essential_unrouted'])} "
                          f"essential edge(s) unconnected")

            # ── 3. 인접 도출 ──
            self._log("\n[3/7] Deriving shared walls from geometry...")
            adj_cfg = AdjacencyConfig(seed=self.seed.get(),
                                      leak_rate=gen_config.leak_rate)
            nwalls = derive_shared_walls(graph, coarse, adj_cfg)
            asum = adjacency_summary(graph)
            self._log(f"  {nwalls} shared walls, {int(asum['leaky'])} leaky, "
                      f"{int(asum['windows_total'])} windows")

            self._log("\n[4/7] Simulating (before optimization)...")
            strategies = [ShortestPathAgent(), CautiousAgent()]
            agent_names = ["Shortest Path", "Cautious"]
            sim = LevelSimulator()
            results_before = []
            for strat, name in zip(strategies, agent_names):
                sim.strategy = strat
                r = sim.simulate(graph)
                results_before.append(r)
                status = "reached EXIT" if r.reached_exit else "STUCK"
                self._log(f"  {name}: {r.total_steps} steps, {status}")

            # ── 3. Evolve ──
            self._log("\n[5/7] Running evolution...")
            preset_name = self.preset_var.get()
            presets = TensionCurve.all_presets()
            target = presets.get(preset_name, TensionCurve.double_peak())

            evo_config = EvolutionConfig(
                population_size=self.pop_size.get(),
                num_generations=self.num_gens.get(),
                seed=self.evo_seed.get(),
                patience=20,
            )

            t0 = time.time()
            optimizer = Optimizer(
                graph, target,
                config=evo_config,
                on_generation=lambda g, b, a: self._log(
                    f"  Gen {g:3d}: best={b:.4f}  avg={a:.4f}"
                ) if g % 10 == 0 else None,
            )
            evo_result = optimizer.run()
            elapsed = time.time() - t0
            self._log(f"\n  Done in {elapsed:.1f}s")
            self._log(f"  Best fitness: {evo_result.best_fitness:.4f}")

            best_graph = evo_result.best_individual.graph

            # ── 4. Proximity tuning (local correction) ──
            self._log("\n[6/7] Running wall tuning...")
            tuner = WallTuner(
                target,
                config=TunerConfig(seed=self.evo_seed.get()),
            )
            tune_result = tuner.tune(best_graph)
            self._log(f"  Iterations: {tune_result.iterations_used}")
            self._log(f"  Walls changed: {tune_result.walls_changed} "
                      f"(windows +{tune_result.windows_added} "
                      f"-{tune_result.windows_removed})")
            self._log(f"  Fitness: {tune_result.initial_fitness:.4f} → {tune_result.final_fitness:.4f}")

            # ── 5. Simulate (after) ──
            self._log("\n[7/7] Simulating (after optimization)...")
            results_after = []
            for strat, name in zip(strategies, agent_names):
                sim.strategy = strat
                r = sim.simulate(best_graph)
                results_after.append(r)
                status = "reached EXIT" if r.reached_exit else "STUCK"
                self._log(f"  {name}: {r.total_steps} steps, {status}")

            # ── 정제 (L3) ──
            # separation 은 제6단계가 결정하므로 타일 단위 정제는 그 뒤에 온다.
            wall_sep = {frozenset((w.node_a, w.node_b)):
                        {"separation": w.separation}
                        for w in best_graph.proximity_links.values()}
            layout_data = from_level_graph(best_graph)
            tile_layout = refine_layout(layout_data, coarse, layout_cfg,
                                        walls=wall_sep)

            # ── Save outputs ──
            self._log("\nSaving outputs...")

            # JSON schema v2 (v1 fields + layout block)
            LevelSerializer(best_graph).write(
                str(OUTPUT_DIR / "level.json"),
                meta={
                    "seed": gen_config.seed,
                    "evo_seed": evo_config.seed,
                    "target_curve": preset_name,
                    "fitness": round(float(tune_result.final_fitness), 6),
                    "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
                },
                layout=layout_to_json(coarse, best_graph,
                                      refine_seed=gen_config.seed),
                simulation_results=simulation_block(results_after, agent_names),
            )
            self._log("  -> level.json  (schema v2)")

            # Standalone plan drawing
            from stealth_pcg.layout.render_html import write_report as write_plan
            write_plan(
                tile_layout, layout_data, str(OUTPUT_DIR / "layout_plan.html"),
                meta={"seed": str(gen_config.seed), "curve": preset_name,
                      "fitness": f"{tune_result.final_fitness:.4f}"},
            )
            self._log("  -> layout_plan.html")
            import matplotlib.pyplot as plt

            # Graph structure
            crit = graph.critical_path()
            fig = draw_graph(graph, path=crit, title="Generated Level — Critical Path")
            fig.savefig(OUTPUT_DIR / "graph_structure.png", dpi=150, bbox_inches="tight", facecolor="white")
            plt.close(fig)
            self._log("  → graph_structure.png")

            # Proximity layer
            if graph.proximity_count > 0:
                fig = draw_proximity(graph, title="Proximity Layer — Spatial Adjacency")
                fig.savefig(OUTPUT_DIR / "proximity_layer.png", dpi=150, bbox_inches="tight", facecolor="white")
                plt.close(fig)
                self._log(f"  → proximity_layer.png ({graph.proximity_count} links)")

            # Optimized graph
            for r, name in zip(results_after, agent_names):
                if r.reached_exit:
                    fig = draw_graph(best_graph, path=r.path,
                                     title=f"Optimized — {name}")
                    fname = f"optimized_{name.lower().replace(' ','_')}.png"
                    fig.savefig(OUTPUT_DIR / fname, dpi=150, bbox_inches="tight", facecolor="white")
                    plt.close(fig)
                    self._log(f"  → {fname}")

            # Before/after curves
            fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 5))
            draw_curve_comparison(target, results_before, agent_names,
                                  ax=ax1, title="BEFORE Optimization")
            draw_curve_comparison(target, results_after, agent_names,
                                  ax=ax2, title="AFTER Optimization")
            fig.savefig(OUTPUT_DIR / "curves_comparison.png", dpi=150, bbox_inches="tight", facecolor="white")
            plt.close(fig)
            self._log("  → curves_comparison.png")

            # Fitness history
            fig = draw_fitness_history(evo_result)
            fig.savefig(OUTPUT_DIR / "fitness_history.png", dpi=150, bbox_inches="tight", facecolor="white")
            plt.close(fig)
            self._log("  → fitness_history.png")

            # ── Generate HTML report ──
            self._generate_html_report(
                gen_config, evo_config, preset_name, graph, best_graph,
                results_before, results_after, agent_names, evo_result,
                tile_layout, layout_data,
            )
            self._log("  → report.html")

            self._log(f"\nAll outputs saved to: {OUTPUT_DIR.resolve()}")
            self._log("Opening output folder...")

            # Open output
            report_path = (OUTPUT_DIR / "report.html").resolve()
            webbrowser.open(report_path.as_uri())

        except Exception as e:
            self._log(f"\nERROR: {e}")
            import traceback
            self._log(traceback.format_exc())
        finally:
            self.root.after(0, lambda: self.run_btn.config(
                state="normal", bg="#ffa657", text="▶  RUN PIPELINE"
            ))

    def _generate_html_report(self, gen_cfg, evo_cfg, preset_name,
                               graph, best_graph,
                               results_before, results_after, agent_names,
                               evo_result, tile_layout=None,
                               layout_data=None) -> None:
        """Generate a self-contained HTML report with embedded images."""
        import base64

        def img_tag(filename: str) -> str:
            path = OUTPUT_DIR / filename
            if not path.exists():
                return ""
            with open(path, "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            return f'<img src="data:image/png;base64,{b64}" style="max-width:100%;border-radius:8px;margin:8px 0;">'

        if tile_layout is not None and layout_data is not None:
            layout_section = render_report_fragment(
                tile_layout, layout_data,
                meta={"seed": str(gen_cfg.seed), "curve": preset_name},
                theme="dark",
            )
        else:
            layout_section = '<p style="color:#8b949e">Layout stage skipped.</p>'

        html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>Stealth PCG Report</title>
<style>
  body {{ font-family: 'Consolas', monospace; background: #0d1117; color: #c9d1d9; padding: 32px; max-width: 1200px; margin: 0 auto; }}
  h1 {{ color: #ffa657; }} h2 {{ color: #58a6ff; border-bottom: 1px solid #21262d; padding-bottom: 8px; }}
  .stat {{ display: inline-block; background: #161b22; border: 1px solid #21262d; border-radius: 8px; padding: 12px 20px; margin: 4px; text-align: center; }}
  .stat .value {{ font-size: 24px; font-weight: bold; color: #3fb950; }}
  .stat .label {{ font-size: 11px; color: #8b949e; }}
  table {{ border-collapse: collapse; width: 100%; margin: 12px 0; }}
  th, td {{ border: 1px solid #21262d; padding: 6px 12px; text-align: left; font-size: 12px; }}
  th {{ background: #161b22; color: #58a6ff; }}
  .section {{ background: #161b22; border: 1px solid #21262d; border-radius: 8px; padding: 16px; margin: 16px 0; }}
</style></head><body>
<h1>Stealth PCG — Pipeline Report</h1>
<p style="color:#8b949e">Generated at {time.strftime('%Y-%m-%d %H:%M:%S')}</p>

<div>
  <div class="stat"><div class="value">{graph.node_count}</div><div class="label">Nodes</div></div>
  <div class="stat"><div class="value">{graph.edge_count}</div><div class="label">Edges</div></div>
  <div class="stat"><div class="value" style="color:#ffa657">{evo_result.total_generations}</div><div class="label">Generations</div></div>
  <div class="stat"><div class="value">{evo_result.best_fitness:.4f}</div><div class="label">Best Fitness</div></div>
</div>

<h2>Parameters</h2>
<div class="section">
<table>
<tr><th>Parameter</th><th>Value</th><th>Parameter</th><th>Value</th></tr>
<tr><td>Seed</td><td>{gen_cfg.seed}</td><td>Population</td><td>{evo_cfg.population_size}</td></tr>
<tr><td>Extra Objectives</td><td>{gen_cfg.num_extra_objectives}</td><td>Generations</td><td>{evo_cfg.num_generations}</td></tr>
<tr><td>Key-Locks</td><td>{gen_cfg.num_key_locks}</td><td>Evo Seed</td><td>{evo_cfg.seed}</td></tr>
<tr><td>Choke Points</td><td>{gen_cfg.num_choke_points}</td><td>Target Curve</td><td>{preset_name}</td></tr>
<tr><td>Corridors</td><td>{gen_cfg.num_corridor_expansions}</td><td>Corridor Length</td><td>{gen_cfg.corridor_length}</td></tr>
</table>
</div>

<h2>Level Structure</h2>
<div class="section">{img_tag("graph_structure.png")}</div>

<h2>Proximity Layer</h2>
<div class="section">{img_tag("proximity_layer.png") if (OUTPUT_DIR / "proximity_layer.png").exists() else '<p style="color:#8b949e">No proximity links generated (rate=0%)</p>'}</div>

<h2>Spatial Layout — Stage 6</h2>
<div class="section">{layout_section}</div>

<h2>Tension Curves: Before vs After</h2>
<div class="section">{img_tag("curves_comparison.png")}</div>

<h2>Optimized Level — Agent Paths</h2>
<div class="section">
{''.join(img_tag(f"optimized_{n.lower().replace(' ','_')}.png") for n in agent_names)}
</div>

<h2>Evolution Fitness History</h2>
<div class="section">{img_tag("fitness_history.png")}</div>

</body></html>"""

        with open(OUTPUT_DIR / "report.html", "w", encoding="utf-8") as f:
            f.write(html)

    def run(self) -> None:
        self.root.mainloop()


def main() -> None:
    app = PipelineGUI()
    app.run()


if __name__ == "__main__":
    main()
