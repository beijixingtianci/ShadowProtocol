"""
stealth_pcg.evolution.encoding
===============================
Individual encoding for evolutionary search.

The genome consists of:
1. **Edge-level genes** (continuous): patrol_density, cover_availability,
   exposure_length for each edge.
2. **Node-level genes** (binary via threshold): safe_zone for OBSERVATION
   and SIDE_OBJECTIVE nodes.

ENTRY is always safe_zone=true (not evolvable).
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

from stealth_pcg.core.graph import LevelGraph, Edge
from stealth_pcg.core.types import NodeType

GENES_PER_EDGE = 3

# Node types whose safe_zone is evolvable
SAFE_ZONE_EVOLVABLE = {NodeType.OBSERVATION, NodeType.SIDE_OBJECTIVE}


@dataclass
class Individual:
    """A single candidate in the evolutionary population."""

    graph: LevelGraph
    fitness: float = float("inf")
    generation: int = 0

    @classmethod
    def from_base_graph(cls, base: LevelGraph, generation: int = 0) -> Individual:
        """Create an individual with randomised content parameters."""
        graph = base.deep_copy()
        # Edge genes
        for edge in graph.edges.values():
            edge.patrol_density = random.uniform(0.0, 1.0)
            edge.cover_availability = random.uniform(0.0, 1.0)
            edge.exposure_length = random.randint(1, 5)
        # Node genes (safe_zone)
        for node in graph.nodes.values():
            if node.node_type in SAFE_ZONE_EVOLVABLE:
                node.attrs["safe_zone"] = random.random() >= 0.5
        return cls(graph=graph, generation=generation)

    def _safe_zone_node_ids(self) -> list[str]:
        """Sorted IDs of nodes with evolvable safe_zone."""
        return sorted(
            nid for nid, n in self.graph.nodes.items()
            if n.node_type in SAFE_ZONE_EVOLVABLE
        )

    def get_genome(self) -> list[float]:
        """Extract the genome as a flat float vector.

        Layout: [edge_genes...] + [node_safe_zone_genes...]
        """
        genome: list[float] = []
        # Edge genes
        for eid in sorted(self.graph.edges.keys()):
            edge = self.graph.get_edge(eid)
            genome.append(edge.patrol_density)
            genome.append(edge.cover_availability)
            genome.append(edge.exposure_length / 5.0)
        # Node genes
        for nid in self._safe_zone_node_ids():
            node = self.graph.get_node(nid)
            genome.append(1.0 if node.attrs.get("safe_zone", True) else 0.0)
        return genome

    def set_genome(self, genome: list[float]) -> None:
        """Write a flat float vector back into graph attributes."""
        sorted_eids = sorted(self.graph.edges.keys())
        idx = 0
        # Edge genes
        for eid in sorted_eids:
            edge = self.graph.get_edge(eid)
            edge.patrol_density = max(0.0, min(1.0, genome[idx]))
            edge.cover_availability = max(0.0, min(1.0, genome[idx + 1]))
            edge.exposure_length = max(1, min(5, round(genome[idx + 2] * 5)))
            idx += GENES_PER_EDGE
        # Node genes
        for nid in self._safe_zone_node_ids():
            if idx < len(genome):
                node = self.graph.get_node(nid)
                node.attrs["safe_zone"] = genome[idx] >= 0.5
                idx += 1

    @property
    def genome_length(self) -> int:
        edge_genes = len(self.graph.edges) * GENES_PER_EDGE
        node_genes = len(self._safe_zone_node_ids())
        return edge_genes + node_genes

    def deep_copy(self) -> Individual:
        return Individual(
            graph=self.graph.deep_copy(),
            fitness=self.fitness,
            generation=self.generation,
        )
