local out, st = os.getenv("OB_OUT"), os.getenv("OB_STATE")
local K=tonumber(os.getenv("OB_K")); local NF=tonumber(os.getenv("OB_NF") or "3000")
local B0={256,264,248,248,288,272}; local B4={256,264,224,208,224,280}
local o={f=0}
local log=io.open(out..".txt","w")
o.n = emu.add_machine_frame_notifier(function()
  local ok,err=pcall(function()
  o.f=o.f+1
  local P=manager.machine.ioport.ports[":IN1"].fields
  if o.f==2 then manager.machine:load(st); return end
  local f=o.f
  local sp=manager.machine.devices[":maincpu"].spaces["program"]
  local p=0x80369B40
  if f==3 then log:write(string.format("orig char=%d ac=%d\n",sp:read_i16(0x802EF0E8),sp:read_u32(p+0xac)))
    sp:write_i16(0x802EF0E8,K); sp:write_u32(p+0xb0,B0[K+1]); sp:write_u32(p+0xb4,B4[K+1]); sp:write_u32(p+0xac,(K==4) and 3 or 15) end
  if f>=4 then
    sp:write_u32(p+0x160,150000)
    local ph=f%300
    P["P1 Down"]:set_value(ph<260 and 1 or 0)
    P["P1 Left"]:set_value((ph>=260 and ph<280) and 1 or 0)
    P["P1 Right"]:set_value((ph>=280) and 1 or 0)
    P["P1 Button 1"]:set_value((f%2==0) and 1 or 0)
    if true then log:write(string.format("%d depth=%d dug=%d chain=%d st=%d lives=%d caps=%d\n",f,sp:read_u32(p+0xf4),sp:read_u32(p+0x128),sp:read_u32(p+0x12c),sp:read_u32(p+0xd8),sp:read_u16(p+0x88),sp:read_u16(p+0x8a))) end
  end
  if f==NF then log:close(); manager.machine:exit() end
  end) if not ok then print("ERR",err) end
end)
