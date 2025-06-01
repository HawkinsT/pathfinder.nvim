local M = {}

local vim = vim

local config = require("pathfinder.config")

function M.set_default_highlights()
	local shared_highlights = {
		{ "PathfinderHighlight", { fg = "#DDDDDD", bg = "none" } },
		{ "PathfinderNumberHighlight", { fg = "#00FF00", bg = "none" } },
		{ "PathfinderColumnHighlight", { fg = "#FFFF00", bg = "none" } },
		{ "PathfinderDim", { fg = "#808080", bg = "none" } },
		{ "PathfinderNextKey", { fg = "#FF00FF", bg = "none" } },
		{ "PathfinderFutureKeys", { fg = "#BB00AA", bg = "none" } },
	}

	for _, item in ipairs(shared_highlights) do
		local group, opts = item[1], item[2]
		local ok, current =
			pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
		if not ok or vim.tbl_isempty(current) then
			vim.api.nvim_set_hl(0, group, opts)
		end
	end
end

M.HIGHLIGHT_NS = vim.api.nvim_create_namespace("pathfinder_highlight")
M.DIM_NS = vim.api.nvim_create_namespace("pathfinder_dim")

local function highlight_spans(buf, ns, spans, hl_group)
	if not spans then
		return
	end
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, ns, span.lnum - 1, span.start_col, {
			hl_group = hl_group,
			end_col = span.finish_col + 1,
			priority = 10001,
		})
	end
end

function M.highlight_candidate(candidate, input_prefix, ns)
	local buf = candidate.buf_nr
	local label = candidate.label or ""
	local is_match = label:sub(1, #input_prefix) == input_prefix

	local hl_group = is_match and "PathfinderHighlight" or "PathfinderDim"

	-- Build virt_text on matches.
	local leftover = label:sub(#input_prefix + 1)
	local virt_text = {}
	if is_match and #leftover > 0 then
		virt_text[#virt_text + 1] = { leftover:sub(1, 1), "PathfinderNextKey" }
		if #leftover > 1 then
			virt_text[#virt_text + 1] =
				{ leftover:sub(2), "PathfinderFutureKeys" }
		end
	end

	local function put(ln, col_start, col_end, with_text)
		local opts = {
			hl_group = hl_group,
			end_col = col_end,
			priority = 10001,
		}
		if with_text and #virt_text > 0 then
			opts.virt_text = virt_text
			opts.virt_text_pos = "overlay"
		end
		vim.api.nvim_buf_set_extmark(buf, ns, ln, col_start, opts)
	end

	-- Main filename/URL spans.
	for i, span in ipairs(candidate.target_spans) do
		put(
			span.lnum - 1,
			span.start_col,
			span.finish_col + 1,
			is_match and i == 1
		)
	end

	if is_match then
		highlight_spans(
			buf,
			ns,
			candidate.line_nr_spans,
			"PathfinderNumberHighlight"
		)
		highlight_spans(
			buf,
			ns,
			candidate.col_nr_spans,
			"PathfinderColumnHighlight"
		)
	end
end

-- Returns a list of window IDs in the current tabpage, either all or just current.
function M.get_windows_to_check()
	local current_tabpage = vim.api.nvim_get_current_tabpage()
	if config.config.pick_from_all_windows then
		local wins = vim.api.nvim_tabpage_list_wins(current_tabpage)
		local valid_wins = {}
		for _, win in ipairs(wins) do
			if vim.api.nvim_win_is_valid(win) then
				valid_wins[#valid_wins + 1] = win
			end
		end
		return valid_wins
	else
		return { vim.api.nvim_get_current_win() }
	end
end

-- Clears dim/highlight extmarks in all relevant windows.
local function clear_extmarks(windows, highlight_ns, dim_ns)
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

function M.assign_labels(candidates, selection_keys)
	local n, k = #candidates, #selection_keys
	if n == 0 then
		return
	end
	if k < 2 then
		error("At least two selection_keys must be specified")
	end

	-- 1. Smallest length that can label every candidate.
	local function capacity(len) -- strings of length len with no adjacent dupes
		if len == 1 then
			return k
		end
		return k * (k - 1) ^ (len - 1)
	end

	local L = 1
	while capacity(L) < n do
		L = L + 1
	end

	-- 2. Enumerate strings that obey 'no two identical neighbours'.
	local labels, limit = {}, n
	local function dfs(prefix)
		if #labels == limit then
			return
		end -- already have enough
		if #prefix == L then -- full‑length label ready
			labels[#labels + 1] = prefix
			return
		end
		for _, ch in ipairs(selection_keys) do
			if #prefix == 0 or ch ~= prefix:sub(-1) then -- no repeat with the last char
				dfs(prefix .. ch)
				if #labels == limit then
					return
				end
			end
		end
	end
	dfs("")

	-- 3. Assign the labels.
	for i, cand in ipairs(candidates) do
		cand.label = labels[i]
	end
end

-- Returns the subset of candidates whose labels start with 'input'.
local function get_matching_candidates(candidates, input)
	local matches = {}
	for _, candidate in ipairs(candidates) do
		if candidate.label:sub(1, #input) == input then
			matches[#matches + 1] = candidate
		end
	end
	return matches
end

-- Dims all visible lines, then calls highlight_candidate() for each candidate.
local function update_highlights(
	candidates,
	input_prefix,
	highlight_ns,
	dim_ns,
	highlight_candidate
)
	local windows = M.get_windows_to_check()
	local seen_bufs = {}

	-- 1. Clear all old extmarks.
	for _, win in ipairs(windows) do
		local buf = vim.api.nvim_win_get_buf(win)
		if buf > 0 and not seen_bufs[buf] then
			vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
			vim.api.nvim_buf_clear_namespace(buf, dim_ns, 0, -1)
			seen_bufs[buf] = true
		end
	end

	-- 2. Dim the visible lines in each window.
	for _, win in ipairs(windows) do
		if vim.api.nvim_win_is_valid(win) then
			local buf = vim.api.nvim_win_get_buf(win)
			vim.api.nvim_win_call(win, function()
				local start_row = vim.fn.line("w0") - 1
				local end_row = vim.fn.line("w$") - 1

				vim.api.nvim_buf_set_extmark(buf, dim_ns, start_row, 0, {
					end_row = end_row + 1, -- extmark end_row is exclusive
					end_col = 0, -- anchor at first col
					hl_group = "PathfinderDim",
					hl_eol = true, -- fill to end of screen‐line
					priority = 10000,
				})
			end)
		end
	end

	-- 3. Now re‐draw highlights on top.
	for _, cand in ipairs(candidates) do
		highlight_candidate(cand, input_prefix, highlight_ns)
	end

	vim.cmd("redraw")
end

-- Prevent highlights getting stuck on error.
local function safe_update_highlights(
	candidates,
	input_prefix,
	highlight_ns,
	dim_ns,
	highlight_candidate
)
	local function on_error(err)
		local wins = M.get_windows_to_check()
		clear_extmarks(wins, highlight_ns, dim_ns)

		-- Still provide the full error message.
		local full = debug.traceback(tostring(err), 2)
		vim.notify(
			("%s"):format(full),
			vim.log.levels.ERROR,
			{ title = "pathfinder.nvim" }
		)
	end

	xpcall(function()
		update_highlights(
			candidates,
			input_prefix,
			highlight_ns,
			dim_ns,
			highlight_candidate
		)
	end, on_error)
end

-- Main input loop that starts with an immediate highlight, then reads user keystrokes.
function M.start_selection_loop(
	candidates,
	highlight_ns,
	dim_ns,
	highlight_candidate,
	on_complete,
	required_length
)
	local user_input = ""

	safe_update_highlights(
		candidates,
		user_input,
		highlight_ns,
		dim_ns,
		highlight_candidate
	)

	-- Read keystrokes.
	while true do
		local ok, key = pcall(vim.fn.getchar)
		if not ok or not key then
			break
		end

		local backspace_tc =
			vim.api.nvim_replace_termcodes("<BS>", true, false, true)
		local is_backspace = (
			key == 8
			or key == 127
			or (type(key) == "string" and key == backspace_tc)
		)
		if is_backspace then
			if #user_input > 0 then
				user_input = user_input:sub(1, -2)
			else
				-- If backspace when there's no user-input to delete then cancel.
				local windows = M.get_windows_to_check()
				clear_extmarks(windows, highlight_ns, dim_ns)
				return
			end
		else
			local char = type(key) == "number" and vim.fn.nr2char(key) or key
			user_input = user_input .. char
		end

		safe_update_highlights(
			candidates,
			user_input,
			highlight_ns,
			dim_ns,
			highlight_candidate
		)
		local matches = get_matching_candidates(candidates, user_input)

		-- If no matches, cancel.
		if #matches == 0 then
			local windows = M.get_windows_to_check()
			clear_extmarks(windows, highlight_ns, dim_ns)
			return
		end

		-- If exactly one match with a fully typed label, we’re done.
		if #matches == 1 and #user_input == required_length then
			local windows = M.get_windows_to_check()
			clear_extmarks(windows, highlight_ns, dim_ns)
			vim.schedule(function()
				on_complete(matches[1])
			end)
			return
		end
	end
end

return M
