--- Environment Manipulation
-- @module local.environment

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

local environment = {}
local e2lib = require("e2lib")
local eio = require("eio")
local err = require("err")
local hash = require("hash")
local strict = require("strict")

--- create new environment
-- @return environment
function environment.new()
    local env = {}
    local meta = { __index = environment }
    setmetatable(env, meta)
    env.dict = {}
    env.sorted = {}
    return env
end

--- set variable
-- @param env environment
-- @param var key
-- @param val value
-- @return env as passed in the first parameter
function environment.set(env, var, val)
    env.dict[var] = val
    table.insert(env.sorted, var)
    table.sort(env.sorted)
    return env
end

--- return a hash representing the environment
-- @param env environment
function environment.id(env)
    local hc = hash.hash_start()
    for var, val in env:iter() do
        hash.hash_append(hc, string.format("%s=%s", var, val))
    end
    return hash.hash_finish(hc)
end

--- merge environment from merge into env.
-- @param env environment
-- @param merge environment
-- @param override bool: shall vars from merge override vars from env?
-- @return environment as merged from env and merge
function environment.merge(env, merge, override)
    for i, var in ipairs(merge.sorted) do
        if not env.dict[var] then
            table.insert(env.sorted, var)
        end
        if not env.dict[var] or override then
            env.dict[var] = merge.dict[var]
        end
    end
    return env
end

--- iterate over the environment, in alphabetical order
-- @param env environment
function environment.iter(env)
    local index = nil
    local function _iter(t)
        local var
        index, var = next(t, index)
        return var, env.dict[var]
    end
    return _iter, env.sorted
end

--- return a (copy of the) dictionary
-- @param env environment
-- @return a copy of the dictionary representing the environment
function environment.get_dict(env)
    local dict = {}
    for k,v in env:iter() do
        dict[k] = v
    end
    return dict
end

--- Write environment as key=value\n... string to file. File is created or
-- truncated. Value is quoted with e2lib.shquote() so the file can be sourced
-- by a shell.
-- @param env Environment.
-- @param file File name.
-- @return True on success, false on error.
-- @return Error object on failure.
function environment.tofile(env, file)
    local rc, re, e, out

    out = {}
    for var, val in env:iter() do
        table.insert(out, string.format("%s=%s\n", var, e2lib.shquote(val)))
    end

    rc, re = eio.file_write(file, table.concat(out))
    if not rc then
        e = err.new("writing environment script")
        return false, e:cat(re)
    end

    return true
end

local function unittest()
    local function p(...)
        --print(...)
    end

    local e1 = environment.new()
    e1:set("var1.3", "val1.3")
    e1:set("var1.1", "val1.1")
    e1:set("var1.2", "val1.2")
    e1:set("var1.4", "val1.4")
    print(e1:id())
    assert(e1:id() == "84C3CB1BFF877D12F500C05D7B133DA2B8BC0A4A")

    local e2 = environment.new()
    e2:set("var2.3", "val2.3")
    e2:set("var2.1", "val2.1")
    e2:set("var2.2", "val2.2")
    e2:set("var2.4", "val2.4")
    assert(e2:id() == "7E63398D2CA50AE2763042392628E8031AF30B02")

    for var, val in e1:iter() do
        p(var, val)
    end

    for var, val in e2:iter() do
        p(var, val)
    end

    e1:merge(e2)
    assert(e1:id() == "AF0572C5622CD21D3839AEA8D43234F6A67B7BA2")

    for var, val in e1:iter() do
        p(var, val)
    end

    -- check merge without / with override
    local e3 = environment.new()
    e3:set("var", "val3")
    local e4 = environment.new()
    e4:set("var", "val4")
    e3:merge(e4, false)
    for var, val in e3:iter() do
        p(var, val)
    end
    assert(e3:id() == "0728A49396F211F911E69FB929F7FEE715F4F981")

    local e5 = environment.new()
    e5:set("var", "val5")
    e5:merge(e4, true)
    for var, val in e5:iter() do
        p(var, val)
    end
    assert(e5:id() == "404AA226CF94A483FD61878682F8E2759998B197")

    local dict = e5:get_dict()
    assert(dict['var'] == "val4")
end

-- unittest()

return strict.lock(environment)

-- vim:sw=4:sts=4:et:
