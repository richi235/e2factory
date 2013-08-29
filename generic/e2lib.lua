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

local buildconfig = require("buildconfig")
local lock = require("lock")
local err = require("err")
local plugin = require("plugin")
local tools = require("tools")
local cache = require("cache")
local luafile = require("luafile")
local le2lib = require("le2lib")

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
    env = {},
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

--- Get current working directory.
-- @return Current working directory (string) or false on error.
-- @return Error object on failure.
function e2lib.cwd()
    local path, errstring = le2lib.cwd()

    if not path then
        return false,
            err.new("cannot get current working directory: %s", errstring)
    end

    return path
end

--- Dirent table, returned by @{stat}.
-- @table dirent
-- @field dev Device-id (number).
-- @field ino Inode-number (number).
-- @field mode Permissions and access mode (number).
-- @field nlink Number of hard links (number).
-- @field uid User ID (number).
-- @field gid Group ID (number).
-- @field rdev Device id for char of block special files (number).
-- @field size File size (number).
-- @field atime access time (number).
-- @field mtime modification time (number).
-- @field ctime change time (number).
-- @field blksize block size (number).
-- @field type One of the following strings: block-special, character-special,
--             fifo-special, regular, directory, symbolic-link, socket, unknown.


--- Get file status information.
-- @param path Path to the file, including special files.
-- @param followlinks Whether symlinks should be followed, or information
--        about the link should be returned (boolean).
-- @return Dirent table containing attributes (see @{dirent}), or false on error
-- @return Error object on failure.
function e2lib.stat(path, followlinks)
    local dirent, errstring = le2lib.stat(path, followlinks)

    if not dirent then
        return false, err.new("stat failed: %s: %s", path, errstring)
    end

    return dirent
end

--- Checks if file exists.
-- If executable is true, it also checks whether the file is executable.
-- @param path Path to check.
-- @param executable Check if executable (true) or not (false).
-- @return True if file exists, false otherwise.
function e2lib.exists(path, executable)
    return le2lib.exists(path, executable)
end

--- Create a symlink.
-- @param oldpath Path to point to (string).
-- @param newpath New symlink path (string).
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.symlink(oldpath, newpath)
    local rc, errstring = le2lib.symlink(oldpath, newpath)

    if not rc then
        return false, err.new("creating symlink failed: %s -> %s: %s",
            newpath, oldpath, errstring)
    end

    return true
end

--- Create a hardlink.
-- @param oldpath Path to existing file (string).
-- @param newpath Path to new file (string).
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.hardlink(oldpath, newpath)
    local rc, errstring = le2lib.hardlink(oldpath, newpath)

    if not rc then
        return false, err.new("creating hard link failed: %s -> %s: %s",
            newpath, oldpath, errstring)
    end

    return true
end

--- Wait for process to terminate.
-- @param pid Process ID, -1 to wait for any child.
-- @return Exit status of process (WEXITSTATUS), or false on error.
-- @return Process ID of the terminated child or error object on failure.
function e2lib.wait(pid)
    local rc, pid = le2lib.wait(pid)

    if not rc then
        local errstring = pid
        return false, err.new("waiting for child %d failed: %s", pid, errstring)
    end

    return rc, pid
end

--- Poll input output multiplexing.
-- Only indicates first selected file descriptor.
-- @param timeout Timeout in milliseconds (number).
-- @param fdvec Vector of file descriptors (table of numbers).
-- @return Returns 0 on timeout, < 0 on error and > 0 to indicate which file
--         descriptor triggered.
-- @return True if it's a POLLIN event.
-- @return True if it's a POLLOUT event.
function e2lib.poll(timeout, fdvec)
    return le2lib.poll(timeout, fdvec)
end

--- Set file descriptor in non-blocking mode.
-- @param fd Open file descriptor.
function e2lib.unblock(fd)
    return le2lib.unblock(fd)
end

--- Creates a new process. Returns both in the parent and in the child.
-- @return Process ID of the child or false on error in the parent process.
--         Returns zero in the child process.
-- @return Error object on failure.
function e2lib.fork()
    local pid, errstring = le2lib.fork()

    if pid == false then
        return false, err.new("failed to fork a new child: %s", errstring)
    end

    return pid
end

--- Set umask value.
-- @param mask New umask value.
-- @return Previous umask value.
function e2lib.umask(mask)
    return le2lib.umask(mask)
end

--- Set environment variable.
-- @param var Variable name (string).
-- @param val Variable content (string).
-- @param overwrite True to overwrite existing variable of same name.
-- @return True on success, false on error.
function e2lib.setenv(var, val, overwrite)
    -- used in only once, questionable
    return le2lib.setenv(var, val, overwrite)
end

