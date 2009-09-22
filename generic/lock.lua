module("lock",package.seeall)

function new()
  local lock = {

    locks = {},

    lock = function(l, dir)
      local e = new_error("locking failed")
      rc, re = e2lib.mkdir(dir)
      if not rc then
	return false, e:cat(re)
      end
      table.insert(l.locks, dir)
      return true
    end,

    unlock = function(l, dir)
      local e = new_error("unlocking failed")
      for i,x in ipairs(l.locks) do
	if dir == x then
	  table.remove(l.locks, i)
	  rc, re = e2lib.rmdir(dir)
	  if not rc then
	    return false, e:cat(re)
	  end
	end
      end
      return true, nil
    end,

    cleanup = function(l)
      while #l.locks > 0 do
        l:unlock(l.locks[1])
      end
    end,
  }

  return lock
end

--[[
local test=false
if test then
  -- some dummy functions to test without context...
  function new_error(x)
    return true
  end
  e2lib = {}
  e2lib.mkdir = function(x)
    print("mkdir " .. x)
    return true
  end
  e2lib.rmdir = function(x)
    print("rmdir " .. x)
    return true
  end

  l = new()

  l:lock("/tmp/foo1")
  l:lock("/tmp/foo2")
  l:lock("/tmp/foo3")
  l:unlock("/tmp/foo2")
  l:cleanup()
end
]]
