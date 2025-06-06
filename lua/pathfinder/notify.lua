local M = {}

M.title = "pathfinder.nvim"

function M.notify(msg, level, opts)
	opts = opts or {}
	if not opts.title then
		opts.title = M.title
	end
	return vim.notify(msg, level, opts)
end

function M.info(msg, opts)
	return M.notify(msg, vim.log.levels.INFO, opts)
end

function M.warn(msg, opts)
	return M.notify(msg, vim.log.levels.WARN, opts)
end

function M.error(msg, opts)
	return M.notify(msg, vim.log.levels.ERROR, opts)
end

return M
