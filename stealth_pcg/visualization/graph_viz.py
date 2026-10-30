"""
stealth_pcg.visualization.graph_viz
====================================
Graph rendering: nodes coloured by type, edges styled by attributes,
optional path overlay.
"""

from __future__ import annotations

from typing import Sequence

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import networkx as nx

from stealth_pcg.core.graph import LevelGraph, Node, Edge
from stealth_pcg.core.types import NodeType, TraversalType, Visibility, WallMaterial


# ── Colour palette for node types ──

NODE_COLORS: dict[NodeType, str] = {
    NodeType.ENTRY:          "#4CAF50",  # green
    NodeType.EXIT:           "#F44336",  # red
    NodeType.OBJECTIVE:      "#FF9800",  # orange
    NodeType.SIDE_OBJECTIVE: "#FFD54F",  # light amber
    NodeType.TRANSIT:        "#90A4AE",  # blue-grey
    NodeType.OBSERVATION:    "#29B6F6",  # light blue
    NodeType.HIGH_SECURITY:  "#D32F2F",  # dark red
    NodeType.CHOKE:          "#E91E63",  # pink
    NodeType.ALT_PATH:       "#7E57C2",  # purple
    NodeType.KEY_ROOM:       "#66BB6A",  # light green
}

NODE_SHAPES: dict[NodeType, str] = {
    NodeType.ENTRY:          "s",  # square
    NodeType.EXIT:           "s",
    NodeType.OBJECTIVE:      "D",  # diamond
    NodeType.SIDE_OBJECTIVE: "d",
    NodeType.TRANSIT:        "o",  # circle
    NodeType.OBSERVATION:    "^",  # triangle up
    NodeType.HIGH_SECURITY:  "h",  # hexagon
    NodeType.CHOKE:          "p",  # pentagon
    NodeType.ALT_PATH:       "v",  # triangle down
    NodeType.KEY_ROOM:       "*",  # star
}


def _build_nx_graph(graph: LevelGraph) -> nx.DiGraph:
    """Convert LevelGraph to a networkx DiGraph for layout computation."""
    G = nx.DiGraph()
    for nid, node in graph.nodes.items():
        G.add_node(nid, node_type=node.node_type, label=_node_label(node))
    for eid, edge in graph.edges.items():
        G.add_edge(edge.source, edge.target, edge_id=eid, edge_obj=edge)
    return G


def _node_label(node: Node) -> str:
    """Short label for a node."""
    short_id = node.id.split("_")[-1]
    name = node.node_type.value.replace("_", "\n")
    label = f"{name}\n#{short_id}"
    if node.provides:
        label += f"\nKEY:{node.provides}"
    return label


def compute_layout(graph: LevelGraph) -> dict[str, tuple[float, float]]:
    """Compute a hierarchical layout based on BFS depth from ENTRY."""
    G = _build_nx_graph(graph)

    # Try hierarchical layout based on topological sort
    try:
        # Use BFS layers for x-position, spread within layer for y
        entry_id = graph.find_entry().id
        layers: dict[int, list[str]] = {}
        visited = {entry_id}
        queue = [(entry_id, 0)]
        node_depth: dict[str, int] = {entry_id: 0}

        while queue:
            nid, depth = queue.pop(0)
            layers.setdefault(depth, []).append(nid)
            for edge in graph.out_edges(nid):
                if edge.target not in visited:
                    visited.add(edge.target)
                    node_depth[edge.target] = depth + 1
                    queue.append((edge.target, depth + 1))

        # Place unvisited nodes
        for nid in G.nodes():
            if nid not in node_depth:
                max_depth = max(layers.keys()) if layers else 0
                depth = max_depth + 1
                layers.setdefault(depth, []).append(nid)
                node_depth[nid] = depth

        pos: dict[str, tuple[float, float]] = {}
        for depth, nodes in layers.items():
            for i, nid in enumerate(nodes):
                x = depth * 2.0
                y = (i - (len(nodes) - 1) / 2) * 1.5
                pos[nid] = (x, y)

        return pos
    except Exception:
        # Fallback to spring layout
        return nx.spring_layout(G, seed=42)


def draw_graph(
    graph: LevelGraph,
    *,
    ax: plt.Axes | None = None,
    path: Sequence[str] | None = None,
    title: str = "Level Graph",
    show_edge_labels: bool = True,
    figsize: tuple[float, float] = (14, 8),
) -> plt.Figure:
    """Draw the level graph with colour-coded nodes and styled edges.

    Parameters
    ----------
    graph : LevelGraph
    ax : matplotlib Axes, optional
    path : list of node IDs, optional
        If provided, highlights this path with thick coloured edges.
    title : str
    show_edge_labels : bool
    figsize : tuple
    """
    if ax is None:
        fig, ax = plt.subplots(1, 1, figsize=figsize)
    else:
        fig = ax.figure

    G = _build_nx_graph(graph)
    pos = compute_layout(graph)

    # ── Draw edges ──
    path_edges: set[tuple[str, str]] = set()
    if path:
        for i in range(len(path) - 1):
            path_edges.add((path[i], path[i + 1]))

    for (u, v, data) in G.edges(data=True):
        edge: Edge = data["edge_obj"]
        is_path = (u, v) in path_edges

        # Edge style
        color = "#E53935" if is_path else "#546E7A"
        width = 3.0 if is_path else 1.2
        style = "solid"

        if edge.locked:
            color = "#FF6F00" if not is_path else "#E53935"
            style = "dashed"
        if edge.visibility == Visibility.HIDDEN:
            color = "#9575CD" if not is_path else "#E53935"
            style = "dotted"
        if not edge.mandatory:
            width = max(0.8, width * 0.6)

        ax.annotate(
            "", xy=pos[v], xytext=pos[u],
            arrowprops=dict(
                arrowstyle="-|>",
                color=color,
                lw=width,
                linestyle=style,
                connectionstyle="arc3,rad=0.1",
                mutation_scale=15,
            ),
        )

        # Edge label
        if show_edge_labels:
            mid_x = (pos[u][0] + pos[v][0]) / 2
            mid_y = (pos[u][1] + pos[v][1]) / 2 + 0.15
            label_parts = []
            if edge.locked:
                label_parts.append(f"LOCK:{edge.key_id or ''}")
            if edge.traversal_type != TraversalType.NORMAL:
                label_parts.append(edge.traversal_type.value)
            if label_parts:
                ax.text(mid_x, mid_y, " ".join(label_parts),
                        fontsize=6, ha="center", color="#455A64", alpha=0.8)

    # ── Draw nodes (by type for different markers) ──
    for ntype in NodeType:
        nodes_of_type = [
            nid for nid, n in graph.nodes.items()
            if n.node_type == ntype
        ]
        if not nodes_of_type:
            continue

        xs = [pos[nid][0] for nid in nodes_of_type]
        ys = [pos[nid][1] for nid in nodes_of_type]

        # Highlight path nodes
        if path:
            path_set = set(path)
            edge_colors = [
                "#E53935" if nid in path_set else NODE_COLORS[ntype]
                for nid in nodes_of_type
            ]
            edge_widths = [2.5 if nid in path_set else 1.0 for nid in nodes_of_type]
        else:
            edge_colors = [NODE_COLORS[ntype]] * len(nodes_of_type)
            edge_widths = [1.0] * len(nodes_of_type)

        ax.scatter(
            xs, ys,
            c=[NODE_COLORS[ntype]] * len(nodes_of_type),
            edgecolors=edge_colors,
            linewidths=edge_widths,
            s=600,
            marker=NODE_SHAPES.get(ntype, "o"),
            zorder=5,
        )

    # ── Node labels ──
    for nid, node in graph.nodes.items():
        x, y = pos[nid]
        label = _node_label(node)
        ax.text(x, y, label, fontsize=6, ha="center", va="center",
                fontweight="bold", zorder=6)

    # ── Legend ──
    legend_patches = [
        mpatches.Patch(color=NODE_COLORS[nt], label=nt.value.replace("_", " "))
        for nt in NodeType
        if any(n.node_type == nt for n in graph.nodes.values())
    ]
    ax.legend(handles=legend_patches, loc="upper left", fontsize=7,
              framealpha=0.9, ncol=2)

    ax.set_title(title, fontsize=14, fontweight="bold")
    ax.set_aspect("equal")
    ax.axis("off")
    fig.tight_layout()
    return fig


# ── Proximity link colours by wall type ──
WALL_COLORS: dict[WallMaterial, str] = {
    WallMaterial.CONCRETE: "#546E7A",
    WallMaterial.DRYWALL:  "#FF9800",
    WallMaterial.GLASS:    "#29B6F6",
    WallMaterial.METAL:    "#8D6E63",
    WallMaterial.MESH:     "#E91E63",
}

