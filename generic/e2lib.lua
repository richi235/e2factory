--- Utility and Helper Library
-- @module generic.e2lib

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

-- Before we do anything else, lock the global environment and default
-- packages to catch bugs
local strict = require("strict")
strict.lock(_G)
for k,_ in pairs(_G) do
    if type(_G[k]) == "table" and _G[k] ~= _G then
        strict.lock(_G[k])
    end
end

local e2lib = {}

-- Multiple modules below require e2lib themselves. This leads to a module
-- loading loop.
--
-- We solve this problem by registering e2lib as loaded, and supply the empty
-- table that we are going to fill later (after the require block below).
package.loaded["e2lib"] = e2lib

require("buildconfig")
require("e2util")
local lock = require("lock")
local err = require("err")
local plugin = require("plugin")
local tools = require("tools")
local cache = require("cache")
local luafile = require("luafile")

-- Module-level global variables
--
--   globals.interactive -> BOOL
--
--     True, when lua was started in interactive mode (either by giving
--     the "-i" option or by starting lua and loading the e2 files
--     manually).
local global_config = false

e2lib.globals = {
    logflags = {
        { "v1", true },    -- minimal
        { "v2", true },    -- verbose
        { "v3", false },   -- verbose-build
        { "v4", false }    -- tooldebug
    },
    log_debug = false,
    debug = false,
    playground = false,
    interactive = arg and (arg[ -1 ] == "-i"),
    -- variables initialized in init()
    username = nil,
    homedir = nil,
    hostname = nil,
    termwidth = 72,
    env = {},
    last_output = false,
    tmpdirs = {},
    tmpfiles = {},
    default_projects_server = "projects",
    default_project_version = "2",
    local_e2_branch = nil,
    local_e2_tag = nil,
    --- command line arguments that influence global settings are stored here
    -- @class table
    -- @name cmdline
    cmdline = {},
    template_path = string.format("%s/templates", buildconfig.SYSCONFDIR),
    extension_config = ".e2/extensions",
    e2config = ".e2/e2config",
    global_interface_version_file = ".e2/global-version",
    lock = nil,
    logrotate = 5,   -- configurable via config.log.logrotate
    _version = "e2factory, the emlix embedded build system, version " ..
    buildconfig.VERSION,
    _licence = [[
e2factory is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.]],
    debuglogfile = nil,
    debuglogfilebuffer = {},
}

--- Interrupt handling.
--
-- e2util sets up a SIGINT handler that calls back into this function.
function e2lib.interrupt_hook()
    e2lib.abort("*interrupted by user*")
end

--- Make sure the environment variables inside the globals table are
-- initialized properly, and abort otherwise.
-- This function always succeeds or aborts.
function e2lib.init()
    e2lib.log(4, "e2lib.init()")
    -- DEBUG: change to "cr" to log return from function
    debug.sethook(e2lib.tracer, "c")

    e2lib.globals.warn_category = {
        WDEFAULT = false,
        WDEPRECATED = false,
        WOTHER = true,
        WPOLICY = false,
        WHINT = false,
    }

    -- get environment variables
    local getenv = {
        { name = "HOME", required = true },
        { name = "USER", required = true },
        { name = "EDITOR", required = false, default = "vi" },
        { name = "TERM", required = false, default = "linux" },
        { name = "E2_CONFIG", required = false },
        { name = "TMPDIR", required = false, default = "/tmp" },
        { name = "E2TMPDIR", required = false },
        { name = "COLUMNS", required = false, default = "72" },
        { name = "E2_SSH", required = false },
        { name = "E2_LOCAL_BRANCH", required = false },
        { name = "E2_LOCAL_TAG", required = false },
    }

    local osenv = {}
    for _, var in pairs(getenv) do
        var.val = os.getenv(var.name)
        if var.required and not var.val then
            e2lib.abort(string.format("%s is not set in the environment", var.name))
        end
        if var.default and not var.val then
            var.val = var.default
        end
        osenv[var.name] = var.val
    end
    e2lib.globals.osenv = osenv

    -- assign some frequently used environment variables
    e2lib.globals.homedir = e2lib.globals.osenv["HOME"]
    e2lib.globals.username = e2lib.globals.osenv["USER"]
    e2lib.globals.terminal = e2lib.globals.osenv["TERM"]
    if e2lib.globals.osenv["E2TMPDIR"] then
        e2lib.globals.tmpdir = e2lib.globals.osenv["E2TMPDIR"]
    else
        e2lib.globals.tmpdir = e2lib.globals.osenv["TMPDIR"]
    end

    -- get the host name
    local hostname = io.popen("hostname")
    if not hostname then
        e2lib.abort("execution of \"hostname\" failed")
    end

    e2lib.globals.hostname = hostname:read("*a")
    hostname:close()
    if not e2lib.globals.hostname then
        e2lib.abort("hostname ist not set")
    end

    e2lib.globals.lock = lock.new()
end

--- init2.
function e2lib.init2()
    local rc, re
    local e = err.new("initializing globals (step2)")

    -- get the global configuration
    local config = e2lib.get_global_config()

    -- honour tool customizations from the config file
    if config.tools then
        for k,v in pairs(config.tools) do
            tools.set_tool(k, v.name, v.flags)
        end
    end

    -- handle E2_SSH environment setting
    local ssh = nil
    ssh  = e2lib.globals.osenv["E2_SSH"]
    if ssh then
        e2lib.log(3, string.format(
        "using ssh command from the E2_SSH environment variable: %s", ssh))
        tools.set_tool("ssh", ssh)
    end

    -- initialize the tools library after resetting tools
    local rc, re = tools.init()
    if not rc then
        e2lib.abort(e:cat(re))
    end

    -- get host system architecture
    local host_system_arch, re = e2lib.get_sys_arch()
    if not host_system_arch then
        e2lib.abort(e:cat(re))
    end
end

--- function call tracer
-- @param event string: type of event
-- @param line line number of event (unused)
function e2lib.tracer(event, line)
    local ftbl = debug.getinfo(2)
    if ftbl == nil or ftbl.name == nil then
        return
    end

    -- approximate module name, not always accurate but good enough
    local module
    if ftbl.source == nil or ftbl.source == "=[C]" then
        module = "C."
        -- DEBUG: comment this to see all C calls.
        return
    else
        module = string.match(ftbl.source, "(%w+%.)lua$")
        if module == nil then
            module = "<unknown module>."
            -- DEBUG: comment this to see all unknown calls.
            return
        end
    end

    if event == "call" then
        local out = string.format("%s%s(", module, ftbl.name)
        for lo = 1, 10 do
            local name, value = debug.getlocal(2, lo)
            if name == nil or name == "(*temporary)" then
                break
            end
            if lo > 1 then
                out = out .. ", "
            end

            if type(value) == "string" then
                local isbinary = false

                -- check the first 40 bytes for values common in binary data
                for _,v in ipairs({string.byte(value, 1, 41)}) do
                    if (v >= 0 and v < 9) or (v > 13 and v < 32) then
                        isbinary = true
                        break
                    end
                end

                if isbinary then
                    out = string.format("%s%s=<binary data>", out, name)
                else
                    local svalue = string.sub(value, 0, 800)
                    if string.len(value) > string.len(svalue) then
                        svalue = svalue .. "..."
                    end

                    out = string.format("%s%s=\"%s\"", out, name, svalue)
                end
            else
                out = string.format("%s%s=%s", out, name, tostring(value))
            end

        end
        out = out .. ")"
        e2lib.log(4, out)
    else
        e2lib.log(4, string.format("< %s%s", module, ftbl.name))
    end
end

--- Print a warning, composed by concatenating all arguments to a string.
-- @param ... any number of strings
-- @return nil
function e2lib.warn(category, ...)
    local msg = table.concat({...})
    return e2lib.warnf(category, "%s", msg)
end

--- Print a warning.
-- @param format string: a format string
-- @param ... arguments required for the format string
-- @return nil
function e2lib.warnf(category, format, ...)
    if (format:len() == 0) or (not format) then
        e2lib.bomb("calling warnf() with zero length format")
    end
    if type(e2lib.globals.warn_category[category]) ~= "boolean" then
        e2lib.bomb("calling warnf() with invalid warning category")
    end
    if e2lib.globals.warn_category[category] == true then
        local prefix = "Warning: "
        if e2lib.globals.log_debug then
            prefix = string.format("Warning [%s]: ", category)
        end
        e2lib.log(1, prefix .. string.format(format, ...))
    end
    return nil
end

--- Exit, cleaning up temporary files and directories.
-- Return code is '1' and cannot be overwritten.
-- This function takes any number of strings or an error object as arguments.
-- Please pass error objects to this function in the future.
-- @param ... an error object, or any number of strings
-- @return This function does not return
function e2lib.abort(...)
    local t = { ... }
    local e = t[1]
    if type(e) == "table" and e.print then
        e:print()
    else
        local msg = table.concat(t)
        if msg:len() == 0 then
            e2lib.bomb("calling abort() with zero length message")
        end
        e2lib.log(1, "Error: " .. msg)
    end
    e2lib.finish(1)
end

--- Write a message about an internal error, including a traceback
-- and exit. Return code is 32.
-- @param ... any number of strings.
-- @return This function does not return.
function e2lib.bomb(...)
    local msg = table.concat({...})
    io.stderr:write(
    "Internal Error:\n" ..
    msg .. "\n" ..
    "\n" ..
    "You encountered an internal error in the e2 tool.\n" ..
    "Please send a description of the problem, including the\n" ..
    "stacktrace below to <bugs@e2factory.org>.\n" ..
    "If possible include a copy of the project in the bug report.\n" ..
    "\n" ..
    "Thank you - the e2factory team.\n")
    io.stderr:write(debug.traceback().."\n")
    os.exit(32)
end

--- Set E2_CONFIG in the environment to file. Also sets commandline option.
-- @param file Config file name (string).
function e2lib.sete2config(file)
    e2util.setenv("E2_CONFIG", file, 1)
    e2lib.globals.osenv["E2_CONFIG"] = file
    e2lib.globals.cmdline["e2-config"] = file
end

--- Enable or disable logging for level.
-- @param level number: loglevel
-- @param value bool
-- @return nil
function e2lib.setlog(level, value)
    e2lib.globals.logflags[level][2] = value
end

--- Get logging setting for level
-- @param level number: loglevel
-- @return bool
function e2lib.getlog(level)
    return e2lib.globals.logflags[level][2]
end

--- Return highest loglevel that is enabled.
-- @return number
function e2lib.maxloglevel()
    local level = 0
    for i = 1, 4 do
        if e2lib.getlog(i) then level = i end
    end
    return level
end

--- get log flags for calling subtools with the same log settings
-- @return string: a string holding command line flags
function e2lib.getlogflags()
    local logflags = ""
    if e2lib.getlog(1) then
        logflags = "--v1"
    end
    if e2lib.getlog(2) then
        logflags = logflags .. " --v2"
    end
    if e2lib.getlog(3) then
        logflags = logflags .. " --v3"
    end
    if e2lib.getlog(4) then
        logflags = logflags .. " --v4"
    end
    if e2lib.globals.log_debug then
        logflags = logflags .. " --log-debug"
    end
    return " " .. logflags
end

--- log to the debug logfile, and log to console if getlog(level)
-- @param level number: loglevel
-- @param format string: format string
-- @param ... additional parameters to pass to string.format
-- @return nil
function e2lib.logf(level, format, ...)
    if not format then
        e2lib.bomb("calling log() without format string")
    end
    local msg = string.format(format, ...)
    return e2lib.log(level, msg)
end

--- log to the debug logfile, and log to console if getlog(level)
-- is true
-- @param level number: loglevel
-- @param msg string: log message
function e2lib.log(level, msg)
    if level < 1 or level > 4 then
        e2lib.bomb("invalid log level")
    end
    if not msg then
        e2lib.bomb("calling log() without log message")
    end
    local log_prefix = "[" .. level .. "] "
    -- remove end of line if it exists
    if msg:match("\n$") then
        msg = msg:sub(1, msg:len() - 1)
    end

    if e2lib.globals.debuglogfile then

        -- write out buffered messages first
        for _,m in ipairs(e2lib.globals.debuglogfilebuffer) do
            e2lib.globals.debuglogfile:write(m)
        end
        e2lib.globals.debuglogfilebuffer = {}

        e2lib.globals.debuglogfile:write(log_prefix .. msg .. "\n")
        e2lib.globals.debuglogfile:flush()
    else
        table.insert(e2lib.globals.debuglogfilebuffer, log_prefix .. msg .. "\n")
    end
    if e2lib.getlog(level) then
        if e2lib.globals.log_debug then
            io.stderr:write(log_prefix)
        end
        io.stderr:write(msg .. "\n")
    end
end

--- Rotate log file.
function e2lib.rotate_log(file)
    local e = err.new("rotating logfile: %s", file)
    local rc, re
    local logdir = e2lib.dirname(file)
    local logfile = e2lib.basename(file)
    local dir = e2util.directory(logdir, false)
    if not dir then
        return false, e:cat(string.format("%s: can't read directory", dir))
    end
    local files = {}
    for _,f in ipairs(dir) do
        local match = f:match(string.format("%s.[0-9]+", logfile))
        if match then
            table.insert(files, 1, match)
        end
    end
    -- sort in reverse order
    local function comp(a, b)
        local na = a:match(string.format("%s.([0-9]+)", logfile))
        local nb = b:match(string.format("%s.([0-9]+)", logfile))
        return tonumber(na) > tonumber(nb)
    end
    table.sort(files, comp)
    for _,f in ipairs(files) do
        local n = f:match(string.format("%s.([0-9]+)", logfile))
        if n then
            n = tonumber(n)
            if n >= e2lib.globals.logrotate - 1 then
                local del = string.format("%s/%s.%d", logdir, logfile, n)
                rc, re = e2lib.rm(del)
                if not rc then
                    return false, e:cat(re)
                end
            else
                local src = string.format("%s/%s.%d", logdir, logfile, n)
                local dst = string.format("%s/%s.%d", logdir, logfile, n + 1)
                rc, re = e2lib.mv(src, dst)
                if not rc then
                    return false, e:cat(re)
                end
            end
        end
    end
    local src = file
    local dst = string.format("%s/%s.0", logdir, logfile)
    if e2lib.isfile(src) then
        rc, re = e2lib.mv(src, dst)
        if not rc then
            return false, e:cat(re)
        end
    end
    return true, nil
end

--- Clean up temporary files and directories, shut down plugins.
function e2lib.cleanup()
    local rc, re = plugin.exit_plugins()
    if not rc then
        e2lib.logf(1, "deinitializing plugins failed (ignoring)")
    end
    e2lib.rmtempdirs()
    e2lib.rmtempfiles()
    if e2lib.globals.lock then
        e2lib.globals.lock:cleanup()
    end
end

--- exit from the tool, cleaning up temporary files and directories
-- @param rc number: return code (optional, defaults to 0)
-- @return This function does not return.
function e2lib.finish(returncode)
    if not returncode then
        returncode = 0
    end
    e2lib.cleanup()
    os.exit(returncode)
end

--- Returns the "directory" part of a path
-- @param path string: a path with components separated by slashes.
-- @return all but the last component of the path, or "." if none could be found.
function e2lib.dirname(path)
    assert(type(path) == "string")

    local s, e, dir = string.find(path, "^(.*)/[^/]+[/]*$")
    if dir == "" then
        return "/"
    end

    return dir or "."
end

--- Returns the "filename" part of a path.
-- @param path string: a path with components separated by slashes.
-- @return returns the last (right-most) component of a path, or the path
-- itself if no component could be found.
function e2lib.basename(path)
    assert(type(path) == "string")

    local s, e, base = string.find(path, "^.*/([^/]+)[/]*$")
    if not base then
        base = path
    end

    return base
end

--- Return a file path joined from the supplied components.
-- This function is modelled after Python's os.path.join, but missing some
-- features and handles edge cases slightly different. It only knows about
-- UNIX-style forward slash separators. Joining an empty string at the end will
-- result in a trailing separator to be added, following Python's behaviour.
-- The function does not fail under normal circumstances.
--
-- @param p1 A potentially empty path component (string). This argument is
--           mandatory.
-- @param p2 A potentially empty, optional path component (string).
-- @param ... Further path components, following the same rule as "p2".
-- @return A joined path (string), which may be empty.
function e2lib.join(p1, p2, ...)
	assert(type(p1) == "string")
	assert(p2 == nil or type(p2) == "string")

	local sep = "/"
	local args = {p1, p2, ...}
	local buildpath = ""
	local sepnext = false

	for _,component in ipairs(args) do
		assert(type(component) == "string")

		if sepnext then
			-- If the previous or next component already
			-- has a separator in the right place, we don't
			-- need to add one. We do however not go to the
			-- trouble removing multiple separators.
			if buildpath:sub(-1) == sep or
				component:sub(1) == sep then
				-- do nothing
			else
				buildpath = buildpath .. sep
			end
		end

		buildpath = buildpath .. component

		if component:len() > 0 then
			sepnext = true
		else
			sepnext = false
		end
	end

	return buildpath
end

--- Checks whether file matches some usual backup file names left behind by vi
-- and emacs.
function e2lib.is_backup_file(path)
    return string.find(path, "~$") or string.find(path, "^#.*#$")
end

function e2lib.chomp(str, chr)
    local chr = chr or "/"
    if string.sub(str, -1, -1) == chr then
        return string.sub(str, 1, -2)
    else
        return str
    end
end

--- quotes a string so it can be safely passed to a shell
-- @param str string to quote
-- @return quoted string
function e2lib.shquote(str)
    assert(type(str) == "string")

    str = string.gsub(str, "'", "'\"'\"'")
    return "'"..str.."'"
end

--- Determines the type of an archive.
-- Returns an empty string for tar archives, "--gzip" for
-- gzip files, "--bzip2" for bzip2 files,
-- and "zip" for zip archives.
-- @param path Path to an archive file (string).
-- @return False on error, otherwise a string as described above.
-- @return An error object on failure.
function e2lib.tartype(path)
    local e = err.new("Could not determine archive type")
    local c

    local f, re = io.open(path, "r")
    if not f then
        return false, e:append(": %s", re)
    end

    local d = f:read(512)
    if not d then
        return false, e:append(": read error")
    end

    f:close()

    local l = string.len(d)

    if l > 261 and string.sub(d, 258, 262) == "ustar" then
        c = ""
    elseif l > 1 and string.sub(d, 1, 2) == "\031\139" then
        c = "--gzip"
    elseif l > 2 and string.sub(d, 1, 3) == "BZh" then
        c = "--bzip2"
    elseif l > 3 and string.sub(d, 1, 4) == "PK\003\004" then
        c = "zip"
    else
        return false, e:append(": could not determine type")
    end

    return c
end

--- translate filename suffixes to valid tartypes for e2-su-2.2
-- @param filename string: filename
-- @return string: tartype, or nil on failure
-- @return an error object on failure
function e2lib.tartype_by_suffix(filename)
    local tartype
    if filename:match("tgz$") or filename:match("tar.gz$") then
        tartype = "tar.gz"
    elseif filename:match("tar.bz2$") then
        tartype = "tar.bz2"
    elseif filename:match("tar$") then
        tartype = "tar"
    else
        e = err.new("unknown suffix for filename: %s", filename)
        return false, e
    end
    return tartype
end

--- Generates the command to unpack an archive file.
-- @param physpath Current location and filename to be unpacked later.
-- @param virtpath Location and name of the file at the time of unpacking.
-- @param destdir Path where the unpacked files shall be put.
-- @return Tool name (string), or false on error.
-- @return Argument vector table for the tool, or an error object on failure.
function e2lib.howtounpack(physpath, virtpath, destdir)
    local tool
    local toolargv = {}
    local rc, re = e2lib.tartype(physpath)

    if not rc then
        return false, re
    end

    if rc == "zip" then
        tool = "unzip"
        table.insert(toolargv, virtpath)
        table.insert(toolargv, "-d")
        table.insert(toolargv, destdir)
    else
        tool = "tar"
        table.insert(toolargv, "-C")
        table.insert(toolargv, destdir)
        if rc ~= "" then
            table.insert(toolargv, rc)
        end
        table.insert(toolargv, "-xf")
        table.insert(toolargv, virtpath)
    end

    return tool, toolargv
end

