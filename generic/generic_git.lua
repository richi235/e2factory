--- Git
-- @module generic.generic_git

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

--- functions with '1' postfix take url strings as parameter. the others
-- take server / location

local generic_git = {}
local e2lib = require("e2lib")
local cache = require("cache")
local url = require("url")
local tools = require("tools")
local err = require("err")
local strict = require("strict")

--- Clone a git repository.
-- @param surl URL to the git repository (string).
-- @param destdir Destination on file system (string). Must not exist.
-- @param skip_checkout Pass -n to git clone? (boolean)
-- @return True on success, false on error
-- @return Error object on failure
local function git_clone_url(surl, destdir, skip_checkout)
    local rc, re
    local e = err.new("cloning git repository")

    if (not surl) or (not destdir) then
        return false, err.new("git_clone_url(): missing parameter")
    end

    local u, re = url.parse(surl)
    if not u then
        return false, e:cat(re)
    end

    local src, re = generic_git.git_url1(u)
    if not src then
        return false, e:cat(re)
    end

    local flags = ""
    if skip_checkout then
        flags = "-n"
    end

    local cmd = string.format("git clone %s --quiet %s %s", flags, 
        e2lib.shquote(src), e2lib.shquote(destdir))

    local rc, re = e2lib.callcmd_log(cmd)
    if rc ~= 0 then
        return false, e:cat(re)
    end

    return true, nil
end

--- git branch wrapper
-- @param gitwc string: path to the git repository
-- @param track bool: use --track or --no-track
-- @param branch string: name of the branch to create
-- @param start_point string: where to start the branch
-- @return bool
-- @return nil, an error object on failure
function generic_git.git_branch_new1(gitwc, track, branch, start_point)
    -- git branch [--track|--no-track] <branch> <start_point>
    local f_track = nil
    if track == true then
        f_track = "--track"
    else
        f_track = "--no-track"
    end
    local cmd = string.format( "cd %s && git branch %s %s %s",
    e2lib.shquote(gitwc), f_track, e2lib.shquote(branch),
    e2lib.shquote(start_point))
    local rc = e2lib.callcmd_capture(cmd)
    if rc ~= 0 then
        return false, err.new("creating new branch failed")
    end
    return true, nil
end

--- git checkout wrapper
-- @param gitwc string: path to the git repository
-- @param branch name of the branch to checkout
-- @return bool
-- @return an error object on failure
function generic_git.git_checkout1(gitwc, branch)
    e2lib.logf(3, "checking out branch: %s", branch)
    -- git checkout <branch>
    local cmd = string.format("cd %s && git checkout %s", e2lib.shquote(gitwc),
    e2lib.shquote(branch))
    local rc = e2lib.callcmd_capture(cmd)
    if rc ~= 0 then
        return false, err.new("git checkout failed")
    end
    return true, nil
end

--- git rev-list wrapper function
-- @param gitdir string: GIT_DIR
-- @param ref string: a reference, according to the git manual
-- @return string: the commit id matching the ref parameter, or nil on error
-- @return an error object on failure
function generic_git.git_rev_list1(gitdir, ref)
    local e = err.new("git rev-list failed")
    local rc, re
    local tmpfile = e2lib.mktempfile()
    local args = string.format("--max-count=1 '%s' -- >'%s'", ref, tmpfile)
    rc, re = e2lib.git(gitdir, "rev-list", args)
    if not rc then
        return false, e -- do not include the low-level error here
    end
    local f, msg = io.open(tmpfile, "r")
    if not f then
        return nil, e:cat(msg)
    end
    local rev = f:read()
    f:close()
    e2lib.rmtempfile(tmpfile)
    if (not rev) or (not rev:match("^%S+$")) then
        return nil, err.new("can't parse git rev-list output")
    end
    if rev then
        e2lib.logf(4, "git_rev_list: %s", rev)
    else
        e2lib.logf(4, "git_rev_list: unknown ref: %s", ref)
    end
    return rev, nil
end

--- initialize a git repository
-- @param rurl string: remote url
-- @return bool
-- @return an error object on failure
function generic_git.git_init_db1(rurl)
    if (not rurl) then
        e2lib.abort("git_init_db1(): missing parameter")
    end
    local e = err.new("git_init_db failed")
    local rc, re
    local u, re = url.parse(rurl)
    if not u then
        return false, e:cat(re)
    end
    local rc = false
    local cmd = nil
    local gitdir = string.format("/%s", u.path)
    local gitcmd = string.format("mkdir -p %s && GIT_DIR=%s git init-db --shared",
    e2lib.shquote(gitdir), e2lib.shquote(gitdir))
    if u.transport == "ssh" or u.transport == "scp" or
        u.transport == "rsync+ssh" then
        local ssh = tools.get_tool("ssh")
        cmd = string.format("%s %s %s", e2lib.shquote(ssh), e2lib.shquote(u.server),
        e2lib.shquote(gitcmd))
    elseif u.transport == "file" then
        cmd = gitcmd
    else
        return false, err.new("git_init_db: can not initialize git repository"..
            " on this transport: %s", u.transport)
    end
    rc = e2lib.callcmd_capture(cmd)
    if rc ~= 0 then
        return false, e:append("error running git init-db")
    end
    return true, nil
