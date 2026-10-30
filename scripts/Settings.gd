## Settings — 전역 설정 (Autoload)
## 담당: 오디오 버스 생성·볼륨, 언어, 설정 저장 (user://settings.cfg)
##
## [오디오 버스]
## Master / BGM / SFX 세 버스를 만든다. BGM 은 MusicDirector 가 사용한다.
## 새 소리를 붙일 때는 플레이어의 bus 만 지정하면 볼륨 슬라이더가 바로 적용된다:
##   var bgm := AudioStreamPlayer.new()
##   bgm.bus = "BGM"          # ← 이 한 줄이면 슬라이더가 적용된다
##   bgm.stream = load("res://assets/audio/ogg/sector.ogg")
##   add_child(bgm)
##
##   var sfx := AudioStreamPlayer.new()
##   sfx.bus = "SFX"
extends Node

const CONFIG_PATH := "user://settings.cfg"

# ── 오디오 버스 이름 ──
const BUS_MASTER := "Master"
const BUS_BGM := "BGM"
const BUS_SFX := "SFX"

# ── 언어 ──
## 언어 코드 → 표시 이름
const LANGUAGES := {
	"ko": "한국어",
	"zh": "简体中文",
}
## 번역이 끝난 언어 (여기 없는 언어는 설정 화면에서 비활성)
const READY_LANGUAGES := ["ko", "zh"]

## 한국어 원문 → 중국어 번역 사전.
## 화면에 보이는 한국어 문자열을 "그대로" 키로 쓴다.
##
## 원문 키 방식을 쓰는 이유: 호출부를 일일이 tr() 로 감싸지 않아도,
## 라벨·버튼을 만드는 "생성 헬퍼" 몇 곳만 고치면 하위 문구가 전부 따라온다.
##
## ※ 숫자가 들어가는 문구는 숫자 덩어리를 # 로 적는다 → "목표 #/# 수집"
##    (실제로는 "목표 2/3 수집" 이 들어와도 tr() 이 숫자를 보존하며 치환한다)
## ※ 여기 없는 문자열은 그냥 한국어로 표시된다. 오류 없이 점진 추가 가능.
const ZH := {
	# ── 타이틀 (TitleScreen) ──
	"▶   임무 시작": "▶   开始任务",
	"⚡   빠른 시작": "⚡   快速开始",
	"⚙   설  정": "⚙   设 置",
	"✕   종료": "✕   退出",
	"WASD 이동 · F 상호작용 · E 암살 · Shift 달리기 · Ctrl 은신":
		"WASD 移动 · F 交互 · E 暗杀 · Shift 奔跑 · Ctrl 潜行",

	# ── 생성 화면 (StartScreen) ──
	"경험 곡선": "体验曲线",
	"난이도": "难度",
	"생성 파라미터": "生成参数",
	"진화 설정": "进化设置",
	"맞닿은 벽 중 소리가 새는 벽(얇은 벽·유리·철망 등)의 비율":
		"相邻墙体中漏音墙体（薄墙·玻璃·铁丝网等）的比例",
	"▶  생성 및 시작": "▶  生成并开始",
	"빠른 시작 (기존 레벨)": "快速开始（使用现有关卡）",
	"↩  되돌아가기": "↩  返回",
	"✎ 사용자 정의": "✎ 自定义",
	"사용자 정의 곡선": "自定义曲线",
	"사용자 정의": "自定义",
	"드래그: 점 이동 · 빈 곳 클릭: 점 추가 · 우클릭: 점 삭제": "拖动：移动点 · 点击空白处：添加点 · 右键：删除点",
	"레벨 생성 중": "关卡生成中",
	"긴장도": "紧张度",
	"진행 →": "进度 →",
	"export_for_godot.py 를 찾을 수 없습니다: ": "找不到 export_for_godot.py：",
	"Python 실행 파일을 찾지 못했습니다 (시도: %s). Python 을 설치하고 PATH 에 추가하세요.":
		"找不到 Python 可执行文件（已尝试：%s）。请安装 Python 并加入 PATH。",
	"생성 실패 (exit %d):\n%s": "生成失败（exit %d）：\n%s",

	# ── 게임 HUD / 종료 화면 (Main) ──
	"목표 0/0": "目标 0/0",
	"메인 메뉴": "主菜单",
	"난이도  ": "难度  ",
	"      곡선  ": "      曲线  ",
	"      내장 레벨": "      内置关卡",
	"  ·  안전 구역": "  ·  安全区",
	"목표  # / #": "目标  # / #",
	"        ▸  필요 키  ": "        ▸  需要钥匙  ",
	"        ▸  EXIT 로 탈출": "        ▸  前往 EXIT 逃脱",
	"탈출 성공\n\nHP #        남은 암살 #        방문한 구역 #":
		"逃脱成功\n\nHP #        剩余暗杀 #        已访问区域 #",
	"임무 실패\n\n발각되었습니다": "任务失败\n\n已被发现",

	# ── 결과 화면 (Main) ──
	"탈출 성공": "逃脱成功",
	"임무 실패 — 발각되었습니다": "任务失败 — 已被发现",
	"경험 곡선 비교": "体验曲线对比",
	"통계": "统计",
	"DTW (플레이어 ↔ 목표)": "DTW（玩家 ↔ 目标）",
	"DTW (AI ↔ 목표)": "DTW（AI ↔ 目标）",
	"방문한 방": "访问房间",
	"이동 걸음": "移动步数",
	"암살": "暗杀",
	"발각": "被发现",
	"소요 시간": "用时",
	"수집 키": "收集钥匙",
	"없음": "无",
	"DTW 는 낮을수록 목표 곡선에 가깝다": "DTW 越低越接近目标曲线",
	"진행도 →": "进度 →",
	"목표 곡선 (%s)": "目标曲线（%s）",
	"AI 예측 (shortest_path)": "AI 预测（shortest_path）",
	"실제 플레이어": "实际玩家",
	"플레이어 · 구조": "玩家 · 结构",
	"플레이어 · 실시간 (최고값)": "玩家 · 实时（峰值）",
	"DTW (구조 ↔ 목표)": "DTW（结构 ↔ 目标）",
	"DTW (실시간 ↔ 목표)": "DTW（实时 ↔ 目标）",
	"사망": "死亡",
	"사망 — 진행 %d%% 까지의 구간만 목표와 비교": "死亡 — 仅与目标曲线前 %d%% 段比较",
	"같은 레벨 재시도   ( ESC )": "重试同一关卡   ( ESC )",
	"WASD 이동     Shift 달리기     Ctrl 은신 (엄폐물 옆: 안 보임)     마우스 조준     F 상호작용     E 암살(배후) · F 시체 운반     M 지도     F3 소음 표시":
		"WASD 移动     Shift 奔跑     Ctrl 潜行（掩体旁：不可见）     鼠标瞄准     F 交互     E 暗杀（背后） · F 搬运尸体     M 地图     F3 噪音显示",

	# ── HUD 알림 메시지 (GameState.post_message) ──
	"KEY %s 획득": "获得钥匙 %s",
	"목표 #/# 수집": "目标 #/# 已收集",
	"피격!": "被击中！",
	"암살 횟수 소진": "暗杀次数已用尽",
	"암살 성공": "暗杀成功",
	"안전 구역": "安全区",

	# ── 플레이어 안내 (Player / Item) ──
	"주변에 상호작용할 대상이 없습니다": "附近没有可交互目标",
	"시체 운반 중 (F: 내려놓기)": "搬运尸体中（F：放下）",
	"시체를 내려놓았습니다": "已放下尸体",
	"시체를 운반 중에는 암살할 수 없습니다": "搬运尸体时无法暗杀",
	"적의 뒤에서 접근하세요": "请从敌人背后接近",
	"암살 기회 +1": "暗杀机会 +1",

	# ── 잠금문 (Door) — %s = 키 이름 ──
	"%s 키가 필요합니다": "需要钥匙 %s",
	"%s 조용히 잠금 해제": "已悄悄解锁 %s",
	"%s 문 해제": "%s 门已解锁",
	"내려놓기": "放下",
	"운반": "搬运",

	# ── 설정 패널 (SettingsPanel) ──
	"설  정": "设 置",
	"언어 / Language": "语言 / Language",
	"사운드 / Sound": "声音 / Sound",
	"전체 볼륨": "总音量",
	"효과음": "音效",
	"BGM 스위치": "BGM 开关",
	"켜짐": "已开启",
	"꺼짐": "已关闭",
	"기본값 복원": "恢复默认值",
	"닫  기": "关 闭",
	"  (번역 준비 중)": "  （翻译准备中）",
	"이 언어의 번역이 아직 완료되지 않았습니다": "该语言的翻译尚未完成",
	"※ BGM은 긴장도(alert)에 따라 자동으로 전환됩니다. 스위치로 켜고 끌 수 있습니다.":
		"※ BGM 会随紧张度（alert）自动切换，可用开关开启或关闭。",

	# ── 일시정지 메뉴 (PauseMenu) ──
	"일시정지": "暂停",
	"ESC 를 다시 누르면 계속합니다": "再按一次 ESC 继续",
	"계  속": "继 续",
	"다시 시작": "重新开始",
	"메뉴로 나가기": "返回主菜单",

	# ── 지도 범례 (Minimap) ──
	"플레이어": "玩家",
	"경비 (추격)": "守卫（追击）",
	"경비 (의심)": "守卫（怀疑）",
	"경비 (조사)": "守卫（调查）",
	"경비 (순찰)": "守卫（巡逻）",
	"쓰러진 경비": "被击倒的守卫",
	"키": "钥匙",
	"목표": "目标",
	"잠긴 문": "上锁的门",
	"지도  —  M / ESC 로 닫기   (일시정지 중)": "地图  —  按 M / ESC 关闭（暂停中）",
}

# ── 설정 값 ──
var language: String = "ko"
var master_volume: float = 0.8   # 0.0 ~ 1.0
var bgm_volume: float = 0.8
var sfx_volume: float = 0.8
var music_enabled: bool = true   # BGM On/Off (BGM 버스 mute 로 구현)

## 설정이 바뀔 때마다 발생 (UI 갱신용)
signal settings_changed


func _ready() -> void:
	_ensure_audio_buses()
	load_settings()
	apply_audio()
	_apply_music_enabled()
	print("[Settings] 설정 불러옴: language=%s master=%.0f%% bgm=%.0f%% sfx=%.0f%% music=%s" % [
		language, master_volume * 100, bgm_volume * 100, sfx_volume * 100, "ON" if music_enabled else "OFF"])


# ═══════════════════════════════════════
#  오디오 버스
# ═══════════════════════════════════════

## BGM / SFX 버스를 만들어 Master 로 보낸다 (Godot 기본은 Master 뿐)
func _ensure_audio_buses() -> void:
	for bus_name in [BUS_BGM, BUS_SFX]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx: int = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			var master_idx: int = AudioServer.get_bus_index(BUS_MASTER)
			if master_idx >= 0:
				AudioServer.set_bus_send(idx, BUS_MASTER)


## 세 볼륨 값을 버스에 적용
func apply_audio() -> void:
	_set_bus_volume(BUS_MASTER, master_volume)
	_set_bus_volume(BUS_BGM, bgm_volume)
	_set_bus_volume(BUS_SFX, sfx_volume)


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	var v: float = clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_mute(idx, v <= 0.001)
	AudioServer.set_bus_volume_db(idx, _to_db(v))


## 선형 볼륨(0~1) → dB. 0 은 -80dB (linear_to_db(0) 은 -inf)
func _to_db(v: float) -> float:
	if v <= 0.001:
		return -80.0
	return linear_to_db(v)


# ═══════════════════════════════════════
#  언어
# ═══════════════════════════════════════

## 번역이 끝난 언어인가 (아니면 UI 에서 비활성)
func is_language_ready(code: String) -> bool:
	return code in READY_LANGUAGES


## 한국어 원문을 현재 언어 문자열로 바꾼다. 중국어 사전에 없으면 원문(한국어) 그대로.
## 사용: Settings.tr_ko("임무 시작") → 중국어면 "开始任务", 한국어면 "임무 시작"
##
## 숫자가 섞인 문구도 처리한다:
##   "목표 2/3 수집" → 숫자 덩어리를 # 로 바꿔 사전을 찾고(ZH 에는 "목표 #/# 수집"),
##   찾은 중국어 문장에 원래 숫자를 다시 끼워 넣는다 → "目标 2/3 已收集"
func tr_ko(ko: String) -> String:
	if language != "zh":
		return ko
	if ZH.has(ko):
		return str(ZH[ko])

	# 앞뒤 공백은 UI 정렬용이라 사전 키에는 없다 → 공백을 떼고 한 번 더 찾은 뒤 되돌려 붙인다.
	# (예: "난이도  " → "难度  ")
	var bare := ko.strip_edges()
	if bare != ko and ZH.has(bare):
		var head := ko.substr(0, ko.length() - ko.strip_edges(true, false).length())
		var tail := ko.substr(ko.strip_edges(false, true).length())
		return head + str(ZH[bare]) + tail

	# 숫자 덩어리를 # 로 정규화하면서 원래 숫자를 보관
	var nums: Array = []
	var norm := ""
	var i := 0
	var n := ko.length()
	while i < n:
		var ch := ko.substr(i, 1)
		if ch >= "0" and ch <= "9":
			var start := i
			while i < n and ko.substr(i, 1) >= "0" and ko.substr(i, 1) <= "9":
				i += 1
			nums.append(ko.substr(start, i - start))
			norm += "#"
		else:
			norm += ch
			i += 1

	if nums.is_empty() or not ZH.has(norm):
		return ko

	# 중국어 문장을 # 로 자르고 그 사이에 원래 숫자를 끼워 넣는다
	var tmpl: String = str(ZH[norm])
	var segs := tmpl.split("#", true)
	var out := ""
	for idx in range(segs.size()):
		out += segs[idx]
		if idx < nums.size():
			out += nums[idx]
	return out


## (구버전 호환) key 기반 번역 진입점 — 이제는 원문 번역 tr() 로 위임한다
func tr_key(_key: String, fallback: String) -> String:
	return tr_ko(fallback)


func set_language(code: String) -> void:
	if not LANGUAGES.has(code):
		return
	if not is_language_ready(code):
		push_warning("[Settings] 언어 '%s' 는 아직 번역이 완료되지 않았습니다" % code)
		return
	language = code
	save_settings()
	settings_changed.emit()
	_apply_language()


## UI 가 코드로 생성되므로, 언어를 바꾸면 현재 화면을 다시 불러와야 반영된다.
## (게임을 종료할 필요는 없다 — 지금 보고 있는 화면이 즉시 새 언어로 다시 그려진다)
## ※ 게임 중(일시정지 메뉴)에 바꾸면 현재 레벨이 다시 시작되므로 주의.
func _apply_language() -> void:
	var t := get_tree()
	if t == null:
		return
	# 일시정지 상태에서 바꾸면 새 씬이 멈춘 채로 뜨므로 반드시 먼저 풀어준다
	t.paused = false
	t.reload_current_scene()


# ═══════════════════════════════════════
#  볼륨 설정 (UI 슬라이더에서 호출)
# ═══════════════════════════════════════

func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	_set_bus_volume(BUS_MASTER, master_volume)
	save_settings()
	settings_changed.emit()


func set_bgm_volume(v: float) -> void:
	bgm_volume = clampf(v, 0.0, 1.0)
	_set_bus_volume(BUS_BGM, bgm_volume)
	save_settings()
	settings_changed.emit()


func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	_set_bus_volume(BUS_SFX, sfx_volume)
	save_settings()
	settings_changed.emit()


## BGM 전체 On/Off. 끄면 BGM 버스를 mute 하여 모든 음악 재생 차단.
func set_music_enabled(b: bool) -> void:
	music_enabled = b
	_apply_music_enabled()
	save_settings()
	settings_changed.emit()


func _apply_music_enabled() -> void:
	var idx: int = AudioServer.get_bus_index(BUS_BGM)
	if idx >= 0:
		AudioServer.set_bus_mute(idx, not music_enabled)


## 전부 기본값으로
func reset_to_defaults() -> void:
	var lang_before: String = language
	language = "ko"
	master_volume = 0.8
	bgm_volume = 0.8
	sfx_volume = 0.8
	music_enabled = true
	apply_audio()
	_apply_music_enabled()
	save_settings()
	settings_changed.emit()
	# 언어가 실제로 바뀐 경우에만 화면을 다시 불러온다 (불필요한 재시작 방지)
	if lang_before != language:
		_apply_language()


# ═══════════════════════════════════════
#  저장 / 불러오기 (user://settings.cfg)
# ═══════════════════════════════════════

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("general", "language", language)
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "bgm", bgm_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("audio", "music_enabled", music_enabled)
	var err: int = cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("[Settings] 설정 저장 실패 (code %d)" % err)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		# 첫 실행 — 기본값으로 파일을 만든다
		save_settings()
		return
	language = str(cfg.get_value("general", "language", "ko"))
	master_volume = float(cfg.get_value("audio", "master", 0.8))
	bgm_volume = float(cfg.get_value("audio", "bgm", 0.8))
	sfx_volume = float(cfg.get_value("audio", "sfx", 0.8))
	music_enabled = bool(cfg.get_value("audio", "music_enabled", true))


## 설정 파일 절대 경로 (디버그용)
func get_config_path() -> String:
	return ProjectSettings.globalize_path(CONFIG_PATH)
