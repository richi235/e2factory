--- Generic git interface. Not to be confused with the git plugin which is
-- only responsible for dealing with sources. Functions with '1' postfix
-- take url strings as parameter. The others take server / location.
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

local generic_git = {}
local e2lib = require("e2lib")
local eio = require("eio")
local cache = require("cache")
local url = require("url")
local tools = require("tools")
local err = require("err")
local strict = require("strict")

--- Trim off whitespaces and newline at the front and back of a string.
-- @param str String to trim.
-- @return Trimmed string.
local function trim(str)
    return string.match(str, "^%s*(.-)%s*$")
end

--- Clone a git repository.
-- @param surl URL to the git repository (string).
-- @param destdir Destination on file system (string). Must not exist.
-- @param skip_checkout Pass -n to git clone? (boolean).
-- @return True on success, false on error.
-- @return Error object on failure.
local function git_clone_url(surl, destdir, skip_checkout)
    local rc, re, e, u, src, argv

    e = err.new("cloning git repository")

    if not surl or not destdir then
        return false, err.new("git_clone_url(): missing parameter")
    end

    u, re = url.parse(surl)
    if not u then
        return false, e:cat(re)
    end

    src, re = generic_git.git_url1(u)
    if not src then
        return false, e:cat(re)
    end

    argv = { "clone" }

    if skip_checkout then
        table.insert(argv, "-n")
    end

    table.insert(argv, "--quiet")
    table.insert(argv, src)
    table.insert(argv, destdir)

    rc, re = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    return true
end

--- Create argument vector for calling git.
-- Defaults: If git_dir is given and the default for work_tree is requested,
-- it's assumed to be one directory level up. If work_tree is given and the
-- default for git_dir is requested, it's work_tree/.git. If neither are given,
-- git_dir defaults to '.git' and work_tree to '.'.
-- @param gitdir Git repository directory, nil for the default and false to omit.
-- @param gitwc Git working copy directory, nil for the default and false to omit.
-- @param ... Further arguments are added to the end of the argument vector.
-- @return Argument vector table.
local function git_new_argv2(git_dir, work_tree, ...)
    local argv = {...}

    if git_dir == nil and work_tree == nil then
        e2lib.abort("git_new_argv2: git_dir == nil and work_tree == nil")
    end

    if git_dir == nil then
        if work_tree then
            git_dir = e2lib.join(work_tree, ".git")
        else
            git_dir = ".git"
        end
    end
    if work_tree == nil then
        if git_dir then
            work_tree = e2lib.dirname(git_dir)
        else
            work_tree = "."
        end
    end

    if work_tree then
        table.insert(argv, 1, "--work-tree="..work_tree)
    end
    if git_dir then
        table.insert(argv, 1, "--git-dir="..git_dir)
    end

    return argv
end

function generic_git.git_new_argv(git_dir, work_tree, ...)
    return git_new_argv2(git_dir, work_tree, ...)
end

--- Call out to git. XXX: replace e2lib.git with this.
-- @param argv Array of arguments to git.
-- @return True on success, false on error.
-- @return Error object on failure.
-- @return Any captured git output or the empty string if nothing was captured.
function generic_git.git(argv)
    local rc, re, e, git, cmd, fifo, out

    git, re = tools.get_tool("git")
    if not git then
        return false, re
    end

    cmd = e2lib.shquote(git)
    for _,arg in ipairs(argv) do
        cmd = cmd .. " "
        cmd = cmd .. e2lib.shquote(arg)
    end

    -- fifo contains the last 4 lines, out everything - it's simpler that way.
    fifo = {}
    out = {}

    local function capture(msg)
        if msg == "" then
            return
        end

        if #fifo > 4 then
            table.remove(fifo, 1)
        end

        e2lib.log(3, msg)
        table.insert(fifo, msg)
        table.insert(out, msg)
    end

    rc, re = e2lib.callcmd_capture(cmd, capture)
    if not rc then
        e = new.new("git command %q failed", cmd)
        return false, e:cat(re), table.concat(out)
    elseif rc ~= 0 then
        e = err.new("git command %q failed with exit status %d", cmd, rc)
        for _,v in ipairs(fifo) do
            e:append("%s", v)
        end
        return false, e, table.concat(out)
    end

    return true, nil, table.concat(out)
end

--- Return a table containing pairs of commit id and refs of the local
-- or remote repository.
-- @param git_dir Path to GIT_DIR.
-- @param remote True for the remote default repository (usually "origin"),
--               false for the local repository.
-- @return Table containing tables of "id", "ref" pairs, or false on error.
-- @return Error object on failure.
local function get_refs(git_dir, remote)
    local rc, re, e, argv, out, t, emsg

    emsg = "error in get_refs()"

    if type(remote) ~= "boolean" then
        return false, err.new("%s: remote is not of type boolean", emsg)
    end

    argv = git_new_argv2(git_dir, false)
    if remote then
        table.insert(argv, "ls-remote")
        table.insert(argv, "origin")
    else
        table.insert(argv, "show-ref")
        table.insert(argv, "--head") -- ls-remote does this by default
    end

    rc, re, out = generic_git.git(argv)
    if not rc then
        e = err.new(emsg)
        return false, e:cat(re)
    end

    t = {}
    for id, ref in string.gmatch(out, "(%x+)%s+(%S+)%s+") do
        if string.len(id) ~= 40 then
            return false, err.new("%s: malformed commit ID", emsg)
        end
        if string.len(ref) == 0 then
            return false, err.new("%s: empty ref", emsg)
        end
        table.insert(t, { id=id, ref=ref })
    end

    if #t == 0 then
        return false,
            err.new("%s: no references found in git output", emsg)
    end

    return true, nil, t
end

--- Search id for a given ref (tags, branches) in either local or remote
-- repository.
-- @param git_dir Path to GIT_DIR.
-- @param remote True for remote repository, false for local repository.
-- @param ref Full ref string.
-- @return True on success, false on error.
-- @return Error object on failure.
-- @return Commit ID string on successful lookup, false otherwise.
function generic_git.lookup_id(git_dir, remote, ref)
    local rc, re, t

    rc, re, t = get_refs(git_dir, remote)
    if not rc then
        return false, re
    end

    for _,r in ipairs(t) do
        if r.ref == ref then
            return true, nil, r.id
        end
    end

    return true, nil, false
end

--- Search ref for a given commit id in either local or remote repository.
-- The first matching ref is returned. Use filter to check for specific refs.

-- @param git_dir Path to GIT_DIR.
-- @param remote True for remote repository, false for local repository.
-- @param id Full commit ID string, must be 40 chars long.
-- @param filter Filter string to select specific refs. Filter is passed to
--               string.match(), and is always anchored (^) to the start of
--               the ref. False disables filtering.
-- @return True on success, false on error.
-- @return Error object on failure.
-- @return Pathspec ref string on successful lookup, false otherwise.
function generic_git.lookup_ref(git_dir, remote, id, filter)
    local rc, re, t

    if string.len(id) ~= 40 then
        return false, err.new("error in lookup_ref(): malformed commit ID")
    end

    if not (filter == false or type(filter) == "string") then
        return false,
            err.new("error in lookup_ref(): filter argument of wrong type")
    end

    rc, re, t = get_refs(git_dir, remote)
    if not rc then
        return false, re
    end

    if filter == false then
        filter = ".*"
    end

    for _,r in ipairs(t) do
        if string.match(r.ref, "^" .. filter) then
            if r.id == id then
                return true, nil, r.ref
            end
        end
    end

    return true, nil, false
end

--- Git branch wrapper. Sets up a branch, but does not switch to it.
-- @param gitwc Path to the git repository.
-- @param track Use --track if true, otherwise use --no-track.
-- @param branch Name of the branch to create.
-- @param start_point Start of the branch (string).
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.git_branch_new1(gitwc, track, branch, start_point)
    local rc, re, e, argv

    argv = git_new_argv2(nil, gitwc, "branch")

    if track == true then
        table.insert(argv, "--track")
    else
        table.insert(argv, "--no-track")
    end

    table.insert(argv, branch)
    table.insert(argv, start_point)

    rc, re = generic_git.git(argv)
    if not rc then
        e = err.new("creating new branch failed")
        return false, e:cat(re)
    end

    return true
end

--- Git checkout wrapper.
-- @param gitwc Path to the git working directory.
-- @param branch Branch name to check out.
-- @return True on success, false on error.
-- @return An error object on failure.
function generic_git.git_checkout1(gitwc, branch)
    local rc, re, e, argv

    argv = git_new_argv2(nil, gitwc, "checkout", branch)
    rc, re = generic_git.git(argv)
    if not rc then
        e = err.new("git checkout failed")
        return false, e:cat(re)
    end

    return true
end

--- Initialize a git repository.
-- @param rurl URL string where the repository should be created.
-- @param shared Should the repository be shared with other users or not.
--               Defaults to true.
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.git_init_db1(rurl, shared)
    local rc, re, e, u, gitdir, gitargv, argv

    -- XXX: Remove the default behaviour and require a choice
    if shared == nil then
        shared = true
    end

    if not rurl then
        return false, err.new("git_init_db1(): missing parameter")
    end

    e = err.new("git_init_db failed")

    u, re = url.parse(rurl)
    if not u then
        return false, e:cat(re)
    end

    gitdir = e2lib.join("/", u.path);
    gitargv = { "--git-dir="..gitdir, "init-db" }
    if shared then
        table.insert(gitargv, "--shared")
    end

    if u.transport == "ssh" or u.transport == "scp" or
        u.transport == "rsync+ssh" then

        argv = { "mkdir", "-p", gitdir }
        rc, re = e2lib.ssh_remote_cmd(u, argv)
        if not rc then
            return false, e:cat(re)
        end

        table.insert(gitargv, 1, "git")
        rc, re = e2lib.ssh_remote_cmd(u, gitargv)
        if not rc then
            return false, e:cat(re)
        end
    elseif u.transport == "file" then
        rc, re = e2lib.mkdir_recursive(gitdir)
        if not rc then
            return false, e:cat(re)
        end

        rc, re = generic_git.git(gitargv)
        if not rc then
            return false, e:cat(re)
        end
    else
        return false, err.new("git_init_db: initializing git repository"..
            " on transport %q is not supported", u.transport)
    end

    return true
end

--- Git push.
-- @param gitdir Absolute path to git-dir
-- @param rurl URL string to repository.
-- @param refspec string: a git refspec
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.git_push1(gitdir, rurl, refspec)
    local rc, re, e, u, remote_git_url, argv

    if not rurl or not gitdir or not refspec then
        return false, err.new("git_push1(): missing parameter")
    end

    e = err.new("git push failed")
    u, re = url.parse(rurl)
    if not u then
        return false, e:cat(re)
    end

    remote_git_url, re = generic_git.git_url1(u)
    if not remote_git_url then
        return false, e:cat(re)
    end

    argv = { "--git-dir=" .. gitdir, "push", remote_git_url, refspec }
    rc, re = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    return true
end

--- Git remote add. XXX: local to generic_git
-- @param lurl string: local git repo
-- @param rurl string: remote url
-- @param name string: remote name
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.git_remote_add1(lurl, rurl, name)
    local rc, re, e, lrepo, rrepo, giturl, gitdir, argv

    if not lurl or not rurl or not name then
        return false, err.new("git_remote_add1: missing parameter")
    end

    e = err.new("git remote-add failed")
    lrepo, re = url.parse(lurl)
    if not lrepo then
        return false, e:cat(re)
    end

    rrepo, re = url.parse(rurl)
    if not rrepo then
        return false, e:cat(re)
    end

    giturl, re = generic_git.git_url1(rrepo)
    if not giturl then
        return false, e:cat(re)
    end

    gitdir = e2lib.join("/", lrepo.path)
    argv = { "--git-dir="..gitdir, "remote", "add", name, giturl }

    rc, re = generic_git.git(argv)
    if not rc then
        return false, re
    end

    return true
end

--- Add git remote. XXX: Local to to generic_git
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.git_remote_add(c, lserver, llocation, name, rserver, rlocation)
    local rc, re, rurl, lurl

    rurl, re = cache.remote_url(c, rserver, rlocation)
    if not rurl then
        return false, re
    end

    lurl, re = cache.remote_url(c, lserver, llocation)
    if not lurl then
        return false, re
    end

    rc, re = generic_git.git_remote_add1(lurl, rurl, name)
    if not rc then
        return false, re
    end

    return true
end

--- Generate git URL string from URL object.
-- @param u URL object
-- @return Git URL string or false on error.
-- @return Error object on failure.
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
        return false,
            err.new("git_url1: transport not supported: %s", u.transport)
    end

    return giturl
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

--- Git config query. XXX: used only in git plugin
-- @param gitdir string: gitdir
-- @param query string: query to pass to git config
-- @return Value printed to stdout by git config, or false on error.
-- @return Error object on failure.
function generic_git.git_config(gitdir, query)
    local e, rc, re, argv, out

    argv = git_new_argv2(gitdir, false, "config", query)
    rc, re, out = generic_git.git(argv)
    if not rc then
        e = err.new("git config failed")
        return false, e:cat(re)
    end

    return trim(out)
end

--- Git add.
-- @param gitdir Path to GIT_DIR.
-- @param argv Argument vector to pass to git add, usually the files to add.
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.git_add(gitdir, argv)
    local rc, re, e, v

    v = git_new_argv2(gitdir, nil, "add", unpack(argv))

    rc, re = generic_git.git(v)
    if not rc then
        e = err.new("git add failed")
        return false, e:cat(re)
    end

    return true
end

--- Git commit.
-- @param gitdir Path to GIT_DIR.
-- @param argv Argument vector to pass to git commit, like a comment.
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.git_commit(gitdir, argv)
    local e, rc, re, v

    v = git_new_argv2(gitdir, false, "commit", unpack(argv))

    rc, re = generic_git.git(v)
    if not rc then
        e = err.new("git commit failed")
        return false, e:cat(re)
    end

    return true
end

--- Check local tag and the remote tag point to the same commit.
-- @param gitdir Path to GIT_DIR.
-- @param tag Git tag name.
-- @return True on success, false on error or mismatch.
-- @return Error object on failure.
function generic_git.verify_remote_tag(gitdir, tag)
    local e = err.new("verifying remote tag")
    local rc, re, rtag, argv, rid, lid

    rc, re, rid = generic_git.lookup_id(gitdir, true, "refs/tags/" .. tag)
    if not rc then
        return false, e:cat(re)
    end

    if not rid then
        re = err.new("can not find commit ID for remote tag %q in %q",
            gitdir, tag)
        return false, e:cat(re)
    end

    rc, re, lid = generic_git.lookup_id(gitdir, false, "refs/tags/" .. tag)
    if not rc then
        return false, e:cat(re)
    end

    if rid ~= lid then
        re = err.new("can not find commit ID for local tag %q in %q",
            gitdir, tag)
        return false, e:cat(re)
    end

    if lid ~= rid then
        return false, e:append(
        "local tag differs from remote tag\n"..
        "tag name: %s\n"..
        "local:  %s\n"..
        "remote: %s\n", tag, lid, rid)
    end

    return true
end

--- Verify that the working copy is clean and matches HEAD. XXX: only in e2tool
-- @param gitwc Path to git working tree.
-- @return True if the working copy is clean, false on any error.
-- @return Error object on failure.
-- @return True if the error is because the work tree is dirty.
function generic_git.verify_clean_repository(gitwc)
    local e, rc, re, out, argv, files

    e = err.new("verifying that repository is clean failed")

    -- check for unknown files in the filesystem
    argv = git_new_argv2(nil, gitwc, "ls-files", "--exclude-standard",
        "--directory", "--others")

    rc, re, files = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    if string.len(files) > 0 then
        re = err.new("the following files are not checked in:\n%s", files)
        return false, e:cat(re), true
    end

    -- verify that the working copy matches HEAD
    argv = git_new_argv2(nil, gitwc, "diff-index", "--name-only", "HEAD")

    rc, re, files = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    if string.len(files) > 0 then
        re = err.new("the following files are modified:\n%s", files)
        return false, e:cat(re), true
    end

    -- verify that the index matches HEAD
    argv = git_new_argv2(nil, gitwc, "diff-index", "--name-only",
        "--cached", "HEAD")
    rc, re, files = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    if string.len(files) > 0 then
        re =
            err.new("the following files in the index are modified:\n%s", files)
        return false, e:cat(re), true
    end

    return true
end

--- verify that HEAD matches the given tag. XXX: only used in e2tool
-- @param gitwc Path to git work tree.
-- @param verify_tag Git tag to verify.
-- @return True on success, false on error and mismatch.
-- @return Error object on failure.
-- @return True on mismatch.
function generic_git.verify_head_match_tag(gitwc, verify_tag)
    local rc, re, e, argv, tag

    e = err.new("verifying that HEAD matches 'refs/tags/%s'", verify_tag)

    argv = git_new_argv2(nil, gitwc, "describe", "--tags",
        "--match", verify_tag)

    rc, re, tag = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    tag = trim(tag)
    if tag ~= verify_tag then
        return false, err.new("tag %q does not match expected tag %q",
            tag, verify_tag), true
    end

    return true
end

---
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

--- Create a new git source repository. XXX: only used in e2-new-source
-- @param c cache table
-- @param lserver string: local server
-- @param llocation string: working copy location on local server
-- @param rserver string: remote server
-- @param rlocation string: repository location on remote server
-- @param flags table of flags XXX: unused
-- @return True on success, false on error.
-- @return Error object on failure.
function generic_git.new_repository(c, lserver, llocation, rserver, rlocation, flags)
    local rc, re, e, lserver_url, lurl, targs, gitdir, argv

    e = err.new("setting up new git repository failed")

    lserver_url, re = cache.remote_url(c, lserver, llocation)
    if not lserver_url then
        return false, e:cat(re)
    end

    lurl, re = url.parse(lserver_url)
    if not lurl then
        return false, e:cat(re)
    end

    gitdir = e2lib.join("/", lurl.path)
    rc, re = e2lib.mkdir_recursive(gitdir)
    if not rc then
        e:cat("can't create path to local git repository")
        return false, e:cat(re)
    end

    rc, re = generic_git.git_init_db(c, lserver, llocation)
    if not rc then
        e:cat("can't initialize local git repository")
        return false, e:cat(re)
    end

    rc, re = generic_git.git_remote_add(c, lserver, llocation, "origin", rserver, rlocation)
    if not rc then
        return false, e:cat(re)
    end

    argv = { "--git-dir="..gitdir, "config", "branch.master.remote", "origin" }
    rc, re = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    argv = { "--git-dir="..gitdir, "config", "branch.master.merge",
        "refs/heads/master" }
    rc, re = generic_git.git(argv)
    if not rc then
        return false, e:cat(re)
    end

    rc, re = generic_git.git_init_db(c, rserver, rlocation)
    if not rc then
        return false, e:cat(re)
    end

    return true
end

return strict.lock(generic_git)

-- vim:sw=4:sts=4:et:
