--- e2-build-numbers command.
-- This command was removed in e2factory 2.3.13.
-- @module local.e2-build-numbers

--[[
   e2factory, the emlix embedded build system

   Copyright (C) Tobias Ulmer <tu@emlix.com>, emlix GmbH

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
local e2tool = require("e2tool")
local err = require("err")

e2lib.init()
local info, re = e2tool.local_init(nil, "build-numbers")
if not info then
    e2lib.abort(re)
end

e2lib.abort(err.new("e2-build-numbers is deprecated and has been removed"))

-- vim:sw=4:sts=4:et:
