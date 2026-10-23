# Mr. Driller 2 / G 싱크로 연사(Drill (Auto))와 IRQ10 입력 주기

Namco System 10(NS10) MiSTer 코어에서 Mr. Driller 2 / Mr. Driller G용 "싱크로 연사"를 구현한 기록이다.
게임이 입력을 받는 구조, IRQ10 주기가 왜 중요한지, 어떻게 측정하고 고쳤는지, 어떻게 재현하는지를 담았다.
다른 개발자나 AI가 이 문서만 보고 같은 결과를 재현하거나 다른 에뮬레이터/코어에 옮길 수 있게 쓰는 것이 목표다.

관련 커밋: `e147f68`(Drill (Auto) 25/s), `f94157c`(IRQ10 2xVBlank 기본값).
작업 일지: `docs/fixes-2026-10-23.md`.

> **2026-10-24 갱신:** Drill (Auto) 알고리즘을 "IN1 읽기 2번마다 반전"(6.1)에서 **착지 동기 연사**로 바꿨다.
> 게임은 착지한 첫 프레임의 새 누름(에지)만 받으므로 고정 30/s 패턴은 낙하 프레임 수가 홀수일 때마다 1프레임을 잃었다.
> 새 `ns10_autofire.sv`는 메인 RAM 버스를 엿봐서 플레이어 상태(낙하/쿨다운)와 게임 패드 값을 보고 판정 가능한 첫 프레임에
> 바로 누르고, Driller 세트의 IRQ10은 5/8, 7/8 프레임으로 옮겼다. 원인, 주소, 구현, 검증은 `docs/fixes-2026-10-24.md`.
> 아래 6.1 이하 연사 설명은 이전 방식의 기록이다.

---

## 1. 요약

- 실기 싱크로 연사기는 vsync마다 버튼을 켬/끔으로 바꾼다. 게임이 매 프레임 입력을 받으면 정확히 30회/초가 된다.
- Driller 2 / G는 IN1 입력을 **IRQ10 인터럽트**에서 읽는다. 그리고 **두 번 중 한 번만 저장**한다(게임 롬 코드).
  따라서 **게임이 입력을 받는 속도 = IRQ10 주기 / 2**다.
- MAME는 IRQ10을 **100 Hz**로 낸다. 근거 없는 임시값이다(소스에 TODO 주석). 그래서 게임은 50 Hz로 입력을 받고,
  60 fps 화면에서 초당 약 10프레임은 새 입력이 없다. 연사가 "가끔 1프레임 비는" 25회/초가 된다.
- IRQ10을 **VBlank의 2배(프레임당 2회, 119.88 Hz)** 로 내면 게임이 **매 프레임 정확히 한 번** 입력을 저장한다.
  그러면 연사가 매 프레임 반전하는 **29.97회/초**가 된다. 사용자의 실기(Driller G) 경험, 실기 연사 영상과 맞았다.
- 코어 기본값은 2xVBlank다(릴리스 고정). 디버그 빌드에만 OSD `IRQ10 (Input)`(2xVBlank / 100Hz) 선택이 있다.
- **실기 IRQ10의 실제 주기는 측정되지 않았다.** 2xVBlank는 롬 정황, 실기 체감, 영상 비교로 고른 값이다.

---

## 2. NS10 입력 하드웨어 (게임이 보는 것)

| 주소 | 내용 |
|---|---|
| `0x1FBA0004` | IN1 하위 16비트, active low. P1: bit 0-3 방향, **bit 4 = Button1 (Drill)**, bit 5,6 버튼, bit 7 Start |
| `0x1FBA0006` | IN1 상위 16비트 |
| `0x1FBA001A` | 인터럽트 상태. **bit 3 = I/O 인터럽트(IRQ10)** |
| `0x1FBA0012`-`0x1FBA0018` | 인터럽트 해제. 쓰기 주소 `(a-0x12)/2` = 해제할 비트. IRQ10은 `0x1FBA0018` |

- IRQ10은 PS1 CPU의 외부 인터럽트 입력(I_STAT bit 10, PS1에서는 라이트건 핀)이다. NS10에서는 보드 로직이 구동한다.
- GPU VBLANK 인터럽트(IRQ0, 59.94 Hz)와는 **별개**다. VBLANK 주기로 IRQ10 주기를 알 수는 없다.
- 이 게임들은 PS1 컨트롤러 포트(SIO)를 쓰지 않는다. 그래서 PS1 본체의 "프레임마다 패드 읽기"는 해당하지 않는다.
- 주의: IN1은 `0x1FBA0004`다. `0x1FA00004`가 아니다(초기에 잘못 잡았던 주소).

코어 구현: `rtl/ns10/ns10_io.sv`(EXP3 영역, `exp3_addr[20:1] == 20'hD0002`가 IN1 하위 읽기).

---

## 3. 게임 롬이 입력을 처리하는 방식

MAME 0.289에서 RAM을 덤프하고 capstone으로 디스어셈블해 확인했다. 두 게임은 같은 라이브러리를 쓴다.

| | mrdrilr2j (Driller 2) | mrdrilrg (Driller G) |
|---|---|---|
| 인터럽트 분배기 (`0x1FBA001A` 읽기) | `0x8016BB64` | `0x8029654C` |
| 2단계 함수 (분배기가 호출) | `0x8016DF0C` | `0x80297DF8` 부근에서 입력 함수 호출 |
| IN1 읽기 함수 | `0x8016CEB4` | `0x80296C08` |
| IRQ10 호출 카운터 (인자로 전달) | `0x802CE100` | (gp 상대) |
| 패드 구조체 | `0x802CE158` (+0x20 P1 현재값, +0x22 누적 OR) | `0x803C9AD0` |
| 게임이 프레임마다 복사하는 패드 변수 | `0x8023F94E` (Drill = `0x0200`) | (미확인, 측정에는 `0x803C9AF0` 사용) |

처리 흐름 (Driller 2 주소 기준):

1. IRQ10 → 분배기 `0x8016BB64`가 `0x1FBA001A` bit 3을 보고 `0x8016DF0C(count)`를 호출한다.
   이어서 `0x1FBA0018`에 써서 해제하고 count를 1 올린다.
2. `0x8016DF0C`는 `count & 1`로 두 단계를 번갈아 한다.
   - **짝수 회**: 입력 함수 `0x8016CEB4(count)`가 IN1을 읽고 **저장한다**. 이어서 PS1 패드 라이브러리 형식 버퍼
     (상태 0xFF = 패드 없음 등)를 정리하고 출력(램프 등)을 처리한다.
   - **홀수 회**: 입력 함수는 IN1을 **읽기만 하고 버린다**(`a0&1` → `0x8016D208`로 분기). 출력 자동 꺼짐
     카운트다운(64틱, `0x802D63EC`)만 한다.
3. 메인 루프는 **매 프레임 VBLANK 직후(GP1(05) 쓰기 전)** 마지막 저장값을 게임용 변수(`0x8023F94E`)로 복사한다.

확인 실험 (MAME, 1샘플 펄스 스윕):
- 10 ms짜리 1샘플 Drill 펄스를 여러 위상에 넣었다. 한쪽 순번 43개는 전부 무시됐고, 다른 쪽 42개는 위상과
  관계없이 전부 인식됐다.
- ISR 단계 측정에서도 두 게임 모두 100번 중 정확히 50번만 저장했다.

IRQ10의 다른 용도 (주기를 바꿀 때의 영향 범위):
- 게임 속도, 시간 표시, 사운드에는 IRQ10을 쓰지 않는다.
- 통신 상태 머신 타임아웃: 카운터 `0x802D63E4`가 0x79(121) 미만이면 대기, 이상이면 타임아웃 (`0x80174634`).
  120 Hz면 1.0초, 100 Hz면 1.2초다.
