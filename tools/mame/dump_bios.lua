-- MAME Lua oracle: dump the decoded 4 MB BIOS region and stop.
-- Env NS10_BIOSOUT = output path.
ns10b = {}
ns10b.sub = emu.add_machine_frame_notifier(function()
  if ns10b.done then return end
  ns10b.done = true
  local r = manager.machine.memory.regions[":maincpu:rom"]
  local f = io.open(os.getenv("NS10_BIOSOUT") or "bios.bin", "wb")
  for i = 0, r.size - 1, 4 do f:write(string.pack("<I4", r:read_u32(i))) end
  f:close()
  manager.machine:exit()
end)
