local out, st = os.getenv("OB_OUT"), os.getenv("OB_STATE")
local A0=tonumber(os.getenv("OB_A0")); local A1=tonumber(os.getenv("OB_A1"))
local o={f=0, seen={}}
local log=io.open(out..".txt","w")
o.n = emu.add_machine_frame_notifier(function()
  local ok,err=pcall(function()
  o.f=o.f+1
  local P=manager.machine.ioport.ports[":IN1"].fields
  if o.f==2 then manager.machine:load(st); return end
  if o.f==4 then
    local cpu=manager.machine.devices[":maincpu"]
    o.tap=cpu.spaces["program"]:install_write_tap(A0,A1,"w",function(off,data,mask)
      local pc=cpu.state["GENPC"].value; local ra=cpu.state["ra"].value
      log:write(string.format("f%d %08x d=%08x m=%08x pc=%08x ra=%08x\n",o.f,off,data,mask,pc,ra))
    end)
  end
  if o.f>=6 and o.f<200 then P["P1 Button 1"]:set_value((o.f%2==0) and 1 or 0) end
  if o.f>=60 and o.f<70 then P["P1 Left"]:set_value(1) end
  if o.f==70 then P["P1 Left"]:set_value(0) end
  if o.f==250 then log:close(); manager.machine:exit() end
  end) if not ok then print("ERR",err) end
end)