- 출력 자동 꺼짐 64틱(홀수 단계에서만 감소).
- 디버그 출력(`0x8016BE08`).

---

## 4. IRQ10 주기에 따라 무엇이 달라지나

게임이 입력을 저장하는 속도는 항상 IRQ10 주기의 절반이다.

| IRQ10 | 입력 저장 | 프레임 대비 | 실기 vsync 연사기 (매 프레임 반전) | 코어 Drill (Auto) (IN1 읽기 2번마다 반전) |
|---|---|---|---|---|
| 2xVBlank (119.88 Hz) | 59.94 Hz | 매 프레임 1번 | 30/s, 정확 | **30/s, 매 프레임 반전** |
| 100 Hz (MAME) | 50 Hz | 초당 약 10프레임 새 입력 없음 | 약 20/s, 불규칙 (앨리어싱) | 25/s, 가끔 1프레임 반복 |
| 1xVBlank (59.94 Hz) | 29.97 Hz | 2프레임에 1번 | **연사 안 됨** (늘 같은 값이 저장됨) | 15/s (2프레임 켬, 2프레임 끔) |

- 사용자는 실기 Driller G에서 vsync 연사기가 정상적으로 연사되는 것을 경험했다. 그래서 1xVBlank는 아니다.
- 100 Hz였다면 그 연사기는 약 20/s로 불규칙했을 것이다(MAME 측정 19.98/s).
- 일반 입력도 영향을 받는다. 100 Hz에서는 17 ms(1프레임 남짓) 탭이 40번 중 7번 누락됐고, 2xVBlank에서는 0번이었다
  (시뮬레이션).

---

## 5. 실기 IRQ10 주기에 대한 증거

확정된 것은 없다. 아래는 판단 근거다.

1. **MAME의 100 Hz는 임시값이다.**
   - `src/mame/namco/namcos10.cpp`: `TIMER(config, "io_timer").configure_periodic(..., attotime::from_hz(100));`
   - 2023년 리팩터 커밋 `ec6b3d2b5542`에서 들어왔고, 바로 위에 다음 주석이 있다.
     `TODO: Trace main PCB to see where JAMMA I/O goes and/or how int10 can be triggered (SM10MA3?)`
   - 웹에서도 System 10 IRQ10 하드웨어 자료를 찾지 못했다.
2. **롬 정황 (120 Hz 쪽, 증명은 아님)**
   - 짝수 단계에서 PS1 패드 라이브러리 형식 버퍼를 정리한다. PS1에서는 이 버퍼가 프레임마다 갱신되므로,
     IRQ10/2 = 프레임이 되도록 설계했다고 보는 것이 자연스럽다.
   - 통신 타임아웃이 "120틱 초과"다. 120 Hz에서 정확히 1초다.
3. **사용자 실기 체감**: 25/s(100 Hz)는 "가끔 1프레임이 비는" 느낌이었다. 2xVBlank는 "확실히 더 일관되고 부드럽다".
4. **실기 연사 영상(유튜브) 비교**: 2xVBlank 쪽이 훨씬 가깝다(사용자 판단).

확정하려면 실기 NS10 보드에서 IRQ10 신호(또는 `0x1FBA001A` bit 3 발생 간격)를 측정해야 한다.

---

## 6. 구현

### 6.1 Drill (Auto) 키 — `rtl/ns10/ns10_autofire.sv`

요구사항 (사용자 결정):
- 키매핑 항목 **Drill (Auto)** 를 추가한다. Driller MRA에서만 이름이 붙는다. OSD 설정은 없고 기본 매핑도 없다.
- 누르고 있는 동안만 연사하고, 떼면 즉시 멈춘다. 일반 Drill과 OR한다.
- OSD가 열려 있으면 연사하지 않는다.

알고리즘:
- **CPU의 IN1 하위 읽기(상승 에지)를 세서 2번마다 반전**한다. 시간이나 vsync를 기준으로 하지 않는다.
  - 게임은 IRQ10 두 번 중 한 번(어느 쪽인지는 부팅 때 결정)만 저장한다. 2번마다 반전하면 어느 쪽을 저장하든
    저장되는 값이 매번 직전과 반대가 된다.
  - 반전은 그 읽기가 값을 래치한 클럭에 일어난다. 그래서 읽힌 값은 반전 전 값이다(`ns10_io`가 `rd` 클럭에 래치).
- 누르는 순간 바로 켬(첫 켬은 읽기 2번 동안 유지되므로 첫 발이 빠지지 않는다).
- 떼기, OSD 열림, 리셋이면 즉시 끔. OSD를 닫았을 때 계속 누르고 있으면 켬부터 다시 시작한다.
- P1/P2 독립.
- 게임의 실제 입력 읽기에 맞추므로 IRQ10 주기, CPU Turbo, 처리 지연과 무관하게 "저장 샘플마다 반전"이 된다.
  그래서 IRQ10을 2xVBlank로 바꿨을 때 이 모듈은 수정 없이 30/s가 되었다.

연결 (`NAMCOS10.sv`):

```systemverilog
// J1 11번째 버튼 "Button1 (Auto)" = joy bit 14 (맨 끝에 추가해서 기존 매핑 비트는 그대로)
ns10_autofire ns10_autofire
(
	.clk(clk_1x), .reset(cpu_reset),
	.in_rd(exp3_read && exp3_addr[20:1] == 20'hD0002),   // 0x1FBA0004
	.osd(OSD_STATUS),
	.btn({joy2[14], joy[14]}),
	.fire(af_fire)
);
// IN1: P1 bit 4 = joy[4] | af_fire[0], P2 bit 12 = joy2[4] | af_fire[1]
```

MRA: `tools/mkmra.py`가 `mrdrilr*` MRA에만 `<buttons>` 끝에 `Drill (Auto)`를 붙인다.
다른 게임 MRA는 버튼 이름이 10개라서 11번째 버튼이 보이지 않는다.

### 6.2 IRQ10 2xVBlank — `rtl/ns10/ns10_io.sv`

```systemverilog
localparam integer TIMER_PERIOD = 338688;            // 33868800 / 100 (MAME 100 Hz)
localparam integer FRAME_NOM    = 565050;            // 33868800 / 59.94 (리셋 직후 초기값)
reg        vbl_1;
reg [19:0] fcnt, fper;                               // VBLANK 이후 클럭 수, 직전 프레임 길이
wire       vbl_rise = vblank & ~vbl_1;
wire       vbl_tick = (fcnt == fper/4) || (fcnt == fper/4 + fper/2);

	vbl_1 <= vblank;
	if (vbl_rise) begin fcnt <= 0; fper <= fcnt; end
	else if (~&fcnt) fcnt <= fcnt + 1'd1;           // 포화 (VBLANK가 멈추면 IRQ도 멈춤)

	if (irq10_vbl ? (vbl_tick && !vbl_rise) : (tcnt == TIMER_PERIOD - 1)) begin
		intr[3] <= 1;                               // 0x1FBA001A bit 3
		irq10   <= 1;                               // PS1 IRQ10 펄스
	end
```

설계 이유:
- **VBLANK에 고정**: 따로 도는 119.88 Hz 타이머는 실제 프레임 주기(인터레이스 263/262라인 등)와 조금씩
  어긋나서 가끔 한 프레임에 저장이 0번이나 2번이 된다. VBLANK에서 매번 다시 맞추면 항상 프레임당 정확히 2번이다.
- **1/4, 3/4 지점**: 게임은 VBLANK 직후 패드를 복사한다. IRQ를 VBLANK와 같은 시점에 내면 복사와 저장의
  순서가 흔들릴 수 있어서, 복사 시점에서 떨어진 위치를 골랐다.
- **직전 프레임 길이(`fper`)를 측정해서 쓴다**: 비디오 모드가 바뀌어도 맞는다.
- 어느 쪽(1/4 또는 3/4)이 "저장 단계"가 될지는 게임 카운터의 홀짝으로 부팅 때 정해진다. 입력 지연 차이는 최대 반 프레임이다.

신호 연결:
- `rtl/psx_top.vhd`: `vblank_irq <= irq_VBLANK;`. irq.vhd의 IRQ0 입력과 같은 clk1x 신호다.
- `rtl/psx_mister.vhd`: 포트 `vblank_irq`를 통과시킨다.
- `NAMCOS10.sv`: `.irq10_vbl(!DEBUG || !status[87]), .vblank(vblank_irq)`.
  - 릴리스 리비전: 항상 2xVBlank. OSD 항목 없음.
  - 디버그 리비전: `` `ifdef NS10_DEBUG `` 안의 `"O[87],IRQ10 (Input),2xVBlank,100Hz;"`(첫 항목이 기본값).

### 6.3 다른 에뮬레이터/코어에 옮길 때 체크리스트

1. IRQ10(I/O 인터럽트) 발생원을 VBLANK 기준 프레임당 2회로 바꾼다(MAME 예: §7.2 패치).
   인터럽트 상태 bit 3 세트와 IRQ10 펄스를 같이 낸다.
2. 연사는 시간 기반이 아니라 **게임의 IN1 읽기 횟수 기반**(2번마다 반전)으로 만든다.
   2xVBlank라면 vsync마다 반전해도 30/s가 되지만, 읽기 기반이면 IRQ10 주기와 관계없이 항상 최적이다.
3. 검증은 게임 변수로 한다: 매 프레임 GP1(05) 쓰기 시점에 `0x8023F94E`(Driller 2)의 `0x0200` 비트가
   매번 바뀌는지 본다.

---

## 7. 실험과 재현 방법

### 7.1 MAME Lua 측정 도구 — `tools/mame/tap_input.lua`

IN1 읽기에 탭을 걸어 입력을 주입하거나 연사 모델을 넣는다. 매 GP1(05) 쓰기마다 게임 패드 변수를 읽어
"게임이 본 누름 수"와 "직전 값을 반복한 프레임 수"를 출력한다.

| 환경변수 | 의미 |
|---|---|
| `NS10_INLOG` | 로그 경로 |
| `NS10_T1` | 종료 시각(초) |
| `NS10_INJ` | `"t0,t1,hexmask;..."` 구간 동안 IN1 비트를 누름(active low) |
| `NS10_AF` | `"t0,t1"` 구간 동안 P1 Drill (Auto) |
| `NS10_AFMODE` | `read`: IN1 읽기 2번마다 반전(코어와 같음), `vbl`: GP1(05)마다 반전(vsync 연사기) |
| `NS10_PAD` | 매 프레임 읽을 게임 변수(hex). Driller 2 `8023F94E`, Driller G `803C9AF0` |
| `NS10_SNAP` | `"t,t,..."` 스냅샷 시각. 같은 시각을 반복하면 연속 프레임을 캡처한다 |

Driller 2 플레이 중 측정 예 (코인 25 s, 시작 27 s, 메뉴/스테이지 선택 29~37 s, 연사 58~75 s):

```sh
NS10_INLOG=af.log NS10_T1=75 NS10_AF="58,75" NS10_AFMODE=read NS10_PAD=8023F94E \
NS10_INJ="25,25.3,20000000;27,27.3,80;29,29.3,10;31,31.3,10;33,33.3,10;35,35.3,10;37,37.3,10" \
./namcos10.exe mrdrilr2j -rompath "<roms>" -inipath <ini 폴더(ui.ini: skip_warnings 1)> \
  -nvram_directory <빈 폴더> -nothrottle -video none -sound none -skip_gameinfo \
  -autoboot_script tools/mame/tap_input.lua
# 출력: mode read: N presses seen by the game in F frames (r/s), K frames repeated the last value
```

테스트 모드 SWITCH TEST 진입: `NS10_INJ="8,40,40000000;30,30.2,4;32,32.2,10"`
(TEST 스위치 bit 30, 아래 bit 2, Drill bit 4로 진입. Driller 2는 첫 부팅 초기화 후 약 30 s, G는 약 15 s.)

MAME Lua 주의:
- psxcpu는 RAM 탭이 동작하지 않는다. RAM 값은 I/O 탭 콜백 안에서 `read_u16`로 읽는다.
- 상태는 전역 변수에 둔다(autoboot 청크의 local은 GC되어 탭이 사라진다).
- 경고 화면에서 멈추지 않게 `-inipath`로 `skip_warnings 1`인 ui.ini를 준다.

### 7.2 MAME에서 2xVBlank 재현 — `tools/mame/irq10_vbl2.py`

MAME **복사본**의 `namcos10.cpp`를 패치한다.
- 환경변수 `NS10_IRQ10=vbl2`가 있으면 화면 VBLANK 콜백에서 직전 프레임 길이를 재고, 1/4와 3/4 지점에 타이머로
  IRQ10을 낸다(`m_int |= 8; m_io_update_interrupt(1);`). 이때 원래 100 Hz 타이머 콜백은 무시한다.
- 환경변수가 없으면 원래 MAME와 같다.

```sh
python tools/mame/irq10_vbl2.py <mame 복사본>/src/mame/namco/namcos10.cpp
# MSYS2 UCRT64, OS=Windows_NT 필요
OS=Windows_NT MSYSTEM=UCRT64 bash -lc 'export OS=Windows_NT MINGW64=/ucrt64; cd <mame 복사본> && make SUBTARGET=namcos10 SOURCES=src/mame/namco/namcos10.cpp -j16'
NS10_IRQ10=vbl2 ./namcos10.exe mrdrilr2j ...
```

이 작업의 복사본 빌드는 `D:\scratch_mame_irq`에 보관되어 있다(사용자 요청, 보완 자료). 사용자 MAME 폴더는 수정하지 않았다.

### 7.3 ModelSim 시뮬레이션

| 스크립트 | 내용 |
|---|---|
| `sim/ns10/run_autofire.sh [seed]` (`tb_autofire.sv`) | 연사 모듈 단독 검증. 10 ms 읽기 ±0.3 ms, 한 번 걸러 저장, 59.94 Hz 프레임 소비. 25/s, 반전, 첫 발, 떼기/OSD/리셋 즉시 끔, P1/P2 독립, 랜덤 탭 300회 |
| `sim/ns10/run_irq10.sh [seed]` (`tb_irq10.sv`) | 실제 `ns10_io` + `ns10_autofire`, 33.8688 MHz. VBLANK 263/262라인 필드. 게임 모델(IRQ10 후 2~52 µs 지연 읽기, 한 번 걸러 저장, 해제 쓰기, VBLANK 후 0.1~3 ms 패드 복사). 검사 항목: 2xVBlank IRQ 위치(1/4, 3/4 ±300 ns), 초당 횟수, 30/s, 반복 프레임 0, 17 ms 탭 누락 0, 100 Hz 주기, 모드 전환 |

둘 다 시뮬 시간 제한, 무입력/무IRQ 워치독, 실행 15분 제한(`timeout 900`)을 둔다. `run_irq10.sh`는 약 10분 걸린다.

---

## 8. 결과

### 8.1 시뮬레이션 (`run_irq10.sh` 시드 1, PASS)

| 항목 | 2xVBlank | 100 Hz |
|---|---|---|
| IRQ10 | 119회/초, 프레임 1/4·3/4 위치 | 99회/초, 10 ms 주기 |
| Drill (Auto) | 29.97/s, 반복 프레임 0 | 25.11/s, 3초에 반복 30프레임 |
| 17 ms 탭 누락 | 0/40 | 7/40 |

### 8.2 MAME, 실제 게임 코드

| 게임 / 측정 변수 | 100 Hz | 2xVBlank |
|---|---|---|
| mrdrilr2j / `0x8023F94E` (플레이 중) | 25.01/s, 978프레임 중 반복 163 | 29.91/s, 반복 1 |
| mrdrilrg / `0x803C9AF0` (메뉴~시작) | 24.97/s, 929프레임 중 반복 156 | 29.91/s, 반복 1 |
| (참고) vsync 연사기 모델 `AFMODE=vbl`, mrdrilr2j, 100 Hz | 19.98/s, 불규칙 | — |
| (참고) IN1 읽기마다 반전, 100 Hz | 0 (저장값이 늘 같음) | — |

- 2xVBlank의 반복 1프레임은 게임이 200 ms 동안 GP1(05)를 쓰지 않은 장면 전환 구간이다. 연사와 무관하다.
- 두 모드에서 메뉴, 스테이지/캐릭터 선택, 플레이, 테스트 모드 화면이 같았다.
  JVS CABINET OPTIONS 비활성도 같다. 즉 통신 타임아웃 경로에 차이가 없다.
- 같은 시간 동안 2xVBlank 쪽이 더 깊이 팠다(26 m → 33 m).

### 8.3 다른 게임 (기본값을 바꾸기 전 확인)

- Gamshara, Star Trigon도 IN1을 IRQ10마다 읽는다(초당 100회 → 약 120회).
- 70초 동안 두 모드의 화면이 같았다: Gamshara 타이틀/랭킹/데모/플레이, Star Trigon 타이틀/소개/플레이어·모드 선택.

### 8.4 실기 (사용자, MiSTer)

- 100 Hz(25/s): 실기 연사기 느낌과 비슷하지만 빠르게 파지다가 중간중간 1프레임이 비어 살짝 느려진다.
- 2xVBlank(30/s): 확실히 더 일관되고 부드럽다. 실기 연사 영상과 훨씬 가깝다.
- 게임 플레이 중 동작은 Driller 2 / G 모두 같다.

---

## 9. 실기에서 쉽게 비교하는 방법: SWITCH TEST

DIP의 Test 스위치를 켜고 SWITCH TEST에 들어간다. Drill (Auto)를 누르면 상단 `1P:0000` / `1P:0200`이 바뀐다.

| | 100 Hz | 2xVBlank |
|---|---|---|
| Driller 2 (MiSTer 실기 화면) | 빠르게 깜빡임 | **계속 눌린 것처럼 보임** |
| Driller G (MiSTer 실기 화면) | 빠르게 깜빡임 | 빠르게 깜빡임 |
| 두 게임 (MAME 연속 프레임 캡처) | 불규칙 (같은 값이 2프레임 이어짐) | **매 프레임 정확히 번갈아** |

해석 (Driller 2):
- 테스트 화면은 640x480 인터레이스, 단일 버퍼(GP1(05) = `05000000`)다.
- PS1 GPU는 인터레이스 그리기에서 **표시 중인 필드의 라인을 건너뛴다.** 프레임마다 정확히 반전하면 한쪽
  필드에는 항상 0200, 다른 쪽에는 항상 0000만 그려진다. 두 필드가 겹쳐 고정된 그림("계속 눌림")으로 보인다.
- 100 Hz는 반전 위상이 프레임과 어긋나서 깜빡임이 보인다.
- 즉 "계속 눌린 것처럼 보임"이 오히려 매 프레임 정확히 반전한다는 신호다. 실기에 정확한 30 Hz 연사를
  넣어도 같은 모습일 것이다.
- MAME의 GPU는 모든 라인을 그리므로 이 현상을 보여주지 않는다.
- Driller G가 두 설정 모두 깜빡이는 이유는 확인하지 않았다(테스트 화면 그리기 방식 차이로 추정).
  MAME에서는 G도 2xVBlank에서 매 프레임 정확히 번갈아 나온다.

---

## 10. 알려진 한계와 열린 질문

- **실기 IRQ10 주기는 미확인이다.** 실기 측정 결과가 나오면 이 문서와 `ns10_io.sv`를 갱신해야 한다.
- **처리 지연 프레임**: 게임이 프레임을 놓치면 그 사이 입력이 두 번 저장되어, 그 순간에는 연사 한 번이 빠질 수 있다.
  구조상 실기도 같을 것이다.
- **입력 지연 위상**: 1/4 또는 3/4 중 어느 쪽이 저장 단계인지는 부팅 때 정해진다. 차이는 최대 반 프레임이다.
- **일시정지/VBLANK 정지**: VBLANK가 멈추면 `fcnt`가 포화되어 IRQ10도 멈춘다. 100 Hz 모드에서는 계속 난다.
- **디버그 OSD 저장값**: 순서를 바꿨기 때문에, 예전 디버그 빌드에서 2xVBlank로 저장한 값은 이후 디버그 빌드에서 100Hz로 읽힌다.
- **MiSTer 내장 연사와 함께 쓰지 말 것**: 같은 버튼에 켜면 서로 간섭한다.
- **기존 키매핑**: SYSTEM10 키매핑을 저장한 사용자는 Drill (Auto)를 한 번 새로 매핑해야 한다.
- **MAME autofire 플러그인**: 이 게임에서 정확하지 않았다(사용자). 연사 체감의 기준은 실기다.

---

## 11. 현재 상태 (2026-10-23)

- `main`에 커밋: `e147f68`(Drill (Auto)), `f94157c`(2xVBlank 기본값, 시뮬/MAME 도구, 문서).
- 디버그 빌드 `Arcade-SYSTEM10_20261023.rbf`로 실기 A/B 확인 완료(사용자).
- 릴리스 빌드는 아직 확정되지 않았다.
  - SEED 4 빌드에서 HDMI 스케일러(ascal) setup -0.048 ns가 나왔다.
  - 사용자가 릴리스 빌드의 OSD 메뉴 표시 문제(하위 메뉴가 펼쳐져 나옴)를 보고해서 작업을 중단했다.

---

## 12. 파일 목록

| 파일 | 역할 |
|---|---|
| `rtl/ns10/ns10_autofire.sv` | Drill (Auto): 착지 동기 연사 (2026-10-24, 이전: IN1 읽기 2번마다 반전) |
| `rtl/ns10/ns10_io.sv` | IN1 / 인터럽트 레지스터, IRQ10 발생 (100 Hz / 2xVBlank, Driller는 5/8, 7/8) |
| `rtl/psx_top.vhd`, `rtl/psx_mister.vhd` | GPU VBLANK 인터럽트(`vblank_irq`)를 밖으로 연결 |
| `NAMCOS10.sv` | J1 11번째 버튼, 연사 OR, IRQ10 모드 선택(디버그 OSD `O[87]`) |
| `tools/mkmra.py`, `releases/_Arcade/*.mra` | Driller MRA에만 `Drill (Auto)` 버튼 이름 |
| `sim/ns10/tb_autofire.sv`, `run_autofire.sh` | 연사 모듈 + IRQ10, RAM 버스 위 Driller 게임 모델 시뮬 |
| `sim/ns10/tb_irq10.sv`, `run_irq10.sh` | IRQ10 위상 / 주기 / 탭 시뮬 |
| `tools/mame/tap_input.lua` | MAME 입력 주입 / 게임이 본 연사 측정 |
| `tools/mame/irq10_vbl2.py` | MAME 복사본에 2xVBlank IRQ10 패치 |
| `docs/fixes-2026-10-23.md` | 작업 일지 (요구사항, 결정 과정, 빌드 기록) |
