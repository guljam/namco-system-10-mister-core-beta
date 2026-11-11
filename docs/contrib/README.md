# docs/contrib — 다른 코어(Namco_System_10_MiSTer)용 기여 패치

이 폴더는 **우리 코어가 아니라 다른 개발자의 코어 `Namco_System_10_MiSTer`** (기준 커밋 `8a8c283`)에
적용하도록 만든 패치와 그 단위 테스트입니다. 우리 저장소의 소스에는 적용하지 않습니다.

| 파일 | 설명 |
|---|---|
| `namco_s10-irq10-2xvblank.patch` | OSD 옵션 `Hardware > IRQ10 (Input)`을 추가하는 패치 (`git apply`용, 앞부분 설명문 + diff) |
| `tb_s10_io_irq10.sv` | 패치가 만든 IRQ10 로직의 ModelSim/Questa 단위 테스트벤치 |

## 패치 내용

IRQ10 소스를 선택하는 OSD 옵션을 추가합니다.

- **100Hz** (기본값, 기존 동작 그대로 = MAME)
- **2xVBlank**: 마지막으로 측정한 프레임 길이의 1/4, 3/4 지점에서 IRQ10 펄스를 프레임당 2번 발생
  (59.94Hz 기준 약 119.88회/초). 100Hz 카운터는 계속 동작하고 펄스만 게이트됩니다. CD-ROM IRQ10 경로는 그대로입니다.

Mr. Driller 2 / G는 IRQ10 두 번에 한 번 IN1을 저장하므로, 100Hz에서는 초당 50회 샘플링되어
59.94fps와 맥놀이가 생기고, 2xVBlank에서는 프레임당 정확히 1회 샘플링됩니다.
Driller 2/G, Gamshara, Star Trigon에서만 확인했고 다른 게임(Taiko 등)은 미검증이라 옵션으로만 넣었습니다.
배경 설명은 `docs/rapid-fire-irq-eng.md` 참고.

수정되는 파일 (대상 코어 기준): `Namco_S10.sv`(OSD 비트 65, `psx_vbl`), `rtl/s10_io.sv`(`irq10_vbl`, `vblank` 입력),
`sim/system/tb_s10.template.vhd`(새 포트를 `'0`으로 연결).

## 사용법

### 1. 패치 적용

대상 코어 저장소를 기준 커밋(`8a8c283`) 또는 그 이후로 받은 뒤, 저장소 루트에서:

```sh
git clone https://github.com/<owner>/Namco_System_10_MiSTer   # 이미 있으면 생략
cd Namco_System_10_MiSTer
git checkout 8a8c283                                          # 충돌이 나면 이 커밋 기준으로
git apply --check /path/to/docs/contrib/namco_s10-irq10-2xvblank.patch   # 먼저 검사
git apply         /path/to/docs/contrib/namco_s10-irq10-2xvblank.patch
```

- 패치 파일 앞부분의 설명문은 `git apply`가 무시합니다 (`diff --git`부터 읽음).
- 커밋 로그로 남기려면 `git am` 대신 `git apply` 후 직접 커밋하세요 (이 파일은 mbox 형식이 아님).
- 적용 후 Quartus에서 코어를 다시 빌드하면 OSD에 `IRQ10 (Input)`이 나타납니다.

### 2. 단위 테스트 (ModelSim/Questa)

적용된 대상 코어의 `rtl/` 폴더로 `tb_s10_io_irq10.sv`를 복사한 뒤:

```sh
vlog -sv s10_io.sv tb_s10_io_irq10.sv
vsim -c tb_irq10 -do "run -all"
```

`PASS`가 출력되면 정상입니다. 검증 항목: 100Hz 간격 338688 clk, 2xVBlank 오프셋이 프레임의 1/4, 3/4 (±2 clk)로
프레임당 2회, CD INTRQ가 여전히 IRQ10을 발생시키는지. 워치독(펄스 간격 1,000,000 clk)과 절대 사이클 제한
(12,000,000 clk)이 있어 멈추면 실패로 종료됩니다.

---

**English summary:** `namco_s10-irq10-2xvblank.patch` is a patch for the *other* developer's
`Namco_System_10_MiSTer` core (base `8a8c283`), not for this repo. It adds an OSD option choosing the IRQ10
source (100 Hz default, or 2x VBlank). Apply with `git apply` from the target repo root; verify the logic with
`tb_s10_io_irq10.sv` in ModelSim/Questa (`vlog -sv s10_io.sv tb_s10_io_irq10.sv; vsim -c tb_irq10 -do "run -all"`).
