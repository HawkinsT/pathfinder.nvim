local api = vim.api
local candidates = require("pathfinder.candidates")

local M = {}

--- Use collect_candidates_in_range(scan_fn, skip_folds) for each window in
--- opts.win_ids -> filter via validate_fn (optional) -> deduplicate -> return list
--- opts = { win_ids, buf_of_win, scan_range, scan_fn, skip_folds, validate_fn? }
function M.collect(opts)
	local all = {}
	for _, win in ipairs(opts.win_ids) do
		if api.nvim_win_is_valid(win) then
			local buf = opts.buf_of_win(win)
			local s, e = opts.scan_range(win)
			local raw = candidates.collect_candidates_in_range(buf, win, s, e, opts.scan_fn, opts.skip_folds)
			vim.list_extend(all, raw)
		end
	end

	if opts.validate_fn then
		local f = {}
		for _, c in ipairs(all) do
			if opts.validate_fn(c) then
				table.insert(f, c)
			end
		end
		all = f
	end

	return candidates.deduplicate_candidates(all)
end

return M
