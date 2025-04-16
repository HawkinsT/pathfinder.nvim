local M = {}

local vim = vim

local config = require("pathfinder.config")

--- Define and set highlight groups that both file and URL selectors use.
function M.set_default_highlights()
	-- Each entry is { group_name, highlight_opts }
	local shared_highlights = {
		{ "PathfinderHighlight", { fg = "#DDDDDD", bg = "none" } },
		{ "PathfinderNumberHighlight", { fg = "#00FF00", bg = "none" } },
		{ "PathfinderDim", { fg = "#808080", bg = "none" } },
		{ "PathfinderNextKey", { fg = "#FF00FF", bg = "none" } },
		{ "PathfinderFutureKeys", { fg = "#BB00AA", bg = "none" } },
	}

	for _, item in ipairs(shared_highlights) do
		local group, opts = item[1], item[2]
		local ok, current = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
		if not ok or vim.tbl_isempty(current) then
			vim.api.nvim_set_hl(0, group, opts)
		end
	end
end

--- Returns a list of window IDs in the current tabpage, either all or just current.
function M.get_windows_to_check()
	local current_tabpage = vim.api.nvim_get_current_tabpage()
	if config.config.pick_from_all_windows then
		local wins = vim.api.nvim_tabpage_list_wins(current_tabpage)
		local valid_wins = {}
		for _, win in ipairs(wins) do
			if vim.api.nvim_win_is_valid(win) then
				table.insert(valid_wins, win)
			end
		end
		return valid_wins
	else
		return { vim.api.nvim_get_current_win() }
	end
end

--- Clears dim/highlight extmarks in all relevant windows.
function M.clear_extmarks(windows, highlight_ns, dim_ns)
	local seen_buffers = {}
	for _, win in ipairs(windows) do
		local buf = vim.api.nvim_win_get_buf(win)
		if buf > 0 and not seen_buffers[buf] then
			vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
			vim.api.nvim_buf_clear_namespace(buf, dim_ns, 0, -1)
			seen_buffers[buf] = true
		end
	end
	vim.cmd("redraw")
end

--- Assigns selection labels to a list of candidate objects.
function M.assign_labels(candidates, selection_keys)
	local function calculate_minimum_label_length(n)
		local length = 1
		while true do
			local max_combinations = 1
			for i = 1, length do
				max_combinations = max_combinations * (#selection_keys - i + 1)
			end
			if max_combinations >= n then
				return length
			end
			length = length + 1
		end
	end

	local candidate_count = #candidates
	local label_length = calculate_minimum_label_length(candidate_count)

	local function generate_labels(n)
		local result = {}
		for i = 1, n do
			local label = ""
			local available = vim.deepcopy(selection_keys)
			local index = ((i - 1) % #available) + 1
			label = label .. available[index]
			table.remove(available, index)
			for j = 2, label_length do
				if #available == 0 then
					break
				end
				index = ((i + j - 2) % #available) + 1
				label = label .. available[index]
				table.remove(available, index)
			end
			table.insert(result, label)
		end
		return result
	end

	local labels = generate_labels(candidate_count)
	for i, cand in ipairs(candidates) do
		cand.label = labels[i]
	end
end

--- Returns the subset of candidates whose labels start with 'input'.
function M.get_matching_candidates(candidates, input)
	local matches = {}
	for _, candidate in ipairs(candidates) do
		if candidate.label:sub(1, #input) == input then
			table.insert(matches, candidate)
		end
	end
	return matches
end

--- Dims all visible lines, then calls highlight_candidate() for each candidate.
function M.update_highlights(candidates, input_prefix, highlight_ns, dim_ns, highlight_candidate)
	local windows = M.get_windows_to_check()

	-- First clear existing extmarks
	local seen_buffers = {}
	for _, win in ipairs(windows) do
		local buf = vim.api.nvim_win_get_buf(win)
		if buf > 0 and not seen_buffers[buf] then
			vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
			vim.api.nvim_buf_clear_namespace(buf, dim_ns, 0, -1)
			seen_buffers[buf] = true
		end
	end

	-- Dim all lines in the visible region of each window
	for _, win in ipairs(windows) do
		local buf = vim.api.nvim_win_get_buf(win)
		local win_start = vim.fn.line("w0", win)
		local win_end = vim.fn.line("w$", win)
		for line = win_start, win_end do
			local line_text = vim.fn.getbufline(buf, line)[1] or ""
			vim.api.nvim_buf_set_extmark(buf, dim_ns, line - 1, 0, {
				end_col = #line_text,
				hl_group = "PathfinderDim",
				hl_eol = true,
				priority = 10000,
			})
		end
	end

	-- Now apply the domain-specific highlight logic for each candidate
	for _, cand in ipairs(candidates) do
		highlight_candidate(cand, input_prefix, highlight_ns)
	end

	vim.cmd("redraw")
end

--- The main input loop that starts with an immediate highlight, then reads user keystrokes.
function M.start_selection_loop(
	candidates,
	selection_keys,
	highlight_ns,
	dim_ns,
	highlight_candidate, -- function(candidate, input_prefix, highlight_ns)
	on_complete,
	required_length
)
	local user_input = ""

	-- Highlight everything right away (so it’s visible before first keystroke)
	M.update_highlights(candidates, user_input, highlight_ns, dim_ns, highlight_candidate)

	-- Now read keystrokes
	while true do
		local ok, key = pcall(vim.fn.getchar)
		if not ok or not key then
			break
		end

		local backspace_tc = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
		local is_backspace = (key == 8 or key == 127 or (type(key) == "string" and key == backspace_tc))
		if is_backspace then
			if #user_input > 0 then
				user_input = user_input:sub(1, -2)
			else
				-- No more input to delete => cancel
				local windows = M.get_windows_to_check()
				M.clear_extmarks(windows, highlight_ns, dim_ns)
				return
			end
		else
			local char = type(key) == "number" and vim.fn.nr2char(key) or key
			user_input = user_input .. char
		end

		M.update_highlights(candidates, user_input, highlight_ns, dim_ns, highlight_candidate)
		local matches = M.get_matching_candidates(candidates, user_input)

		-- If no matches, cancel
		if #matches == 0 then
			local windows = M.get_windows_to_check()
			M.clear_extmarks(windows, highlight_ns, dim_ns)
			return
		end

		-- If exactly one match with a fully typed label, we’re done
		if #matches == 1 and #user_input == required_length then
			local windows = M.get_windows_to_check()
			M.clear_extmarks(windows, highlight_ns, dim_ns)
			vim.schedule(function()
				on_complete(matches[1])
			end)
			return
		end
	end
end

return M
