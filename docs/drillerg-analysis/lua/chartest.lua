local out, st = os.getenv("OB_OUT"), os.getenv("OB_STATE")
local K=tonumber(os.getenv("OB_K")); local DIR=os.getenv("OB_DIR") or "P1 Down"
local PER=tonumber(os.getenv("OB_PER") or "2"); local NF=tonumber(os.getenv("OB_NF") or "400")
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
  if f==3 then sp:write_i16(0x802EF0E8,K); sp:write_u32(p+0xb0,B0[K+1]); sp:write_u32(p+0xb4,B4[K+1]) end
  if f>=4 then
    P[DIR]:set_value(1)
    P["P1 Button 1"]:set_value((f%PER==0) and 1 or 0)
    log:write(string.format("%d st=%d a94=%x dug=%d chain=%d depth=%d y=%d x=%d xs=%d air=%d pend=%d xc=%d\n",f,
      sp:read_u32(p+0xd8),sp:read_u32(p+0x94),sp:read_u32(p+0x128),sp:read_u32(p+0x12c),sp:read_u32(p+0xf4),sp:read_i32(p+0x118),sp:read_u32(p+0xe4),sp:read_i32(p+0xec),sp:read_u32(p+0x160),sp:read_i32(p+0x164),sp:read_i16(0x80369EBE)))
  end
  if f==NF then log:close(); manager.machine:exit() end
  end) if not ok then print("ERR",err) end
end)
