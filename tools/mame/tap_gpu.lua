-- MAME Lua oracle for tools/gputrace.py: GPU command stream per field.
-- Usage: namcos10.exe <game> -autoboot_script tools/mame/tap_gpu.lua
-- Env NS10_GPULOG = output path, NS10_T0 / NS10_T1 = machine time window in s (default 30..60).
-- NS10_FULL=1 also logs every primitive parameter (input for tools/gpumodel.py).
-- Logs CPU writes to GP0/GP1, DMA2 MADR/BCR/CHCR, DICR, I_STAT/I_MASK, and on a DMA2 linked list
-- start walks the ordering table in RAM and logs every GP0 command header (what the core's
-- trace sees as GP0 entries). Lines: <time s> <frame> <kind> <data>; VBL = frame done.
-- State lives in globals: autoboot-chunk locals are garbage collected (taps would vanish).
gtap = { taps = {} }
gtap.f = io.open(os.getenv("NS10_GPULOG") or "gpu.log", "w")
gtap.t0 = tonumber(os.getenv("NS10_T0") or "30")
gtap.t1 = tonumber(os.getenv("NS10_T1") or "60")
gtap.madr = 0
gtap.full = os.getenv("NS10_FULL") == "1"   -- log the parameters of every primitive (timing model input)

function gtap.on()
  local t = emu.time()
  return t >= gtap.t0 and t < gtap.t1
end

function gtap.log(kind, d)
  if not gtap.on() then return end
  gtap.f:write(string.format("%.6f %d %s %08X\n", emu.time(), gtap.screen:frame_number(), kind, d & 0xffffffff))
end

-- GP0 packet: length of the packet (words after the header) by command
function gtap.plen(op)
  if op >= 0x20 and op <= 0x3f then
    local verts = (op & 0x08) ~= 0 and 4 or 3
    local per = 1 + ((op & 0x04) ~= 0 and 1 or 0) + ((op & 0x10) ~= 0 and 1 or 0)
    return verts * per - ((op & 0x10) ~= 0 and 1 or 0)
  end
  return nil
end

function gtap.walk(addr)
  local n = 0
  local mem = gtap.space
  while n < 20000 do
    local hdr = mem:read_u32(addr & 0x3ffffc)
    local cnt = hdr >> 24
    local p = (addr & 0x3ffffc) + 4
    local left = cnt
    while left > 0 do
      local w = mem:read_u32(p)
      local op = w >> 24
      if op ~= 0 then gtap.log("GP0", w) end
      -- skip the parameters of polygon packets (one header per primitive)
      local l = gtap.plen(op)
      if op >= 0x40 and op <= 0x5f then l = ((op & 0x10) ~= 0 and 3 or 2) end
      if op >= 0x60 and op <= 0x7f then
        l = 1 + ((op & 0x04) ~= 0 and 1 or 0) + (((op >> 3) & 3) == 0 and 1 or 0)
      end
      if op == 0x02 or (op >= 0xa0 and op <= 0xdf) then l = 2 end
      if op >= 0x80 and op <= 0x9f then l = 3 end
      l = math.min(l or 0, left - 1)
      if op == 0x02 or (op >= 0x80 and op <= 0xdf) or gtap.full then
        for k = 1, l do gtap.log("PAR", mem:read_u32(p + 4 * k)) end
      end
      p = p + 4 * (l + 1)
      left = left - (l + 1)
    end
    n = n + 1
    if (hdr & 0xffffff) == 0xffffff or (hdr & 0x800000) ~= 0 then break end
    addr = hdr & 0xffffff
  end
end

function gtap.install()
  if gtap.installed then return end
  gtap.installed = true
  local cpu = manager.machine.devices[":maincpu"]
  gtap.space = cpu.spaces["program"]
  for _, s in pairs(manager.machine.screens) do gtap.screen = s end
  local sp = gtap.space
  gtap.taps[#gtap.taps+1] = sp:install_write_tap(0x1f801810, 0x1f801817, "gpu_w", function(offset, data, mask)
    if offset == 0x1f801814 then gtap.log("GP1", data) else gtap.log("GP0CPU", data) end
  end)
  gtap.taps[#gtap.taps+1] = sp:install_write_tap(0x1f8010a0, 0x1f8010af, "dma2_w", function(offset, data, mask)
    if offset == 0x1f8010a0 then gtap.madr = data; gtap.log("MADR2", data)
    elseif offset == 0x1f8010a4 then gtap.log("BCR2", data)
    elseif offset == 0x1f8010a8 then
      gtap.log("CHCR2", data)
      if (data & 0x01000000) ~= 0 and ((data >> 9) & 3) == 2 and gtap.on() then gtap.walk(gtap.madr) end
    end
  end)
  gtap.taps[#gtap.taps+1] = sp:install_write_tap(0x1f8010f4, 0x1f8010f7, "dicr_w", function(offset, data, mask) gtap.log("DICR", data) end)
  gtap.taps[#gtap.taps+1] = sp:install_write_tap(0x1f801070, 0x1f801077, "irq_w", function(offset, data, mask)
    gtap.log(offset == 0x1f801070 and "I_STAT" or "I_MASK", data)
  end)
  gtap.vbl = emu.add_machine_frame_notifier(function()
    gtap.log("VBL", 0)
    if emu.time() >= gtap.t1 and not gtap.closed then gtap.closed = true; gtap.f:close(); manager.machine:exit() end
  end)
end

gtap.install()
gtap.start = emu.add_machine_reset_notifier(gtap.install)
