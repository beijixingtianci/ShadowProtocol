"""stealth_pcg.layout.render_html
================================
배치 결과를 건축 평면도 형식의 SVG 로 렌더링한다.

- ``render_layout_svg()``     : <svg> 문자열만. 어디에든 끼워 넣을 수 있다.
- ``render_report_fragment()``: SVG + 표제란 + 범례. 자체 <style> 를 동봉하므로
                                기존 report.html 에 그대로 붙여도 스타일이 깨지지 않는다.
- ``write_report()``          : 단독으로 열리는 HTML.

theme="paper"(기본) 은 제도 용지, theme="dark" 는 GUI 리포트의 어두운 배경에
맞춘 변형이다.
"""
from __future__ import annotations

import html
import math
from typing import Dict, List, Optional, Sequence

from .config import LayoutInput
from .refine import TileLayout

FONT_STACK = ("Inter,'Helvetica Neue',Arial,'Noto Sans KR',"
              "'Malgun Gothic','Apple SD Gothic Neo',sans-serif")

THEMES: Dict[str, Dict[str, str]] = {
    "paper": {
        "ink": "#23272A", "paper": "#D9D8CF", "deep": "#CFCEC3",
        "grid": "#C2C1B4", "accent": "#B5432F", "label": "#17191A",
        "page": "#EFEEE8", "card": "#FBFAF6", "rule": "#B3B2A4",
        "outline": "#4B5153", "room_op": ".82",
    },
    "dark": {
        "ink": "#C9D1D9", "paper": "#12171D", "deep": "#1C232B",
        "grid": "#232A31", "accent": "#FF7B72", "label": "#0B0E11",
        "page": "#0D1117", "card": "#161B22", "rule": "#21262D",
        "outline": "#8B949E", "room_op": ".78",
    },
}

ROOM_FILL: Dict[str, str] = {
    "entry": "#7FA8A0", "exit": "#5F8F86",
    "objective": "#C4714E", "side_objective": "#A9915C",
    "transit": "#BDBAAC", "observation": "#93A87E",
    "high_security": "#A34A3A", "choke": "#8C3F52",
    "alt_path": "#7E8C99", "key_room": "#6B5B95",
}
ROOM_LABEL_KO: Dict[str, str] = {
    "entry": "진입", "exit": "탈출", "objective": "목표",
    "side_objective": "부가목표", "transit": "이동", "observation": "관찰",
    "high_security": "고경계", "choke": "병목", "alt_path": "대체경로",
    "key_room": "키보관",
}
WALL_COLOR: Dict[str, str] = {
    "concrete": "#6E7478", "drywall": "#B08359", "glass": "#5AA0C4",
    "metal": "#8A7A6A", "mesh": "#BCA245",
}
TRAV_COLOR: Dict[str, str] = {
    "normal": "#8A9095", "stealth_required": "#6E9C84",
    "takedown_required": "#B87049", "vent": "#8A69A8",
    "climb": "#5AA0C4", "hack": "#BCA245",
}
ALWAYS_LABEL = {"entry", "exit", "objective", "key_room", "choke"}
_META_LABEL = {"seed": "시드", "curve": "목표 곡선", "fitness": "적합도",
               "generated_at": "생성 시각"}


def _esc(s) -> str:
    return html.escape(str(s), quote=True)


# --------------------------------------------------------------------------- #
def render_layout_svg(tl: TileLayout, data: LayoutInput,
                      scale: float = 3.0, pad: float = 30.0,
                      show_grid: bool = True, theme: str = "paper") -> str:
    T = THEMES.get(theme, THEMES["paper"])
    x0, y0, x1, y1 = tl.extent
    w = (x1 - x0) * scale + pad * 2
    h = (y1 - y0) * scale + pad * 2

    def P(x, y):
        return ((x - x0) * scale + pad, (y - y0) * scale + pad)

    def pth(points) -> str:
        return " ".join(f"{'M' if i == 0 else 'L'}{px:.1f},{py:.1f}"
                        for i, (px, py) in enumerate(P(a, b) for a, b in points))

    o: List[str] = []
    o.append(f'<svg class="lyt-plan" viewBox="0 0 {w:.0f} {h:.0f}" width="100%" '
             f'preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg" '
             f'role="img" aria-label="생성된 레벨의 격자 배치 평면도">')
    o.append('<defs><pattern id="lytHatch" width="6" height="6" '
             'patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
             f'<line x1="0" y1="0" x2="0" y2="6" stroke="{T["ink"]}" '
             'stroke-opacity=".20" stroke-width="1.6"/></pattern></defs>')
    o.append(f'<rect width="{w:.0f}" height="{h:.0f}" fill="{T["paper"]}"/>')

    if show_grid:
        o.append(f'<g stroke="{T["grid"]}" stroke-width=".7">')
        acc = 0
        for cw in tl.col_widths + [0]:
            px, _ = P(acc, 0)
            o.append(f'<line x1="{px:.1f}" y1="{pad:.1f}" x2="{px:.1f}" '
                     f'y2="{h - pad:.1f}"/>')
            acc += cw
        acc = 0
        for rh in tl.row_heights + [0]:
            _, py = P(0, acc)
            o.append(f'<line x1="{pad:.1f}" y1="{py:.1f}" x2="{w - pad:.1f}" '
                     f'y2="{py:.1f}"/>')
            acc += rh
        o.append('</g>')

    cp = list(data.critical_path)
    cp_set = set(cp)

    # 미충족 proximity — 배치로는 벽을 맞대지 못했지만 소리 전파는 유지된다
    o.append(f'<g stroke="{T["ink"]}" stroke-opacity=".22" stroke-width="1.2" '
             'stroke-dasharray="2 5">')
    for wl in tl.walls:
        if not wl.satisfied:
            ax, ay = P(*wl.p0); bx, by = P(*wl.p1)
            o.append(f'<line x1="{ax:.1f}" y1="{ay:.1f}" x2="{bx:.1f}" y2="{by:.1f}"/>')
    o.append('</g>')

    # 지상 복도
    o.append('<g fill="none" stroke-linejoin="round" stroke-linecap="round">')
    for cg in tl.corridors.values():
        if cg.layer != "ground" or len(cg.points) < 2:
            continue
        d = pth(cg.points)
        col = TRAV_COLOR.get(cg.traversal_type, "#8A9095")
        o.append(f'<path d="{d}" stroke="{T["deep"]}" '
                 f'stroke-width="{cg.width * scale:.1f}"/>')
        dash = ' stroke-dasharray="7 5"' if cg.visibility == "hidden" else ''
        o.append(f'<path d="{d}" stroke="{col}" stroke-opacity=".55" '
                 f'stroke-width="{max(1.6, cg.width * scale - 3):.1f}"{dash}/>')
    o.append('</g>')

    # 방
    for rg in tl.rooms.values():
        fill = ROOM_FILL.get(rg.node_type, "#BDBAAC")
        on_cp = rg.node_id in cp_set
        o.append('<g>')
        for (rx0, ry0, rx1, ry1) in rg.rects:
            ax, ay = P(rx0, ry0); bx, by = P(rx1, ry1)
            o.append(f'<rect x="{ax:.1f}" y="{ay:.1f}" width="{bx - ax:.1f}" '
                     f'height="{by - ay:.1f}" fill="{fill}" '
                     f'fill-opacity="{T["room_op"]}"/>')
        if rg.node_type in ("high_security", "choke"):
            for (rx0, ry0, rx1, ry1) in rg.rects:
                ax, ay = P(rx0, ry0); bx, by = P(rx1, ry1)
                o.append(f'<rect x="{ax:.1f}" y="{ay:.1f}" width="{bx - ax:.1f}" '
                         f'height="{by - ay:.1f}" fill="url(#lytHatch)"/>')
        o.append(f'<g stroke="{T["ink"] if on_cp else T["outline"]}" '
                 f'stroke-width="{2.2 if on_cp else 1.2}" stroke-linecap="square">')
        for (pa, pb) in rg.outline:
            ax, ay = P(*pa); bx, by = P(*pb)
            o.append(f'<line x1="{ax:.1f}" y1="{ay:.1f}" x2="{bx:.1f}" y2="{by:.1f}"/>')
        o.append('</g></g>')

    # proximity 공유벽
    o.append('<g stroke-linecap="butt">')
    for wl in tl.walls:
        if not wl.satisfied:
            continue
        ax, ay = P(*wl.p0); bx, by = P(*wl.p1)
        col = WALL_COLOR.get(wl.wall_type, "#6E7478")
        dash = (' stroke-dasharray="9 4"'
                if wl.wall_type in ("fence", "vent_shaft") else '')
        op = 0.45 + 0.5 * min(1.0, wl.sound_leak)
        o.append(f'<line x1="{ax:.1f}" y1="{ay:.1f}" x2="{bx:.1f}" y2="{by:.1f}" '
                 f'stroke="{col}" stroke-opacity="{op:.2f}" stroke-width="5"{dash}>'
                 f'<title>{_esc(wl.a)} / {_esc(wl.b)} — {_esc(wl.wall_type)}, '
                 f'sound_leak {wl.sound_leak:.2f}</title></line>')
    o.append('</g>')

    # 오버레이 — 통풍구·등반, 그리고 과도 우회로 강등된 엣지
    o.append('<g fill="none" stroke-linecap="round">')
    for cg in tl.corridors.values():
        if cg.layer != "overlay" or len(cg.points) < 2:
            continue
        ax, ay = P(*cg.points[0]); bx, by = P(*cg.points[-1])
        dxx, dyy = bx - ax, by - ay
        ln = max(1.0, math.hypot(dxx, dyy))
        mx = (ax + bx) / 2 - dyy * .16
        my = (ay + by) / 2 + dxx * .16
        col = TRAV_COLOR.get(cg.traversal_type, "#8A69A8")
        o.append(f'<path d="M{ax:.1f},{ay:.1f} Q{mx:.1f},{my:.1f} {bx:.1f},{by:.1f}" '
                 f'stroke="{col}" stroke-width="2.2" stroke-dasharray="3 6" '
                 f'opacity=".85"><title>{_esc(cg.edge_id)} — '
                 f'{_esc(cg.traversal_type)}</title></path>')
    o.append('</g>')

    # 잠긴 문
    o.append('<g>')
    for cg in tl.corridors.values():
        if not cg.locked or len(cg.points) < 2:
            continue
        mx, my = P(*cg.points[len(cg.points) // 2])
        o.append(f'<circle cx="{mx:.1f}" cy="{my:.1f}" r="6.5" fill="{T["paper"]}" '
                 f'stroke="{T["accent"]}" stroke-width="2"/>')
        o.append(f'<text x="{mx:.1f}" y="{my + 3.2:.1f}" text-anchor="middle" '
                 f'font-size="8" font-weight="700" fill="{T["accent"]}">'
                 f'{_esc((cg.key_id or "K")[-2:])}</text>')
    o.append('</g>')

    # 라벨
    o.append(f'<g font-family="{FONT_STACK}">')
    for rg in tl.rooms.values():
        bw = (rg.bbox[2] - rg.bbox[0]) * scale
        if bw < 26 and rg.node_type not in ALWAYS_LABEL:
            continue
        cx, cy = P(*rg.center)
        label = ROOM_LABEL_KO.get(rg.node_type, rg.node_type)
        idx = cp.index(rg.node_id) + 1 if rg.node_id in cp_set else None
        o.append(f'<text x="{cx:.1f}" y="{cy - 1:.1f}" text-anchor="middle" '
                 f'font-size="10.5" font-weight="600" fill="{T["label"]}">'
                 f'{_esc(label)}<title>{_esc(rg.node_id)} · '
                 f'{_esc(rg.node_type)}</title></text>')
        sub = rg.node_id + (f' · {idx}' if idx else '')
        o.append(f'<text x="{cx:.1f}" y="{cy + 9.5:.1f}" text-anchor="middle" '
                 f'font-size="7.5" fill="{T["label"]}" fill-opacity=".62">'
                 f'{_esc(sub)}</text>')
    o.append('</g>')

    # 축척 막대
    bar, bx, by = 10, pad, h - pad * 0.38
    o.append(f'<rect x="{bx - 7:.1f}" y="{by - 12:.1f}" '
             f'width="{bar * scale + 120:.1f}" height="22" fill="{T["paper"]}" '
             f'fill-opacity=".92"/>')
    o.append(f'<g font-family="{FONT_STACK}" fill="{T["ink"]}" fill-opacity=".75">')
    o.append(f'<line x1="{bx:.1f}" y1="{by:.1f}" x2="{bx + bar * scale:.1f}" '
             f'y2="{by:.1f}" stroke="{T["ink"]}" stroke-width="2"/>')
    for k in (0, 5, 10):
        xx = bx + k * scale
        o.append(f'<line x1="{xx:.1f}" y1="{by - 3:.1f}" x2="{xx:.1f}" '
                 f'y2="{by + 3:.1f}" stroke="{T["ink"]}" stroke-width="2"/>')
    o.append(f'<text x="{bx + bar * scale + 7:.1f}" y="{by + 3.5:.1f}" '
             f'font-size="9">{bar}타일 · {bar * tl.tile_size}px</text></g>')

    o.append('</svg>')
    return "".join(o)


# --------------------------------------------------------------------------- #
_LEGEND_ROOMS = ["entry", "transit", "observation", "objective", "side_objective",
                 "key_room", "high_security", "choke", "alt_path", "exit"]
_LEGEND_WALLS = ["concrete", "drywall", "glass", "metal", "mesh"]


def _legend(T: Dict[str, str]) -> str:
    rooms = "".join(f'<li><span class="lyt-sw" style="background:{ROOM_FILL[k]}">'
                    f'</span>{ROOM_LABEL_KO[k]}</li>' for k in _LEGEND_ROOMS)
    walls = "".join(f'<li><span class="lyt-ln" style="background:{WALL_COLOR[k]}">'
                    f'</span>{k}</li>' for k in _LEGEND_WALLS)
    return (f'<div class="lyt-legend"><div><h4>방 유형</h4><ul>{rooms}</ul></div>'
            f'<div><h4>공유벽</h4><ul>{walls}</ul></div>'
            f'<div><h4>표기</h4><ul class="lyt-one">'
            f'<li><span class="lyt-ln" style="background:{T["ink"]}"></span>'
            f'임계 경로 (굵은 외곽선·번호)</li>'
            f'<li><span class="lyt-ln lyt-dash"></span>통풍구·등반 (지상층 밖)</li>'
            f'<li><span class="lyt-dot"></span>잠긴 문 (key_id)</li>'
            f'<li><span class="lyt-faint"></span>미충족 proximity</li>'
            f'</ul></div></div>')


def _titleblock(tl: TileLayout, meta: Dict[str, str]) -> str:
    st = tl.stats
    rows = [("도면", "레벨 배치 평면 · L2/L3")]
    for key, label in _META_LABEL.items():
        if key in meta:
            rows.append((label, str(meta[key])))
    rows += [
        ("방 / 복도", f"{int(st['rooms'])} / {int(st['corridors'])}"),
        ("격자", f"{int(st['grid_cols'])} × {int(st['grid_rows'])} 셀 · "
                f"{int(st['extent_tiles_w'])} × {int(st['extent_tiles_h'])} 타일"),
        ("L자 방", f"{int(st['l_cut_rooms'])}개"),
        ("공유벽", f"{int(st.get('walls', 0))}면"),
        ("오버레이 강등", f"{int(st['unrouted'])}개 "
                       f"(필수 {int(st.get('essential_unrouted', 0))})"),
        ("배치 탐색", "성공" if st["solved"] else "부분 실패 (A* 보완)"),
    ]
    body = "".join(f'<tr><th>{_esc(k)}</th><td>{_esc(v)}</td></tr>' for k, v in rows)
    return f'<table class="lyt-tb"><tbody>{body}</tbody></table>'


def _style(T: Dict[str, str]) -> str:
    return f"""<style id="lyt-style">
.lyt-wrap{{display:grid;grid-template-columns:minmax(0,1fr) 262px;gap:20px;
 align-items:start;font-family:{FONT_STACK};color:{T['ink']}}}
.lyt-plan{{display:block;min-width:600px}}
.lyt-canvas{{background:{T['paper']};border:1px solid {T['rule']};overflow-x:auto}}
.lyt-side{{display:flex;flex-direction:column;gap:16px}}
table.lyt-tb{{width:100%;border-collapse:collapse;background:{T['card']};
 border:1px solid {T['rule']};font-size:12px;margin:0}}
table.lyt-tb th{{text-align:left;font-weight:500;opacity:.65;padding:5px 8px;
 white-space:nowrap;width:45%;vertical-align:top;border:0;background:none;
 color:{T['ink']};font-size:12px}}
table.lyt-tb td{{padding:5px 8px;font-weight:550;border:0;color:{T['ink']};
 font-size:12px}}
table.lyt-tb tr+tr{{border-top:1px solid {T['rule']}}}
.lyt-legend{{background:{T['card']};border:1px solid {T['rule']};padding:11px 12px;
 font-size:11.5px}}
.lyt-legend h4{{font-size:11px;font-weight:600;margin:0 0 5px;opacity:.68}}
.lyt-legend div+div{{margin-top:12px}}
.lyt-legend ul{{list-style:none;margin:0;padding:0;display:grid;
 grid-template-columns:1fr 1fr;gap:3px 8px}}
.lyt-legend ul.lyt-one{{grid-template-columns:1fr}}
.lyt-legend li{{display:flex;align-items:center;gap:6px}}
.lyt-sw{{width:13px;height:10px;flex:none;border:1px solid rgba(128,128,128,.5)}}
.lyt-ln{{width:13px;height:3px;flex:none}}
.lyt-dash{{background-image:repeating-linear-gradient(90deg,#8A69A8 0 3px,
 transparent 3px 6px)}}
.lyt-faint{{width:13px;height:0;flex:none;border-top:2px dotted currentColor;
 opacity:.5}}
.lyt-dot{{width:9px;height:9px;flex:none;border-radius:50%;
 border:2px solid {T['accent']}}}
@media (max-width:880px){{.lyt-wrap{{grid-template-columns:1fr}}}}
</style>"""


def render_report_fragment(tl: TileLayout, data: LayoutInput,
                           meta: Optional[Dict[str, str]] = None,
                           scale: float = 3.0, theme: str = "paper") -> str:
    """기존 report.html 에 그대로 붙일 수 있는 자기완결 조각."""
    T = THEMES.get(theme, THEMES["paper"])
    return (_style(T)
            + '<div class="lyt-wrap"><div class="lyt-canvas">'
            + render_layout_svg(tl, data, scale=scale, theme=theme)
            + '</div><aside class="lyt-side">'
            + _titleblock(tl, meta or {}) + _legend(T)
            + '</aside></div>')


def write_report(tl: TileLayout, data: LayoutInput, path: str,
                 meta: Optional[Dict[str, str]] = None,
                 notes: Optional[Sequence[str]] = None,
                 scale: float = 3.0, theme: str = "paper") -> str:
    T = THEMES.get(theme, THEMES["paper"])
    note = ""
    if notes:
        note = ('<div class="lyt-notes"><h2>읽는 법</h2><ul>'
                + "".join(f"<li>{_esc(n)}</li>" for n in notes) + '</ul></div>')
    doc = f"""<!DOCTYPE html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>레벨 배치 평면도 — 파이프라인 6단계</title>
<style>
*{{box-sizing:border-box}}
body{{margin:0;background:{T['page']};color:{T['ink']};font-family:{FONT_STACK};
 font-size:15px;line-height:1.55;padding-top:env(safe-area-inset-top,0px);
 padding-bottom:env(safe-area-inset-bottom,0px)}}
.lyt-page{{max-width:1240px;margin:0 auto;padding:30px 20px 70px}}
.lyt-head{{border-bottom:2px solid {T['ink']};padding-bottom:13px;margin-bottom:24px;
 display:flex;flex-wrap:wrap;gap:12px;align-items:baseline;
 justify-content:space-between}}
.lyt-head h1{{font-size:23px;font-weight:650;letter-spacing:-.015em;margin:0}}
.lyt-head p{{margin:0;font-size:13px;opacity:.7;max-width:62ch}}
.lyt-notes{{margin-top:28px;font-size:13.5px;max-width:78ch;opacity:.85}}
.lyt-notes h2{{font-size:15px;font-weight:600;margin:0 0 8px}}
</style></head><body><div class="lyt-page">
<header class="lyt-head"><h1>레벨 배치 평면도</h1>
<p>위상 그래프를 2차원 격자에 사상한 결과. 굵은 외곽선이 임계 경로,
점선 호가 지상층을 벗어나는 통풍구·등반 경로이다.</p></header>
{render_report_fragment(tl, data, meta, scale=scale, theme=theme)}
{note}
</div></body></html>"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc)
    return path
