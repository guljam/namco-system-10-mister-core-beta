# Driller AI (Mr. Driller G) 인계 문서 — 2026-11-02 세션 끝

이 문서만 읽고 다음 세션(또는 다른 AI/개발자)이 바로 이어서 작업할 수 있도록 정리했다.
이전 버전(2026-10-30, "게임 전체 미리 계산" 구상)은 git 기록에 있다. 그 구상은 폐기됐고 지금은 실시간 AI가 동작한다.
자세한 원인/가설/해결 기록: `docs/fixes-2026-11-02.md` (세 부분: rtai 신규, 실시간 파이프라인 + GroovyMAME + 대전, MiSTer + 실기 수정).
게임 메모리 맵: `docs/drillerg-memory-map.md`, 점수 분석: `docs/drillerg-score-strategy.md`.

---

## 1. 사용자 목표 (2026-11-02 확정)

### 1-1. 지금까지 달성
- **실시간 AI가 MiSTer 실기에서 1000 m(아메리카)를 클리어** (사용자 확인 2026-11-02). 사용자 평가: "지능이 낮아도 클리어 + 이전 AI와 달리 실시간 플레이 = 큰 도약".
- GroovyMAME에서도 같은 코드로 동작(1P: AI가 플레이, 대전: AI가 2P).

### 1-2. 다음 목표 (사용자가 정한 순서)
1. **노미스 클리어**: 압사, 산소 부족 사망 없음.
2. **퍼펙트 에어 클리어**: 산소 캡슐 전부 먹고 죽지 않음.
3. **더 빠른 시간**에 클리어.
4. **최고 점수**.

### 1-3. 방향 (사용자 결정 2026-11-02)
- **GroovyMAME 쪽 AI를 먼저 완성**하고, 그 뒤 MiSTer로 이식한다(같은 C 코드).
- **가중치(신경망) 모델 + 자기 개선 학습**: 사용자의 플레이 데이터로 기반을 깔고, 시뮬레이터에서 수만 판 자기 대국으로 개선한다.
  - PC는 GPU 가속 등을 써도 된다. 입력: 블록 패턴, 캐릭터 특성, 산소 등 상황. 출력: 다음 행동.
  - MiSTer 생각 예산은 **0.5초 이내**까지 허용(맵이 움직이지 않을 때 더 생각해도 됨, 게임은 절대 멈추면 안 됨).
- **MiSTer에서도 사용자 플레이 기록을 남기고 싶다** (사용자 아이디어, 아직 구현 안 함, 5장 참고):
  코어 시작부터 기록 → OSD를 열어 NVRAM이 저장될 때 기록 파일도 자동 저장. 내용: 메모리 상태, 게임 안에서 몇 프레임에 어떤 입력을 눌렀는지.
- FPGA 남은 공간에 신경망 가속기 넣기 → **권하지 않음**(검토 결과, 6-3 참고). 사용자에게 설명함.

### 1-4. 절대 조건 / 사용자 규칙
- 게임이 생각 때문에 1프레임이라도 멈추면 안 된다(완전 실시간).
- 난수 조작 금지(유리한 맵 고르기 금지).
- MiSTer 빌드는 디버그만. 릴리스 빌드는 사용자 승인 후. 빌드 1회 ~20분, Quartus 두 개 동시 실행 금지.
- 커밋은 요청 시에만, 커밋 때 `docs/fixes-YYYY-MM-DD.md`에 원인/가설/해결. 푸시는 요청 시에만.
- MAME 테스트는 숨김 실행(`hidrun.exe`), 최대 12개 동시, 옵션 `-window -nomaximize -mouseprovider none -lightgunprovider none -joystickprovider none` 필수. 사용자가 보고 싶다고 할 때만 보이는 창.
- 시뮬레이션은 15분 제한 + 워치독.
- 한국어 사용자, 쉬운 설명.

---

## 2. 구조 한눈에

```
게임 RAM ──(GroovyMAME: vblank 콜백 / MiSTer: FPGA 미러 → DDR3)──> drgbridge.c (RAM → World)
   └─> agent.c (계획 제안 + 정밀 시뮬 검증 + 입력 재생, 워커 스레드) ──> 입력 5비트 ──> 게임
                  └─ psim.c (플레이어) + blocksim.c (블록) = 정밀 시뮬레이터
```

### 2-1. 파일 (tools/drgai/rtai, 순수 C, PC/ARM 공용)
| 파일 | 역할 |
|---|---|
| `agent.c/h` | AI 본체. 계획 제안(Dijkstra 경로 비용) → 정밀 시뮬로 검증 → 점수 → 최고 계획의 입력 재생. 파이프라인: L=12프레임 앞 상태에서 계획, 늦으면 기존 입력 유지, 예측이 크게 틀리면 L=4로 긴급 재계획. 튜닝 값은 환경변수 `RT_*` (`load_params()`). |
| `psim.c/h` | 플레이어 물리(걷기, 파기, 오르기, 낙하, 산소, 압사). `ps_dig_cell()` 공개. |
| `blocksim.c/h` | 블록 물리(지지, 흔들림, 낙하, 연결, 소멸). `Grid.cell` = 칸 크기(0=10240, 넓은 필드/대전 6144). |
| `drgbridge.c/h` | 게임 RAM → World. 모드 판별, 필드 폭, 대전 2P 위치, 입력 지연, 렉 프레임 건너뛰기, **걷기 속도/파기 타이머 실측**. GroovyMAME와 MiSTer가 같은 파일을 쓴다. |
| `drgaid.c` | MiSTer ARM 데몬. 미러 폴링 → 브리지 → 답 쓰기. |
| `game.c/h`, `run.c` | 독립 게임(맵 파일로 한 판 전체) = **시뮬레이션 테스트**와 앞으로의 **자기 대국 학습 환경**. |
| `wcheck.c` | 실제 프레임 덤프(w<f>.bin)와 시뮬 비교(한 프레임씩, `DIGT=15` 환경변수로 타이머 덮어쓰기). |
| `diag/` | 이번 세션 진단 도구(아래 7장). |
| `ref.c`, `difftest.c`, `bench_sim.c` | 예전 planner와의 정확도 비교, 속도 측정. |

### 2-2. GroovyMAME (D:/github_clones/GroovyMAME, 브랜치 `drgai-rt`)
- `src/mame/namco/drgai/` = rtai 파일 **복사본**(수정은 rtai에서 하고 복사). `ns10_drgai.cpp/.h` = vblank 콜백, `namcos10.cpp` 연결.
- Machine Configuration "AI Driller" (기본 On).
- 빌드: `cp agent.c agent.h drgbridge.c drgbridge.h psim.c psim.h blocksim.c blocksim.h <GroovyMAME>/src/mame/namco/drgai/` 후
  `make SUBTARGET=namcos10 SOURCES=src/mame/namco/namcos10.cpp,src/mame/namco/namcos12.cpp,src/mame/namco/ns10_drgai.cpp -j8` (MSYS2 UCRT64, `OS=Windows_NT`).
- 마지막 커밋 04b09c0fad7.

### 2-3. MiSTer
- FPGA: `rtl/ns10/ns10_aimirror.sv` (AI가 읽는 RAM을 DDR3 0x39000000+물리주소로 복사, 칸 22워드 중 AI가 읽는 5워드만, FIFO 2048), `ns10_ddram_arb.sv`의 최저 우선순위 클라이언트 `m_`, `NAMCOS10.sv` OSD "AI Driller"(status 90).
- DDR3: 0x39400000 헤더 `{A1D5, frame, overflows, late, enable}`, 0x39400008 답 `{5A1D, frame, 0, active[15], side[8], 버튼5}`, 0x39400010 통계 `{A1D6, writes, reads, 0, FIFO max}`.
- 데몬: `/media/fat/linux/drgaid`, `/media/fat/linux/user-startup.sh` 끝에서 자동 실행(백업 `user-startup.sh.bak_drgaid`), 로그 `/tmp/drgaid.log`.
  - 옵션: `-d 지연`(기본 1), `-w µs`(기본 5000, VBLANK 후 읽는 시점), `-v`(10초마다 통계). 환경변수 `RT_DBG=1`(판단/예측실패 로그), `RT_WDUMP=0 RT_WDUMPN=2400 RT_WDDIR=/tmp/wd`(매 프레임 World 덤프, 24 KB/프레임).
  - **AI 수정은 코어 재빌드 없이** 데몬 파일만 교체: 빌드 `python -m ziglang cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -std=gnu99 -D_GNU_SOURCE -include unistd.h -pthread -I. -o drgaid drgaid.c drgbridge.c agent.c psim.c blocksim.c` → `pscp` 업로드 → `killall drgaid; /media/fat/linux/drgaid -v > /tmp/drgaid.log 2>&1 &`.
- 현재 코어: `/media/fat/_Arcade/cores/Arcade-SYSTEM10_20261102.rbf`(디버그, 미러 포함). 릴리스 `..._20261024.rbfrel`, `..._20261031.rbfdbg`는 이름만 바꿔 보관 중(지우지 말 것).
- 상태 확인: `tools/drgai/aimirror_check.py`를 MiSTer에 올려 `python3 aimirror_check.py`.

---

## 3. 이번 세션(2026-11-02)에 알아낸 것 — 중요한 순서

1. **MiSTer 미러 넘침**: 한 칸 내려갈 때마다 게임이 그리드 전체(~15,000워드)를 복사 → 512 FIFO 넘침(65535). 5워드 필터 + 2048 + 읽기 절제로 실기 넘침 0, FIFO 최대 ~9.
2. **읽는 시점**: 게임은 VBLANK 후 1~4 ms에 그 프레임 상태를 쓴다(97%가 4 ms 이내, `diag/drgtime.c`로 실측). 바로 읽으면 절반이 반쯤 쓰인 상태 → 5 ms 후에 읽고 지연 1(GroovyMAME와 같은 타이밍). 예측 실패 50% → 12%.
3. **캐릭터마다 파기 타이머가 다르다**: 타이조 3, 나머지 15(상태 8:15..8:11 → 9:10..9:1, **9가 되는 순간 플레이어가 떨어진다**). 예전 모델/테스트는 전부 타이조. 브리지가 실측(관측 최댓값). 경로 비용 = 타이머 + 3.
4. **MAME 테스트 스크립트가 캐릭터를 강제로 타이조로**: `run1.sh`가 호출자 환경 뒤에 `OB_CHAR=4`를 붙였다. 2026-11-02 이전 MAME 자동 테스트는 전부 타이조뿐. 수정됨(`diag/run1.sh`).
5. **계획 검증 순서**: 예산 안에서 순서대로 검증하는데 목표행 계획이 먼저라 탁 트인 곳에서 산소 계획이 검증조차 안 됐다(옆 칸 한 칸 위 산소를 무시하던 원인). 순서 변경 후 단위 테스트 0/8 → 8/8.
6. **걷기 속도**: 캐릭터마다 다르다(832, 858, 910, 728, 676 등). P+0x18C는 첫 추정일 뿐, 브리지가 실측(두 번 연속 같은 걸음). 속도 아이템으로 바뀌어도 따라간다.
7. 모드: 11~13 일반, 14 우주(끝없음, 3000 m 이후 산소 감소가 비정상적으로 커짐 = 설계 의도), 16 타임어택(플레이 중 목표 워드 0, 시계 아이템=셀 0x0003이 1~4초 단축, 시계마다 다름, 회색 X 0x0916 못 팜, 코스 클리어 기록에 따라 EX 스테이지), 10 서바이벌, 18 레이스(대전, AI=2P).
8. 우주/대전의 `?` 블록 = 셀 0x0C13. 효과 11종(풀에어, 이레이즈, 맥스업, 슬로우, 베리어 / 화이트, 크리스탈, X블록화, 180도/90도 회전, 하프에어). 효과가 블록 생성 때 정해지는지(미리 알 수 있는지) 미조사. 사용자 의견: 크리스탈/회전은 맵이 나쁠 때 도움이 되기도 함, 하프에어는 미리 알 수 있으면 피할 것.
9. 화이트 블록(베이지 별 모양, 다른 블록과 붙지 않음) = 0x0F12 또는 0x6F15 추정, 이집트에도 나옴. **푸치는 블록 2칸을 오른다**(모델에 없음).
10. 남은 시뮬 오차(캐릭터0, MAME): 20프레임 앞 예측 15% 불일치. 주 원인: 낙하 중 x 중앙 정렬(fface), 첫 걸음(걷기 실측 전).

### 현재 성적 (1판씩이라 편차 큼)
- 시뮬레이션 17맵(타이조, 인도 500 m): 17/17 클리어, 산소 45.5/56, 사망 0.06.
- MAME 1000 m: 캐릭터0 산소 52 사망 2, 캐릭터5 산소 54 사망 1. 인도: 산소 45~46, 사망 1~3. 이집트: 캐릭터5 2000 m 클리어(사망 3, 모두 산소), 캐릭터0 1048 m 게임오버.
- 사용자 실기 평가: 산소를 전보다 잘 먹고 블록 올라타기도 잘함. **500 m 이후 갑자기 조급해짐, X블록에 둘러싸인 산소와 순수 산소 회복이 약함.**

---

## 4. 다음 작업 (권장 순서)

### 4-1. 데이터 만들기 (GroovyMAME 우선)
- **me1/me2/me3** (`D:/github_clones/GroovyMAME/inp/`, 사용자 플레이: 인도 56/56, 아메리카 80/80, 이집트 104/104) = 사용자 말로 "드릴러의 거의 모든 지혜". **공식 mame.exe로만 재생**(namcos10.exe는 DRILL_AUTO 포트가 더 있어 1프레임 만에 어긋남). nvram/cfg는 F:/global_mame에서 복사(원본 건드리지 말 것), `-playback meN -exit_after_playback -input_directory ...`.
- 재생하면서 Lua로 매 프레임 RAM 창(그리드 0x326C48~0x335E48, 구조체 0x369B38~0x369EA8, 0x307108, 0x2EF0E4)과 입력을 기록 → 작은 C 도구가 `drg_read_world()`로 World 열 + 사람 입력 + 사건(산소, X파괴, 연쇄, 사망)으로 변환. 이전 분석 스크립트 humcap.py(scratch run/)에 산소별 분류가 있었다.
- GroovyMAME에 **기록 모드** 추가(AI Off일 때 브리지가 World + 사람 입력을 파일로): 사용자가 그냥 플레이하면 데이터가 쌓인다. 사용자에게 X블록이 많은 구간, 이집트/북극, 여러 캐릭터 기록을 더 부탁할 것.
- 데이터 정제: 프레임 단위 버튼을 **결정 단위**(어느 칸으로 / 어느 블록을 / 몇 프레임 기다림 / 산소)로 묶는다. agent.c의 Plan 형식(goal kind 0 산소, 1 경유점+대기, 3 제자리 파기+대기)과 같게 하면 비교와 학습에 바로 쓴다.

### 4-2. 장면별 비교 (학습 전 필수)
- 사람이 X로 둘러싸인 산소를 먹은 장면마다 (a) 그 2~3초 전 상태에서 AI가 같은 계획을 후보로 내는가, (b) 사람 입력을 psim에 넣으면 같은 결과가 나오는가.
- (b)가 틀리면 시뮬레이터 수정(학습해도 소용없음), (a)가 안 되면 후보 제안/점수 문제.

### 4-3. 가중치 모델 + 자기 대국 (사용자가 택한 방식)
- 역할 분담(권장): **신경망 = 계획 제안과 순서/점수**, **정밀 시뮬 = 안전 검증**(깔림/산소 부족 걸러냄). 신경망이 틀려도 안전.
  - 사용자는 "다음 버튼 출력"을 말했지만, 프레임 단위 버튼을 직접 내는 망은 물리까지 배워야 하고 위험하다. 결정 단위(목표 칸 + 종류 + 대기)를 내고 기존 컨트롤러가 버튼으로 바꾸는 쪽을 권장. 사용자와 상의할 것.
- 입력 특징: 플레이어 주변 그리드(예: 아래 14행 × 필드 폭) 채널 = 블록 종류 원핫(4색, X, 산소, 빈칸, 벽, 화이트/크리스탈/?), 상태(흔들림/낙하/소멸 타이머), 플레이어(산소, 소모량, 파기 타이머, 걷기, 오르기 높이, 깊이/남은 거리, 상태).
- 학습 1단계: 사람 결정 지도학습(+ 점수 가중치 학습: 사람 선택이 최고점이 되도록, 데이터 적어도 됨).
- 학습 2단계: 자기 대국(AlphaZero식): 망이 제안 → 정밀 시뮬 탐색이 개선 → 그 결과로 다시 학습. 보상은 목표 순서대로(사망 ≫ 놓친 산소 ≫ 시간 ≫ 점수).
- 환경: `game.c`(독립 게임)가 학습 환경. **맵이 더 필요**: 지금 `D:/scratch_drgai/maps`(인도 500 m, 34개 중 17개 사용). MAME에서 `OB_CDELAY`(캐릭터 확정 프레임)를 바꿔 스테이지 버퍼(0x8031B8C0)를 덤프하면 다른 맵. 다른 스테이지는 맵 디코드 테이블/레벨 테이블 확인 필요.
- PC: Core Ultra 265K(20코어), RX 6600 8 GB(Windows). PyTorch ROCm은 Windows에서 RX 6600 미지원 → torch-directml, 또는 작은 망은 CPU 학습으로 충분. WSL2/Linux ROCm은 `HSA_OVERRIDE_GFX_VERSION=10.3.0`로 비공식 동작.
- 추론: 가중치를 바이너리로 내보내고 **C로 직접 구현**(합성곱/MLP, ARM NEON). 작은 CNN 한 번 = 수 MFLOP → ARM 약 2~5 ms(추정, 측정 필요). GroovyMAME와 MiSTer가 같은 코드.

### 4-4. 그 밖의 할 일
- 500 m 이후 조급해지는 원인: 실기 덤프가 처음 40초뿐이라 못 봄. 블록 속도/산소 소모 변화가 의심됨. `RT_WDUMP` 시작 프레임을 늦추거나 N프레임마다 덤프하는 옵션 추가.
- 푸치 2칸 오르기(캐릭터 ID 0x802EF0E8로 판별하거나 오르기 관측), 캐릭터별 산소 소모(브리지가 실측 중).
- `?` 블록 효과 판별(MAME 디버거로 0x0C13을 팔 때 실행되는 분기 추적), 하프에어 회피.
- 대전 늦은 스크롤 모델, 서바이벌 테스트.
- 남은 시뮬 오차(낙하 x 정렬).

---

## 5. MiSTer 플레이 기록 (사용자 아이디어, 설계안)

- 코어가 시작되면 바로 기록, OSD를 열어 NVRAM을 저장할 때 기록 파일도 저장.
- 사람이 플레이할 때도 미러가 돌아야 한다: 지금은 `enable = Driller G && OSD AI Driller On`. "AI Record" OSD 항목을 추가하거나 Driller G면 항상 미러 켜기.
- **사람 입력이 DDR3에 없다** → FPGA 수정 필요: 헤더 낮은 워드의 남는 비트(7비트 0 자리)에 그 프레임의 실제 입력(P1/P2 각 5비트 중 하나라도)을 넣는다. 재빌드 1회.
- 데몬이 기록: 프레임마다 {프레임, 입력, 플레이어 구조체 0x1B4 바이트, 그리드 변경분}(스크롤은 이동으로 표현), 스테이지 시작 때 전체 그리드. SD 카드 `/media/fat/drgai_rec/`. 스테이지 끝/게임오버에 파일 닫기(OSD NVRAM 저장 신호를 따로 쓸 필요는 없을 수도 있음, 사용자와 상의).
- CPU 레지스터 상태는 AI 학습에 필요 없다(게임 RAM이 상태의 전부).
- MAME .inp와 달리 MiSTer는 결정론 재생이 안 되므로 상태를 직접 저장해야 한다.

---

## 6. 판단 근거 (사용자 질문에 답한 것)

### 6-1. .inp만으로 충분한가
입력만 있고 상태가 없다 → 원본으로 쓰되 공식 MAME로 재생해 (상태, 입력) 쌍으로 정제해야 한다. 3판 ≈ 5만 프레임, 산소 ~240개 = 화면→버튼 직접 모방에는 부족, 점수 가중치 학습/계획 템플릿/자기 대국 초기값으로는 충분.

### 6-2. 신경망과 MiSTer 0.5초 예산
작은 망(수 MFLOP)은 ARM에서 수 ms → 예산 문제 없음. 큰 모델(LLM급)은 불가하고 필요도 없다. 병목은 계산량이 아니라 데이터와 시뮬레이터 정확도.

### 6-3. FPGA 9% 남은 공간에 신경망
권하지 않음: DSP 97% 사용(곱셈기 거의 없음), 메모리 블록 80% 사용, ALM 91%(디버그). ARM이 수 ms에 하는 일이라 이득이 없고, 모델을 바꿀 때마다 20분 재빌드 + 타이밍 위험.

---

## 7. 테스트와 디버깅 방법

### 7-1. 시뮬레이션 테스트 (가장 빠름, 결정론)
```
cd tools/drgai/rtai
gcc -O2 -std=gnu99 -Wall -I. -pthread -o /d/scratch_drgai/bin/run.exe run.c agent.c game.c psim.c blocksim.c
cd /d/scratch_drgai && ./bin/run.exe maps/map*.txt | grep TOTAL      # 17맵, 타이조
```
(MSYS2 gcc: `export PATH=/c/msys64/ucrt64/bin:$PATH` — 이러면 python이 ucrt64 것이 되어 ziglang이 없다. ARM 빌드는 PATH를 바꾸지 않은 셸에서.)

### 7-2. MAME 테스트 (최종 확인)
- `diag/run1.sh NAME CDELAY "ENV..."`(D:/scratch_drgai/mt/run1.sh와 같음): 숨김 GroovyMAME 한 판, `drgbot.lua OB_PLAY=builtin`이 메뉴를 진행하고 내장 AI가 플레이. 결과 `mt/NAME.txt`(DEATH, GAME 1 END, CHAR), 로그 `mt/NAME.log`(RT_DBG).
  - `OB_STAGE` 0 우주, 1 북극(넓음), 2 1000 m, 3 이집트(넓음), 4 인도 500 m. `OB_CHAR` 커서 값(캐릭터 id: 0→0, 1→1, 2→5, 3→2, 4→타이조, 5→3). `OB_CDELAY` = 다른 맵. `NS10_AI_THREAD=0` = 결정론 모드(예산 전부 사용).
  - **반드시 여러 캐릭터로 테스트**(타이조만 다르다).
- 대전/타임어택: 사용자 세이브스테이트 `t`(2P 메뉴 직전, A=드릴), `y`(타임어택 진입, Button 1) + `tools/drgai/vsprobe.lua`(`VS_STATE=1 VS_SEQ="30:A,120:U,160:A"`).
- 세이브스테이트 원본 F:/global_mame/cfg/sta/mrdrilrg/ → `mt/sta/`로 복사해서 사용.

### 7-3. 예측 정확도 진단 (diag/)
- 덤프 만들기: GroovyMAME/MiSTer에서 `RT_WDUMP=0 RT_WDUMPN=3000 RT_WDDIR=dir`.
- `diag/shift.c dir`: 입력 지연 -2..+4별 1프레임 예측 불일치 → 최소인 지연이 맞는 값(MAME/MiSTer 모두 +0이 최소면 정상).
- `diag/multi.c dir N digt`: N프레임 앞 예측 불일치율.
- `diag/firstmis.c dir digt`: 첫 불일치 종류 히스토그램 + 예시.
- `wcheck dir f0 n`: 한 구간을 프레임별로(셀 차이까지).
- `diag/climbt.c`, `diag/climbp.c`: 오르기 단위 테스트(작은 손 맵).
- `diag/drgtime.c`: MiSTer에서 게임이 프레임 안 언제 쓰는지 측정.
- `diag/qprobe.lua`: 우주 `?` 블록 파기 전후 기록(아직 판정 조건 버그: 엉뚱한 블록을 잡음).
- 빌드 예: `gcc -O2 -std=gnu99 -I. -o multi.exe diag/multi.c psim.c blocksim.c` (rtai 폴더에서).

### 7-4. 알아둘 함정
- **plink에 `/tmp/...` 경로를 쓰면 MSYS가 Windows 경로로 바꾼다** → `MSYS_NO_PATHCONV=1 plink ...`.
- 이 도구 환경에서 Bash 명령 안의 `\n`(sed/python heredoc 문자열)이 실제 줄바꿈으로 바뀌어 C/Lua 문자열이 깨진 적이 여러 번 있다. 문자열에 `\n`이 들어가는 수정은 Edit 도구로.
- MAME Lua `install_write_tap/read_tap`은 이 드라이버의 CPU RAM 접근에서 호출되지 않는다(트래픽 측정 불가).
- MAME가 0% CPU로 멈추면 USB HID 장치 문제(8BitDo 등) → 뽑았다 꽂기.
- GroovyMAME 빌드 중 파일 복사 순서: rtai 수정 → drgai/로 복사 → make. 복사 잊으면 옛 코드로 테스트된다.
- MiSTer가 재부팅되면 /tmp의 것(aimirror_check.py, drgtime, 덤프)은 사라진다. drgaid는 user-startup.sh로 자동 시작.
- MiSTer 스크린샷, 옛 릴리스 rbf는 지우지 말 것(이름 변경).
- 결과는 1판 편차가 크다. 판단은 여러 맵/캐릭터로.

---

## 8. 주요 RAM 주소 (물리 주소, drgbridge.h)
- 모드 0x369B38, 목표 깊이 0x307108(플레이 중 > 0, 타임어택은 0), P1 구조체 0x369B40(2P = +0x1B4), 그리드 0x326C48(32행 × 22칸 × 88바이트), 단독 플레이 P2쪽 0x2EF0E4, 캐릭터 ID 0x2EF0E8.
- 구조체: +0x98 플레이 타이머, +0xD8 상태(1 서기, 2 낙하, 3 오르기, 4 밀림, 7/8/9 사망), +0xE4 열, +0xEC x, +0xF4 깊이, +0xFC 방향, +0x118 y, +0x15C 흔들림 시간, +0x15E 블록 낙하 속도, +0x160 산소, +0x164 산소 변화 대기량(1000/프레임), +0x18C 걷기 첫 추정.
- 칸: +0x00 상태(3 흔들림, 4 정지, 1/2 낙하, 5/6 연쇄 소멸, 8/9/10 파여 소멸, 7/12 분리대 위 정지, 11 빈칸 표시), +0x2A 종류(0x0F0E~0x0F11 4색, 0x0B0D X, 0x0003 산소/시계, 0x0801 벽, 0x0F12/0x6F15 화이트류, 0x0C13 ?, 0x0916 회색 X), +0x39 파기 타이머, +0x3A/+0x3B 소멸 타이머, +0x3C 흔들림, +0x3F X 남은 타격, +0x42 낙하 오프셋.