--- Reset signal handlers back to their default.
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.signal_reset()
    local rc, errstring

    rc, errstring = le2lib.signal_reset()
    if not rc then
        return false, err.new("resetting signal handlers: %s", errstring)
    end

    return true
end

--- Get current process id.
-- @return Process ID (number)
function e2lib.getpid()
    -- used only for tempfile generation
    return le2lib.getpid()
end

--- Send signal to process.
-- @param pid Process ID to signal (number).
-- @param sig Signal number.
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.kill(pid, sig)
    local rc, errstring = le2lib.kill(pid, sig)

    if not rc then
        return false, err.new("sending signal %d to process %d failed: %s",
            sig, pid, errstring)
    end

    return true
end

--- Interrupt handling.
--
-- le2lib sets up a SIGINT handler that calls back into this function.
function e2lib.interrupt_hook()
    e2lib.abort("*interrupted by user*")
end

--- Make sure the environment variables inside the globals table are
-- initialized properly.
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.init()
    e2lib.log(4, "e2lib.init()")
    -- DEBUG: change to "cr" to log return from function
    local traceflags = os.getenv("E2_TRACE") or "c"
    debug.sethook(e2lib.tracer, traceflags)

    local rc, re = e2lib.signal_reset()
    if not rc then
        e2lib.abort(re)
    end

    e2lib.closefrom(3)
    -- ignore errors, no /proc should not prevent factory from working

    -- Overwrite io functions that create a file descriptor to set the
    -- CLOEXEC flag by default.
    local realopen = io.open
    local realpopen = io.popen

    function io.open(...)
        local ret = {realopen(...)} -- closure
        if ret[1] then
            if not luafile.cloexec(ret[1]) then
                return nil, "Setting CLOEXEC failed"
            end
        end
        return unpack(ret)
    end

    function io.popen(...)
        local ret = {realpopen(...)} -- closure
        if ret[1] then
            if not luafile.cloexec(ret[1]) then
                return nil, "Setting CLOEXEC failed"
            end
        end
        return unpack(ret)
    end

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
            return false, err.new("%s is not set in the environment", var.name)
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
    if e2lib.globals.osenv["E2TMPDIR"] then
        e2lib.globals.tmpdir = e2lib.globals.osenv["E2TMPDIR"]
    else
        e2lib.globals.tmpdir = e2lib.globals.osenv["TMPDIR"]
    end

    -- get the host name
    local hostname = io.popen("hostname")
    if not hostname then
        return false, err.new("execution of \"hostname\" failed")
    end

    e2lib.globals.hostname = hostname:read("*a")
    hostname:close()
    if not e2lib.globals.hostname then
        return false, err.new("hostname ist not set")
    end

    e2lib.globals.lock = lock.new()

    return true
end

--- init2.
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.init2()
    local rc, re, e, config, ssh, host_system_arch

    e = err.new("initializing globals (step2)")

    -- get the global configuration
    config, re = e2lib.get_global_config()
    if not config then
        return false, re
    end

    -- honour tool customizations from the config file
    if config.tools then
        for k,v in pairs(config.tools) do
            rc, re = tools.set_tool(k, v.name, v.flags)
            if not rc then
                return false, e:cat(re)
            end
        end
    end

    -- handle E2_SSH environment setting
    ssh = e2lib.globals.osenv["E2_SSH"]
    if ssh then
        e2lib.logf(3, "using E2_SSH environment variable: %s", ssh)
        rc, re = tools.set_tool("ssh", ssh)
        if not rc then
            return false, e:cat(re)
        end
    end

    -- initialize the tools library after resetting tools
    rc, re = tools.init()
    if not rc then
        return false, e:cat(re)
    end

    -- get host system architecture
    host_system_arch, re = e2lib.get_sys_arch()
    if not host_system_arch then
        return false, e:cat(re)
    end

    return true
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
        e2lib.logf(4, "< %s%s", module, ftbl.name)
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
        e2lib.log(1, "Internal error: calling warnf() with zero length format")
    end
    if type(e2lib.globals.warn_category[category]) ~= "boolean" then
        e2lib.log(1,
            "Internal error: calling warnf() with invalid warning category")
    end
    if e2lib.globals.warn_category[category] == true then
        local prefix = "Warning: "
        if e2lib.globals.log_debug then
            prefix = string.format("Warning [%s]: ", category)
        end
        e2lib.log(1, prefix .. string.format(format, ...))
    end
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
            e2lib.log(1,
                "Internal error: calling abort() with zero length message")
        end
        e2lib.log(1, "Error: " .. msg)
    end
    e2lib.finish(1)
end

--- Set E2_CONFIG in the environment to file. Also sets commandline option.
-- @param file Config file name (string).
function e2lib.sete2config(file)
    e2lib.setenv("E2_CONFIG", file, 1)
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
        e2lib.log(1, "Internal error: calling logf() without format string")
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
        e2lib.log(1, "Internal error: invalid log level")
    end
    if not msg then
        e2lib.log(1, "Internal error: calling log() without log message")
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
-- @param file Absolute path to log file.
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.rotate_log(file)
    local e = err.new("rotating logfile: %s", file)
    local rc, re
    local logdir = e2lib.dirname(file)
    local logfile = e2lib.basename(file)
    local files = {}

    for f, re in e2lib.directory(logdir, false) do
        if not f then
            return false, e:cat(re)
        end

        local match = f:match(string.format("%s.[0-9]+", logfile))
        if match then
            table.insert(files, 1, match)
        end
    end

    -- sort in reverse order
    local function comp(a, b)
        local na = a:match("%.([0-9]+)$")
        local nb = b:match("%.([0-9]+)$")
        return tonumber(na) > tonumber(nb)
    end

    table.sort(files, comp)

    for _,f in ipairs(files) do
        local n = f:match(string.format("%s.([0-9]+)", logfile))
        if n then
            n = tonumber(n)
            if n >= e2lib.globals.logrotate - 1 then
                local del = string.format("%s/%s.%d", logdir, logfile, n)
                rc, re = e2lib.unlink(del)
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

    dst = string.format("%s/%s.0", logdir, logfile)
    assert(not e2util.stat(dst), "did not expect logfile here: "..dst)
    rc, re = e2lib.mv(file, dst)
    if not rc then
        return false, e:cat(re)
    end
    return true
end

--- Clean up temporary files and directories, shut down plugins.
function e2lib.cleanup()
    local rc, re = plugin.exit_plugins()
    if not rc then
        e2lib.log(1, "deinitializing plugins failed (ignoring)")
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
    if e2lib.globals.debuglogfile then
        e2lib.globals.debuglogfile:close()
    end
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

--- quotes a string so it can be safely passed to a shell
-- @param str string to quote
-- @return quoted string
function e2lib.shquote(str)
    assert(type(str) == "string")

    str = string.gsub(str, "'", "'\"'\"'")
    return "'"..str.."'"
end

--- Translate filename suffixes to valid tartypes for e2-su-2.2 only.
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
        return false, err.new("unknown suffix for filename: %s", filename)
    end
    return tartype
end

--- Read the first line from the given file and return it.
-- Beware that end of file is considered an error.
-- @param path Path to file (string).
-- @return The first line or false on error.
-- @return Error object on failure.
function e2lib.read_line(path)
    local f, msg = io.open(path)
    if not f then
        return false, err.new("%s: %s", path, msg)
    end
    local l, msg = f:read("*l")
    f:close()
    if not l then
        if not msg then
            msg = "end of file"
        end

        return false, err.new("%s: %s", path, msg)
    end
    return l
end

--- Use the global parameters from the global configuration.
-- @return True on success, false on error.
-- @return Error object on failure.
local function use_global_config()
    local rc, re

    local function assert_type(x, d, t1)
        local t2 = type(x)
        if t1 ~= t2 then
            return false,
                err.new("configuration error: %s (expected %s got %s)",
                d, t1, t2)
        end

        return true
    end

    local config = global_config
    if not config then
        return false, err.new("global config not available")
    end
    if config.log then
        rc, re = assert_type(config.log, "config.log", "table")
        if not rc then
            return false, re
        end

        if config.log.logrotate then
            rc, re = assert_type(config.log.logrotate, "config.log.logrotate", "number")
            if not rc then
                return false, re
            end
            e2lib.globals.logrotate = config.log.logrotate
        end
    end
    rc, re = assert_type(config.site, "config.site", "table")
    if not rc then
        return false, re
    end

    rc, re = assert_type(config.site.e2_branch, "config.site.e2_branch", "string")
    if not rc then
        return false, re
    end

    rc, re = assert_type(config.site.e2_tag, "config.site.e2_tag", "string")
    if not rc then
        return false, re
    end

    rc, re = assert_type(config.site.e2_server, "config.site.e2_server", "string")
    if not rc then
        return false, re
    end

    rc, re = assert_type(config.site.e2_base, "config.site.e2_base", "string")
    if not rc then
        return false, re
    end

    rc, re = assert_type(config.site.default_extensions, "config.site.default_extensions", "table")
    if not rc then
        return false, re
    end

    return true
end

--- read the global config file
-- local tools call this function inside collect_project_info()
-- global tools must call this function after parsing command line options
-- @param e2_config_file string: config file path (optional)
-- @return bool
-- @return error string on error
function e2lib.read_global_config(e2_config_file)
    local cf
    local rc, re
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
        e2lib.logf(4, "reading global config file: %s", path)
        local rc = e2lib.exists(path)
        if rc then
            e2lib.logf(3, "using global config file: %s", path)
            rc, re = e2lib.dofile2(path, c, true)
            if not rc then
                return false, re
            end
            if not c.data then
                return false, err.new("invalid configuration")
            end
            global_config = c.data
            rc, re = use_global_config()
            if not rc then
                return false, re
            end

            return true
        else
            e2lib.logf(4, "global config file does not exist: %s", path)
        end
    end
    return false, err.new("no config file available")
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
    local rc = e2lib.exists(e2lib.globals.extension_config)
    if not rc then
        return false, e:append("config file does not exist")
    end
    e2lib.logf(3, "reading extension file: %s", e2lib.globals.extension_config)
    local c = {}
    c.extensions = function(x)
        c.data = x
    end
    local rc, re = e2lib.dofile2(e2lib.globals.extension_config, c, true)
    if not rc then
        return false, e:cat(re)
    end
    local extension = c.data
    if not extension then
        return false, e:append("invalid extension configuration")
    end
    return extension, nil
end

--- Get the global configuration.
-- @return The global configuration, or false on error.
-- @return Error object on failure.
function e2lib.get_global_config()
    local config = global_config
    if not config then
        return false, err.new("global config not available")
    end

    return config
end

--- Successively returns the file names in the directory.
-- @param path Directory path (string).
-- @param dotfiles If true, also return files starting with a '.'. Optional.
-- @param noerror If true, do not report any errors. Optional.
-- @return Iterator function, returning a string containing the filename,
--         or false and an err object on error. The iterator signals the
--         end of the list by returning nil.
function e2lib.directory(path, dotfiles, noerror)
    local dir, errstring = le2lib.directory(path, dotfiles)
    if not dir then
        if noerror then
            dir = {}
        else
            -- iterator that signals an error, once.
            local error_signaled = false

            return function ()
                if not error_signaled then
                    error_signaled = true
                    return false, err.new("reading directory `%s' failed: %s",
                        path, errstring)
                else
                    return nil
                end
            end
        end
    end

    table.sort(dir)
    local i = 1

    return function ()
        if i > #dir then
            return nil
        else
            i = i + 1
            return dir[i-1]
        end
    end
end

--- callcmd: call a command, connecting
--  stdin, stdout, stderr to luafile objects.
local function callcmd(infile, outfile, errfile, cmd)
    -- redirect stdin
    io.stdin:close()
    luafile.dup2(infile:fileno(), 0)
    if infile:fileno() ~= 0 then
        infile:cloexec()
    end
    -- redirect stdout
    io.stdout:close()
    luafile.dup2(outfile:fileno(), 1)
    if outfile:fileno() ~= 1 then
        outfile:cloexec()
    end
    -- redirect stderr
    io.stderr:close()
    luafile.dup2(errfile:fileno(), 2)
    if errfile:fileno() ~= 2 then
        errfile:cloexec()
    end
    -- run the command
    local rc = os.execute(cmd)
    return (rc/256)
end

--- Call several commands in a pipe.
-- @param cmds Table of shell commands.
-- @param infile Luafile that is readable, or nil.
-- @param outfile Luafile that is writeable, or nil.
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.callcmd_pipe(cmds, infile, outfile)
    local e = err.new("calling commands in a pipe failed")
    local rc, re

    local input = infile or luafile.open("/dev/null", "r")
    if not input then
        return false, e:cat("input could not be opened")
    end

    local rcs = {}
    local pids = {}
    local ers = {}

    if not input then
        return false, err.new("could not open /dev/null")
    end

    local c = #cmds
    for cmdidx = 1, c do
        local pipein, output
        local errin, errout
        local pid

        rc, errin, errout = luafile.pipe()
        if not rc then
            return false, err.new("failed to open error pipe")
        end

        if cmdidx < c then
            rc , pipein, output = luafile.pipe()
            if not rc then
                return false, err.new("failed to open pipe")
            end
        else
            -- last command in pipe
            output = outfile or errout
        end

        e2lib.logf(3, "+ %s", cmds[cmdidx])
        pid, re = e2lib.fork()
        if not pid then
            return false, e:cat(re)
        elseif pid == 0 then
            if cmdidx < c then
                -- everyone but the last
                pipein:close()
            end

            errin:close()
            rc = callcmd(input, output, errout, cmds[cmdidx])
            os.exit(rc)
        end

        pids[pid] = cmdidx
        e2lib.unblock(errin:fileno())
        ers[cmdidx] = errin
        errout:close()

        -- close all outputs except the last one (outfile)
        if cmdidx < c then
            output:close()
        end

        -- do not close first input (infile)
        if cmdidx > 1 or not infile then
            input:close()
        end
        input = pipein
    end

    while c > 0 do
        local fds = {}
        local ifd = {}
        for i, f in pairs(ers) do
            local n = f:fileno()
            table.insert(fds, n)
            ifd[n] = i
        end
        local i, r = e2lib.poll(-1, fds)

        if i <= 0 then
            return false, err.new("poll error: %s", tostring(i))
        end

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
    rc = true
    while c > 0 do
        local status, pid = e2lib.wait(-1)
        if not status then
            re = pid
            return false, e:cat(re)
        end

        local cmdidx = pids[pid]
        if cmdidx then
            if status ~= 0 then
                rc = false
            end

            rcs[cmdidx] = status
            pids[pid] = nil
            c = c - 1
        end
    end

    if not rc then
        return false,
            err.new("failed to execute commands in a pipe, exit codes are: %s",
                table.concat(rcs, ", "))
    end

    return true
end

--- call a command with stdin redirected from /dev/null, stdout/stderr
-- captured via a pipe
-- the capture function is called for every chunk of output that
-- is captured from the pipe.
-- @return Return status code of the command (number) or false on error.
-- @return Error object on failure.
function e2lib.callcmd_capture(cmd, capture)
    local rc, re, oread, owrite, devnull, pid

    local function autocapture(msg)
        e2lib.log(3, msg)
    end

    capture = capture or autocapture
    rc, oread, owrite = luafile.pipe()
    owrite:setlinebuf()
    oread:setlinebuf()
    devnull = luafile.open("/dev/null", "r")
    if not devnull then
        e2lib.abort("could not open /dev/null")
    end
    e2lib.logf(4, "+ %s", cmd)
    pid, re = e2lib.fork()
    if not pid then
        return false, re
    elseif pid == 0 then
        oread:close()
        rc = callcmd(devnull, owrite, owrite, cmd)
        os.exit(rc)
    else
        owrite:close()
        while not oread:eof() do
            local x = oread:readline()
            if x then
                capture(x)
            end
        end
        oread:close()
        rc, re = e2lib.wait(pid)
        if not rc then
            luafile.close(devnull)
            return false, re
        end

        luafile.close(devnull)
    end

    return rc
end

--- Call a command, log its output and catch the last lines for error reporting.
-- @param cmd string: the command
-- @return Return code of the command (number), or false on error.
-- @return Error object containing command line and last lines of output. It's
--         the callers responsibility to determine whether an error occured
--         based on the return code. If the return code is false, an error
--         within the function occured and a normal error object is returned.
function e2lib.callcmd_log(cmd)
    local e = err.new("command %s failed:", cmd)
    local fifo = {}

    local function logto(msg)
        e2lib.log(3, msg)

        if msg ~= "" then
            if #fifo > 4 then -- keep the last n lines.
                table.remove(fifo, 1)
            end
            table.insert(fifo, msg)
        end
    end

    local rc, re = e2lib.callcmd_capture(cmd, logto)
    if not rc then
        return false, e:cat(e)
    end

    if #fifo == 0 then
        table.insert(fifo, "command failed silently, no output captured")
    end

    for _,v in ipairs(fifo) do
        e:append("%s", v)
    end

    return rc, e
end

--- Executes Lua code loaded from path.
--@param path Filename to load lua code from (string).
--@param gtable Environment (table) that is used instead of the global _G.
--@param allownewdefs Boolean indicating whether new variables may be defined
--                    and undefined ones read.
--@return True on success, false on error.
--@return Error object on failure.
function e2lib.dofile2(path, gtable, allownewdefs)
    local e = err.new("error loading config file: %s", path)
    local chunk, msg = loadfile(path)
    if not chunk then
        return false, e:cat(msg)
    end

    local function checkread(t, k)
        local x = rawget(t, k)
        if x then
            return x
        else
            error(string.format(
                "%s: attempt to reference undefined global variable '%s'",
                path, tostring(k)), 0)
        end
    end

    local function checkwrite(t, k, v)
        error(string.format("%s: attempt to set new global variable `%s' to %s",
            path, tostring(k), tostring(v)), 0)
    end

    if not allownewdefs then
        setmetatable(gtable, { __newindex = checkwrite, __index = checkread })
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
-- @return Absolute base project directory or false on error.
-- @return Error object on failure.
function e2lib.locate_project_root(path)
    local rc, re
    local e = err.new("checking for project directory failed")
    local save_path, re = e2lib.cwd()
    if not save_path then
        return false, e:cat(re)
    end
    if path then
        rc = e2lib.chdir(path)
        if not rc then
            e2lib.chdir(save_path)
            return false, e:cat(re)
        end
    else
        path, re = e2lib.cwd()
        if not path then
            e2lib.chdir(save_path)
            return false, e:cat(re)
        end
    end
    while true do
        if e2lib.exists(".e2") then
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
            return false, e:cat(re)
        end
        path, re = e2lib.cwd()
        if not path then
            e2lib.chdir(save_path)
            return false, e:cat(re)
        end
    end
    e2lib.chdir(save_path)
    return false, err.new("not in a project directory")
end

--- Checks whether the tool is an existing global e2factory tool. Note that
-- there is third class of binaries living in BINDIR, which are not considered
-- global (in a tool sense).
-- @param tool Tool name such as 'e2-create-project', 'e2-build' etc.
-- @return True or false.
-- @return Error object when false.
-- @see islocaltool
function e2lib.isglobaltool(tool)
    local tool = e2lib.join(buildconfig.TOOLDIR, tool)
    if e2lib.isfile(tool) then
        return true
    end

    return false, err.new('global tool "%s" does not exists', tool)
end

--- Check whether tool is an existing local e2factory tool.
-- Only works in a project context.
-- @param tool Tool name such as 'e2-install-e2', 'e2-build' etc.
-- @return True or false
-- @return Error object when false.
-- @see isglobaltool
function e2lib.islocaltool(tool)
    local dir, re = e2lib.locate_project_root()
    if not dir then
        return false, re
    end

    local tool = e2lib.join(dir, ".e2/bin", tool)
    if e2lib.isfile(tool) then
        return tool
    end

    return false, err.new('local tool "%s" does not exist', tool)
end

--- Parse e2version file.
-- @return Table containing tag and branch. False on error.
-- @return Error object on failure.
function e2lib.parse_e2versionfile(filename)
    local f = luafile.open(filename, "r")
    if not f then
        return false, err.new("can't open e2version file: %s", filename)
    end

    local l = f:readline()
    f:close()
    if not l then
        return false, err.new("can't parse e2version file: %s", filename)
    end

    local match = l:gmatch("[^%s]+")

    local version_table = {}
    version_table.branch = match()
    if not version_table.branch then
        return false, err.new("invalid branch name `%s' in e2 version file %s",
            l, filename)
    end

    version_table.tag = match()
    if not version_table.tag then
        return false, err.new("invalid tag name `%s' in e2 version file %s",
            l, filename)
    end

    e2lib.logf(3, "using e2 branch %s tag %s",
        version_table.branch, version_table.tag)

    return strict.lock(version_table)
end

--- Create a temporary file.
-- The template string is passed to the mktemp tool, which replaces
-- trailing X characters by some random string to create a unique name.
-- @param template string: template name (optional)
-- @return Name of the file or false on error.
-- @return Error object on failure.
function e2lib.mktempfile(template)
    if not template then
        template = string.format("%s/e2tmp.%d.XXXXXXXX", e2lib.globals.tmpdir,
            e2lib.getpid())
    end
    local cmd = string.format("mktemp '%s'", template)
    local mktemp = io.popen(cmd, "r")
    if not mktemp then
        return false, err.new("can't mktemp")
    end
    local tmp = mktemp:read()
    if not tmp then
        return false, err.new("can't mktemp")
    end
    mktemp:close()
    -- register tmp for removing with rmtempfiles() later on
    table.insert(e2lib.globals.tmpfiles, tmp)
    e2lib.logf(4, "creating temporary file: %s", tmp)
    return tmp
end

--- Delete the temporary file and remove it from the builtin list of
-- temporary files.
-- @param tmpfile File name to remove (string).
function e2lib.rmtempfile(tmpfile)
    local rc, re

    for i,v in ipairs(e2lib.globals.tmpfiles) do
        if v == tmpfile then
            table.remove(e2lib.globals.tmpfiles, i)
            e2lib.logf(4, "removing temporary file: %s", tmpfile)
            if e2lib.exists(tmpfile) then
                rc, re = e2lib.unlink(tmpfile)
                if not rc then
                    e2lib.warnf(3, "could not remove tmpfile %q", tmpfile)
                end
            end
        end
    end
end

--- Create a temporary directory.
-- The template string is passed to the mktemp tool, which replaces
-- trailing X characters by some random string to create a unique name.
-- @param template string: template name (optional)
-- @return Name of the directory (string) or false on error.
-- @return Error object on failure.
function e2lib.mktempdir(template)
    if not template then
        template = string.format("%s/e2tmp.%d.XXXXXXXX", e2lib.globals.tmpdir,
        e2lib.getpid())
    end
    local cmd = string.format("mktemp -d '%s'", template)
    local mktemp = io.popen(cmd, "r")
    if not mktemp then
        return false, err.new("can't mktemp")
    end
    local tmpdir = mktemp:read()
    if not tmpdir then
        return false, err.new("can't mktemp")
    end
    mktemp:close()
    -- register tmpdir for removing with rmtempdirs() later on
    table.insert(e2lib.globals.tmpdirs, tmpdir)
    e2lib.logf(4, "creating temporary directory: %s", tmpdir)
    return tmpdir
end

--- Recursively delete the temporary directory and remove it from the builtin
-- list of temporary directories.
-- @param tmpdir Directory name to remove (string).
function e2lib.rmtempdir(tmpdir)
    local rc, re

    for i,v in ipairs(e2lib.globals.tmpdirs) do
        if v == tmpdir then
            table.remove(e2lib.globals.tmpdirs, i)
            e2lib.logf(4, "removing temporary directory: %s", tmpdir)
            if e2lib.exists(tmpdir) then
                rc, re = e2lib.unlink_recursive(tmpdir)
                if not rc then
                    e2lib.warnf(3, "could not remove tmpdir %q", tmpdir)
                end
            end
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

--- Remove regular and special files, except dirs.
-- @param pathname Path to file (string).
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.unlink(pathname)
    local rc, errstring = le2lib.unlink(pathname)

    if not rc then
        return false, err.new("could not remove file %s: %s",
            pathname, errstring)
    end

    return true
end

--- Remove directories and files recursively.
-- @param pathname Directory to delete.
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.unlink_recursive(pathname)
    local de, rc, re
    local filepath

    for file, re in e2lib.directory(pathname, true) do
        if not file then
            return false, re
        end

        filepath = e2lib.join(pathname, file)

        de, re = e2lib.stat(filepath)
        if not de then
            return false, re
        end

        if de.type == "directory" then
            rc, re = e2lib.unlink_recursive(filepath)
            if not rc then
                return false, re
            end
        else
            rc, re = e2lib.unlink(filepath)
            if not rc then
                return false, re
            end
        end
    end

    rc, re = e2lib.rmdir(pathname)
    if not rc then
        return false, re
    end

    return true
end

--- Remove single empty directory.
-- @param dir Directory name (string).
-- @return True on success, false on error.
-- @return Error object on failure.
function e2lib.rmdir(dir)
    local rc, errstring = le2lib.rmdir(dir)

    if not rc then
        return false, err.new("could not remove directory %s: %s",
            dir, errstring)
    end

    return true
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

--- Call a tool.
-- @param tool Tool name as registered in the tools library (string).
-- @param args Arguments as a string. Caller is responsible for safe escaping.
-- @return True when the tool returned 0, false on error.
-- @return Error object on failure
function e2lib.call_tool(tool, args)
    local rc, re, cmd, flags, call

    cmd, re = tools.get_tool(tool)
    if not cmd then
        return false, re
    end

    flags, re = tools.get_tool_flags(tool)
    if not flags then
        return false, re
    end

    call = string.format("%s %s %s", cmd, flags, args)
    rc, re = e2lib.callcmd_log(call)
    if not rc or rc ~= 0 then
        return false, re
    end

    return true
end

--- Call a tool with an argument vector.
-- @param tool Tool name as registered in the tools library (string).
-- @param argv Vector of arguments, escaping is handled by the function
--             (table of strings).
-- @return True when the tool returned 0, false on error.
-- @return Error object on failure.
function e2lib.call_tool_argv(tool, argv)
    local rc, re, cmd, flags, call

    cmd, re = tools.get_tool(tool)
    if not cmd then
        return false, re
    end

    flags, re = tools.get_tool_flags(tool)
    if not flags then
        return false, re
    end

    call = string.format("%s %s", e2lib.shquote(cmd), flags)

    for _,arg in ipairs(argv) do
        assert(type(arg) == "string")
        call = call .. " " .. e2lib.shquote(arg)
    end

    rc, re = e2lib.callcmd_log(call)
    if not rc or rc ~= 0 then
        return false, re
    end

    return true
end

--- call a tool with argv and capture output
-- @param tool string: tool name as registered in the tools library
-- @param argv table: a vector of (string) arguments
-- @param capturefn function called for ever chunk of output
-- @return bool
-- @return string: the last line ouf captured output
function e2lib.call_tool_argv_capture(tool, argv, capturefn)
    local rc, re, cmd, flags, call

    cmd, re = tools.get_tool(tool)
    if not cmd then
        return false, re
    end

    flags, re = tools.get_tool_flags(tool)
    if not flags then
        return false, re
    end

    call = string.format("%s %s", e2lib.shquote(cmd), flags)

    for _,arg in ipairs(argv) do
        assert(type(arg) == "string")
        call = call .. " " .. e2lib.shquote(arg)
    end

    rc, re = e2lib.callcmd_capture(call, capturefn)
    if rc ~= 0 then
        return false, re
    end

    return true
end

--- call git
-- @param gitdir string: GIT_DIR (optional, defaults to ".git")
-- @param subtool string: git tool name
-- @param args string: arguments to pass to the tool (optional)
-- @return bool
-- @return an error object on failure
function e2lib.git(gitdir, subtool, args)
    local rc, re, e, git, call

    e = err.new("calling git failed")

    if not gitdir then
        gitdir = ".git"
    end

    if not args then
        args = ""
    end

    git, re = tools.get_tool("git")
    if not git then
        return false, e:cat(re)
    end

    call = string.format("GIT_DIR=%s %s %s %s",
        e2lib.shquote(gitdir), e2lib.shquote(git), e2lib.shquote(subtool), args)
    rc, re = e2lib.callcmd_log(call)
    if not rc or rc ~= 0 then
        return false, e:cat(re)
    end

    return true
end

function e2lib.git_argv(argv)
    return e2lib.call_tool_argv("git")
end


--- call the svn command
-- @param argv table: vector with arguments for svn
-- @return bool
function e2lib.svn(argv)
    assert(type(argv) == "table")

    return e2lib.call_tool_argv("svn", argv)
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

--- Close all file descriptors equal or larger than "fd".
-- @param fd file descriptor (number)
-- @return True on success, false on error
-- @return Error object on failure.
-- @raise Error on invalid input.
function e2lib.closefrom(fd)
    local rc, errstring

    rc, errstring = le2lib.closefrom(fd)
    if not rc then
        return false, err.new("closefrom(%d) failed: %s",
            tonumber(fd), errstring)
    end

    return true
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
    local t = e2lib.stat(dir, true)
    if t and t.type == "directory" then
        return true
    end

    return false
end

--- check if path is a file
-- @param dir string: path
-- @return bool
function e2lib.isfile(path)
    local t = e2lib.stat(path, true)
    if t and t.type == "regular" then
        return true
    end
    return false
end

--- Calculate SHA1 sum of a file.
-- @param path string: path
-- @return SHA1 sum of file or false on error.
-- @return Error object on failure.
function e2lib.sha1sum(path)
    local rc, re, e, sha1sum, sha1sum_flags, cmd, p, msg, out, sha1, file

    assert(type(path) == "string")

    e = err.new("calculating SHA1 checksum failed")

    sha1sum, re = tools.get_tool("sha1sum")
    if not sha1sum then
        return false , e:cat(re)
    end

    sha1sum_flags, re = tools.get_tool_flags("sha1sum")
    if not sha1sum_flags then
        return false, e:cat(re)
    end

    cmd = string.format("%s %s %s", e2lib.shquote(sha1sum), sha1sum_flags,
        e2lib.shquote(path))

    p, msg = io.popen(cmd, "r")
    if not p then
        return false, e:cat(msg)
    end

    out, msg = p:read("*l")
    p:close()

    sha1, file = out:match("(%S+)  (%S+)")
    if type(sha1) ~= "string" then
        return false, e:cat("parsing sha1sum output failed")
    end

    return sha1
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

--- Get system architecture.
-- @return Machine hardware name as a string, false on error.
-- @return Error object on failure.
function e2lib.get_sys_arch()
    local rc, re, e, uname, cmd, p, msg, l, arch

    e = err.new("getting host system architecture failed")

    uname, re = tools.get_tool("uname")
    if not uname then
        return false, e:cat(re)
    end

    cmd = string.format("%s -m", e2lib.shquote(uname))
    p, msg = io.popen(cmd, "r")
    if not p then
        return false, e:cat(msg)
    end

    l, msg = p:read()
    if not l then
        return false, e:cat(msg)
    end

    arch = l:match("(%S+)")
    if not arch then
        return false, e:append("%s: %s: cannot parse", cmd, l)
    end

    return arch
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
    f:close()
    if not rc then
        return false, string.format("write failed: %s", msg)
    end
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
    f:close()
    if not s then
        return nil, err.new("%s", msg)
    end
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
-- @param serverloc string: the string to parse
-- @param default_server string: the default server name
-- @return a table with fields server and location, nil on error
-- @return nil, an error string on error
function e2lib.parse_server_location(serverloc, default_server)
    assert(type(serverloc) == 'string' and type(default_server) == 'string')
    local sl = {}
    sl.server, sl.location = serverloc:match("(%S+):(%S+)")
    if not (sl.server and sl.location) then
        sl.location = serverloc:match("(%S+)")
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

    local config, re = e2lib.get_global_config()
    if not config then
        return false, re
    end

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
    rc, re = le2lib.chdir(path)
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