# 두께는 색이 아니라 선의 굵기로 표현한다. 재질과 두께가 직교하는 축이므로
# 하나의 선 스타일에 섞어 넣으면 구분이 사라진다.
WALL_STYLES: dict[WallMaterial, str] = {
    WallMaterial.CONCRETE: (0, (5, 5)),
    WallMaterial.DRYWALL:  (0, (3, 3)),
    WallMaterial.GLASS:    (0, (1, 1)),
    WallMaterial.METAL:    (0, (5, 2, 1, 2)),
    WallMaterial.MESH:     (0, (8, 2, 1, 2)),
}


def draw_proximity(
    graph: LevelGraph,
    *,
    ax: plt.Axes | None = None,
    title: str = "Proximity Layer (Spatial Adjacency)",
    figsize: tuple[float, float] = (14, 8),
) -> plt.Figure:
    """Draw the proximity layer separately from the edge graph.

    Shows nodes as circles with proximity links as coloured dashed lines.
    Each link is annotated with wall type and sound/visual leak values.
    Edges are drawn very faintly in the background for context.
    """
    if ax is None:
        fig, ax = plt.subplots(1, 1, figsize=figsize)
    else:
        fig = ax.figure

    pos = compute_layout(graph)

    # ── Background: faint edges for spatial context ──
    for eid, edge in graph.edges.items():
        if edge.source in pos and edge.target in pos:
            sx, sy = pos[edge.source]
            tx, ty = pos[edge.target]
            ax.annotate(
                "", xy=(tx, ty), xytext=(sx, sy),
                arrowprops=dict(
                    arrowstyle="-",
                    color="#37474F",
                    lw=0.5,
                    alpha=0.25,
                ),
            )

    # ── Proximity links (main content) ──
    for pid, link in graph.proximity_links.items():
        if link.node_a not in pos or link.node_b not in pos:
            continue
        ax_pos = pos[link.node_a]
        bx_pos = pos[link.node_b]

        color = WALL_COLORS.get(link.material, "#FF9800")
        style = WALL_STYLES.get(link.material, (0, (3, 3)))
        width = 1.5 + link.sound_leak * 2  # thicker = more leakage

        ax.plot(
            [ax_pos[0], bx_pos[0]], [ax_pos[1], bx_pos[1]],
            color=color, linewidth=width, linestyle=style,
            alpha=0.8, zorder=2,
        )

        # Label at midpoint
        mx = (ax_pos[0] + bx_pos[0]) / 2
        my = (ax_pos[1] + bx_pos[1]) / 2 + 0.15
        label = f"{link.material.value} snd:{link.sound_leak:.1f}"
        if link.visual_leak > 0:
            label += f" vis:{link.visual_leak:.1f}"
        ax.text(mx, my, label, fontsize=6, ha="center",
                color=color, alpha=0.9, fontweight="bold")

    # ── Nodes ──
    for nid, node in graph.nodes.items():
        if nid not in pos:
            continue
        x, y = pos[nid]
        c = NODE_COLORS.get(node.node_type, "#90A4AE")

        # Highlight nodes that have proximity links
        has_prox = len(graph.proximity_of(nid)) > 0
        ring_color = "#FF9800" if has_prox else "#263238"
        ring_width = 2.0 if has_prox else 1.0

        ax.scatter([x], [y], c=[c], edgecolors=[ring_color],
                   linewidths=[ring_width], s=500, zorder=5)
        label = _node_label(node)
        ax.text(x, y, label, fontsize=6, ha="center", va="center",
                fontweight="bold", zorder=6)

    # ── Legend ──
    legend_patches = [
        mpatches.Patch(color=WALL_COLORS[wt], label=f"{wt.value}")
        for wt in WallMaterial
    ]
    ax.legend(handles=legend_patches, loc="upper left", fontsize=7,
              framealpha=0.9, title="Wall Types", title_fontsize=8)

    # Stats annotation
    prox_count = graph.proximity_count
    if prox_count > 0:
        avg_sound = sum(p.sound_leak for p in graph.proximity_links.values()) / prox_count
        avg_visual = sum(p.visual_leak for p in graph.proximity_links.values()) / prox_count
        stats_text = (
            f"Proximity links: {prox_count}\n"
            f"Avg sound leak: {avg_sound:.2f}\n"
            f"Avg visual leak: {avg_visual:.2f}"
        )
        ax.text(0.98, 0.02, stats_text, transform=ax.transAxes,
                fontsize=8, va="bottom", ha="right",
                bbox=dict(boxstyle="round", facecolor="#263238", alpha=0.8),
                color="#B0BEC5")

    ax.set_title(title, fontsize=14, fontweight="bold")
    ax.set_aspect("equal")
    ax.axis("off")
    fig.tight_layout()
    return fig
