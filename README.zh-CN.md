# Shadow Protocol — 算法联动的潜行游戏框架

[한국어](README.md) | 简体中文

读取 Python 关卡生成流水线的输出，将其直接变成可游玩的潜行游戏的 Godot 项目。

---

## 0. 标题 / 设置 / 音乐

按 F5 运行后会显示标题画面（`scenes/TitleScreen.tscn`）。
**开始任务** → 进入生成画面，**快速开始** → 使用现有关卡（NORMAL），另有**设置**、**退出**。

- **设置**（`SettingsPanel.gd`，数值由 `Settings` autoload 保存在 `user://settings.cfg`）
  — 语言 한국어 ↔ 简体中文、总音量 / BGM / 音效音量、BGM 开关。
  翻译走 `Settings.ZH` 词典（韩文原文 → 中文）。创建 UI 的辅助函数都会经过 `Settings.tr_ko()`，
  所以新文案只需在词典里加一行。数字写成 `#`，键名之类的值用 `%s` 模板。
  切换语言时会重新加载当前画面（游戏中的话关卡会从头开始）。
- **音乐**（`MusicDirector` autoload，BGM 总线）— 标题播放 title.ogg，游戏中按紧张度（alert_level）
  对 sector → pulse → urgent 三层做交叉淡入淡出，回到安全区则回到 sector。结束时播放 transmission.ogg。
  音源：OpenGameArt "Dark Sci-Fi Audio Pack"（SRG774，CC0）。
- **暂停**（`PauseMenu.gd`）— 游戏中按 ESC。不会与地图（M）重叠弹出。

### 生成画面

从标题的**开始任务**进入的生成画面（`scenes/StartScreen.tscn`）。

- **体验曲线** — 可以从 7 种预设中选择，也可以在图上**直接手绘**（与 stealth_pcg 相同的控制点·余弦插值）
  - 拖动控制点：移动（两端点只能上下，中间点不能越过相邻点）· 点击空白处：加点 · 右键：删点
  - 按预设会套入该形状，一旦手动修改就变成 **✎ 自定义**（用这个按钮可以找回最后绘制的曲线）
  - 绘制的曲线通过 `--curve-points` 传给 Python，并在关卡 JSON 里留下 `meta.target_curve = {name: "custom", points}`
- **生成参数** — Seed（+随机）、目标·钥匙锁·瓶颈·走廊的数量/长度、绕行路·副目标的概率、
  Proximity %（相邻墙中发生声音泄漏的比例 = `leak_rate`，流水线默认 35%）
- **进化设置** — 种群规模、世代数
- **难度** — EASY / NORMAL / HARD / BRUTAL
- **生成并开始** — 用系统 Python 运行 `export_for_godot.py`，重新生成 `levels/level_data.json` 后开始
  （按 `python` → `py` → `python3` 顺序尝试，失败时把最后的输出几行显示在画面上）
- **快速开始** — 不重新生成，直接使用现有 `levels/level_data.json`（没有则用内置关卡），只应用所选难度

游戏结束后，结果画面的**主菜单**按钮会回到标题（生成画面保留上次的设置）。
`stealth_pcg/` 包必须位于项目文件夹或其上层文件夹中。

---

## 1. 运行（没有 JSON 也能直接跑）

Godot 4.3+ → **Import** → 选择 `project.godot` → **F5**

没有 `levels/level_data.json` 时会用内置关卡（9 房间）运行。

---

## 2. 与算法联动

### 2-1. 在 Python 侧生成关卡（stealth_pcg）

`export_for_godot.py` 会直接 import `stealth_pcg/` 包。
如果包在这个文件旁边或上一层（`GP/stealth_pcg`），会自动找到。

```bash
cd demo/
python export_for_godot.py --seed 42 --curve double_peak
```

流水线：图语法生成 → 空间布局 → 共享墙（proximity）推导 → 进化优化 → 模拟 → 序列化。
默认输出是 `demo/levels/level_data.json`（Godot 直接读取的路径）。

| 参数 | 值 | 说明 |
|---|---|---|
| `--seed` | 整数（默认 42） | 语法·布局·进化的种子 |
| `--curve` | `escalating` `v_shape` `inverted_v` `double_peak` `late_climax` `roller_coaster` `flat_high` | 目标紧张度曲线 |
| `--curve-points` | `"0:0.1,0.3:0.85,0.55:0.2,1:0.7"` | 手绘曲线（x:y 列表，x 从 0 增加到 1，0 ≤ y ≤ 1）。提供时替代 `--curve` |
| `--gens` | 整数（默认 40） | 进化世代数 |
| `--pop` | 整数（默认 30） | 种群规模 |
| `--difficulty` | 0–3（默认 1） | 记录到 `meta.difficulty` → 游戏难度 |
| `--out` | 路径 | 输出文件 |
| `--no-layout` | | 省略 schema v2 的 `layout` 块（游戏不使用） |

输出为 schema v2（= v1 + `layout`）。游戏在 `version >= 1` 时按 v1 路径读取。
共享墙材质（`material`）会转换成游戏用的 `wall_type` 一并记录
（concrete→thick，drywall→thin，glass→glass，metal→metal，mesh→fence）。

### 2-2. 确认

F5 运行后左下角会显示类似 `曲线  double_peak   DTW 0.018` 的信息。
控制台里的 `[검증] ... 클리어 가능 ✓` 是布局后基于实际图块的通行可能性检查结果。
如果图在网格布局中卡住（走廊穿过带锁的房间），加载器会改变布局方向，最多重试 16 次
（`[LevelLoader] 배치 N회 재시도 후 …`）。

---

## 3. 字段映射 — 算法 → 游戏

| Python | JSON 路径 | 在游戏中的效果 |
|---|---|---|
| `RoomParams.num_patrols` | `nodes[].room_params.num_patrols` | 该房间实际生成的敌人数 |
| `RoomParams.patrol_speed` | `…patrol_speed` | 敌人移动速度 42–118 px/s，追击速度为其 2.1 倍 |
| `RoomParams.patrol_range` | `…patrol_range` | 敌人视野距离 110–260 px |
| `RoomParams.light_level` | `…light_level` | 敌人视野角 30–52°，房间地面亮度 |
| `RoomParams.cover_ratio` | `…cover_ratio` | 房间内掩体数量（0–5 个） |
| `RoomParams.resource_pickup` | `…resource_pickup` | 超过 0.55 时布置暗杀机会加成 |
| `Node.type` | `nodes[].type` | 房间颜色 + 标签（ENTRY/CHOKE/OBJECTIVE…） |
| `Node.provides` | `nodes[].provides` | 在该房间放置钥匙道具 |
| `Edge.locked` + `key_id` | `edges[].locked/key_id` | 在两个房间之间生成锁门 |
| `Edge.one_way` | `edges[].one_way` | 布局图是否为单向 |
| DTC 目标曲线 | `meta.target_curve` | 保存在 GameState，结束时以日志输出 |
| 模拟曲线 | `meta.simulated_curve` | 同上 |

### 3-1. stealth_pcg JSON Schema v1（`"version": 1`）

顶层有 `"version": 1` 时走 v1 路径（`_construct_v1`），没有则走旧路径（`_construct_legacy`）。

| v1 字段 | 在游戏中的效果 |
|---|---|
| `edges{}.patrol_density / cover_availability / exposure_length / noise_level` | 汇总接触该房间的边，推导 room_params（敌人数 = round(max patrol × 4)，掩体 = min cover…） |
| `nodes{}.size_hint` | 房间大小 small 11×9 / medium 15×11 / large 19×13 |
| `nodes{}.threat_level` | 房间光照强度·色温（low 亮而暖，high 暗而偏红） |
| `nodes{}.safe_zone` | 无敌人 + 青色光环 + 进入时警报归 0 + "안전 구역" 消息，日志记录 `safe_zone` |
| `edges{}.traversal_type` | vent（窄金属格栅）/ climb（梯子）/ hack（终端图标）/ stealth_required（窄而暗）/ takedown_required（红色地面） |
| `edges{}.visibility` | hidden 通道被墙色遮盖，进入两端房间或靠近后显露（conditional 按 obvious 处理） |
| `edges{}.exposure_length` | 走廊宽度（1–2 → 3，3–4 → 4，5 → 5 图块） |
| `proximity{}` | 网格上相邻的两房间面对面的墙以 glass/thin/fence/vent_shaft 外观显示（声音泄漏为 TODO） |
| `meta.target_curve{name, points}` / `meta.fitness.final` | HUD `曲线 / DTW`，日志中的 target_curve（points 的 y 值） |
| `simulation_results.shortest_path.tension_trace` | simulated_curve |
| `clear_conditions` | objective_nodes 放置目标道具，optional_objectives 放置加成，集齐 required_keys 才能逃脱 |

---

## 4. 紧张度 · 结果画面 · 游玩日志 → 验证数据

### 4-1. 实时紧张度 T(t)

`scripts/TensionTracker.gd` 是把 `stealth_pcg/simulation/tension.py` 的 `TensionCalculator.compute()`
原样移植过来的。玩家**每次进入另一个房间时**（折返的房间也算一步）计算一次。

	T(t) = clamp( max( Σ wᵢ·dᵢ(t),  τ·T(t-1) ), 0, 1 )

- 分量：巡逻密度 · 暴露度 · 掩体不足 · 噪音（走过的边）、房间威胁、累积风险（安全区之后的步数）、
  锁定压力（从该房间出发的锁边缺钥匙）、共享墙另一侧的听觉·视觉威胁
- 权重直接使用关卡 JSON 的 `meta.tension_weights`
- "从哪条边进入"用刚踩过的走廊图块判定（即使走廊穿过其他房间也能正确判定）
- 与 Python 智能体一样，到达钥匙房间的步视为持有该钥匙
- 这是**结构紧张度** — 只看地图就能确定，无论警卫做什么，在该房间内都不会变化

**实时紧张度**（游戏专用层，显示在 HUD 顶部的 **TENSION** 条）

	raw = clamp( T_room + 0.25·alert_level + 0.35·guard_threat, 0, 1 )
	guard_threat = max_警卫( 状态权重 × (1 − 距离/480px) )   巡逻 0.15 / 调查 0.35 / 怀疑 0.65 / 追击 1.0

- 每帧更新。上升时快速跟随，下降时每 1.5 秒按 0.6 倍缓慢回落（把 τ=0.6 放到时间轴上）
- 进入房间后至少是该房间的结构紧张度。甩开警卫后回到结构值
- 每（房间的）一步记录最高值·平均值 → 结果画面 / play_log 的"实时"曲线
- 权重·范围在 `TensionTracker.gd` 顶部常量（`LIVE_W_ALERT`、`LIVE_W_GUARD`、`GUARD_STATE_WEIGHT`、`GUARD_RANGE`）

验证：把 AI 路径（`simulation_results.*.path`）原样代入，与 Python 的 `tension_trace` 每一步都一致
（最大误差 0.00006 = JSON 舍入），在游戏里实际走这条路径也会记录出相同的轨迹。

### 4-2. 结果画面

结束时叠加绘制四条曲线 — 目标曲线（蓝色虚线，控制点余弦插值）· AI 预测（绿色，shortest_path）·
玩家结构（橙色，细线）· 玩家实时最高值（红色，粗线）。
下方显示 DTW（结构↔目标、实时↔目标、AI↔目标）、访问的房间、移动步数、暗杀、被发现次数、用时、收集的钥匙。

**中途死亡时**不会把玩家曲线拉伸到全程。x 轴以 AI 路径长度为基准，只画到死亡处为止
（死亡点画 ✕ 和竖线，其后变暗），DTW 也只截取目标曲线的该区间 [0, 进度] 比较。逃脱成功则像现在这样比较全程
（与 Python 的比较方式相同）。
按钮：**主菜单** / **同关卡重试**（ESC）。

DTW 与 Python 一样，先把目标曲线按轨迹长度采样，再做 `normalised_dtw`
（累计 |a−b|，Sakoe-Chiba 带宽 12%，÷(len a + len b)）— 与 `curves/dtw_wrapper.py` 的纯 Python 实现值相同。
即使安装了 `dtaidistance`（Python 会用 C 实现），由于按同样的定义（|a−b|、相同带宽）调用，
值与纯 Python 完全一致 — 相同的 seed 在任何 PC 上都会生成相同的关卡，
结果画面的 AI DTW 与 `meta.fitness.final` 一致（在 JSON 舍入误差以内）。

### 4-3. 游玩日志

游戏结束时会（无论成功失败）保存到以下路径：

- Windows: `%APPDATA%\Godot\app_userdata\ShadowProtocol\play_log.json`
- 运行时控制台会输出准确的绝对路径

```json
{
  "won": true,
  "target_curve": [...],          // 目标曲线控制点 y
  "simulated_curve": [...],       // AI 预测轨迹
  "player_visit_log": [           // 每次进入房间时（含重访）
	{"room_id": "n_0004", "room_type": "OBJECTIVE", "entry_edge": "e_0019",
	 "alert": 0.15, "tension": 0.62, "target_tension": 0.70,
	 "hp": 3, "kills_left": 2, "keys_held": ["K1"],
	 "safe_zone": false, "is_safe_zone": false, "detection_count": 2, "ms": 45200,
	 "live_peak": 0.81, "live_mean": 0.66}
  ],
  "summary": {
	"result": "clear", "total_rooms_visited": 16, "unique_rooms": 12, "total_time_ms": 272000,
	"partial": false, "progress_at_end": 1.0,
	"dtw_player_vs_target": 0.0587, "dtw_live_vs_target": 0.0504, "dtw_ai_vs_target": 0.0510,
	"player_tension_trace": [...], "player_live_peak_trace": [...], "player_live_mean_trace": [...],
	"ai_tension_trace": [...],
	"target_curve_name": "double_peak", "target_curve_points": [[0, 0.1], [0.25, 0.8], ...],
	"target_sampled_for_player": [...],
	"detection_count": 2, "kill_count": 3, "keys_collected": ["K1", "K2"], "hp_left": 2,
	"tension_weights": {...}
  }
}
```

- `tension` 是结构紧张度（与 Python 相同的值），`live_peak` / `live_mean` 是在该房间期间的实时紧张度
- `partial` / `progress_at_end` — 中途死亡时为 true / 按 AI 路径长度基准记录走到了哪里（DTW 只比较该区间）
- `target_tension` 是游玩过程中的基准值（把 AI 路径长度视为预期长度的进度）。最终 DTW 与
  `target_sampled_for_player`（按实际轨迹长度重新采样）比较
- `detection_count` — 警卫**看到**玩家并升到 SUSPICIOUS 的次数（从 ALERT 降下来的不算）

用这份日志进行**"设计意图曲线 ↔ AI 预测 ↔ 真实玩家体感"**三方验证。

---

## 4-4. 声音 / 警卫调查 / 房间模板

**移动与噪音** — `Shift` 奔跑，`Ctrl` 隐身（任何地方都无声，在掩体旁还会从视野中消失。同时按下时隐身优先）。

| 状态 | 速度 (px/s) | 噪音半径 (px) |
|---|---|---|
| 行走 | 130 | 90 |
| 奔跑 | 235 | 280 |
| 隐身 | 49 | 0（无声） |
| 暗杀 | — | 120 |
| 开门 / 解锁锁门 | — | 140 / 200（隐身中为 0） |

**SoundSystem**（autoload）— 从噪音发生点向敌人发射射线，每穿过一面墙就乘以材质系数来缩小有效半径。
默认墙 0.20，thin 0.50，glass 0.35，fence 0.85，vent_shaft 0.65，metal 0.40，
掩体 0.70，关闭的门 0.40。按 `F3` 显示噪音源与听到噪音的敌人。

**警卫 INVESTIGATE** — 听到声音会显示 `?` 并变为蓝灰色，以 0.7 倍速度走向声源。
到达（或被墙挡住）后环顾 3 秒再回到巡逻。调查中看到玩家会升级为 SUSPICIOUS，
SUSPICIOUS 状态下听到的声音会增大怀疑量表。ALERT 不会被声音降级。
调查中再次听到的声音会累积怀疑，音量大（intensity > 0.5）时更新目标。

**视觉线索** — 视野内看到同伴的尸体会伴随 `!?` 调查（怀疑 0.4，警报 +0.10，3 秒），
打开的门在视野距离 0.7 倍内会伴随 `?` 调查（怀疑 0.15，警报 +0.03，2 秒）。
每个警卫对同一具尸体·门只调查一次，调查中新看到的线索只保留目标并使怀疑 +0.2。

**警戒解除（de-escalation）** — 失去视野后逐级下降。
ALERT →（1.5 秒内继续追向最后目击点）→ SUSPICIOUS →（在最后目击点搜索 4 秒）→
INVESTIGATE →（环顾 3 秒）→ PATROL。被发现后到完全冷静约需 8.5 秒。
搜索中再次看到会持续推高怀疑直到 ALERT，搜索中听到的声音也会推高怀疑，满了就 ALERT。

**搬运尸体** — 在倒下的警卫附近按 F 扛起，再按 F 放到前方。
搬运中速度 60%（与隐身相乘），不能奔跑·暗杀，行走噪音 ×1.5，即使隐身也有 45px 噪音。
被搬运的尸体警卫看不到，放下的尸体即使已看过的警卫也会再次调查。

**地图（M）** — 房间（访问过的房间高亮）、实际走廊形状、锁门、剩余钥匙·目标、警卫状态、玩家位置。
未发现的隐藏通道不会显示。

**房间模板**（`scripts/RoomTemplates.gd`）— 按房间类型的内墙布置。
OBJECTIVE/HIGH_SECURITY = 2 个 L 形隔断，CHOKE = 中间开口的十字形，KEY_ROOM/ALT_PATH = 4 个角落立柱，
TRANSIT/OBSERVATION/SIDE_OBJECTIVE = 开放房间。坐标以 15×11 为基准，大小不同的房间按比例缩放。
走廊图块上不放墙，会在放入内墙的状态下做通行可能性检查。

---

## 5. 操作

| 按键 | 动作 |
|---|---|
| WASD | 移动 |
| 鼠标 | 瞄准方向 |
| F | 交互（获取钥匙、收集目标、解锁） |
| E | 暗杀 — 只能从敌人**背后**成功，有次数限制 |
| Shift | 奔跑（快但噪音 280px） |
| Ctrl | 隐身 — 任何地方都慢（38%）且无声、半透明。在掩体旁不会被敌人看到，在开阔地能看到但察觉速度为 0.6 倍。隐身中开门不出声。与 Shift 同按时隐身优先 |
| F | （倒下的警卫附近）扛起尸体 / 搬运中放下 — 优先于门·道具 |
| M | 地图（暂停）。按 M 或 ESC 关闭 |
| F3 | 噪音调试显示切换 |
| ESC | 暂停菜单（继续 / 设置 / 重新开始 / 回到菜单）。结束画面则为重试 |

收集全部目标物 → 到达 EXIT 房间 → 逃脱成功。

---

## 6. 结构

```
project.godot          Autoload(GameState) + 输入映射
scenes/Main.tscn       只有一个根节点 — 其余全部由代码生成
scripts/
  Entities.gd          玩家/敌人/道具/门/掩体/墙的生成工厂
  GameState.gd         全局状态（Autoload）
  LevelLoader.gd       JSON 解析 → BFS 布局 → 房间/走廊/内容物生成
  Player.gd            移动·瞄准·隐身·交互·暗杀
  Enemy.gd             巡逻 FSM（PATROL→SUSPICIOUS→ALERT）+ 视野锥
  Item.gd              钥匙/目标物/加成
  Door.gd              锁门
  Cover.gd             掩体
  Main.gd              入口 + HUD 构建
levels/level_data.json Python 流水线输出
```

只有 `.tscn` 文件只有一个的原因：场景格式手写很容易因版本差异而损坏。
所有节点都用 GDScript 创建，消除了这个风险。

---

## 7. 物理层

| 层 | 对象 | 备注 |
|---|---|---|
| 1 | 墙 / 掩体 / 锁门 | 阻挡移动 + 阻挡敌人视线 |
| 2 | 玩家 | |
| 4 | 敌人 | |
| 8 | 道具 | 可穿透，只检测交互 |

---

## 8. 想调整的时候

- 敌人太强 → `Enemy.gd` 的 `_apply_config()` 里的 `fov_range`、`patrol_speed` 系数
- 房间太大/太小 → `LevelLoader.gd` 顶部的 `ROOM_W`、`ROOM_H`、`GAP`
- 相机缩放 → `Entities.gd` 的 `make_player()` 里的 `cam.zoom`
- 暗杀判定角度 → `Player.gd` 的 `ASSASSIN_ARC_DEG`

---

## 9. 视觉构成

| 脚本 | 作用 |
|---|---|
| `CharArt.gd` | 手绘风角色绘制 — 头/躯干/四肢/武器以矢量绘制 |
| `VisualKit.gd` | 光照贴图、遮影体、粒子、暗角着色器、面板样式 |
| `RoomFloor.gd` | 房间地面 — 方格地砖 + 地面上刻印的房间名 |
| `CorridorFloor.gd` | 走廊地面 — 金属板接缝 + 中央引导线 |
| `Wall.gd` | 墙 — 顶部高光营造立体感 |
| `ExitMarker.gd` | 逃脱点 — 扩散环动画 |

**光照系统**：用 `CanvasModulate` 把全局压暗，每个房间放置 `PointLight2D`（带阴影）。
墙·掩体·门上挂有 `LightOccluder2D`，会产生**实时阴影**。
房间亮度（`light_level`）和色温按房间类型变化 — `OBSERVATION` 偏蓝，`CHOKE` 偏红，`EXIT` 偏青。

**角色**：玩家是披斗篷持短刀的特工，敌人是带头盔·面罩·手电·背包的警卫。
行走时四肢摆动，敌人的身体颜色和面罩颜色随状态（巡逻/怀疑/警戒）变化，
头顶显示怀疑量表和 `?` `!` 标记。

### 画面太暗或太亮时
调整 `Main.gd` 顶部的 `AMBIENT` 值。

```gdscript
const AMBIENT := Color(0.30, 0.32, 0.42)   # 越低越暗·对比越强
```

### 性能太重时
把 `LevelLoader.gd` 的 `_paint_room()` 里 `lamp.shadow_enabled = false`，
去掉阴影计算，会明显变轻。

---

## 10. 难度

### 两种设置方法

**A. 在 Python 侧指定**（记录到 JSON meta，游戏自动读取）

```bash
python export_for_godot.py --seed 42 --dtc late_climax --difficulty 2
```

**B. 在 Godot 里直接设置** — 选中 Main 节点后在检查器的 `Difficulty` 滑条（0~3）
※ JSON 里有 `meta.difficulty` 时以该值为优先。

| 值 | 名称 | 敌人数 | 移动/视野 | 掩体 | HP | 暗杀 | 警报上升 |
|---|---|---|---|---|---|---|---|
| 0 | EASY | ×0.55 | ×0.78 / ×0.80 | +2 | 4 | 5 | ×0.6 |
| 1 | NORMAL | ×1.00 | ×1.00 / ×1.00 | +0 | 3 | 3 | ×1.0 |
| 2 | HARD | ×1.45 | ×1.18 / ×1.22 | −1 | 2 | 2 | ×1.4 |
| 3 | BRUTAL | ×1.85 | ×1.32 / ×1.40 | −1 | 1 | 2 | ×1.8 |

### 任何难度都不会被破坏的不变条件

难度倍率会乘到 `num_patrols` 等算法给出的值上，但以下条件优先于倍率被强制保证
（`LevelLoader.gd` 顶部常量）。

| 条件 | 理由 |
|---|---|
| `ENTRY` / `OBSERVATION` 房间敌人为 0 | 始终保证起点和休整点 |
| 每个房间至少 2 个掩体 | 避免隐身手段消失 |
| 每房间最多 4 个敌人 | 保证回避空间 |
| 敌人·掩体禁止生成在走廊图块和入口 2 格以内 | 防止通道被堵导致无法通关 |
| HP ≥ 1，暗杀 ≥ 1 | |
| 道具固定在房间中央 | 始终可接近 |

### 运行时自动验证

游戏开始时 `verify_solvable()` 会在实际图块地图上做 flood fill，检查以下项目并把结果打印到输出面板。

```
[검증] NORMAL 난이도 — 클리어 가능 ✓  (도달 타일 1966/1966)
```

检查项目：
1. 门**锁着**的状态下所有 `KEY_ROOM` 可达（能否吃到钥匙）
2. 门**打开**的状态下所有 `OBJECTIVE` 和 `EXIT` 可达（能否通关）
3. 门**锁着**的状态下 `EXIT` **不可**达（没有绕过锁的捷径）

任何一项不符都会显示警告。

---

## 11. 配色

| 区域 | 颜色 |
|---|---|
| 场景外（墙外） | 鲜艳的红色 — `Main.gd` 的 `VOID_RED` |
| 墙 | 黑色 |
| 走廊 | 灰色混凝土 + 金属板接缝 |
| 房间 | 灰色底 + 按类型的浅色调 |

外侧红色放在单独的 `CanvasLayer(-20)` 上，不受 `CanvasModulate` 影响，
与光照亮度无关始终保持鲜艳。
