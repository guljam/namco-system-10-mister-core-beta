-- MAME Lua oracle: log Namco System 10 board-register traffic (EXP1 region and DMA5).
-- Usage: namcos10.exe <game> -autoboot_script tools/mame/tap_exp1.lua
-- Env NS10_TAPLOG = output path, NS10_MAXLOG = max sequential entries.
-- State lives in globals: autoboot-chunk locals are garbage collected, which silently
-- removes passthrough taps.
ns10 = { nseq = 0, hist = {}, taps = {} }
ns10.out_path = os.getenv("NS10_TAPLOG") or "tap.log"
ns10.max_seq = tonumber(os.getenv("NS10_MAXLOG") or "200000")
ns10.f = io.open(ns10.out_path, "w")
ns10.norle = os.getenv("NS10_NORLE") == "1"

function ns10.log(rw, a, d, m)
  local k = string.format("%s %08X", rw, a)
  ns10.hist[k] = (ns10.hist[k] or 0) + 1
  -- run-length compress repeats of the same access (NAND data streams, watchdog kicks)
  if ns10.norle then
    -- full-fidelity mode for model replay
  elseif k == ns10.last_key then
    ns10.run = ns10.run + 1
    if ns10.run > 3 then return end
  else
    if ns10.run and ns10.run > 3 then ns10.f:write(string.format("   ... %s repeated %d times total\n", ns10.last_key, ns10.run)) end
    ns10.last_key = k
    ns10.run = 1
  end
  if ns10.nseq < ns10.max_seq then
    ns10.nseq = ns10.nseq + 1
    local ok, err = pcall(function()
      ns10.f:write(string.format("%.6f %s %08X %08X %08X pc=%08X\n", emu.time(), rw, a, d & 0xffffffff, m & 0xffffffff, ns10.pc.value))
    end)
    if not ok and not ns10.err_shown then ns10.err_shown = true; print("ns10 log error: " .. tostring(err)) end
  end
end

function ns10.tap(lo, hi, name)
  local sp = ns10.space
  ns10.taps[#ns10.taps+1] = sp:install_read_tap(lo, hi, name.."_r", function(offset, data, mask) ns10.log("R", offset, data, mask) end)
  ns10.taps[#ns10.taps+1] = sp:install_write_tap(lo, hi, name.."_w", function(offset, data, mask) ns10.log("W", offset, data, mask) end)
end

function ns10.install()
  if ns10.installed then return end
  ns10.installed = true
  ns10.cpu = manager.machine.devices[":maincpu"]
  ns10.space = ns10.cpu.spaces["program"]
  ns10.pc = ns10.cpu.state["GENPC"] or ns10.cpu.state["PC"] or ns10.cpu.state["pc"]
  ns10.tap(0x1f000000, 0x1f7fffff, "exp1a")
  ns10.tap(0x1fa00000, 0x1fbfffff, "exp1b")
  ns10.tap(0x1fe00000, 0x1fffffff, "exp1c")
  ns10.tap(0x1f801000, 0x1f801027, "memctl")
  ns10.tap(0x1f801060, 0x1f801063, "ramsize")
  ns10.tap(0x1f8010d0, 0x1f8010df, "dma5")
  ns10.tap(0x1f8010f0, 0x1f8010f7, "dpcr")
  ns10.tap(0x1f801800, 0x1f801803, "cdrom")
  ns10.tap(0x1f801040, 0x1f80104f, "sio0")
  ns10.tap(0x1f802000, 0x1f803fff, "exp2")
  print("ns10 taps installed: " .. #ns10.taps)
end

ns10.install()
ns10.start_sub = emu.add_machine_reset_notifier(ns10.install)
ns10.stop_sub = emu.add_machine_stop_notifier(function()
  ns10.f:write("=== histogram ===\n")
  local keys = {}
  for k, _ in pairs(ns10.hist) do keys[#keys+1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do ns10.f:write(string.format("%s %d\n", k, ns10.hist[k])) end
  ns10.f:close()
end)

-- PC range sampling once per frame: tells which BIOS-window offsets actually execute.
ns10.pcmin, ns10.pcmax = 0xffffffff, 0
ns10.frame_sub = emu.add_machine_frame_notifier(function()
  local pc = ns10.pc.value & 0x1fffffff
  if pc >= 0x1fc00000 then
    if pc < ns10.pcmin then ns10.pcmin = pc end
    if pc > ns10.pcmax then ns10.pcmax = pc end
  end
end)
ns10.stop_sub2 = emu.add_machine_stop_notifier(function()
  print(string.format("ns10 BIOS-window PC samples: min=%08X max=%08X", ns10.pcmin, ns10.pcmax))
end)
