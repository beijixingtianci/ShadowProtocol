"""
stealth_pcg.evolution.optimizer
================================
Main evolutionary loop for content parameter optimisation.

Takes a structurally-fixed graph and a target tension curve,
then evolves content parameters (patrol_density, cover_availability,
exposure_length) to minimise DTW distance to the target.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Callable

from stealth_pcg.core.graph import LevelGraph
from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.evolution.encoding import Individual
from stealth_pcg.evolution.fitness import FitnessEvaluator
from stealth_pcg.evolution.operators import (
    select_parents,
    blend_crossover,
    gaussian_mutation,
    reset_mutation,
)
from stealth_pcg.simulation.agent import AgentStrategy
from stealth_pcg.simulation.tension import TensionWeights


@dataclass
class EvolutionConfig:
    """Parameters for the evolutionary search."""

    population_size: int = 50
    num_generations: int = 80
    tournament_size: int = 3
    crossover_rate: float = 0.7
    mutation_rate: float = 0.15       # per-gene Gaussian mutation rate
    mutation_sigma: float = 0.12      # Gaussian noise std dev
    reset_rate: float = 0.02          # per-gene random reset rate
    elitism_count: int = 2            # best N carried over unchanged
    seed: int | None = None
    # Early stopping: halt if best fitness hasn't improved in this many gens
    patience: int = 20


@dataclass
class EvolutionResult:
    """Output of the evolutionary search."""

    best_individual: Individual
    best_fitness: float
    fitness_history: list[float]     # best fitness per generation
    avg_fitness_history: list[float] # population average per generation
    total_generations: int = 0
    converged: bool = False          # True if early stopping triggered


class Optimizer:
    """Evolutionary optimiser for level content parameters.

    Usage::

        optimizer = Optimizer(
            base_graph=graph,
            target_curve=TensionCurve.double_peak(),
        )
        result = optimizer.run()
        best_graph = result.best_individual.graph
    """

    def __init__(
        self,
        base_graph: LevelGraph,
        target_curve: TensionCurve,
        *,
        config: EvolutionConfig | None = None,
        agents: list[AgentStrategy] | None = None,
        tension_weights: TensionWeights | None = None,
        on_generation: Callable[[int, float, float], None] | None = None,
    ) -> None:
        """
        Parameters
        ----------
        base_graph : LevelGraph
            Structurally-fixed graph from the grammar generator.
        target_curve : TensionCurve
            Designer-defined target tension curve.
        config : EvolutionConfig, optional
            GA parameters.
        agents : list of AgentStrategy, optional
            Agent types for multi-agent evaluation.
        tension_weights : TensionWeights, optional
            Weights for the tension function.
        on_generation : callable, optional
            Callback ``(gen, best_fitness, avg_fitness)`` called each generation.
        """
        self.base_graph = base_graph
        self.target_curve = target_curve
        self.config = config or EvolutionConfig()
        self.evaluator = FitnessEvaluator(
            target_curve,
            agents=agents,
            tension_weights=tension_weights,
        )
        self.on_generation = on_generation

    def run(self) -> EvolutionResult:
        """Execute the evolutionary search."""
        cfg = self.config
        if cfg.seed is not None:
            random.seed(cfg.seed)

        # Initialise population
        population = [
            Individual.from_base_graph(self.base_graph, generation=0)
            for _ in range(cfg.population_size)
        ]

        # Evaluate initial population
        for ind in population:
            ind.fitness = self.evaluator.evaluate(ind.graph)

        population.sort(key=lambda x: x.fitness)

        fitness_history: list[float] = []
        avg_history: list[float] = []
        best_ever = population[0].deep_copy()
        stagnation_counter = 0

        for gen in range(cfg.num_generations):
            # ── Record stats ──
            best_fit = population[0].fitness
            avg_fit = sum(ind.fitness for ind in population) / len(population)
            fitness_history.append(best_fit)
            avg_history.append(avg_fit)

            if self.on_generation:
                self.on_generation(gen, best_fit, avg_fit)

            # ── Track best ever ──
            if population[0].fitness < best_ever.fitness:
                best_ever = population[0].deep_copy()
                stagnation_counter = 0
            else:
                stagnation_counter += 1

            # ── Early stopping ──
            if stagnation_counter >= cfg.patience:
                return EvolutionResult(
                    best_individual=best_ever,
                    best_fitness=best_ever.fitness,
                    fitness_history=fitness_history,
                    avg_fitness_history=avg_history,
                    total_generations=gen + 1,
                    converged=True,
                )

            # ── Create next generation ──
            next_gen: list[Individual] = []

            # Elitism: carry over best unchanged
            for i in range(min(cfg.elitism_count, len(population))):
                elite = population[i].deep_copy()
                elite.generation = gen + 1
                next_gen.append(elite)

            # Fill rest with offspring
            while len(next_gen) < cfg.population_size:
                # Select parents
                parents = select_parents(population, 2, cfg.tournament_size)

                # Crossover
                if random.random() < cfg.crossover_rate:
                    child = blend_crossover(parents[0], parents[1])
                else:
                    child = parents[0].deep_copy()

                # Mutation
                child = gaussian_mutation(
                    child,
                    mutation_rate=cfg.mutation_rate,
                    sigma=cfg.mutation_sigma,
                )
                child = reset_mutation(child, reset_rate=cfg.reset_rate)

                child.generation = gen + 1
                next_gen.append(child)

            # ── Evaluate new population ──
            for ind in next_gen:
                if ind.fitness == float("inf"):  # not yet evaluated
                    ind.fitness = self.evaluator.evaluate(ind.graph)

            next_gen.sort(key=lambda x: x.fitness)
            population = next_gen[:cfg.population_size]

        # Final stats
        if population[0].fitness < best_ever.fitness:
            best_ever = population[0].deep_copy()

        fitness_history.append(best_ever.fitness)
        avg_history.append(
            sum(ind.fitness for ind in population) / len(population)
        )

        return EvolutionResult(
            best_individual=best_ever,
            best_fitness=best_ever.fitness,
            fitness_history=fitness_history,
            avg_fitness_history=avg_history,
            total_generations=cfg.num_generations,
            converged=False,
        )
