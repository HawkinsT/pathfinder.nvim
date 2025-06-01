local M = {}

local api = vim.api
local candidates = require("pathfinder.candidates")

-- Use collect_candidates_in_range(scan_fn, skip_folds) for each window in
-- opts.win_ids -> filter via validate_fn (optional) -> deduplicate -> return list.
-- opts = { win_ids, buf_of_win, scan_range, scan_fn, skip_folds, validate_fn? }
function M.collect(opts)
	local buf = opts.buf
	local s, e = opts.start_line, opts.end_line
	local skip_folds = opts.skip_folds
	local scan_fn = opts.scan_fn
	local validate_fn = opts.validate_fn

	local all = {}
	for _, win in ipairs(opts.win_ids) do
		if api.nvim_win_is_valid(win) then
			local raw = candidates.collect_candidates_in_range(
				buf,
				win,
				s,
				e,
				scan_fn,
				skip_folds
			)
			vim.list_extend(all, raw)
		end
	end

	if validate_fn then
		local filtered = {}
		for _, c in ipairs(all) do
			if validate_fn(c) then
				filtered[#filtered + 1] = c
			end
		end
		all = filtered
	end

	return candidates.deduplicate_candidates(all)
end

return M
