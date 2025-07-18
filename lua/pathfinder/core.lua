local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local candidates = require("pathfinder.candidates")
local config = require("pathfinder.config")
local notify = require("pathfinder.notify")
local picker = require("pathfinder.picker")
local utils = require("pathfinder.utils")
local validation = require("pathfinder.validation")
local visual_select = require("pathfinder.visual_select")

visual_select.set_default_highlights()

local messages = {
	none_valid = "Valid file target not found",
	none_count = "Valid file target not found (%d available)",
	none_direc_count = "%s file target not found (%d available)",
	cannot_open = "Unable to locate file; check it still exists",
}

-- Expects absolute line and column numbers (1, 1) which will then be converted:
-- Rows are 1-indexed and columns are 0-indexed here, because why not...
local function goto_line_column(window, line_arg, col_arg)
	local target_line = math.max(1, line_arg)
	local target_col = (col_arg and col_arg > 0) and (col_arg - 1) or 0
	pcall(api.nvim_win_set_cursor, window, { target_line, target_col })
end

-- Check all windows in all tabs for if the specified file's already open and
-- go to this instance if so.
local function find_and_goto_existing_window(target_abs_path, line_arg, col_arg)
	for _, t in ipairs(api.nvim_list_tabpages()) do
		for _, w in ipairs(api.nvim_tabpage_list_wins(t)) do
			local buf = api.nvim_win_get_buf(w)
			local buf_name = api.nvim_buf_get_name(buf)
			if buf_name and buf_name ~= "" then
				local buf_abs_path = fn.fnamemodify(buf_name, ":p")
				if buf_abs_path == target_abs_path then
					api.nvim_set_current_tabpage(t)
					api.nvim_set_current_win(w)
					if line_arg then
						goto_line_column(w, line_arg, col_arg)
					end
					return true -- file already open in some tab/window and switched to
				end
			end
		end
	end
	return false -- file not currently open in any tab/window
end

-- Open files using Visual Studio Code's API when available.
local function vscode_open(file, linenr, colnr)
	if utils.is_wsl() then
		local win = utils.wsl_path_to_windows(file)
		if win then
			file = win
		end
	end

	local ok, vscode = pcall(require, "vscode")
	if ok and vscode and vscode.eval_async then
		local js = [[
           const uri = vscode.Uri.file(args.file);
           let opts;
           if (args.line) {
               opts = { selection: { startLine: args.lint - 1, startColumn: (args.col || 1) - 1 } };
           }
           await vscode.commands.executeCommand('vscode.open', uri, opts);
        ]]
		vscode.eval_async(
			js,
			{ args = { file = file, line = linenr, col = colnr } }
		)
		return
	end

	local cli_args = { "code", "-g" }
	if linenr then
		cli_args[#cli_args + 1] =
			string.format("%s:%d:%d", file, linenr, colnr or 1)
	else
		cli_args[#cli_args + 1] = file
	end
	fn.jobstart(cli_args, { detach = true })
end

function M.try_open_file(valid_cand, is_gF)
	local target_abs_path = vim.fn.fnamemodify(valid_cand.open_path, ":p")

	-- Only set line number if gF specified.
	local line_arg = is_gF and valid_cand.linenr or nil
	local col_arg = is_gF
			and config.config.use_column_numbers
			and valid_cand.colnr
		or nil

	if config.config.vscode_handling and utils.is_vscode() then
		vscode_open(target_abs_path, line_arg, col_arg)
		return true
	end

	if config.config.reuse_existing_window then
		if
			find_and_goto_existing_window(target_abs_path, line_arg, col_arg)
		then
			return true
		end
	end

	local open_cmd = config.config.open_mode
	local escaped_target_path = fn.fnameescape(target_abs_path)

	if type(open_cmd) == "function" then
		open_cmd(escaped_target_path, line_arg, col_arg)
	else
		vim.cmd(open_cmd .. " " .. escaped_target_path)
		-- For commands like :edit, set cursor on the current window (0).
		if line_arg then
			goto_line_column(0, line_arg, col_arg)
		end
	end

	return true
end

local function select_file(is_gF)
	local tmux = require("pathfinder.tmux")

	if tmux.is_enabled() then
		local tmux_result = tmux.select_file(is_gF)
		if tmux_result == true then
			return
		end
	end

	local all_raw = {}

	for _, win in ipairs(visual_select.get_windows_to_check()) do
		if api.nvim_win_is_valid(win) then
			local buf = api.nvim_win_get_buf(win)
			local cfg = config.get_config_for_buffer(buf)
			local s = fn.line("w0", win)
			local e = fn.line("w$", win)

			local scan_fn = function(line_text, lnum, physical_lines)
				return candidates.scan_line(
					line_text,
					lnum,
					1,
					cfg.scan_unenclosed_words,
					physical_lines,
					cfg
				)
			end

			-- Wrap validation in the individual buffer's context.
			local validate_fn = function(cand)
				local ok
				api.nvim_buf_call(buf, function()
					validation.validate_candidate(
						cand.filename,
						function(abs_path_candidate)
							ok = (
								abs_path_candidate
								and abs_path_candidate ~= ""
							)
							if ok then
								cand.open_path = abs_path_candidate
							end
						end,
						true
					)
				end)
				return ok
			end

			local wins_raw = picker.collect({
				win_ids = { win },
				buf = buf,
				start_line = s,
				end_line = e,
				scan_fn = scan_fn,
				skip_folds = true,
				validate_fn = validate_fn,
			})

			vim.list_extend(all_raw, wins_raw)
		end
	end

	if #all_raw == 0 then
		notify.info(messages.none_valid)
		return
	end

	visual_select.assign_labels(all_raw, config.config.selection_keys)
	visual_select.start_selection_loop(
		all_raw,
		visual_select.HIGHLIGHT_NS,
		visual_select.DIM_NS,
		function(cand, prefix, ns)
			if cand.label:sub(1, #prefix) == prefix then
				if not is_gF then
					cand.line_nr_spans = nil
				end
				if not (is_gF and config.config.use_column_numbers) then
					cand.col_nr_spans = nil
				end
				visual_select.highlight_candidate(cand, prefix, ns)
			end
		end,
		function(sel)
			api.nvim_win_call(sel.win_id, function()
				validation.validate_candidate(
					sel.filename,
					function(chosen_path)
						if chosen_path and chosen_path ~= "" then
							sel.open_path = chosen_path
							vim.schedule(function()
								M.try_open_file(sel, is_gF)
							end)
						else
							notify.warn(messages.cannot_open)
						end
					end,
					false
				)
			end)
		end,
		#all_raw[1].label
	)
end

-- Processes files under the cursor, regardless of if unenclosed or not.
local function process_cursor_file(is_gF, count, nextfile)
	local current_buf = api.nvim_get_current_buf()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local cursor_row = cursor_pos[1] -- 1-based row
	local cursor_col0 = cursor_pos[2] -- 0-based column

	-- Get the full text of the current logical line.
	local line_text, _, phys_lines =
		utils.get_merged_line(cursor_row, cursor_row, current_buf, 0)

	if not line_text or line_text == "" then
		return false
	end

	local candidates_on_line = candidates.scan_line(
		line_text,
		cursor_row,
		nil, -- scan the whole line, then filter by cursor position
		true, -- force scanning unenclosed words
		phys_lines,
		config.config
	)

	if #candidates_on_line == 0 then
		return false
	end

	local target_candidate = nil
	local best_fit_span_start = -1 -- used to find the most specific (innermost/latest starting) match

	-- Try to find a candidate whose filename part (target_spans) contains the cursor.
	for i = 1, #candidates_on_line do
		local cand = candidates_on_line[i]
		if cand.lnum == cursor_row and cand.target_spans then
			for _, span in ipairs(cand.target_spans) do
				if
					span.lnum == cursor_row
					and cursor_col0 >= span.start_col
					and cursor_col0 <= span.finish_col
				then
					if span.start_col > best_fit_span_start then
						best_fit_span_start = span.start_col
						target_candidate = cand
					end
				end
			end
		end
	end

	-- If no direct hit on a filename part, try a broader check:
	-- Is the cursor within the entire span of any candidate (filename + line/col specifier)?
	-- Pick the last one that starts at or before the cursor and ends at or after it.
	if not target_candidate then
		local encompassing_candidate = nil
		for i = 1, #candidates_on_line do
			local cand = candidates_on_line[i]
			-- cand.start_col and cand.finish are 1-indexed for the logical line.
			if
				cand.lnum == cursor_row
				and (cursor_col0 + 1) >= cand.start_col
				and (cursor_col0 + 1) <= cand.finish
			then
				encompassing_candidate = cand -- keep the last one that qualifies
			end
		end
		if encompassing_candidate then
			target_candidate = encompassing_candidate
		end
	end

	if not target_candidate then
		return false
	end

	if is_gF then
		if nextfile then
			if count > 0 then
				target_candidate.linenr = count
				target_candidate.colnr = nil
			end
		end
		if not config.config.use_column_numbers then
			target_candidate.colnr = nil
		end
	end

	local resolved_path = utils.get_absolute_path(target_candidate.filename)
	if not utils.is_valid_file(resolved_path) then
		return false
	end

	return M.try_open_file({
		open_path = resolved_path,
		linenr = target_candidate.linenr,
		colnr = target_candidate.colnr,
	}, is_gF)
end

local function custom_gf(is_gF, count)
	local user_count = count
	local nextfile = (config.config.gF_count_behaviour == "nextfile")
		or (config.config.gF_count_behavior == "nextfile")
	local idx = (nextfile and is_gF) and 1 or vim.v.count1

	local buf = api.nvim_get_current_buf()
	local win = api.nvim_get_current_win()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local cursor_row = cursor_pos[1] -- vim.fn.line(".")
	local cursor_col = cursor_pos[2] + 1 -- vim.fn.col(".")
	local lim = config.config.file_forward_limit
	local end_ln = (lim == 0) and api.nvim_buf_line_count(buf)
		or (lim == -1) and fn.line("w$", win)
		or math.min(api.nvim_buf_line_count(buf), cursor_row + lim - 1)

	if
		(is_gF or (not is_gF and count <= 1))
		and process_cursor_file(is_gF, count, nextfile)
	then
		return
	end

	local scan_fn = function(line, ln, phys)
		local minc = (ln == cursor_row) and cursor_col or nil
		return candidates.scan_line(
			line,
			ln,
			minc,
			config.config.scan_unenclosed_words,
			phys,
			config.config
		)
	end

	local raw = candidates.collect_candidates_in_range(
		buf,
		win,
		cursor_row,
		end_ln,
		scan_fn,
		false
	)

	raw = candidates.deduplicate_candidates(raw)

	if config.config.scan_unenclosed_words then
		local fwd, cur_cand, ci = {}, nil, nil
		for _, c in ipairs(raw) do
			if c.lnum == cursor_row then
				if c.finish >= cursor_col then
					if c.start_col <= cursor_col then
						cur_cand, ci = c, #fwd + 1
					end
					fwd[#fwd + 1] = c
				end
			else
				fwd[#fwd + 1] = c
			end
		end
		if cur_cand and ci and ci > 1 then
			table.remove(fwd, ci)
			table.insert(fwd, 1, cur_cand)
		end
		raw = fwd
	elseif not is_gF and count > 1 then
		local cfile = fn.expand("<cfile>")
		local abs_path_candidate = utils.get_absolute_path(cfile)
		if utils.is_valid_file(abs_path_candidate) then
			table.insert(raw, 1, {
				filename = cfile,
				open_path = abs_path_candidate,
				lnum = cursor_row,
				finish = cursor_col - 1,
			})
		end
	end

	validation.collect_valid_candidates_seq(
		raw,
		idx,
		function(valids, cancelled)
			if cancelled then
				return
			end
			if valids[idx] then
				local c = valids[idx]
				if is_gF then
					c.linenr = (nextfile and user_count > 0 and user_count)
						or c.linenr
						or 1
				end
				if not config.config.use_column_numbers then
					c.colnr = nil
				elseif is_gF and user_count > 0 then
					c.colnr = nil
				end
				M.try_open_file(c, is_gF)
			elseif #valids == 0 then
				notify.info(messages.none_valid)
			else
				notify.info(string.format(messages.none_count, #valids))
			end
		end
	)
end

--- Jump to the count'th valid file target.
-- direction: 1 -> next; -1 -> previous
local function jump_file(direction, count)
	count = count or vim.v.count1

	local buf = api.nvim_get_current_buf()
	local win = api.nvim_get_current_win()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local cursor_row = cursor_pos[1] -- vim.fn.line(".")
	local cursor_col = cursor_pos[2] + 1 -- vim.fn.col(".")
	local lim = config.config.file_forward_limit
	local start_ln, end_ln

	-- Determine scan range based on direction and `file_forward_limit`.
	if direction == 1 then
		start_ln = cursor_row
		end_ln = (lim == 0) and api.nvim_buf_line_count(buf)
			or (lim == -1) and fn.line("w$", win)
			or math.min(api.nvim_buf_line_count(buf), cursor_row + lim - 1)
	else
		end_ln = cursor_row
		start_ln = (lim == 0) and 1
			or (lim == -1) and fn.line("w0", win)
			or math.max(1, cursor_row - lim + 1)
	end

	-- Collect and deduplicate raw candidates.
	local raw = candidates.collect_candidates_in_range(
		buf,
		win,
		start_ln,
		end_ln,
		function(line, lnum, phys)
			return candidates.scan_line(
				line,
				lnum,
				nil,
				config.config.scan_unenclosed_words,
				phys,
				config.config
			)
		end,
		false -- don't skip folds
	)
	raw = candidates.deduplicate_candidates(raw)

	-- Filter out candidate at the cursor to prevent next/prev from re-selecting it.
	local filtered = {}
	for _, c in ipairs(raw) do
		local overlaps = (
			c.lnum == cursor_row
			and c.start_col <= cursor_col
			and c.finish >= cursor_col
		)
		if not overlaps then
			if direction == 1 then
				if
					c.lnum > cursor_row
					or (c.lnum == cursor_row and c.start_col > cursor_col)
				then
					filtered[#filtered + 1] = c
				end
			else
				if
					c.lnum < cursor_row
					or (c.lnum == cursor_row and c.finish < cursor_col)
				then
					filtered[#filtered + 1] = c
				end
			end
		end
	end

	-- Reverse list direction if backwards search, such that closer file candidates are tried first.
	if direction == -1 then
		local rev = {}
		for i = #filtered, 1, -1 do
			rev[#rev + 1] = filtered[i]
		end
		filtered = rev
	end

	-- Temporarily disable file select prompt for calling collect_valid_candidates_seq.
	for _, c in ipairs(filtered) do
		c._force_auto = true
	end

	-- Validate in sequence and jump to the count'th valid file.
	validation.collect_valid_candidates_seq(filtered, count, function(valids, _)
		local direc_name = direction == 1 and "Forward" or "Backward"

		if #valids >= count then
			local c = valids[count]
			api.nvim_win_set_cursor(0, { c.lnum, c.start_col - 1 })
		else
			notify.info(
				string.format(messages.none_direc_count, direc_name, #valids)
			)
		end
	end)
end

function M.next_file(count)
	jump_file(1, count)
end

function M.prev_file(count)
	jump_file(-1, count)
end

function M.select_file()
	select_file(false)
end

function M.select_file_line()
	select_file(true)
end

function M.gf()
	custom_gf(false, vim.v.count)
end

function M.gF()
	custom_gf(true, vim.v.count)
end

return M
