local M = {}

local version = require("pathfinder.version")

function M.check()
	vim.health.start("pathfinder")

	version.health()

	-- Check if `curl` is on the user's PATH.
	if vim.fn.executable("curl") == 1 then
		vim.health.ok("`curl` is available")
	else
		vim.health.warn("`curl` is not available, URL opening may fail")
	end

	-- Check for /proc if on native Windows (not WSL).
	if vim.fn.has("win32") == 1 and vim.fn.has("wsl") == 0 then
		local stat = vim.loop.fs_stat("/proc/version")
		if stat then
			vim.health.ok("`/proc` is available")
		else
			vim.health.warn(
				"`/proc` is not available, terminal directory resolution may fail",
				{
					"Install Cygwin/MSYS2 or run Neovim inside WSL",
					"Download from https://cygwin.com or http://msys2.org",
				}
			)
		end
	end
end

return M
