--- e2-build command
-- @module local.e2-build

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

local cache = require("cache")
local console = require("console")
local e2build = require("e2build")
local e2lib = require("e2lib")
local e2option = require("e2option")
local e2tool = require("e2tool")
local err = require("err")
local policy = require("policy")
local scm = require("scm")

local function e2_build(arg)
    local rc, re = e2lib.init()
    if not rc then
        error(re)
    end

    local info, re = e2tool.local_init(nil, "build")
    if not info then
        error(re)
    end

    e2option.flag("all", "build all results (default unless for working copy)")
    policy.register_commandline_options()
    e2option.flag("branch-mode", "build selected results in branch mode")
    e2option.flag("wc-mode", "build selected results in working-copy mode")
    e2option.flag("force-rebuild", "force rebuilding even if a result exists [broken]")
    e2option.flag("playground", "prepare environment but do not build")
    e2option.flag("keep", "do not remove chroot environment after build")
    e2option.flag("buildid", "display buildids and exit")
    -- cache is not yet initialized when parsing command line options, so
    -- remember settings in order of appearance, and perform settings as soon
    -- as the cache is initialized.
    local writeback = {}
    local function disable_writeback(server)
        table.insert(writeback, { set = "disable", server = server })
    end
    local function enable_writeback(server)
        table.insert(writeback, { set = "enable", server = server })
    end
    local function perform_writeback_settings(writeback)
        local rc, re
        local enable_msg = "enabling writeback for server '%s' [--enable-writeback]"
        local disable_msg =
        "disabling writeback for server '%s' [--disable-writeback]"
        for _,set in ipairs(writeback) do
            if set.set == "disable" then
                e2lib.logf(3, disable_msg, set.server)
                rc, re = cache.set_writeback(info.cache, set.server, false)
                if not rc then
                    local e = err.new(disable_msg, set.server)
                    error(e:cat(re))
                end
            elseif set.set == "enable" then
                e2lib.logf(3, enable_msg, set.server)
                rc, re = cache.set_writeback(info.cache, set.server, true)
                if not rc then
                    local e = err.new(enable_msg, set.server)
                    error(e:cat(re))
                end
            end
        end
    end
    e2option.option("disable-writeback", "disable writeback for server", nil,
    disable_writeback, "SERVER")
    e2option.option("enable-writeback", "enable writeback for server", nil,
    enable_writeback, "SERVER")

    local opts, arguments = e2option.parse(arg)
    if not opts then
        error(arguments)
    end

    -- get build mode from the command line
    local build_mode, re = policy.handle_commandline_options(opts, true)
    if not build_mode then
        error(re)
    end

    info, re = e2tool.collect_project_info(info)
    if not info then
        error(re)
    end

    perform_writeback_settings(writeback)

    -- apply the standard build mode to all results
    for _,res in pairs(info.results) do
        res.build_mode = build_mode
    end

    -- handle result selection
    local results = {}

    if opts["all"] and #arguments ~= 0 then
        e2lib.abort("--all with additional results does not make sense")
    elseif opts["all"] then
        for r,_ in pairs(info.results) do
            table.insert(results, r)
        end
    elseif #arguments > 0 then
        for i,r in ipairs(arguments) do
            table.insert(results, r)
        end
    end

    -- handle command line flags
    local build_mode = nil
    if opts["branch-mode"] and opts["wc-mode"] then
        e = err.new("--branch-mode and --wc-mode are mutually exclusive")
        error(e)
    end
    if opts["branch-mode"] then
        -- selected results get a special build mode
        build_mode = policy.default_build_mode("branch")
    end
    if opts["wc-mode"] then
        if #results == 0 then
            e2lib.abort("--wc-mode requires one or more results")
        end
        build_mode = policy.default_build_mode("working-copy")
    end
    local playground = opts["playground"]
    if playground then
        if opts.release then
            error(err.new("--release and --playground are mutually exclusive"))
        end
        if opts.all then
            error(err.new("--all and --playground are mutually exclusive"))
        end
        if #arguments ~= 1 then
            error(err.new("please select one single result for the playground"))
        end
    end
    local force_rebuild = opts["force-rebuild"]
    local keep_chroot = opts["keep"]

    -- apply flags to the selected results
    rc, re = e2tool.select_results(info, results, force_rebuild,
        keep_chroot, build_mode, playground)
    if not rc then
        error(re)
    end

    -- a list of results to build, topologically sorted
    local sel_res = {}
    if #results > 0 then
        local re
        sel_res, re = e2tool.dlist_recursive(info, results)
        if not sel_res then
            error(re)
        end
    else
        local re
        sel_res, re = e2tool.dsort(info)
        if not sel_res then
            error(re)
        end
    end

    rc, re = e2tool.print_selection(info, sel_res)
    if not rc then
        error(re)
    end

    if opts.release then
        local version_table, re = e2lib.parse_e2versionfile(
            e2lib.join(info.root, e2lib.globals.e2version_file))
        if not version_table then
           error(re)
        end

        if version_table.tag == "^" then
            error(
                err.new("e2 is on a pseudo tag while building in release mode."))
        end
    end

    -- calculate buildids for selected results
    for _,r in ipairs(sel_res) do
        local bid, re = e2tool.buildid(info, r)
        if not bid then
            error(re)
        end
    end

    if opts["buildid"] then
        for _,r in ipairs(sel_res) do
            local bid, re = e2tool.buildid(info, r)
            if not bid then
                error(re)
            end
            console.infof("%-20s [%s]\n", r, bid)
        end
    else
        -- build
        local rc, re = e2build.build_results(info, sel_res)
        if not rc then
            error(re)
        end
    end
end

local pc, re = e2lib.trycall(e2_build, arg)
if not pc then
    e2lib.abort(re)
end

e2lib.finish(0)

-- vim:sw=4:sts=4:et:
