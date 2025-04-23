local api = vim.api
local candidates = require("pathfinder.candidates")
local visual_select = require("pathfinder.visual_select")

local M = {}

--- Interactive picker: scan -> (opt) validate -> dedupe -> label -> select loop
--- opts = {
---   win_ids, buf_of_win, scan_range, scan_fn, skip_folds,
---   validate_fn (cand→bool)?, dedupe_fn?, label_keys,
---   highlight_ns, dim_ns, highlight_fn, on_select
--- }
function M.pick(opts)
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

	local uniq = opts.dedupe_fn and opts.dedupe_fn(all) or candidates.deduplicate_candidates(all)

	if #uniq == 0 then
		vim.notify("No candidates found", vim.log.levels.INFO)
		return
	end

	visual_select.assign_labels(uniq, opts.label_keys)
	local req = #uniq[1].label
	visual_select.start_selection_loop(uniq, opts.highlight_ns, opts.dim_ns, opts.highlight_fn, opts.on_select, req)
end

--- Non‑UI collector: scan -> (opt) validate -> dedupe -> return list
--- opts = { win_ids, buf_of_win, scan_range, scan_fn, skip_folds, validate_fn?, dedupe_fn?  }
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

	local uniq = opts.dedupe_fn and opts.dedupe_fn(all) or candidates.deduplicate_candidates(all)

	return uniq
end

return M