--- Read the first line from the given file and return it.
-- @param path Path to file (string).
-- @return The first line or nil on error.
-- @return Error object on failure.
function e2lib.read_line(path)
    local f, msg = io.open(path)
    if not f then
        return nil, err.new("%s", msg)
    end
    local l, msg = f:read("*l")
    if not l then
        return nil, err.new("%s", msg)
    end
    f:close()
    return l
end

-- Iterators
--
-- These iterators are convenience functions for use in "for" statements.
--
--   read_configuration(PATH)
--
--     Returns the successive non-empty lines contained in the file PATH.
--     Comments (of the form "# ...") are removed.
function e2lib.read_configuration(p)
    if e2util.exists(p) then
        local function nextline(s)
            while true do
                local ln = s:read("*l")
                if not ln then
                    s:close()
                    return nil
                elseif not string.find(ln, "^%s*#") and string.find(ln, "%S") then
                    local s = string.find(ln, "#.*")
                    if s then return string.sub(ln, 1, s - 1)
                    else return ln end
                end
            end
        end
        return nextline, io.open(p)
    else
        e2lib.abort("no such file: " .. p)
    end
end

--- read the global config file
-- local tools call this function inside collect_project_info()
-- global tools must call this function after parsing command line options
-- @param e2_config_file string: config file path (optional)
-- @return bool
-- @return error string on error
function e2lib.read_global_config(e2_config_file)
    local cf
    if type(e2lib.globals.cmdline["e2-config"]) == "string" then
        cf = e2lib.globals.cmdline["e2-config"]
    elseif type(e2lib.globals.osenv["E2_CONFIG"]) == "string" then
        cf = e2lib.globals.osenv["E2_CONFIG"]
    end
    
    local cf_path
    if cf then
        cf_path = { cf }
    elseif e2_config_file then
        cf_path = { e2_config_file }
    else
        cf_path = {
            -- this is ordered by priority
            string.format("%s/.e2/e2.conf-%s.%s.%s", e2lib.globals.homedir,
            buildconfig.MAJOR, buildconfig.MINOR, buildconfig.PATCHLEVEL),
            string.format("%s/.e2/e2.conf-%s.%s", e2lib.globals.homedir, buildconfig.MAJOR,
            buildconfig.MINOR),
            string.format("%s/.e2/e2.conf", e2lib.globals.homedir),
            string.format("%s/e2.conf-%s.%s.%s", buildconfig.SYSCONFDIR,
            buildconfig.MAJOR, buildconfig.MINOR, buildconfig.PATCHLEVEL),
            string.format("%s/e2.conf-%s.%s", buildconfig.SYSCONFDIR,
            buildconfig.MAJOR, buildconfig.MINOR),
            string.format("%s/e2.conf", buildconfig.SYSCONFDIR),
        }
    end
    -- use ipairs to keep the list entries ordered
    for _,path in ipairs(cf_path) do
        local c = {}
        c.config = function(x)
            c.data = x
        end
        e2lib.log(4, string.format("reading global config file: %s", path))
        local rc = e2util.exists(path)
        if rc then
            e2lib.log(3, string.format("using global config file: %s", path))
            local rc, e = e2lib.dofile_protected(path, c, true)
            if not rc then
                return nil, e
            end
            if not c.data then
                return false, "invalid configuration"
            end
            global_config = c.data
            e2lib.use_global_config()
            return true, nil
        else
            e2lib.log(4, string.format(
            "global config file does not exist: %s", path))
        end
    end
    return false, "no config file available"
end

--- Create a extensions config.
function e2lib.write_extension_config(extensions)
    local e = err.new("writing extensions config: %s", e2lib.globals.extension_config)
    local f, re = io.open(e2lib.globals.extension_config, "w")
    if not f then
        return false, e:cat(re)
    end
    f:write(string.format("extensions {\n"))
    for _,ex in ipairs(extensions) do
        f:write(string.format("  {\n"))
        for k,v in pairs(ex) do
            f:write(string.format("    %s=\"%s\",\n", k, v))
        end
        f:write(string.format("  },\n"))
    end
    f:write(string.format("}\n"))
    f:close()
    return true, nil
end

--- read the local extension configuration
-- This function must run while being located in the projects root directory
-- @return the extension configuration table
-- @return an error object on failure
function e2lib.read_extension_config()
    local e = err.new("reading extension config file: %s",
    e2lib.globals.extension_config)
    local rc = e2util.exists(e2lib.globals.extension_config)
    if not rc then
        return false, e:append("config file does not exist")
    end
    e2lib.logf(3, "reading extension file: %s", e2lib.globals.extension_config)
    local c = {}
    c.extensions = function(x)
        c.data = x
    end
    local rc, re = e2lib.dofile_protected(e2lib.globals.extension_config, c, true)
    if not rc then
        return false, e:cat(re)
    end
    local extension = c.data
    if not extension then
        return false, e:append("invalid extension configuration")
    end
    return extension, nil
end

--- use the global parameters from the global configuration
-- this function always succeeds or aborts
-- @return nothing
function e2lib.use_global_config()

    -- check if type(x) == t, and abort if not.
    local function assert_type(x, d, t1)
        local t2 = type(x)
        if t1 ~= t2 then
            e2lib.abort(
            string.format("configuration error: %s (expected %s got %s)", d, t1, t2))
        end
    end

    local config = global_config
    if not config then
        e2lib.abort("global config not available")
    end
    if config.log then
        assert_type(config.log, "config.log", "table")
        if config.log.logrotate then
            assert_type(config.log.logrotate, "config.log.logrotate", "number")
            e2lib.globals.logrotate = config.log.logrotate
        end
    end
    assert_type(config.site, "config.site", "table")
    assert_type(config.site.e2_branch, "config.site.e2_branch", "string")
    assert_type(config.site.e2_tag, "config.site.e2_tag", "string")
    assert_type(config.site.e2_server, "config.site.e2_server", "string")
    assert_type(config.site.e2_base, "config.site.e2_base", "string")
    assert_type(config.site.default_extensions, "config.site.default_extensions", "table")
end

--- get the global configuration
-- this function always succeeds or aborts
-- @return the global configuration
function e2lib.get_global_config()
    local config = global_config
    if not config then
        e2lib.abort("global config not available")
    end
    return config
end

--- Successively returns the files in the directory.
-- @param p Directory path (string).
-- @param dotfiles If true, also return files starting with a '.'. Optional.
-- @param noerror If true, do not call e2lib.abort on error, but pretend the
-- directory is empty. Optional.
-- @return Iterator function.
-- @return dir table.
function e2lib.directory(p, dotfiles, noerror)
    local dir = e2util.directory(p, dotfiles)
    if not dir then
        if noerror then
            dir = {}
        else
            e2lib.abort("directory `", p, "' does not exist")
        end
    end
    table.sort(dir)
    local i = 1
    local function nextfile(s)
        if i > #s then
            return nil
        else
            local j = i
            i = i + 1
            return s[ j ]
        end
    end
    return nextfile, dir
end

--- callcmd: call a command, connecting
--  stdin, stdout, stderr to luafile objects.
function e2lib.callcmd(infile, outfile, errfile, cmd)
    -- redirect stdin
    io.stdin:close()
    luafile.dup2(infile:fileno(), 0)
    -- redirect stdout
    io.stdout:close()
    luafile.dup2(outfile:fileno(), 1)
    -- redirect stderr
    io.stderr:close()
    luafile.dup2(errfile:fileno(), 2)
    -- run the command
    local rc = os.execute(cmd)
    return (rc/256)
end

--- callcmd_redirect: call a command with
--  stdin redirected from /dev/null
--  stdout/stderr redirected to a luafile object.
function e2lib.callcmd_redirect(cmd, out)
    local devnull, pid, rc
    devnull = luafile.open("/dev/null", "r")
    e2lib.log(3, "+ " .. cmd)
    pid = e2util.fork()
    if pid == 0 then
        rc = e2lib.callcmd(devnull, out, out, cmd)
        os.exit(rc)
    else
        rc = e2util.wait(pid)
        luafile.close(devnull)
        return rc
    end
end

--- callcmd_pipe: call several commands in a pipe.
--  cmds is a table of unix commands
--  redirect endpoints to /dev/null, unless given
--  return nil on success, descriptive string on error
function e2lib.callcmd_pipe(cmds, infile, outfile)
    local i = infile or luafile.open("/dev/null", "r")
    local c = #cmds
    local rc = nil
    local rcs = {}
    local pids = {}
    local ers = {}
    for n = 1, c do
        local o, pr, fr, er, ew
        pr, er, ew = luafile.pipe()
        if not pr then e2lib.abort("failed to open pipe (error)") end
        if n < c then
            pr, fr, o = luafile.pipe()
            if not pr then e2lib.abort("failed to open pipe") end
        else
            o = outfile or ew
        end
        e2lib.log(3, "+ " .. cmds[n])
        local pid = e2util.fork()
        if pid == 0 then
            if n < c then fr:close() end
            er:close()
            rc = e2lib.callcmd(i, o, ew, cmds[n])
            os.exit(rc)
        end
        pids[pid] = n
        e2util.unblock(er:fileno())
        ers[n] = er
        ew:close()
        if n < c then o:close() end
        if n > 1 or not infile then i:close() end
        i = fr
    end
    while c > 0 do
        local fds = {}
        local ifd = {}
        for i, f in pairs(ers) do
            local n = f:fileno()
            table.insert(fds, n)
            ifd[n] = i
        end
        local i, r = e2util.poll(-1, fds)
        if i <= 0 then e2lib.abort("fatal poll abort " .. tostring(i)) end
        i = ifd[fds[i]]
        if r then
            local x
            repeat
                x = ers[i]:readline()
                if x then
                    e2lib.log(3, x)
                end
            until not x
        else
            ers[i]:close()
            ers[i] = nil
            c = c - 1
        end
    end
    c = #cmds
    while c > 0 do
        local r, p = e2util.wait(-1)
        if not r then e2lib.abort(p) end
        local n = pids[p]
        if n then
            if r ~= 0 then rc = rc or r end
            rcs[n] = r
            pids[p] = nil
            c = c - 1
        end
    end
    return rc and "failed to execute commands in a pipe, exit codes are: "
    .. table.concat(rcs, ", ")
end

--- call a command with stdin redirected from /dev/null, stdout/stderr
-- captured via a pipe
-- the capture function is called for every chunk of output that
-- is captured from the pipe.
-- @return unknown
function e2lib.callcmd_capture(cmd, capture)
    local rc, oread, owrite, devnull, pid
    local function autocapture(...)
        local msg = table.concat({...})
        e2lib.log(3, msg)
        e2lib.globals.last_output = msg
    end
    e2lib.globals.last_output = false
    capture = capture or autocapture
    rc, oread, owrite = luafile.pipe()
    owrite:setlinebuf()
    oread:setlinebuf()
    devnull = luafile.open("/dev/null", "r")
    e2lib.log(4, "+ " .. cmd)
    pid = e2util.fork()
    if pid == 0 then
        oread:close()
        rc = e2lib.callcmd(devnull, owrite, owrite, cmd)
        os.exit(rc)
    else
        owrite:close()
        --log("capturing...")
        while not oread:eof() do
            local x = oread:readline()
            if x then
                --print("read: '" .. x .. "'")
                capture(x)
            end
        end
        oread:close()
        rc = e2util.wait(pid)
        luafile.close(devnull)
        --log("capturing done...")
        --log("exit status was " .. rc)
    end
    return rc
end

--- call a command, log its output to a loglevel, catch the last line of
-- output and return it in addition to the commands return code
-- @param cmd string: the command
-- @param loglevel number: loglevel (optional, defaults to 3)
-- @return number: the return code
-- @return string: the program output, or nil
function e2lib.callcmd_log(cmd, loglevel)
    local e = ""
    if not loglevel then
        loglevel = 3
    end
    local function logto(output)
        e2lib.log(loglevel, output)
        e = e .. output
    end
    local rc = e2lib.callcmd_capture(cmd, logto)
    return rc, e
end

--- Protected execution of Lua code.
-- Runs the code in the Lua file at path with a restricted global environment.
-- gtable contains a table with the initial global environment. If allownewdefs 
-- is given and true, then the code may define new global variables.
-- This function aborts on error.
-- XXX: This looks like a more restricted version of dofile2 with problematic
-- error handling. Merge the two and fix usage.
-- @param path Filename to load lua code from (string).
-- @param gtable Environment (table) that is used instead of the global _G.
-- @param allownewdefs Allow adding new definitions to gtable (boolean).
-- @return True on success.
-- @see dofile2
function e2lib.dofile_protected(path, gtable, allownewdefs)
    local chunk, msg = loadfile(path)
    if not chunk then
        return false, msg
    end
    local t = gtable
    -- t._G = t
    local function checkread(t, k)
        local x = rawget(t, k)
        if x then return x
        else e2lib.abort(path, ": attempt to reference undefined global variable '",
            k, "'")
        end
    end
    local function checkwrite(t, k, v)
        e2lib.abort(path, ": attempt to set new global variable `", k, "' to ", v)
    end
    if not allownewdefs then
        setmetatable(t, { __newindex = checkwrite, __index = checkread })
    end
    setfenv(chunk, t)
    local s, msg = pcall(chunk)
    if not s then
        e2lib.abort(msg)
    end
    return true, nil
end

--- Executes Lua code loaded from path.
--@param path Filename to load lua code from (string).
--@param gtable Environment (table) that is used instead of the global _G.
--@return True on success, false on error.
--@return Error object on failure.
function e2lib.dofile2(path, gtable)
    local e = err.new("error loading config file: %s", path)
    local chunk, msg = loadfile(path)
    if not chunk then
        return false, e:cat(msg)
    end
    setfenv(chunk, gtable)
    local s, msg = pcall(chunk)
    if not s then
        return false, e:cat(msg)
    end
    return true, nil
end

--- Locates the root directory of the current project. If path is not given,
-- then the current working directory is taken as the base directory from
-- where to start.
-- @param path Project directory (string) or nil.
-- @return Absolute base project directory or nil on error.
-- XXX: change nil to false.
-- @return Error object on failure.
function e2lib.locate_project_root(path)
    local rc, re
    local e = err.new("checking for project directory failed")
    local save_path = e2util.cwd()
    if not save_path then
        return nil, e:append("cannot get current working directory")
    end
    if path then
        rc = e2lib.chdir(path)
        if not rc then
            e2lib.chdir(save_path)
            return nil, e:cat(re)
        end
    else
        path = e2util.cwd()
        if not path then
            e2lib.chdir(save_path)
            return nil, e:append("cannot get current working directory")
        end
    end
    while true do
        if e2util.exists(".e2") then
            e2lib.logf(3, "project is located in: %s", path)
            e2lib.chdir(save_path)
            return path
        end
        if path == "/" then
            break
        end
        rc = e2lib.chdir("..")
        if not rc then
            e2lib.chdir(save_path)
            return nil, e:cat(re)
        end
        path = e2util.cwd()
        if not path then
            e2lib.chdir(save_path)
            return nil, e:append("cannot get current working directory")
        end
    end
    e2lib.chdir(save_path)
    return nil, err.new("not in a project directory")
end

--- Parse version files.
function e2lib.parse_versionfile(filename)
    local f = luafile.open(filename, "r")
    if not f then
        e2lib.abort("can't open version file: " .. filename)
    end
    local l = f:readline()
    if not l then
        e2lib.abort("can't parse version file: " .. filename)
    end
    local v = l:match("[0-9]+")
    if not v then
        e2lib.abort("invalid format of project version `" .. l .. "' in " .. filename)
    end
    --log(4, "project version is " .. v)
    return v
end

--- Parse e2version file.
function e2lib.parse_e2versionfile(filename)
    local f = luafile.open(filename, "r")
    if not f then
        e2lib.abort("can't open e2version file: " .. filename)
    end
    local l = f:readline()
    if not l then
        e2lib.abort("can't parse e2version file: " .. filename)
    end
    local match = l:gmatch("[^%s]+")
    local v = {}
    v.branch = match() or e2lib.abort("invalid branch name `", l, "' in e2 version file ",
    filename)
    v.tag = match() or e2lib.abort("invalid tag name `", l, "' in e2 version file ",
    filename)
    e2lib.log(3, "using e2 branch " .. v.branch .. " tag " .. v.tag)
    return v
end

--- Create a temporary file.
-- The template string is passed to the mktemp tool, which replaces
-- trailing X characters by some random string to create a unique name.
-- This function always succeeds (or aborts immediately).
-- @param template string: template name (optional)
-- @return string: name of the file
function e2lib.mktempfile(template)
    if not template then
        template = string.format("%s/e2tmp.%d.XXXXXXXX", e2lib.globals.tmpdir,
        e2util.getpid())
    end
    local cmd = string.format("mktemp '%s'", template)
    local mktemp = io.popen(cmd, "r")
    if not mktemp then
        e2lib.abort("can't mktemp")
    end
    local tmp = mktemp:read()
    if not tmp then
        e2lib.abort("can't mktemp")
    end
    mktemp:close()
    -- register tmp for removing with rmtempfiles() later on
    table.insert(e2lib.globals.tmpfiles, tmp)
    e2lib.log(4, string.format("creating temporary file: %s", tmp))
    return tmp
end

--- remove a temporary file and remove it from the builtin list of
-- temporary files
-- This function always succeeds (or aborts immediately)
-- @param path
function e2lib.rmtempfile(tmpfile)
    for i,v in ipairs(e2lib.globals.tmpfiles) do
        if v == tmpfile then
            table.remove(e2lib.globals.tmpfiles, i)
            e2lib.log(4, string.format("removing temporary file: %s", tmpfile))
            e2lib.rm(tmpfile, "-f")
        end
    end
end

--- Create a temporary directory.
-- The template string is passed to the mktemp tool, which replaces
-- trailing X characters by some random string to create a unique name.
-- This function always succeeds (or aborts immediately).
-- @param template string: template name (optional)
-- @return string: name of the directory
function e2lib.mktempdir(template)
    if not template then
        template = string.format("%s/e2tmp.%d.XXXXXXXX", e2lib.globals.tmpdir,
        e2util.getpid())
    end
    local cmd = string.format("mktemp -d '%s'", template)
    local mktemp = io.popen(cmd, "r")
    if not mktemp then
        e2lib.abort("can't mktemp")
    end
    local tmpdir = mktemp:read()
    if not tmpdir then
        e2lib.abort("can't mktemp")
    end
    mktemp:close()
    -- register tmpdir for removing with rmtempdirs() later on
    table.insert(e2lib.globals.tmpdirs, tmpdir)
    e2lib.log(4, string.format("creating temporary directory: %s", tmpdir))
    return tmpdir
end

--- Remove a temporary directory and remove it from the builtin list of
-- temporary directories.
-- This function always succeeds (or aborts immediately)
-- @param path
function e2lib.rmtempdir(tmpdir)
    for i,v in ipairs(e2lib.globals.tmpdirs) do
        if v == tmpdir then
            table.remove(e2lib.globals.tmpdirs, i)
            e2lib.log(4, string.format("removing temporary directory: %s", tmpdir))
            e2lib.rm(tmpdir, "-fr")
        end
    end
end

--- remove temporary directories registered with mktempdir()
-- This function does not support error checking and is intended to be
-- called from the finish() function.
function e2lib.rmtempdirs()
    e2lib.chdir("/")  -- avoid being inside a temporary directory
    while #e2lib.globals.tmpdirs > 0 do
        e2lib.rmtempdir(e2lib.globals.tmpdirs[1])
    end
end

--- remove temporary files registered with mktempfile()
-- This function does not support error checking and is intended to be
-- called from the finish() function.
function e2lib.rmtempfiles()
    while #e2lib.globals.tmpfiles > 0 do
        e2lib.rmtempfile(e2lib.globals.tmpfiles[1])
    end
end

--- call the rm tool with flags and filename
-- @param file string: the file parameter
-- @param flags string: flags to pass to rm (optional)
-- @return bool
-- @return an error object on failure
function e2lib.rm(file, flags)
    if not flags then
        flags = ""
    end
    local args = string.format("%s %s", flags, file)
    return e2lib.call_tool("rm", args)
end

--- call the touch tool with flags and filename
-- @param file string: the file parameter
-- @param flags string: flags to pass to touch (optional)
-- @return bool
function e2lib.touch(file, flags)
    if not flags then
        flags = ""
    end
    local args = string.format("%s %s", flags, file)
    return e2lib.call_tool("touch", args)
end

--- call the rmdir command
-- @param dir string: the directory name
-- @param flags string: flags to pass to rmdir
-- @return bool
-- @return the last line ouf captured output
function e2lib.rmdir(dir, flags)
    if not flags then
        flags = ""
    end
    local args = string.format("%s %s", flags, dir)
    return e2lib.call_tool("rmdir", args)
end

--- call the mkdir command
-- @param dir string: the directory name
-- @param flags string: flags to pass to mkdir
-- @return bool
-- @return the last line ouf captured output
function e2lib.mkdir(dir, flags)
    flags = flags or ""
    assert(type(dir) == "string")
    assert(string.len(dir) > 0)
    assert(type(flags) == "string")

    -- TODO: quote flags as well
    local args = string.format("%s %s", flags, e2lib.shquote(dir))
    return e2lib.call_tool("mkdir", args)
end

--- call the patch command
-- @param dir string: the directory name
-- @param flags string: flags to pass to mkdir
-- @return bool
-- @return the last line ouf captured output
function e2lib.patch(args)
    return e2lib.call_tool("patch", args)
end

--- call a tool
-- @param tool string: tool name as registered in the tools library
-- @param args string: arguments
-- @return bool
-- @return string: the last line ouf captured output
function e2lib.call_tool(tool, args)
    local cmd = tools.get_tool(tool)
    if not cmd then
        e2lib.bomb("trying to call invalid tool: " .. tostring(tool))
    end
    local flags = tools.get_tool_flags(tool)
    if not flags then
        e2lib.bomb("invalid tool flags for tool: " .. tostring(tool))
    end
    local call = string.format("%s %s %s", cmd, flags, args)
    local rc, e = e2lib.callcmd_log(call)
    if rc ~= 0 then
        return false, e
    end
    return true, e
end

--- call a tool with argv
-- @param tool string: tool name as registered in the tools library
-- @param argv table: a vector of (string) arguments
-- @return bool
-- @return string: the last line ouf captured output
function e2lib.call_tool_argv(tool, argv)
    local cmd = tools.get_tool(tool)
    if not cmd then
        e2lib.bomb("trying to call invalid tool: " .. tostring(tool))
    end
    local flags = tools.get_tool_flags(tool)
    if not flags then
        e2lib.bomb("invalid tool flags for tool: " .. tostring(tool))
    end

    -- TODO: flags should be quoted as well, requires config changes
    local call = string.format("%s %s", e2lib.shquote(cmd), flags)

    for _,arg in ipairs(argv) do
        assert(type(arg) == "string")
        call = call .. " " .. e2lib.shquote(arg)
    end

    local rc, e = e2lib.callcmd_log(call)
    if rc ~= 0 then
        return false, e
    end
    return true, e
end

--- call git
-- @param gitdir string: GIT_DIR (optional, defaults to ".git")
-- @param subtool string: git tool name
-- @param args string: arguments to pass to the tool (optional)
-- @return bool
-- @return an error object on failure
function e2lib.git(gitdir, subtool, args)
    local rc, re
    local e = err.new("calling git failed")
    if not gitdir then
        gitdir = ".git"
    end
    if not args then
        args = ""
    end
    local git, re = tools.get_tool("git")
    if not git then
        return false, e:cat(re)
    end
    -- TODO: args should be quoted as well
    local call = string.format("GIT_DIR=%s %s %s %s",
    e2lib.shquote(gitdir), e2lib.shquote(git), e2lib.shquote(subtool), args)
    rc, re = e2lib.callcmd_log(call)
    if rc ~= 0 then
        e:append(call)
        return false, e:cat(re)
    end
    return true, e
end

--- call the svn command
-- @param argv table: vector with arguments for svn
-- @return bool
function e2lib.svn(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("svn", argv)
end

--- call the ln command
-- @param dst string: destination name
-- @param link string: link name
-- @return bool
-- @return the last line of captured output
function e2lib.symlink(dst, link)
    local args = string.format("-s '%s' '%s'", dst, link)
    return e2lib.call_tool("ln", args)
end

--- call the chmod command
-- @param mode string: the new mode
-- @param path string: path
-- @return bool
-- @return the last line ouf captured output
function e2lib.chmod(mode, path)
    local args = string.format("'%s' '%s'", mode, path)
    return e2lib.call_tool("chmod", args)
end

--- call the mv command
-- @param src string: source name
-- @param dst string: destination name
-- @return bool
-- @return the last line ouf captured output
function e2lib.mv(src, dst)
    assert(type(src) == "string" and type(dst) == "string")
    assert(string.len(src) > 0 and string.len(dst) > 0)

    return e2lib.call_tool_argv("mv", { src, dst })
end

--- call the cp command
-- @param src string: source name
-- @param dst string: destination name
-- @param flags string: additional flags
-- @return bool
-- @return the last line ouf captured output
function e2lib.cp(src, dst, flags)
    if not flags then
        flags = ""
    end
    local args = string.format("%s '%s' '%s'", flags, src, dst)
    return e2lib.call_tool("cp", args)
end

--- call the ln command
-- @param src string: source name
-- @param dst string: destination name
-- @param flags string: additional flags
-- @return bool
-- @return the last line ouf captured output
function e2lib.ln(src, dst, flags)
    if not flags then
        flags = ""
    end
    local args = string.format("%s '%s' '%s'", flags, src, dst)
    return e2lib.call_tool("ln", args)
end

--- call the curl command
-- @param argv table: argument vector
-- @return bool
-- @return an error object on failure
function e2lib.curl(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("curl", argv)
end

--- call the ssh command
-- @param argv table: argument vector
-- @return bool
-- @return an error object on failure
function e2lib.ssh(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("ssh", argv)
end

--- call the scp command
-- @param argv table: argument vector
-- @return bool
-- @return an error object on failure
function e2lib.scp(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("scp", argv)
end

--- call the rsync command
-- @param argv table: vector filled with arguments
-- @return bool
-- @return an error object on failure
function e2lib.rsync(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("rsync", argv)
end

--- call the gzip command
-- @param argv table: argument vector
-- @return bool
-- @return the last line ouf captured output
function e2lib.gzip(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("gzip", argv)
end

--- call the catcommand
-- @param argv table: argument vector
-- @return bool
-- @return an error object on failure
function e2lib.cat(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("cat", argv)
end

--- check if dir is a directory
-- @param dir string: path
-- @return bool
function e2lib.isdir(dir)
    local t = e2util.stat(dir, true)
    if t and t.type == "directory" then
        return true
    end

    return false
end

--- check if path is a file
-- @param dir string: path
-- @return bool
function e2lib.isfile(path)
    local t = e2util.stat(path, true)
    if t and t.type == "regular" then
        return true
    end
    return false
end

--- calculate SHA1 sum for a file
-- @param path string: path
-- @return string: sha1 sum of file
-- @return an error object on failure
function e2lib.sha1sum(path)
    assert(type(path) == "string")

    local e = err.new("calculating SHA1 checksum failed")

    local sha1sum, re = tools.get_tool("sha1sum")
    if not sha1sum then
        return nil, e:cat(re)
    end

    local sha1sum_flags, re = tools.get_tool_flags("sha1sum")
    if not sha1sum_flags then
        return nil, e:cat(re)
    end

    -- TODO: sha1sum_flags should be quoted as well
    local cmd = string.format("%s %s %s", e2lib.shquote(sha1sum), sha1sum_flags,
    e2lib.shquote(path))

    local p, msg = io.popen(cmd, "r")
    if not p then
        return nil, e:cat(msg)
    end

    local out, msg = p:read("*l")
    p:close()

    local sha1, file = out:match("(%S+)  (%S+)")
    if type(sha1) ~= "string" then
        return nil, e:cat("parsing sha1sum output failed")
    end
    return sha1
end

--- call the e2-su command
-- @param argv table: argument vector
-- @return bool
function e2lib.e2_su(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("e2-su", argv)
end

--- call the e2-su-2.2 command
-- @param argv table: argument vector
-- @return bool
function e2lib.e2_su_2_2(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("e2-su-2.2", argv)
end

--- call the tar command
-- @param argv table: argument vector
-- @return bool
function e2lib.tar(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("tar", argv)
end

--- get system architecture
-- @return string: machine hardware name
-- @return an error object on failure
function e2lib.get_sys_arch()
    local rc, re
    local e = err.new("getting host system architecture failed")
    local uname = tools.get_tool("uname")
    local cmd = string.format("%s -m", e2lib.shquote(uname))
    local p, msg = io.popen(cmd, "r")
    if not p then
        return nil, e:cat(msg)
    end
    local l, msg = p:read()
    if not l then
        return nil, e:cat(msg)
    end
    local arch = l:match("(%S+)")
    if not arch then
        return nil, e:append("%s: %s: cannot parse", cmd, l)
    end
    return arch, nil
end

--- return a table of parent directories
-- @param path string: path
-- @return a table of parent directories, including path.
function e2lib.parentdirs(path)
    local i = 2
    local t = {}
    local stop = false
    while true do
        local px
        local p = path:find("/", i)
        if not p then
            p = #path
            stop = true
        end
        px = path:sub(1, p)
        table.insert(t, px)
        i = p + 1
        if stop then
            break
        end
    end
    return t
end

--- write a string to a file
-- @param file string: filename
-- @param data string: data
-- @return bool
-- @return nil, or an error string
function e2lib.write_file(file, data)
    local f, msg = io.open(file, "w")
    if not f then
        return false, string.format("open failed: %s", msg)
    end
    local rc, msg = f:write(data)
    if not rc then
        f:close()
        return false, string.format("write failed: %s", msg)
    end
    f:close()
    return true, nil
end

--- read a file into a string
-- @param file string: filename
-- @return string: the file content
-- @return nil, or an error object
function e2lib.read_file(file)
    local f, msg = io.open(file, "r")
    if not f then
        return nil, err.new("%s", msg)
    end
    local s, msg = f:read("*a")
    if not s then
        return nil, err.new("%s", msg)
    end
    f:close()
    return s, nil
end

--- read a template file, located relative to the current template directory
-- @param file string: relative filename
-- @return string: the file content
-- @return an error object on failure
function e2lib.read_template(file)
    local e = err.new("error reading template file")
    local filename = string.format("%s/%s", e2lib.globals.template_path, file)
    local template, re = e2lib.read_file(filename)
    if not template then
        return nil, e:cat(re)
    end
    return template, nil
end

--- parse a server:location string, taking a default server into account
-- @param arg string: the string to parse
-- @param default_server string: the default server name
-- @return a table with fields server and location, nil on error
-- @return nil, an error string on error
function e2lib.parse_server_location(arg, default_server)
    local sl = {}
    sl.server, sl.location = arg:match("(%S+):(%S+)")
    if not (sl.server and sl.location) then
        sl.location = arg:match("(%S+)")
        if not (sl.location and default_server) then
            return nil, "can't parse location"
        end
        sl.server = default_server
    end
    if sl.location:match("[.][.]") or
        sl.location:match("^/") then
        return nil, "invalid location"
    end
    return sl
end

--- setup cache from the global server configuration
-- @return a cache object
-- @return an error object on failure
function e2lib.setup_cache()
    local e = err.new("setting up cache failed")
    local config = e2lib.get_global_config()
    if type(config.cache) ~= "table" or type(config.cache.path) ~= "string" then
        return false, e:append("invalid cache configuration: config.cache.path")
    end
    local replace = { u=e2lib.globals.username }
    local cache_path = e2lib.format_replace(config.cache.path, replace)
    local cache_url = string.format("file://%s", cache_path)
    local c, re = cache.new_cache("local cache", cache_url)
    if not c then
        return nil, e:cat(re)
    end
    for name,server in pairs(config.servers) do
        local flags = {}
        flags.cachable = server.cachable
        flags.cache = server.cache
        flags.islocal = server.islocal
        flags.writeback = server.writeback
        flags.push_permissions = server.push_permissions
        local rc, re = cache.new_cache_entry(c, name, server.url, flags)
        if not rc then
            return nil, e:cat(re)
        end
    end
    return c, nil
end

--- replace format elements, according to the table
-- @param s string: the string to work on
-- @param t table: a table of key-value pairs
-- @return string
function e2lib.format_replace(s, t)
    -- t has the format { f="foo" } to replace %f by foo inside the string
    -- %% is automatically replaced by %
    local start = 1
    while true do
        local p = s:find("%%", start)
        if not p then
            break
        end
        t["%"] = "%"
        for x,y in pairs(t) do
            if s:sub(p+1, p+1) == x then
                s = s:sub(1, p-1) .. y .. s:sub(p+2, #s)
                start = p + #y
                break
            end
        end
        start = start + 1
    end
    return s
end

--- change directory
-- @param path
-- @return bool
-- @return an error object on failure
function e2lib.chdir(path)
    local rc, re
    rc, re = e2util.cd(path)
    if not rc then
        return false, err.new("chdir %s failed: %s", path, re)
    end
    return true, nil
end

--- align strings
-- @param columns screen width
-- @param align1 column to align string1to
-- @param string1 first string
-- @param align2 column to align string2 to
-- @param string2 second string
function e2lib.align(columns, align1, string1, align2, string2)
    local lines = 1
    if align2 + #string2 > columns then
        -- try to move string2 to the left first
        align2 = columns - #string2
    end
    if align1 + #string1 + #string2 > columns then
        -- split into two lines
        lines = 2
    end
    local s
    if lines == 1 then
        s = string.rep(" ", align1) .. string1 ..
        string.rep(" ", align2 - #string1 - align1) .. string2
    else
        s = string.rep(" ", align1) .. string1 .. "\n" ..
        string.rep(" ", align2) .. string2
    end
    return s
end

return strict.lock(e2lib)

-- vim:sw=4:sts=4:et:
