# Shadow Protocol — 알고리즘 연동 게임 프레임워크

Python 레벨 생성 파이프라인의 출력을 그대로 읽어 플레이 가능한 잠입 게임으로 만드는 Godot 프로젝트.

---

## 0. 타이틀 / 설정 / 음악

F5 로 실행하면 타이틀 화면(`scenes/TitleScreen.tscn`)이 뜬다.
**임무 시작** → 아래 생성 화면, **빠른 시작** → 기존 레벨(NORMAL), **설정**, **종료**.

- **설정** (`SettingsPanel.gd`, 값은 `Settings` autoload 가 `user://settings.cfg` 에 저장)
  — 언어 한국어 ↔ 简体中文, 전체 / BGM / 효과음 볼륨, BGM 켜기·끄기.
  번역은 `Settings.ZH` 사전 (한국어 원문 → 중국어). UI 를 만드는 헬퍼가 `Settings.tr_ko()` 를 거치므로
  새 문구는 사전에 한 줄 추가하면 된다. 숫자는 `#`, 키 이름 같은 값은 `%s` 템플릿으로 적는다.
  언어를 바꾸면 현재 화면을 다시 불러온다 (게임 중이면 레벨이 처음부터 다시 시작된다).
- **음악** (`MusicDirector` autoload, BGM 버스) — 타이틀은 title.ogg, 게임 중에는 긴장도(alert_level)에 따라
  sector → pulse → urgent 3겹을 교차 페이드, 안전 구역에서는 sector 로 돌아간다. 종료 시 transmission.ogg.
  음원: OpenGameArt "Dark Sci-Fi Audio Pack" (SRG774, CC0).
- **일시정지** (`PauseMenu.gd`) — 게임 중 ESC. 지도(M)와 겹쳐 열리지 않는다.

### 생성 화면

타이틀의 **임무 시작** 으로 들어오는 생성 화면(`scenes/StartScreen.tscn`).

- **경험 곡선** — 프리셋 7종을 고르거나, 그래프에서 **직접 그린다** (stealth_pcg 와 같은 제어점·코사인 보간)
  - 점 드래그: 이동 (양 끝점은 위아래만, 가운데 점은 이웃을 넘지 못함) · 빈 곳 클릭: 점 추가 · 우클릭: 점 삭제
  - 프리셋을 누르면 그 모양이 실리고, 손대는 순간 **✎ 사용자 정의** 가 된다 (이 버튼으로 마지막에 그린 곡선을 되찾는다)
  - 그린 곡선은 `--curve-points` 로 Python 에 넘어가고, 레벨 JSON 에는 `meta.target_curve = {name: "custom", points}` 로 남는다
- **생성 파라미터** — Seed(+Random), 목표·키잠금·병목·복도 수/길이, 우회로·보조목표 확률,
  Proximity % (맞닿은 벽 중 소리가 새는 벽의 비율 = `leak_rate`, 파이프라인 기본 35%)
- **진화 설정** — 개체군, 세대 수
- **난이도** — EASY / NORMAL / HARD / BRUTAL
- **생성 및 시작** — 시스템 Python 으로 `export_for_godot.py` 를 실행해 `levels/level_data.json` 을 새로 만들고 시작
  (`python` → `py` → `python3` 순으로 시도, 실패하면 마지막 출력 몇 줄을 화면에 표시)
- **빠른 시작** — 생성 없이 기존 `levels/level_data.json` (없으면 내장 레벨), 고른 난이도만 적용

게임이 끝나면 결과 화면의 **메인 메뉴** 버튼으로 타이틀에 돌아온다 (생성 화면은 직전 설정 유지).
`stealth_pcg/` 패키지는 프로젝트 폴더 또는 그 상위 폴더에 있어야 한다.

---

## 1. 실행 (JSON 없이 바로)

Godot 4.3+ → **Import** → `project.godot` 선택 → **F5**

`levels/level_data.json` 이 없으면 내장 레벨(9방)로 실행된다.

---

## 2. 알고리즘과 연동

### 2-1. Python 쪽에서 레벨 생성 (stealth_pcg)

`export_for_godot.py` 는 `stealth_pcg/` 패키지를 직접 import 한다.
패키지가 이 파일 옆 또는 한 단계 위(`GP/stealth_pcg`)에 있으면 자동으로 찾는다.

```bash
cd demo/
python export_for_godot.py --seed 42 --curve double_peak
```

파이프라인: 그래프 문법 생성 → 공간 배치 → 공유벽(proximity) 도출 → 진화 최적화 → 시뮬레이션 → 직렬화.
기본 출력은 `demo/levels/level_data.json` (Godot 이 바로 읽는 경로).

| 인자 | 값 | 설명 |
|---|---|---|
| `--seed` | 정수 (기본 42) | 문법·배치·진화 시드 |
| `--curve` | `escalating` `v_shape` `inverted_v` `double_peak` `late_climax` `roller_coaster` `flat_high` | 목표 긴장도 곡선 |
| `--curve-points` | `"0:0.1,0.3:0.85,0.55:0.2,1:0.7"` | 직접 그린 곡선 (x:y 목록, x 는 0 에서 1 까지 증가, 0 ≤ y ≤ 1). 주면 `--curve` 대신 사용 |
| `--gens` | 정수 (기본 40) | 진화 세대 수 |
| `--pop` | 정수 (기본 30) | 개체군 크기 |
| `--difficulty` | 0–3 (기본 1) | `meta.difficulty` 로 기록 → 게임 난이도 |
| `--out` | 경로 | 출력 파일 |
| `--no-layout` | | schema v2 의 `layout` 블록 생략 (게임은 사용하지 않음) |

출력은 schema v2 (= v1 + `layout`). 게임은 `version >= 1` 이면 v1 경로로 읽는다.
공유벽 재질(`material`)은 게임용 `wall_type` 으로 변환해 함께 기록한다
(concrete→thick, drywall→thin, glass→glass, metal→metal, mesh→fence).

### 2-2. 확인

F5 로 실행하면 좌하단에 `곡선  double_peak   DTW 0.018` 처럼 표시된다.
콘솔의 `[검증] ... 클리어 가능 ✓` 은 배치 후 실제 타일 단위 통과 가능성 검사 결과다.
그래프가 격자 배치에서 막히면(복도가 잠금 구역의 방을 관통하는 경우) 로더가 배치 방향을
바꿔 최대 16회 재시도한다 (`[LevelLoader] 배치 N회 재시도 후 …`).

---

## 3. 필드 매핑 — 알고리즘 → 게임

| Python | JSON 경로 | 게임에서의 효과 |
|---|---|---|
| `RoomParams.num_patrols` | `nodes[].room_params.num_patrols` | 그 방에 실제로 생성되는 적의 수 |
| `RoomParams.patrol_speed` | `…patrol_speed` | 적 이동속도 42–118 px/s, 추격속도는 그 2.1배 |
| `RoomParams.patrol_range` | `…patrol_range` | 적 시야 거리 110–260 px |
| `RoomParams.light_level` | `…light_level` | 적 시야각 30–52°, 방 바닥 밝기 |
| `RoomParams.cover_ratio` | `…cover_ratio` | 방 안 엄폐물 개수 (0–5개) |
| `RoomParams.resource_pickup` | `…resource_pickup` | 0.55 초과 시 암살기회 보너스 배치 |
| `Node.type` | `nodes[].type` | 방 색상 + 라벨 (ENTRY/CHOKE/OBJECTIVE…) |
| `Node.provides` | `nodes[].provides` | 그 방에 키 아이템 배치 |
| `Edge.locked` + `key_id` | `edges[].locked/key_id` | 두 방 사이에 잠금문 생성 |
| `Edge.one_way` | `edges[].one_way` | 배치 그래프의 양방향 여부 |
| DTC 목표곡선 | `meta.target_curve` | GameState 에 보관, 종료 시 로그로 출력 |
| 시뮬레이션 곡선 | `meta.simulated_curve` | 동일 |

### 3-1. stealth_pcg JSON Schema v1 (`"version": 1`)

최상위에 `"version": 1` 이 있으면 v1 경로(`_construct_v1`)로, 없으면 기존 경로(`_construct_legacy`)로 읽는다.

| v1 필드 | 게임에서의 효과 |
|---|---|
| `edges{}.patrol_density / cover_availability / exposure_length / noise_level` | 방에 닿는 간선들을 모아 room_params 유도 (적 수 = round(max patrol × 4), 엄폐 = min cover …) |
| `nodes{}.size_hint` | 방 크기 small 11×9 / medium 15×11 / large 19×13 |
| `nodes{}.threat_level` | 방 조명 세기·색온도 (low 밝고 따뜻, high 어둡고 붉게) |
| `nodes{}.safe_zone` | 적 없음 + 청록 링 + 진입 시 경보 0 + "안전 구역" 메시지, 로그에 `safe_zone` 기록 |
| `edges{}.traversal_type` | vent(좁고 금속 그릴) / climb(사다리) / hack(단말기 아이콘) / stealth_required(좁고 어두움) / takedown_required(붉은 바닥) |
| `edges{}.visibility` | hidden 통로는 벽색으로 덮여 있다가 양끝 방에 들어가거나 근처에 오면 드러남 (conditional 은 obvious 취급) |
| `edges{}.exposure_length` | 복도 폭 (1–2 → 3, 3–4 → 4, 5 → 5타일) |
| `proximity{}` | 격자상 이웃한 두 방의 마주 보는 벽을 glass/thin/fence/vent_shaft 외형으로 표시 (소리 누출은 TODO) |
| `meta.target_curve{name, points}` / `meta.fitness.final` | HUD `곡선 / DTW`, 로그의 target_curve (points 의 y 값) |
| `simulation_results.shortest_path.tension_trace` | simulated_curve |
| `clear_conditions` | objective_nodes 에 목표 아이템, optional_objectives 에 보너스, required_keys 를 모두 가져야 탈출 가능 |

---

## 4. 긴장도 · 결과 화면 · 플레이 로그 → 검증 데이터

### 4-1. 실시간 긴장도 T(t)

`scripts/TensionTracker.gd` 는 `stealth_pcg/simulation/tension.py` 의 `TensionCalculator.compute()` 를
그대로 옮긴 것이다. 플레이어가 **다른 방에 들어설 때마다** (되돌아간 방도 한 걸음) 한 번 계산한다.

	T(t) = clamp( max( Σ wᵢ·dᵢ(t),  τ·T(t-1) ), 0, 1 )

- 성분: 순찰 밀도 · 노출 · 엄폐 부족 · 소음 (지나온 간선), 방 위협, 누적 위험 (안전 구역 이후 걸음 수),
  잠금 압박 (이 방에서 나가는 잠금 간선의 키가 없음), 공유벽 너머 청각·시각 위협
- 가중치는 레벨 JSON 의 `meta.tension_weights` 를 그대로 쓴다
- "어느 간선으로 들어왔나" 는 방금 밟은 복도 타일로 판정한다 (복도가 다른 방을 관통해도 맞게 잡힌다)
- Python 에이전트와 같이 키 방에 도착한 걸음은 그 키를 가진 것으로 계산한다
- 이것이 **구조 긴장도** — 지도만 보고 정해지므로 경비가 무엇을 하든 그 방에서는 변하지 않는다

**실시간 긴장도** (게임 전용 층, HUD 상단 **TENSION** 막대에 표시)

	raw = clamp( T_room + 0.25·alert_level + 0.35·guard_threat, 0, 1 )
	guard_threat = max_경비( 상태 가중치 × (1 − 거리/480px) )   순찰 0.15 / 조사 0.35 / 의심 0.65 / 추격 1.0

- 매 프레임 갱신. 오를 때는 빠르게 따라가고, 내려갈 때는 1.5초마다 0.6 배로 천천히 (τ=0.6 을 시간 축으로)
- 방에 들어서면 최소 그 방의 구조 긴장도. 경비를 따돌리면 구조 값으로 돌아온다
- 걸음(방)마다 최고값·평균을 기록한다 → 결과 화면 / play_log 의 "실시간" 곡선
- 가중치·범위는 `TensionTracker.gd` 상단 상수 (`LIVE_W_ALERT`, `LIVE_W_GUARD`, `GUARD_STATE_WEIGHT`, `GUARD_RANGE`)

검증: AI 경로(`simulation_results.*.path`)를 그대로 넣으면 Python `tension_trace` 와 걸음마다 일치
(최대 오차 0.00006 = JSON 반올림), 게임 안에서 그 경로를 실제로 걸어도 같은 궤적이 기록된다.

### 4-2. 결과 화면

종료 시 네 곡선을 겹쳐 그린다 — 목표 곡선(파랑 점선, 제어점 코사인 보간) · AI 예측(초록, shortest_path) ·
플레이어 구조(주황, 가는 선) · 플레이어 실시간 최고값(빨강, 굵은 선).
아래에 DTW(구조↔목표, 실시간↔목표, AI↔목표), 방문한 방, 이동 걸음, 암살, 발각, 소요 시간, 수집 키.

**도중에 죽으면** 플레이어 곡선을 전 구간으로 늘리지 않는다. x 축을 AI 경로 길이 기준으로 잡아
간 데까지만 그리고(사망 지점에 ✕ 와 세로선, 그 뒤는 어둡게), DTW 도 목표 곡선의 그 구간 [0, 진행도] 만
잘라 비교한다. 탈출하면 지금처럼 전 구간 (Python 비교 방식과 동일).
버튼: **메인 메뉴** / **같은 레벨 재시도** (ESC).

DTW 는 Python 과 같이 목표 곡선을 궤적 길이만큼 샘플링한 뒤 `normalised_dtw`
(|a−b| 누적, Sakoe-Chiba 밴드 12%, ÷(len a + len b)) — `curves/dtw_wrapper.py` 의 순수 Python 구현과 같은 값.
`dtaidistance` 가 설치돼 있으면 Python 이 C 구현을 쓰지만, 같은 정의(|a−b|, 같은 밴드)로 호출하므로
값은 순수 Python 과 똑같다 — 같은 seed 는 어느 PC 에서든 같은 레벨을 만들고, 결과 화면의 AI DTW 는
`meta.fitness.final` 과 일치한다 (JSON 반올림 오차 이내).

### 4-3. 플레이 로그

게임이 끝나면 (성공/실패 무관) 다음 경로에 저장된다:

- Windows: `%APPDATA%\Godot\app_userdata\ShadowProtocol\play_log.json`
- 실행 시 콘솔에 정확한 절대경로가 출력됨

```json
{
  "won": true,
  "target_curve": [...],          // 목표 곡선 제어점 y
  "simulated_curve": [...],       // AI 예측 궤적
  "player_visit_log": [           // 방에 들어설 때마다 (재방문 포함)
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

- `tension` 은 구조 긴장도(Python 과 같은 값), `live_peak` / `live_mean` 은 그 방에 있는 동안의 실시간 긴장도
- `partial` / `progress_at_end` — 도중 사망이면 true / AI 경로 길이 기준으로 어디까지 갔는지 (DTW 는 그 구간만 비교)
- `target_tension` 은 플레이 도중의 기준값 (AI 경로 길이를 예상 길이로 본 진행도). 최종 DTW 는
  `target_sampled_for_player` (실제 궤적 길이로 다시 샘플링) 와 비교한다.
- `detection_count` — 경비가 플레이어를 **보고** SUSPICIOUS 로 올라간 횟수 (ALERT 에서 내려온 경우는 제외)

이 로그로 **"설계 의도 곡선 ↔ AI 예측 ↔ 실제 사람의 체감"** 3자 검증을 한다.

---

## 4-4. 소리 / 경비병 조사 / 방 템플릿

**이동과 소음** — `Shift` 달리기, `Ctrl` 은신(어디서나 무음, 엄폐물 옆이면 시야에서도 사라짐. 둘 다 누르면 은신 우선).

| 상태 | 속도 (px/s) | 소음 반경 (px) |
|---|---|---|
| 걷기 | 130 | 90 |
| 달리기 | 235 | 280 |
| 은신 | 49 | 0 (무음) |
| 암살 | — | 120 |
| 문 열기 / 잠금문 해제 | — | 140 / 200 (은신 중이면 0) |

**SoundSystem** (autoload) — 소음 발생 지점에서 적까지 레이를 쏘고, 지나는 벽마다 재질 계수를 곱해
유효 반경을 줄인다. 기본 벽 0.20, thin 0.50, glass 0.35, fence 0.85, vent_shaft 0.65, metal 0.40,
엄폐물 0.70, 닫힌 문 0.40. `F3` 으로 소음 원과 들은 적을 표시한다.

**경비병 INVESTIGATE** — 소리를 들으면 `?` 를 띄우고 청회색으로 바뀌어 소리 난 곳으로 0.7배 속도로 걸어간다.
도착(또는 벽에 막힘) 후 3초간 둘러보고 순찰로 돌아간다. 조사 중 플레이어를 보면 SUSPICIOUS 로 격상,
SUSPICIOUS 상태에서 들은 소리는 의심 게이지를 키운다. ALERT 는 소리로 격하되지 않는다.
조사 중 다시 들린 소리는 의심을 누적하고, 크게(intensity > 0.5) 들리면 목표를 갱신한다.

**시각 단서** — 시야에 들어온 동료의 시체는 `!?` 와 함께 조사(의심 0.4, 경보 +0.10, 3초),
열린 문은 시야 거리 0.7배 안에서 `?` 와 함께 조사(의심 0.15, 경보 +0.03, 2초).
경비병마다 같은 시체·문은 한 번만 조사하며, 이미 조사 중에 새 단서를 보면 목표는 유지하고 의심만 +0.2.

**경계 해제 (de-escalation)** — 시야를 잃으면 한 단계씩 내려간다.
ALERT → (1.5초 동안 마지막 목격 지점으로 계속 추격) → SUSPICIOUS → (마지막 목격 지점 4초 수색) →
INVESTIGATE → (3초 둘러봄) → PATROL. 들킨 뒤 완전히 식기까지 약 8.5초.
수색 중 다시 보이면 의심이 계속 올라 ALERT 로, 수색 중 들린 소리도 의심을 올려 가득 차면 ALERT.

**시체 운반** — 쓰러진 경비 근처에서 F 로 들고, 다시 F 로 앞쪽에 내려놓는다.
운반 중 속도 60% (은신과 곱해짐), 달리기·암살 불가, 걷는 소음 ×1.5, 은신해도 45px 소음.
운반 중인 시체는 경비가 보지 못하고, 내려놓은 시체는 이미 본 경비도 다시 조사한다.

**지도 (M)** — 방(방문한 방은 밝게), 실제 복도 모양, 잠금문, 남은 키·목표, 경비 상태, 플레이어 위치.
발견하지 못한 숨은 통로는 표시하지 않는다.

**방 템플릿** (`scripts/RoomTemplates.gd`) — 방 타입별 내부벽 인프라.
OBJECTIVE/HIGH_SECURITY = L자 칸막이 2개, CHOKE = 가운데만 뚫린 십자형, KEY_ROOM/ALT_PATH = 모서리 기둥 4개,
TRANSIT/OBSERVATION/SIDE_OBJECTIVE = 열린 방. 좌표는 15×11 기준이고 크기가 다른 방에는 비율로 맞춘다.
복도 타일 위에는 벽을 두지 않으며, 내부벽을 넣은 상태로 통과 가능성 검사를 한다.

---

## 5. 조작

| 키 | 동작 |
|---|---|
| WASD | 이동 |
| 마우스 | 조준 방향 |
| F | 상호작용 (키 획득, 목표 수집, 잠금문 해제) |
| E | 암살 — 적의 **뒤쪽**에서만 성공, 횟수 제한 |
| Shift | 달리기 (빠르지만 소음 280px) |
| Ctrl | 은신 — 어디서나 느리고(38%) 무음, 반투명. 엄폐물 옆이면 적에게 안 보이고, 탁 트인 곳이면 보이지만 알아채는 속도가 0.6배. 은신 중 문을 열면 소리가 나지 않는다. Shift 와 함께 누르면 은신 우선 |
| F | (쓰러진 경비 근처) 시체 들기 / 운반 중이면 내려놓기 — 문·아이템보다 우선 |
| M | 지도 (일시정지). M 또는 ESC 로 닫기 |
| F3 | 소음 디버그 표시 토글 |
| ESC | 일시정지 메뉴 (계속 / 설정 / 다시 시작 / 메뉴로). 종료 화면에서는 재시작 |

목표물 전부 수집 → EXIT 방 도달 → 탈출 성공.

---

## 6. 구조

```
project.godot          Autoload(GameState) + 입력 매핑
scenes/Main.tscn       루트 노드 하나뿐 — 나머지는 전부 코드 생성
scripts/
  Entities.gd          플레이어/적/아이템/문/엄폐물/벽 생성 팩토리
  GameState.gd         전역 상태 (Autoload)
  LevelLoader.gd       JSON 파싱 → BFS 배치 → 방/복도/내용물 생성
  Player.gd            이동·조준·은신·상호작용·암살
  Enemy.gd             순찰 FSM (PATROL→SUSPICIOUS→ALERT) + 시야콘
  Item.gd              키/목표물/보너스
  Door.gd              잠금문
  Cover.gd             엄폐물
  Main.gd              진입점 + HUD 구성
levels/level_data.json Python 파이프라인 출력
```

`.tscn` 파일이 하나뿐인 이유: 씬 포맷은 손으로 쓰면 버전별 차이로 깨지기 쉽다.
모든 노드를 GDScript 로 만들어 그 위험을 제거했다.

---

## 7. 물리 레이어

| 레이어 | 대상 | 비고 |
|---|---|---|
| 1 | 벽 / 엄폐물 / 잠금문 | 이동 차단 + 적 시야 차단 |
| 2 | 플레이어 | |
| 4 | 적 | |
| 8 | 아이템 | 통과 가능, 상호작용만 감지 |

---

## 8. 조정하고 싶을 때

- 적이 너무 강하다 → `Enemy.gd` 의 `_apply_config()` 에서 `fov_range`, `patrol_speed` 계수
- 방이 너무 크다/작다 → `LevelLoader.gd` 상단 `ROOM_W`, `ROOM_H`, `GAP`
- 카메라 줌 → `Entities.gd` 의 `make_player()` 안 `cam.zoom`
- 암살 판정 각도 → `Player.gd` 의 `ASSASSIN_ARC_DEG`


---

## 9. 비주얼 구성

| 스크립트 | 역할 |
|---|---|
| `CharArt.gd` | 손그림 캐릭터 드로잉 — 머리/몸통/팔다리/무기를 벡터로 그림 |
| `VisualKit.gd` | 조명 텍스처, 그림자 차단체, 파티클, 비네트 셰이더, 패널 스타일 |
| `RoomFloor.gd` | 방 바닥 — 체크 타일 + 바닥에 각인된 방 이름 |
| `CorridorFloor.gd` | 복도 바닥 — 금속판 이음새 + 중앙 유도선 |
| `Wall.gd` | 벽 — 상단 하이라이트로 입체감 |
| `ExitMarker.gd` | 탈출 지점 — 확산 링 애니메이션 |

**조명 시스템**: `CanvasModulate` 로 전역을 어둡게 깔고, 방마다 `PointLight2D`(그림자 O)를 배치한다.
벽·엄폐물·문에는 `LightOccluder2D` 가 붙어 있어 **실시간 그림자**가 생긴다.
방의 밝기(`light_level`)와 색온도는 방 타입에 따라 달라진다 — `OBSERVATION` 은 푸른빛,
`CHOKE` 는 붉은빛, `EXIT` 는 청록빛.

**캐릭터**: 플레이어는 망토를 걸치고 단검을 든 요원, 적은 헬멧·바이저·손전등·배낭을 갖춘 경비병.
걸을 때 팔다리가 흔들리고, 적은 상태(순찰/의심/경계)에 따라 몸 색과 바이저 색이 바뀌며
머리 위에 의심 게이지와 `?` `!` 표시가 뜬다.

### 밝기가 너무 어둡거나 밝을 때
`Main.gd` 상단의 `AMBIENT` 값을 조절한다.

```gdscript
const AMBIENT := Color(0.30, 0.32, 0.42)   # 낮출수록 어두움·대비 강함
```

### 성능이 무거울 때
`LevelLoader.gd` 의 `_paint_room()` 에서 `lamp.shadow_enabled = false` 로 두면
그림자 계산이 사라져 크게 가벼워진다.


---

## 10. 난이도

### 설정 방법 두 가지

**A. Python 쪽에서 지정** (JSON meta 에 기록되어 게임이 자동으로 읽음)

```bash
python export_for_godot.py --seed 42 --dtc late_climax --difficulty 2
```

**B. Godot 에서 직접** — Main 노드 선택 후 인스펙터의 `Difficulty` 슬라이더 (0~3)
※ JSON 에 `meta.difficulty` 가 있으면 그 값이 우선한다.

| 값 | 이름 | 적 수 | 이동/시야 | 엄폐물 | HP | 암살 | 경보 상승 |
|---|---|---|---|---|---|---|---|
| 0 | EASY | ×0.55 | ×0.78 / ×0.80 | +2 | 4 | 5 | ×0.6 |
| 1 | NORMAL | ×1.00 | ×1.00 / ×1.00 | +0 | 3 | 3 | ×1.0 |
| 2 | HARD | ×1.45 | ×1.18 / ×1.22 | −1 | 2 | 2 | ×1.4 |
| 3 | BRUTAL | ×1.85 | ×1.32 / ×1.40 | −1 | 1 | 2 | ×1.8 |

### 어떤 난이도에서도 깨지지 않는 불변 조건

난이도 배율은 `num_patrols` 등 알고리즘이 내놓은 값에 곱해지지만,
아래 조건은 배율보다 우선해서 강제된다 (`LevelLoader.gd` 상단 상수).

| 조건 | 이유 |
|---|---|
| `ENTRY` / `OBSERVATION` 방은 적 0명 | 시작 지점과 휴식 지점을 항상 보장 |
| 방마다 엄폐물 최소 2개 | 은신 수단이 사라지지 않게 |
| 방당 적 최대 4명 | 회피 공간 확보 |
| 적·엄폐물은 복도 타일과 입구 2칸 이내에 스폰 금지 | 통로가 막혀 진행 불가해지는 것 방지 |
| HP ≥ 1, 암살 ≥ 1 | |
| 아이템은 방 중앙 고정 | 항상 접근 가능 |

### 실행 시 자동 검증

게임 시작 시 `verify_solvable()` 이 실제 타일 맵에서 flood fill 을 돌려
아래를 확인하고 출력 패널에 결과를 찍는다.

```
[검증] NORMAL 난이도 — 클리어 가능 ✓  (도달 타일 1966/1966)
```

검사 항목:
1. 문을 **잠근** 상태에서 모든 `KEY_ROOM` 도달 가능 (키를 먹을 수 있는가)
2. 문을 **연** 상태에서 모든 `OBJECTIVE` 와 `EXIT` 도달 가능 (클리어 가능한가)
3. 문을 **잠근** 상태에서 `EXIT` 도달 **불가** (잠금 우회로가 없는가)

하나라도 어긋나면 경고가 뜬다.

---

## 11. 색 구성

| 영역 | 색 |
|---|---|
| 장면 바깥 (벽 너머) | 선명한 빨강 — `Main.gd` 의 `VOID_RED` |
| 벽 | 검정 |
| 복도 | 회색 콘크리트 + 금속판 이음새 |
| 방 | 회색 베이스에 타입별 옅은 색조 |

바깥 빨강은 `CanvasModulate` 의 영향을 받지 않도록 별도 `CanvasLayer(-20)` 에 두어
조명 밝기와 무관하게 항상 선명하게 보인다.
