## MusicDirector — 동적 배경음악 컨트롤러 (Autoload)
##
## GameState.alert_level(0..1) 을 긴장도로 삼아 세 겹 음악을 crossfade 한다:
##   calm = sector.ogg  (탐색 / 미발각)
##   mid  = pulse.ogg   (적 접근 / 임계 경로)
##   high = urgent.ogg  (추격 / ALERT)
## 타이틀 화면에서는 title.ogg 를 루프 재생하고, 게임 종료 시 transmission.ogg 스팅을 한 번 재생한다.
##
## 모든 플레이어는 Settings 의 "BGM" 버스를 사용하므로, 설정의 BGM 볼륨 슬라이더와
## BGM On/Off 토글이 즉시 반영된다. (별도 버스 생성 불필요)
extends Node

const PATH_CALM  := "res://assets/audio/ogg/sector.ogg"
const PATH_MID   := "res://assets/audio/ogg/pulse.ogg"
const PATH_HIGH  := "res://assets/audio/ogg/urgent.ogg"
const PATH_TITLE := "res://assets/audio/ogg/title.ogg"
const PATH_END   := "res://assets/audio/ogg/transmission.ogg"

## crossfade 속도 (dB/초). 클수록 빠르게 전환.
const FADE_DB_PER_SEC := 30.0

var p_calm: AudioStreamPlayer
var p_mid: AudioStreamPlayer
var p_high: AudioStreamPlayer
var p_title: AudioStreamPlayer
var p_sting: AudioStreamPlayer

var _title_active: bool = false


func _ready() -> void:
	# 일시정지 중에도 BGM 이 계속 흐르도록 (지도 M / ESC 메뉴 / 설정 창).
	# AudioStreamPlayer 는 부모의 process_mode 를 상속하는데, 일시정지 상태에서는
	# PAUSABLE 노드의 오디오 재생이 멈춘다. 여기서 ALWAYS 로 두면 아래에 붙는
	# 3겹 레이어 + 타이틀 + 스팅 플레이어가 모두 일시정지에 영향받지 않는다.
	# (일시정지 중에는 GameState.alert_level 이 갱신되지 않으므로 음악도 그대로 유지된다)
	process_mode = Node.PROCESS_MODE_ALWAYS

	if AudioServer.get_bus_index("BGM") == -1:
		push_warning("[MusicDirector] 'BGM' 버스를 찾지 못했습니다. Settings.gd 를 확인하세요.")

	# 게임플레이 3겹 레이어 (무한 루프)
	p_calm  = _make_layer(PATH_CALM,  true)
	p_mid   = _make_layer(PATH_MID,   true)
	p_high  = _make_layer(PATH_HIGH,  true)
	# 타이틀 루프
	p_title = _make_layer(PATH_TITLE, true)
	# 종료 스팅 (한 번만)
	p_sting = AudioStreamPlayer.new()
	p_sting.bus = "BGM"
	p_sting.stream = load(PATH_END)
	if p_sting.stream != null:
		p_sting.stream.loop = false
	p_sting.volume_db = 0.0
	add_child(p_sting)

	# 부팅 시점은 타이틀 화면 → 타이틀 재생
	if not GameState.is_playing:
		_start_title()

	GameState.game_finished.connect(_on_game_finished)


func _process(delta: float) -> void:
	# 설정에서 음악 끄기 → BGM 버스가 mute 되어 있으므로 그냥 통과
	if not Settings.music_enabled:
		return

	if GameState.is_playing:
		if _title_active:
			p_title.stop()
			p_title.volume_db = -80.0
			_title_active = false
		_update_layers(delta)
	else:
		# 게임 밖(타이틀/메뉴): 게임플레이 레이어 침묵, 타이틀만
		_silence(p_calm, delta)
		_silence(p_mid, delta)
		_silence(p_high, delta)
		_ensure_title()


# ── 게임플레이: alert_level → 3겹 crossfade ──
func _update_layers(delta: float) -> void:
	var t: float = GameState.alert_level
	if GameState.current_room_safe:
		t = 0.0   # 안전 구역에선 강제로 침묵 회귀

	var w_calm: float = clampf(1.0 - t * 1.6, 0.0, 1.0)   # t=0→1, t≈0.62→0
	var w_mid:  float = clampf(t * 2.0 - 0.10, 0.0, 1.0)  # t≈0.05→시작, t≈0.55→1
	var w_high: float = clampf((t - 0.50) * 2.0, 0.0, 1.0) # t≈0.50→시작, t=1→1

	_fade_to(p_calm, w_calm, delta)
	_fade_to(p_mid,  w_mid,  delta)
	_fade_to(p_high, w_high, delta)


func _fade_to(p: AudioStreamPlayer, w: float, delta: float) -> void:
	var target: float = -80.0 if w <= 0.001 else linear_to_db(w)
	p.volume_db = move_toward(p.volume_db, target, FADE_DB_PER_SEC * delta)


func _silence(p: AudioStreamPlayer, delta: float) -> void:
	p.volume_db = move_toward(p.volume_db, -80.0, FADE_DB_PER_SEC * delta)


# ── 타이틀 루프 관리 ──
func _ensure_title() -> void:
	if p_sting != null and p_sting.playing:
		return   # 종료 스팅 재생 중 → 타이틀 루프로 덮어쓰지 않음
	if not _title_active or not p_title.playing:
		_start_title()


func _start_title() -> void:
	p_title.volume_db = 0.0
	if not p_title.playing:
		p_title.play()
	_title_active = true


# ── 게임 종료 스팅 ──
func _on_game_finished(_won: bool) -> void:
	# 게임플레이 레이어 즉시 침묵
	p_calm.volume_db = -80.0
	p_mid.volume_db = -80.0
	p_high.volume_db = -80.0
	p_title.stop()
	_title_active = false
	# 스팅 한 번 재생 (루프 아님)
	if p_sting.stream != null:
		p_sting.play()


# ── 공통 레이어 생성 ──
func _make_layer(path: String, loop: bool) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "BGM"
	p.stream = load(path)
	if p.stream != null:
		p.stream.loop = loop
	p.volume_db = -80.0   # 시작은 침묵, _process 가 올림
	add_child(p)
	p.play()
	return p
