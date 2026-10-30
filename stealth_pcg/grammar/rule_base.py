"""
stealth_pcg.grammar.rule_base
=============================
Abstract base for all graph grammar rules.

Every rule implements two methods:
* ``find_matches(graph)`` — locate all positions where the rule *can* apply.
* ``apply(graph, match)``  — execute the transformation at one position.

Rules are divided into two families:
* **Structural rules (S-rules)** modify the graph's node/edge topology.
* **Attribute rules (A-rules)** modify only edge/node attributes, never topology.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

from stealth_pcg.core.graph import LevelGraph


@dataclass
class Match:
    """A location in the graph where a rule can be applied.

    The meaning of the fields depends on the specific rule.
    ``nodes`` and ``edges`` identify the subgraph that matched the LHS.
    ``data`` carries any extra information the rule needs during ``apply``.
    """

    nodes: list[str] = field(default_factory=list)   # matched node IDs
    edges: list[str] = field(default_factory=list)   # matched edge IDs
    data: dict[str, Any] = field(default_factory=dict)


class Rule(ABC):
    """Abstract base for a graph grammar rule."""

    #: Human-readable identifier (e.g. "S1", "A3").
    name: str = "unnamed"

    @abstractmethod
    def find_matches(self, graph: LevelGraph) -> list[Match]:
        """Return all positions where the rule can fire.

        An empty list means the rule is not applicable in the current state.
        """

    @abstractmethod
    def apply(self, graph: LevelGraph, match: Match) -> None:
        """Transform *graph* in-place at the position described by *match*.

        Precondition: *match* was returned by ``find_matches`` on the same
        (or an equivalent) graph.  The caller must ensure no conflicting
        rule was applied between finding and applying.
        """

    def apply_first(self, graph: LevelGraph) -> bool:
        """Convenience: find matches and apply the first one.

        Returns True if the rule was applied, False if no match was found.
        """
        matches = self.find_matches(graph)
        if not matches:
            return False
        self.apply(graph, matches[0])
        return True

    def apply_all(self, graph: LevelGraph) -> int:
        """Apply to every match found in one pass.

        Note: matches are found once, then applied in order.  This is safe
        for attribute rules but structural rules should generally use
        ``apply_first`` in a loop to avoid stale matches.

        Returns the number of applications.
        """
        matches = self.find_matches(graph)
        for m in matches:
            self.apply(graph, m)
        return len(matches)

    def __repr__(self) -> str:
        return f"Rule({self.name!r})"
