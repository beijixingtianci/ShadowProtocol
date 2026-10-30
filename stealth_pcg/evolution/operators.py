"""
stealth_pcg.evolution.operators
================================
Selection, crossover, and mutation operators for the evolutionary search.
"""

from __future__ import annotations

import random
from typing import Sequence

from stealth_pcg.evolution.encoding import Individual


# ──────────────────────────────────────────────
# Selection
# ──────────────────────────────────────────────

def tournament_selection(
    population: list[Individual],
    tournament_size: int = 3,
) -> Individual:
    """Select one individual via tournament selection (lower fitness = better)."""
    candidates = random.sample(population, min(tournament_size, len(population)))
    return min(candidates, key=lambda ind: ind.fitness)


def select_parents(
    population: list[Individual],
    n_parents: int,
    tournament_size: int = 3,
) -> list[Individual]:
    """Select *n_parents* individuals via repeated tournaments."""
    return [
        tournament_selection(population, tournament_size)
        for _ in range(n_parents)
    ]


# ──────────────────────────────────────────────
# Crossover
# ──────────────────────────────────────────────

def uniform_crossover(
    parent_a: Individual,
    parent_b: Individual,
    *,
    swap_prob: float = 0.5,
) -> tuple[Individual, Individual]:
    """Gene-wise uniform crossover.

    Each gene is independently swapped between parents with probability
    *swap_prob*.  Returns two offspring.
    """
    child_a = parent_a.deep_copy()
    child_b = parent_b.deep_copy()

    genome_a = child_a.get_genome()
    genome_b = child_b.get_genome()

    for i in range(len(genome_a)):
        if random.random() < swap_prob:
            genome_a[i], genome_b[i] = genome_b[i], genome_a[i]

    child_a.set_genome(genome_a)
    child_b.set_genome(genome_b)
    child_a.fitness = float("inf")
    child_b.fitness = float("inf")

    return child_a, child_b


def blend_crossover(
    parent_a: Individual,
    parent_b: Individual,
    *,
    alpha: float = 0.3,
) -> Individual:
    """BLX-α crossover: each gene is sampled from the range
    [min - α·d, max + α·d] where d = |a - b|.

    Returns a single offspring.
    """
    child = parent_a.deep_copy()
    genome_a = parent_a.get_genome()
    genome_b = parent_b.get_genome()
    genome_c: list[float] = []

    for a, b in zip(genome_a, genome_b):
        lo, hi = min(a, b), max(a, b)
        d = hi - lo
        new_lo = max(0.0, lo - alpha * d)
        new_hi = min(1.0, hi + alpha * d)
        genome_c.append(random.uniform(new_lo, new_hi))

    child.set_genome(genome_c)
    child.fitness = float("inf")
    return child


# ──────────────────────────────────────────────
# Mutation
# ──────────────────────────────────────────────

def gaussian_mutation(
    individual: Individual,
    *,
    mutation_rate: float = 0.1,
    sigma: float = 0.15,
) -> Individual:
    """Per-gene Gaussian perturbation.

    Each gene is mutated with probability *mutation_rate* by adding
    Gaussian noise with standard deviation *sigma*.  Values are clamped
    to [0, 1].
    """
    genome = individual.get_genome()

    for i in range(len(genome)):
        if random.random() < mutation_rate:
            genome[i] += random.gauss(0, sigma)
            genome[i] = max(0.0, min(1.0, genome[i]))

    individual.set_genome(genome)
    individual.fitness = float("inf")  # invalidate cached fitness
    return individual


def reset_mutation(
    individual: Individual,
    *,
    reset_rate: float = 0.03,
) -> Individual:
    """Per-gene random reset.

    Each gene has *reset_rate* chance of being set to a completely
    random value.  Helps escape local optima.
    """
    genome = individual.get_genome()

    for i in range(len(genome)):
        if random.random() < reset_rate:
            genome[i] = random.random()

    individual.set_genome(genome)
    individual.fitness = float("inf")
    return individual
