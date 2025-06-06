local M = {}

local notify = require("pathfinder.notify")

-- Minimum supported Neovim version.
local required_version = { major = 0, minor = 10, patch = 0 }

local function fmt(v)
	return string.format("%d.%d.%d", v.major, v.minor, v.patch)
end

-- Check compatibility between current and required Neovim versions.
function M.is_compatible()
	local current = vim.version()
	for _, key in ipairs({ "major", "minor", "patch" }) do
		if current[key] < required_version[key] then
			return false, current, required_version
		elseif current[key] > required_version[key] then
			return true, current, required_version
		end
	end
	return true, current, required_version
end

-- Notify user about incompatible Neovim version.
function M.notify(current)
	local cur_str = fmt(current)
	local req_str = fmt(required_version)
	notify.warn(
		string.format(
			"pathfinder.nvim: Incompatible Neovim version (%s < %s).\n"
				.. "Plugin functionality is disabled.",
			cur_str,
			req_str
		)
	)
end

-- Report health check results for Neovim version.
function M.health()
	local ok, current = M.is_compatible()
	local req_str = fmt(required_version)
	if ok then
		vim.health.ok("Neovim version is >= " .. req_str)
	else
		local cur_str = fmt(current)
		vim.health.warn(
			string.format(
				"Neovim version is %s, but pathfinder.nvim requires %s.",
				cur_str,
				req_str
			)
		)
	end
end

return M
