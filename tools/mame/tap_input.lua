-- MAME Lua oracle for Drill (Auto) (rtl/ns10/ns10_autofire.sv): feeds an autofire model into
-- IN1 (0x1FBA0004) and counts the presses the game itself sees in its per-frame pad copy.
-- Findings (2026-10-23, mrdrilr2j / mrdrilrg): IN1 is read in the 100 Hz IRQ10 handler, the game
-- stores every other read (50 Hz) and copies the latest stored sample once per frame after vblank.
-- Usage: namcos10.exe <game> -autoboot_script tools/mame/tap_input.lua
-- Env NS10_INLOG  = output path, NS10_T1 = machine time to exit (s, default 60)
--     NS10_INJ    = "t0,t1,hexmask;..." clear these IN1 bits (active low = press) in [t0,t1)
--     NS10_AF     = "t0,t1" hold Drill (Auto) for P1 (IN1 bit 4) in [t0,t1)
--     NS10_AFMODE = read: toggle every 2nd IN1 low read, first press on (ns10_autofire.sv, default)
--                   vbl:  toggle on every GP1(05) write (vsync counter LSB, 30 Hz)
--     NS10_PAD    = game pad copy address, hex (mrdrilr2j 8023F94E; drill = 0x0200)
--     NS10_SNAP   = "t,t,..." save a MAME snapshot at these machine times
-- Lines: <time s> <frame> <kind> <data>; at exit: presses the game saw inside the NS10_AF window
-- and frames whose drill bit did not change (0 = the game sees on / off every frame)
-- State lives in globals: autoboot-chunk locals are garbage collected (taps would vanish).
itap = { taps = {}, inj = {}, snaps = {}, presses = 0, frames = 0, same = 0 }
itap.f = io.open(os.getenv("NS10_INLOG") or "input.log", "w")
itap.t1 = tonumber(os.getenv("NS10_T1") or "60")
for t0, t1, m in string.gmatch(os.getenv("NS10_INJ") or "", "([%d%.]+),([%d%.]+),(%x+)") do
  itap.inj[#itap.inj+1] = { tonumber(t0), tonumber(t1), tonumber(m, 16) }
end
do
  local a, b = string.match(os.getenv("NS10_AF") or "", "([%d%.]+),([%d%.]+)")
  itap.af0, itap.af1 = tonumber(a or "-1"), tonumber(b or "-1")
end
itap.mode = os.getenv("NS10_AFMODE") or "read"
itap.pad = tonumber(os.getenv("NS10_PAD") or "0", 16)
for ts in string.gmatch(os.getenv("NS10_SNAP") or "", "[%d%.]+") do itap.snaps[#itap.snaps+1] = tonumber(ts) end
itap.level, itap.cnt, itap.held = 0, 0, false

function itap.log(kind, d)
  pcall(function() itap.f:write(string.format("%.6f %d %s %08X\n", emu.time(), itap.screen:frame_number(), kind, d & 0xffffffff)) end)
end

-- autofire model state, updated when Drill (Auto) is pressed / released
function itap.af_update()
  local t = emu.time()
  local held = t >= itap.af0 and t < itap.af1
  if held and not itap.held then itap.level, itap.cnt = 1, 0 end
  if not held then itap.level = 0 end
  itap.held = held
end

function itap.install()
  if itap.installed then return end
  itap.installed = true
  local cpu = manager.machine.devices[":maincpu"]
  itap.space = cpu.spaces["program"]
  for _, s in pairs(manager.machine.screens) do itap.screen = s end
  itap.taps[#itap.taps+1] = itap.space:install_read_tap(0x1fba0004, 0x1fba0007, "in_r", function(offset, data, mask)
    local t, d = emu.time(), data
    for _, e in ipairs(itap.inj) do
      if t >= e[1] and t < e[2] then d = d & ~e[3] end
    end
    if (mask & 0xffff) ~= 0 then
      itap.af_update()
      if itap.level == 1 then d = d & ~0x10 end
      itap.log("IN1L", d)
      -- this read got the current level; count it (ns10_autofire.sv)
      if itap.held and itap.mode == "read" then
        itap.cnt = 1 - itap.cnt
        if itap.cnt == 0 then itap.level = 1 - itap.level end
      end
    end
    if d ~= data then return d end
  end)
  itap.taps[#itap.taps+1] = itap.space:install_write_tap(0x1f801814, 0x1f801817, "gp1_w", function(offset, data, mask)
    if (data >> 24) ~= 0x05 then return end
    local t = emu.time()
    -- the game has copied its pad for this frame before this write
    if itap.pad ~= 0 then
      local v = itap.space:read_u16(itap.pad)
      itap.log("PAD", v)
      local on = (v & 0x0200) ~= 0
      if t >= itap.af0 + 0.5 and t < itap.af1 then
        itap.frames = itap.frames + 1
        if on and not itap.pad_on then itap.presses = itap.presses + 1 end
        if on == itap.pad_on then itap.same = itap.same + 1 end
      end
      itap.pad_on = on
    end
    itap.log("GP1_05", data)
    itap.af_update()
    if itap.held and itap.mode == "vbl" then itap.level = 1 - itap.level end
  end)
  itap.vbl = emu.add_machine_frame_notifier(function()
    local t = emu.time()
    for i, ts in ipairs(itap.snaps) do
      if t >= ts then table.remove(itap.snaps, i); manager.machine.video:snapshot(); break end
    end
    if t >= itap.t1 and not itap.closed then
      itap.closed = true
      local s = itap.frames / 59.94
      local msg = string.format("mode %s: %d presses seen by the game in %d frames (%.2f/s), %d frames repeated the last value", itap.mode, itap.presses, itap.frames, s > 0 and itap.presses / s or 0, itap.same)
      print(msg)
      itap.f:write(msg .. "\n")
      itap.f:close()
      manager.machine:exit()
    end
  end)
end

itap.install()
itap.start = emu.add_machine_reset_notifier(itap.install)