end

--- do a git push
-- @param gitdir string: absolute path to a gitdir
-- @param rurl string: remote url
-- @param refspec string: a git refspec
-- @return bool
-- @return an error object on failure
function generic_git.git_push1(gitdir, rurl, refspec)
    if (not rurl) or (not gitdir) or (not refspec) then
        e2lib.abort("git_push1(): missing parameter")
    end
    local rc, re
    local e = err.new("git push failed")
    local u, re = url.parse(rurl)
    if not u then
        return false, e:cat(re)
    end
    local remote_git_url, re = generic_git.git_url1(u)
    if not remote_git_url then
        return false, e:cat(re)
    end
    -- GIT_DIR=gitdir git push remote_git_url refspec
    local cmd = string.format("GIT_DIR=%s git push %s %s", e2lib.shquote(gitdir),
    e2lib.shquote(remote_git_url), e2lib.shquote(refspec))
    local rc = e2lib.callcmd_capture(cmd)
    if rc ~= 0 then
        return false, e
    end
    return true, nil
end

--- do a git remote-add
-- @param lurl string: local git repo
-- @param rurl string: remote url
-- @param name string: remote name
-- @return bool
-- @return an error object on failure
function generic_git.git_remote_add1(lurl, rurl, name)
    if (not lurl) or (not rurl) or (not name) then
        e2lib.abort("missing parameter")
    end
    local rc, re
    local e = err.new("git remote-add failed")
    local lrepo, re = url.parse(lurl)
    if not lrepo then
        return false, e:cat(re)
    end
    local rrepo, re = url.parse(rurl)
    if not rrepo then
        return false, e:cat(re)
    end
    local giturl, re = generic_git.git_url1(rrepo)
    if not giturl then
        return false, e:cat(re)
    end
    -- git remote add <name> <giturl>
    local cmd = string.format("cd %s && git remote add %s %s",
    e2lib.shquote("/"..lrepo.path), e2lib.shquote(name), e2lib.shquote(giturl))
    local rc = e2lib.callcmd_capture(cmd)
    if rc ~= 0 then
        return false, e
    end
    return true, nil
end

function generic_git.git_remote_add(c, lserver, llocation, name, rserver, rlocation)
    local rurl, e = cache.remote_url(c, rserver, rlocation)
    if not rurl then
        e2lib.abort(e)
    end
    local lurl, e = cache.remote_url(c, lserver, llocation)
    if not lurl then
        e2lib.abort(e)
    end
    local rc, e = generic_git.git_remote_add1(lurl, rurl, name)
    if not rc then
        e2lib.abort(e)
    end
    return true, nil
end

--- translate a url to a git url
-- @param u url table
-- @return string: the git url
-- @return an error object on failure
function generic_git.git_url1(u)
    local giturl
    if u.transport == "ssh" or u.transport == "scp" or
        u.transport == "rsync+ssh" then
        giturl = string.format("git+ssh://%s/%s", u.server, u.path)
    elseif u.transport == "file" then
        giturl = string.format("/%s", u.path)
    elseif u.transport == "http" or u.transport == "https" or
        u.transport == "git" then
        giturl = string.format("%s://%s/%s", u.transport, u.server, u.path)
    else
        return nil, err.new("git_url1: transport not supported: %s", u.transport)
    end
    return giturl, nil
end

--- clone a git repository by server and location
-- @param c
-- @param server
-- @param location
-- @param destdir string: destination directory
-- @param skip_checkout bool: pass -n to git clone?
-- @return bool
-- @return an error object on failure
function generic_git.git_clone_from_server(c, server, location, destdir,
    skip_checkout)
    local rc, re
    local e = err.new("cloning git repository")
    local surl, re = cache.remote_url(c, server, location)
    if not surl then
        return false, e:cat(re)
    end
    local rc, re = git_clone_url(surl, destdir, skip_checkout)
    if not rc then
        return false, re
    end
    return true, nil
end

--- initialize a git repository
-- @param c a cache
-- @param server string: server name
-- @param location string: location
-- @return bool
-- @return an error object on failure
function generic_git.git_init_db(c, server, location)
    local rc, re
    local e = err.new("initializing git repository")
    local rurl, re = cache.remote_url(c, server, location)
    if not rurl then
        return false, e:cat(re)
    end
    local rc, re = generic_git.git_init_db1(rurl)
    if not rc then
        return false, re
    end
    return true, nil
end

--- do a git push
-- @param c a cache
-- @param gitdir string: gitdir
-- @param server string: server name
-- @param location string: location
-- @param refspec string: a git refspec
-- @return bool
-- @return an error object on failure
function generic_git.git_push(c, gitdir, server, location, refspec)
    local rc, re
    local e = err.new("git push failed")
    local rurl, re = cache.remote_url(c, server, location)
    if not rurl then
        return false, e:cat(re)
    end
    return generic_git.git_push1(gitdir, rurl, refspec)
end

--- do a git config query
-- @param gitdir string: gitdir
-- @param query string: query to pass to git config
-- @return string: the value printed to stdout by git config, or nil
-- @return an error object on failure
function generic_git.git_config(gitdir, query)
    local rc, re
    local e = err.new("running git config")
    local tmpfile = e2lib.mktempfile()
    local cmd = string.format("GIT_DIR=%s git config %s > %s",
    e2lib.shquote(gitdir), e2lib.shquote(query), e2lib.shquote(tmpfile))
    local rc, re = e2lib.callcmd_log(cmd)
    if rc ~= 0 then
        e:append("git config failed")
        return nil, e
    end
    local git_output = e2lib.read_line(tmpfile)
    if not git_output then
        return nil, e:append("can't read git output from temporary file")
    end
    e2lib.rmtempfile(tmpfile)
    return git_output, nil
end

--- do a git add
-- @param gitdir string: gitdir (optional, default: .git)
-- @param args string: args to pass to git add
-- @return bool
-- @return an error object on failure
function generic_git.git_add(gitdir, args)
    local rc, re
    local e = err.new("running git add")
    if not gitdir then
        gitdir = ".git"
    end
    local cmd = string.format("GIT_DIR=%s git add %s",
    e2lib.shquote(gitdir), e2lib.shquote(args))
    local rc, re = e2lib.callcmd_log(cmd)
    if rc ~= 0 then
        return nil, e:cat(re)
    end
    return true, nil
end

--- do a git commit
-- @param gitdir string: gitdir (optional, default: .git)
-- @param args string: args to pass to git add
-- @return bool
-- @return an error object on failure
function generic_git.git_commit(gitdir, args)
    local rc, re
    local e = err.new("git commit failed")
    return e2lib.git("commit", gitdir, args)
end

--- compare a local tag and the remote tag with the same name
-- @param gitdir string: gitdir (optional, default: .git)
-- @param tag string: tag name
-- @return bool, or nil on error
-- @return an error object on failure
function generic_git.verify_remote_tag(gitdir, tag)
    local e = err.new("verifying remote tag")
    local rc, re

    -- fetch the remote tag
    -- TODO: escape args, tag, rtag
    local rtag = string.format("%s.remote", tag)
    local args = string.format("origin refs/tags/%s:refs/tags/%s",
    tag, rtag)
    rc, re = e2lib.git(gitdir, "fetch", args)
    if not rc then
        return false, err.new("remote tag is not available: %s", tag)
    end

    -- store commit ids for use in the error message, if any
    local lrev = generic_git.git_rev_list1(gitdir, tag)
    if not lrev then
        return nil, e:cat(re)
    end
    local rrev = generic_git.git_rev_list1(gitdir, rtag)
    if not rrev then
        return nil, e:cat(re)
    end

    -- check that local and remote tags point to the same revision
    local args = string.format("--quiet '%s' '%s'", rtag, tag)
    local equal, re = e2lib.git(gitdir, "diff", args)

    -- delete the remote tag again, before evaluating the return code
    -- of 'git diff'
    local args = string.format("-d '%s'", rtag)
    rc, re = e2lib.git(gitdir, "tag", args)
    if not rc then
        return nil, e:cat(re)
    end
    if not equal then
        return false, e:append(
        "local tag differs from remote tag\n"..
        "tag name: %s\n"..
        "local:  %s\n"..
        "remote: %s\n", tag, lrev, rrev)
    end
    return true, nil
end

--- verify that the working copy is clean and matches HEAD
-- @param gitwc string: path to a git working tree (default: .)
-- @return bool, or nil on error
-- @return an error object on failure
function generic_git.verify_clean_repository(gitwc)
    gitwc = gitwc or "."
    local e = err.new("verifying that repository is clean")
    local rc, re
    local tmp = e2lib.mktempfile()
    rc, re = e2lib.chdir(gitwc)
    if not rc then
        return nil, e:cat(re)
    end
    -- check for unknown files in the filesystem
    local args = string.format(
    "--exclude-standard --directory --others >%s", tmp)
    rc, re = e2lib.git(nil, "ls-files", args)
    if not rc then
        return nil, e:cat(re)
    end
    local x, msg = io.open(tmp, "r")
    if not x then
        return nil, e:cat(msg)
    end
    local files = x:read("*a")
    x:close()
    if #files > 0 then
        local msg = "the following files are not checked into the repository:\n"
        msg = msg .. files
        return false, err.new("%s", msg)
    end
    -- verify that the working copy matches HEAD
    local args = string.format("--name-only HEAD >%s", tmp)
    rc, re = e2lib.git(nil, "diff-index", args)
    if not rc then
        return nil, e:cat(re)
    end
    local x, msg = io.open(tmp, "r")
    if not x then
        return nil, e:cat(msg)
    end
    local files = x:read("*a")
    x:close()
    if #files > 0 then
        msg = "the following files are modified:\n"
        msg = msg..files
        return false, err.new("%s", msg)
    end
    -- verify that the index matches HEAD
    local args = string.format("--name-only --cached HEAD >%s", tmp)
    rc, re = e2lib.git(nil, "diff-index", args)
    if not rc then
        return nil, e:cat(re)
    end
    local x, msg = io.open(tmp, "r")
    if not x then
        return nil, e:cat(msg)
    end
    local files = x:read("*a")
    x:close()
    if #files > 0 then
        msg = "the following files in index are modified:\n"
        msg = msg..files
        return false, err.new("%s", msg)
    end
    return true
end

--- verify that HEAD matches the given tag
-- @param gitwc string: gitdir (optional, default: .git)
-- @param verify_tag string: tag name
-- @return bool, or nil on error
-- @return an error object on failure
function generic_git.verify_head_match_tag(gitwc, verify_tag)
    assert(verify_tag)
    gitwc = gitwc or "."
    local e = err.new("verifying that HEAD matches 'refs/tags/%s'", verify_tag)
    local rc, re
    local tmp = e2lib.mktempfile()
    local args = string.format("--tags --match '%s' >%s", verify_tag, tmp)
    rc, re = e2lib.chdir(gitwc)
    if not rc then
        return nil, e:cat(re)
    end
    rc, re = e2lib.git(nil, "describe", args)
    if not rc then
        return nil, e:cat(re)
    end
    local x, msg = io.open(tmp, "r")
    if not x then
        return nil, e:cat(msg)
    end
    local tag, msg = x:read()
    x:close()
    if tag == nil then
        return nil, e:cat(msg)
    end
    if tag ~= verify_tag then
        return false
    end
    return true
end

function generic_git.sourceset2ref(sourceset, branch, tag)
    if sourceset == "branch" or
        (sourceset == "lazytag" and tag == "^") then
        return string.format("refs/heads/%s", branch)
    elseif sourceset == "tag" or
        (sourceset == "lazytag" and tag ~= "^") then
        return string.format("refs/tags/%s", tag)
    end
    return nil, "invalid sourceset"
end

--- create a new git source repository
-- @param c cache table
-- @param lserver string: local server
-- @param llocation string: working copy location on local server
-- @param rserver string: remote server
-- @param rlocation string: repository location on remote server
-- @param flags table of flags
-- @return bool
-- @return nil, or an error string on error
function generic_git.new_repository(c, lserver, llocation, rserver, rlocation, flags)
    local rc, re
    local e = err.new("setting up new git repository failed")
    local lserver_url, re = cache.remote_url(c, lserver, llocation)
    if not lserver_url then
        return false, e:cat(re)
    end
    local lurl, re = url.parse(lserver_url)
    if not lurl then
        return false, e:cat(re)
    end
    local rc = e2lib.mkdir(string.format("/%s", lurl.path), "-p")
    if not rc then
        return false, e:cat("can't create path to local git repository")
    end
    rc = generic_git.git_init_db(c, lserver, llocation)
    if not rc then
        return false, e:cat("can't initialize local git repository")
    end
    rc = generic_git.git_remote_add(c, lserver, llocation, "origin",
    rserver, rlocation)
    if not rc then
        return false, e:cat("git remote add failed")
    end
    rc = e2lib.chdir("/"..lurl.path)
    if not rc then
        return false, e:cat(re)
    end
    local targs = {
        string.format("'branch.master.remote' 'origin'"),
        string.format("'branch.master.merge' 'refs/heads/master'"),
    }
    for _,args in ipairs(targs) do
        rc, re = e2lib.git(".", "config", args)
        if not rc then
            return false, e:cat(re)
        end
    end
    rc, re = generic_git.git_init_db(c, rserver, rlocation)
    if not rc then
        return false, e:cat(re)
    end
    return true, nil
end

return strict.lock(generic_git)

-- vim:sw=4:sts=4:et:
