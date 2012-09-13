--[[
   e2factory, the emlix embedded build system

   Copyright (C) 2007-2009 Gordon Hecker <gh@emlix.com>, emlix GmbH
   Copyright (C) 2007-2009 Oskar Schirmer <os@emlix.com>, emlix GmbH
   Copyright (C) 2007-2008 Felix Winkelmann, emlix GmbH

   For more information have a look at http://www.e2factory.org

   e2factory is a registered trademark by emlix GmbH.

   This file is part of e2factory, the emlix embedded build system.

   e2factory is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

local e2lib = require("e2lib")
local e2option = require("e2option")
require("buildconfig")
require("e2util")

e2lib.init()

e2option.documentation = [[
usage: e2 OPTION ...
e2 COMMAND ARGUMENT ...

"e2" is a wrapper script for invoking e2 commands. Any e2 commands called will
be redirected either to the project-local or the global installation, depend‐
ing on whether the invocation took place inside or outside a project tree.
]]

e2option.flag("prefix", "print installation prefix",
function()
    print(buildconfig.PREFIX)
    os.exit(0)
end)

local root = e2lib.locate_project_root()

local e2call = {}
e2call.basename = e2lib.basename(arg[0])

local function quoteargs(argstr) -- probably has to do escaping?
    if #argstr == 0 then return ""
    else return "'" .. argstr .. "'" end
end

if e2call.basename == "e2" and arg[1] and string.sub(arg[1], 1, 1) ~= "-" then
    e2call.toolname = "e2-" .. arg[1]
    e2call.arg_string = quoteargs(table.concat(arg, "' '", 2))
elseif e2call.basename == "e2" then
    e2call.toolname = "e2"
    local opts = e2option.parse(arg)
    if #opts == 0 then
        e2option.usage()
    end
    e2lib.finish(0)
else
    e2call.toolname = e2call.basename
    e2call.arg_string = quoteargs(table.concat(arg, "' '", 1))
end

e2call.globaltool = buildconfig.TOOLDIR .. "/" .. e2call.toolname
if root then
    e2call.localtool = root .. "/.e2/bin/" .. e2call.toolname
end

local env, cmd
if e2util.stat(e2call.globaltool) then
    e2call.tool = e2call.globaltool
    env = string.format("LUA_PATH='%s/?.lua' LUA_CPATH='%s/?.so'",
    buildconfig.LIBDIR, buildconfig.LIBDIR)
    cmd = string.format("%s %s %s %s", env, buildconfig.LUA, e2call.tool,
        e2call.arg_string)
elseif not root then
    e2lib.abort(e2call.toolname ..
    " is not a global tool and we're not in a project environment")
elseif root and e2util.stat(e2call.localtool) then
    e2call.tool = e2call.localtool
    -- Search for .lc files, the local e2 may be of an older version
    env = "LUA_PATH='" .. root .. "/.e2/lib/e2/?.lc;" ..
    root .. "/.e2/lib/e2/?.lua' " ..
    "LUA_CPATH=" .. root .. "/.e2/lib/e2/?.so"
    cmd = env .. " " ..
    root .. "/.e2/bin/e2-lua " ..
    e2call.tool .. " " .. e2call.arg_string
else
    e2lib.abort(e2call.toolname .. " is neither local nor global tool")
end

local function table_log(loglevel, t)
    e2lib.log(loglevel, tostring(t))
    for k,v in pairs(t) do
        e2lib.log(loglevel, k .. "\t->\t" .. v)
    end
end

table_log(3, e2call)

e2lib.log(3, "calling " .. e2call.tool)
e2lib.log(4, cmd)
local rc = os.execute(cmd)
e2lib.finish(rc/256)

-- vim:sw=4:sts=4:et: