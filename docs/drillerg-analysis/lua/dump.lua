local out, st = os.getenv("OB_OUT"), os.getenv("OB_STATE")
local o = { f = 0 }
o.n = emu.add_machine_frame_notifier(function()
  local ok, err = pcall(function()
  o.f = o.f + 1
  if o.f == 2 then manager.machine:load(st); return end
  if o.f == 4 then
    local sp = manager.machine.devices[":maincpu"].spaces["program"]
    local f = io.open(out .. ".bin", "wb")
    for a = 0x80000000, 0x803FFFFF, 0x10000 do f:write(sp:read_range(a, a + 0xFFFF, 8)) end
    f:close()
    manager.machine:exit()
  end
  end)
  if not ok then print("ERR", err) end
end)
