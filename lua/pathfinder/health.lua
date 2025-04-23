local M = {}

function M.check()
	vim.health.start("pathfinder")

	-- Check if `curl` is on the user's PATH.
	if vim.fn.executable("curl") == 1 then
		vim.health.ok("`curl` is available")
	else
		vim.health.warn("`curl` is not available, URL opening may fail")
	end
end

return M
