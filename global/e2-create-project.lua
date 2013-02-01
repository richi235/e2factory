--- e2-create-project command
-- @module global.e2-create-project

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
local cache = require("cache")
local generic_git = require("generic_git")
local err = require("err")
local e2option = require("e2option")
require("buildconfig")

e2lib.init()

local opts, arguments = e2option.parse(arg)
local rc, e = e2lib.read_global_config()
if not rc then
    e2lib.abort(e)
end
e2lib.init2()
local e = err.new("creating project failed")

local config, re = e2lib.get_global_config()
if not config then
    e2lib.abort(e:cat(re))
end
local scache, re = e2lib.setup_cache()
if not scache then
    e2lib.abort(e:cat(re))
end

-- standard global tool setup finished

if e2lib.globals.osenv["E2_LOCAL_TAG"] and e2lib.globals.osenv["E2_LOCAL_BRANCH"] then
    e2lib.globals.local_e2_branch = e2lib.globals.osenv["E2_LOCAL_BRANCH"]
    e2lib.globals.local_e2_tag = e2lib.globals.osenv["E2_LOCAL_TAG"]
elseif e2lib.globals.osenv["E2_LOCAL_TAG"] then
    e2lib.globals.local_e2_branch = "-"
    e2lib.globals.local_e2_tag = e2lib.globals.osenv["E2_LOCAL_TAG"]
elseif e2lib.globals.osenv["E2_LOCAL_BRANCH"] then
    e2lib.globals.local_e2_branch = e2lib.globals.osenv["E2_LOCAL_BRANCH"]
    e2lib.globals.local_e2_tag = "^"
else
    e2lib.globals.local_e2_branch = config.site.e2_branch
    e2lib.globals.local_e2_tag =  config.site.e2_tag
end

if #arguments ~= 1 then
    e2option.usage(1)
end

local sl, re = e2lib.parse_server_location(arguments[1],
e2lib.globals.default_projects_server)
if not sl then
    e2lib.abort(e:cat(re))
end

local p = {}
p.version = buildconfig.GLOBAL_INTERFACE_VERSION[1] -- the project version
p.e2version = string.format("%s %s", e2lib.globals.local_e2_branch,
e2lib.globals.local_e2_tag)
p.server = sl.server				-- the server
p.location = sl.location			-- the project location
p.name = e2lib.basename(sl.location)		-- the project basename
p.server = sl.server				-- the server

-- create the server side structure
local tmpdir = e2lib.mktempdir()
e2lib.chdir(tmpdir)

local version = string.format("%d\n", p.version)
local empty = ""
local files = {
    { filename = "version", content=version },
    { filename = "proj/.keep", content=empty },
    { filename = "git/.keep", content=empty },
    { filename = "files/.keep", content=empty },
    { filename = "cvs/.keep", content=empty },
    { filename = "svn/.keep", content=empty },
}
for _,f in ipairs(files) do
    local dir = e2lib.dirname(f.filename)
    rc, re = e2lib.mkdir(dir, "-p")
    if not rc then
        e2lib.abort(e:cat(re))
    end
    rc, re = e2lib.write_file(f.filename, f.content)
    if not rc then
        e2lib.abort(e:cat(re))
    end
    local sourcefile = string.format("%s/%s", tmpdir, f.filename)
    local flocation = string.format("%s/%s", p.location, f.filename)
    local cache_flags = {}
    rc, re = cache.push_file(scache, sourcefile, p.server, flocation,
    cache_flags)
    if not rc then
        e2lib.abort(e:cat(re))
    end
end
e2lib.chdir("/")
e2lib.rmtempdir(tmpdir)

local tmpdir = e2lib.mktempdir()
e2lib.chdir(tmpdir)

-- create the initial repository on server side
local rlocation = string.format("%s/proj/%s.git", p.location, p.name)
local rc, re = generic_git.git_init_db(scache, p.server, rlocation)
if not rc then
    e2lib.abort(e:cat(re))
end

-- works up to this point

-- create the initial (git) repository
local url = string.format("file://%s/.git", tmpdir)
rc, re = e2lib.git(nil, "init-db")
if not rc then
    e2lib.abort(e:cat(re))
end

local gitignore = e2lib.read_template("gitignore")
if not gitignore then
    e2lib.abort(re)
end
local chroot, re = e2lib.read_template("proj/chroot")
if not chroot then
    e2lib.abort(re)
end
local licences, re = e2lib.read_template("proj/licences")
if not licences then
    e2lib.abort(re)
end
local env, re = e2lib.read_template("proj/env")
if not env then
    e2lib.abort(re)
end
local pconfig, re = e2lib.read_template("proj/config")
if not pconfig then
    e2lib.abort(re)
end
pconfig = pconfig:gsub("<<release_id>>", p.name)
pconfig = pconfig:gsub("<<name>>", p.name)
local name = string.format("%s\n", p.name)
local release_id = string.format("%s\n", p.name) -- use the name for now
local version = string.format("%s\n", p.version)
local e2version = string.format("%s\n", p.e2version)
local syntax = string.format("%s\n", buildconfig.SYNTAX[1])
local empty = ""
local files = {
    { filename = ".e2/.keep", content=empty },
    { filename = "in/.keep", content=empty },
    { filename = "log/.keep", content=empty },
    { filename = "proj/init/.keep", content=empty },
    { filename = "res/.keep", content=empty },
    { filename = "src/.keep", content=empty },
    { filename = "proj/chroot", content=chroot },
    { filename = "proj/licences", content=licences },
    { filename = "proj/env", content=env },
    { filename = "proj/config", content=pconfig },
    { filename = ".e2/syntax", content=syntax },
    { filename = ".e2/e2version", content=e2version },
    { filename = ".gitignore", content=gitignore },
}
for _,f in ipairs(files) do
    local dir = e2lib.dirname(f.filename)
    rc, re = e2lib.mkdir(dir, "-p")
    if not rc then
        e2lib.abort(e:cat(re))
    end
    rc, re = e2lib.write_file(f.filename, f.content)
    if not rc then
        e2lib.abort(e:cat(re))
    end
    rc, re = e2lib.git(nil, "add", f.filename)
    if not rc then
        e2lib.abort(e:cat(re))
    end
end
rc, re = e2lib.write_extension_config(config.site.default_extensions)
if not rc then
    e2lib.abort(e:cat(re))
end
rc, re = e2lib.git(nil, "add", e2lib.globals.extension_config)
if not rc then
    e2lib.abort(e:cat(re))
end
rc, re = e2lib.git(nil, "commit", "-m \"project setup\"")
if not rc then
    e2lib.abort(e:cat(re))
end

local refspec = "master:refs/heads/master"
local rlocation = string.format("%s/proj/%s.git", p.location, p.name)
rc, re = generic_git.git_push(scache, ".git", p.server, rlocation, refspec)
if not rc then
    e2lib.abort(e:cat(re))
end

e2lib.chdir("/")
e2lib.rmtempdir(tmpdir)
e2lib.finish()

-- vim:sw=4:sts=4:et:
