local out, st = os.getenv("OB_OUT"), os.getenv("OB_STATE")
local NF=tonumber(os.getenv("OB_NF") or "20000")
local o={f=0, done=0}
local log=io.open(out..".txt","w")
local prev=""
o.n = emu.add_machine_frame_notifier(function()
  local ok,err=pcall(function()
  o.f=o.f+1
  local P=manager.machine.ioport.ports[":IN1"].fields
  if o.f==2 then manager.machine:load(st); return end
  local f=o.f
  local sp=manager.machine.devices[":maincpu"].spaces["program"]
  local p=0x80369B40
  if f>=4 then
    local d=sp:read_u32(p+0xf4)
    if d<sp:read_u32(0x80307108) then sp:write_u32(p+0x160,150000) end
    -- dig down; every 300 frames wiggle left/right to escape stuck spots
    local ph=f%300
    P["P1 Down"]:set_value(ph<260 and 1 or 0)
    P["P1 Left"]:set_value((ph>=260 and ph<280) and 1 or 0)
    P["P1 Right"]:set_value((ph>=280) and 1 or 0)
    P["P1 Button 1"]:set_value((f%2==0) and 1 or 0)
    local s=string.format("mode=%d st=%d lives=%d caps=%d p18=%d b_life=%d b_time=%d b_perf=%d",
      sp:read_u32(0x80369B38),sp:read_u32(p+0xd8),sp:read_u16(p+0x88),sp:read_u16(p+0x8a),sp:read_u32(p+0x18),sp:read_u32(0x8036AEE0),sp:read_u32(0x8036B2E4),sp:read_u32(0x8036B2E8))
    if s~=prev or f%600==0 then log:write(string.format("%d depth=%d p98=%d dug=%d chain=%d c124=%d xc=%d ",f,d,sp:read_u32(p+0x98),sp:read_u32(p+0x128),sp:read_u32(p+0x12c),sp:read_u32(p+0x124),sp:read_i16(0x80369EBE))..s.."\n"); prev=s end
    if d>=sp:read_u32(0x80307108) and o.done==0 then o.done=f end
    if o.done>0 and (f-o.done)%60==0 and f-o.done<900 then manager.machine.video:snapshot() end
  end
  if f==NF or (o.done>0 and f-o.done>900) then log:close(); manager.machine:exit() end
  end) if not ok then print("ERR",err) end
end)
