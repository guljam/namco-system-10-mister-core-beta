# Patch a COPY of the MAME source (src/mame/namco/namcos10.cpp) for the IRQ10 2x VBlank test:
# with env NS10_IRQ10=vbl2 IRQ10 fires at 1/4 and 3/4 of the frame after each vblank (as rtl/ns10/ns10_io.sv
# irq10_vbl), otherwise MAME's 100 Hz timer. Usage: python irq10_vbl2.py <copy>/src/mame/namco/namcos10.cpp,
# then make SUBTARGET=namcos10 SOURCES=src/mame/namco/namcos10.cpp (docs/fixes-2026-10-23.md)
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
NL = '\r\n' if '\r\n' in s else '\n'
def r(o, n):
    global s
    o, n = o.replace('\n', NL), n.replace('\n', NL)
    assert s.count(o) == 1, o
    s = s.replace(o, n)
r("	TIMER_DEVICE_CALLBACK_MEMBER(io_update_interrupt_callback);\n",
  "	TIMER_DEVICE_CALLBACK_MEMBER(io_update_interrupt_callback);\n"
  "	void vbl2_vblank(screen_device &screen, bool state);\n"
  "	TIMER_CALLBACK_MEMBER(vbl2_fire);\n"
  "	bool m_vbl2 = false;\n"
  "	attotime m_vbl2_last;\n"
  "	emu_timer *m_vbl2_t[2] = { nullptr, nullptr };\n")
r("void namcos10_state::machine_start()\n{\n",
  "void namcos10_state::machine_start()\n{\n"
  "	const char *e = getenv(\"NS10_IRQ10\");\n"
  "	m_vbl2 = e && !strcmp(e, \"vbl2\");\n"
  "	if (m_vbl2) {\n"
  "		m_vbl2_t[0] = timer_alloc(FUNC(namcos10_state::vbl2_fire), this);\n"
  "		m_vbl2_t[1] = timer_alloc(FUNC(namcos10_state::vbl2_fire), this);\n"
  "		subdevice<screen_device>(\"screen\")->register_vblank_callback(vblank_state_delegate(&namcos10_state::vbl2_vblank, this));\n"
  "		osd_printf_info(\"NS10_IRQ10=vbl2: IRQ10 at 1/4 and 3/4 of the frame\\n\");\n"
  "	}\n")
r("TIMER_DEVICE_CALLBACK_MEMBER(namcos10_state::io_update_interrupt_callback)\n{\n",
  "void namcos10_state::vbl2_vblank(screen_device &screen, bool state)\n{\n"
  "	if (!state) return;\n"
  "	attotime now = machine().time();\n"
  "	attotime per = now - m_vbl2_last;\n"
  "	m_vbl2_last = now;\n"
  "	if (per > attotime::from_msec(40) || per < attotime::from_msec(10)) per = attotime::from_hz(59.94);\n"
  "	m_vbl2_t[0]->adjust(per / 4);\n"
  "	m_vbl2_t[1]->adjust(per * 3 / 4);\n"
  "}\n\n"
  "TIMER_CALLBACK_MEMBER(namcos10_state::vbl2_fire)\n{\n"
  "	m_int |= 8;\n"
  "	m_io_update_interrupt(1);\n"
  "}\n\n"
  "TIMER_DEVICE_CALLBACK_MEMBER(namcos10_state::io_update_interrupt_callback)\n{\n"
  "	if (m_vbl2) return;\n")
open(p, 'w', encoding='utf-8', newline='').write(s)
print("patched")
