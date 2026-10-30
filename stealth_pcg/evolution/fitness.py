"""
stealth_pcg.evolution.fitness
=============================
Fitness evaluation: run simulation → compute DTW against target curve.
"""

from __future__ import annotations

from stealth_pcg.core.graph import LevelGraph
from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.curves.dtw_wrapper import curve_fitness
from stealth_pcg.simulation.agent import (
    LevelSimulator,
    AgentStrategy,
    ShortestPathAgent,
    CautiousAgent,
    SimulationResult,
)
from stealth_pcg.simulation.tension import TensionWeights


class FitnessEvaluator:
    """Evaluates an individual by simulating play and comparing to a target curve.

    The fitness is the DTW distance between the simulated tension trace
    and the target curve, averaged across agent types if multi-agent mode
    is enabled.

    **Lower fitness = better match to the target curve.**
    """

    def __init__(
        self,
        target_curve: TensionCurve,
        *,
        agents: list[AgentStrategy] | None = None,
        tension_weights: TensionWeights | None = None,
        length_penalty_weight: float = 0.1,
        desired_path_length: int | None = None,
    ) -> None:
        self.target_curve = target_curve
        self.agents = agents or [ShortestPathAgent(), CautiousAgent()]
        self.tension_weights = tension_weights
        self.length_penalty_weight = length_penalty_weight
        self.desired_path_length = desired_path_length

    def evaluate(self, graph: LevelGraph) -> float:
        """Compute fitness for a single graph.  Returns float (lower = better)."""
        scores: list[float] = []

        for agent_strategy in self.agents:
            sim = LevelSimulator(
                strategy=agent_strategy,
                tension_weights=self.tension_weights,
            )
            result = sim.simulate(graph)

            if not result.reached_exit:
                scores.append(10.0)  # heavy penalty for not reaching exit
                continue

            # Sample target curve to match the simulation's trace length
            trace_len = len(result.tension_trace)
            target_sampled = self.target_curve.sample(trace_len)

            score = curve_fitness(
                result.tension_trace,
                target_sampled,
                length_penalty_weight=self.length_penalty_weight,
                desired_length=self.desired_path_length,
            )
            scores.append(score)

        # Average across agents
        return sum(scores) / len(scores) if scores else 10.0

    def evaluate_detailed(
        self, graph: LevelGraph
    ) -> dict:
        """Evaluate with full diagnostic output.

        Returns a dict with per-agent simulation results, fitness scores,
        and the sampled target curve for visualization.
        """
        details: dict = {
            "agent_results": [],
            "per_agent_fitness": [],
            "overall_fitness": 0.0,
            "target_curve_name": self.target_curve.name,
        }

        for agent_strategy in self.agents:
            sim = LevelSimulator(
                strategy=agent_strategy,
                tension_weights=self.tension_weights,
            )
            result = sim.simulate(graph)

            if not result.reached_exit:
                score = 10.0
            else:
                trace_len = len(result.tension_trace)
                target_sampled = self.target_curve.sample(trace_len)
                score = curve_fitness(
                    result.tension_trace,
                    target_sampled,
                    length_penalty_weight=self.length_penalty_weight,
                    desired_length=self.desired_path_length,
                )

            details["agent_results"].append({
                "agent": agent_strategy.name,
                "result": result,
                "fitness": score,
                "target_sampled": self.target_curve.sample(
                    len(result.tension_trace)
                ) if result.reached_exit else [],
            })
            details["per_agent_fitness"].append(score)

        details["overall_fitness"] = (
            sum(details["per_agent_fitness"]) / len(details["per_agent_fitness"])
            if details["per_agent_fitness"] else 10.0
        )
        return details
