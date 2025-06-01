local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local candidates = require("pathfinder.candidates")
local config = require("pathfinder.config")
local picker = require("pathfinder.picker")
local utils = require("pathfinder.utils")
local validation = require("pathfinder.validation")
local visual_select = require("pathfinder.visual_select")

visual_select.set_default_highlights()

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

local function try_open_file(valid_cand, is_gF, linenr)
	local target_abs_path = vim.fn.fnamemodify(valid_cand.open_path, ":p")

	-- Only set line number if gF specified.
	local line_arg = is_gF and linenr or nil
	local col_arg = is_gF
			and config.config.use_column_numbers
			and valid_cand.colnr
		or nil

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
					validation.validate_candidate(cand.filename, function(res)
						ok = (res and res ~= "")
						if ok then
							cand.open_path = res
						end
					end, true)
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
		vim.notify(
			"No valid file targets in visible windows",
			vim.log.levels.INFO,
			{ title = "pathfinder.nvim" }
		)
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
								try_open_file(sel, is_gF, sel.linenr)
							end)
						else
							vim.notify(
								"No file selected or resolved",
								vim.log.levels.WARN,
								{ title = "pathfinder.nvim" }
							)
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
local function process_cursor_file(is_gF, count)
	local cursor_WORD = fn.expand("<cWORD>")
	local filename, parsed_ln, parsed_col =
		candidates.parse_filename_and_position(cursor_WORD)

	local linenr = parsed_ln

	-- Override buffer line number if count specified and gF behaviour is set
	-- to `nextfile`.
	if
		is_gF
		and config.config.gF_count_behaviour == "nextfile"
		and count > 0
	then
		linenr = count
	end

	local resolved = utils.resolve_file(filename)
	if not utils.is_valid_file(resolved) then
		return false
	end

	return try_open_file(
		{ open_path = resolved, linenr = linenr, colnr = parsed_col },
		is_gF,
		linenr
	)
end

local function custom_gf(is_gF, count)
	local user_count = count
	local nextfile = config.config.gF_count_behaviour == "nextfile"
	local idx = (nextfile and is_gF) and 1 or vim.v.count1

	local buf = api.nvim_get_current_buf()
	local win = api.nvim_get_current_win()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local curln = cursor_pos[1] -- vim.fn.line(".")
	local ccol = cursor_pos[2] -- vim.fn.col(".") - 1
	local end_ln = api.nvim_buf_line_count(buf) -- vim.fn.line("$")

	if not config.config.scan_unenclosed_words then
		if
			(is_gF or (not is_gF and count == 0))
			and process_cursor_file(is_gF, count)
		then
			return
		end
	end

	local scan_fn = function(line, ln, phys)
		local minc = (ln == curln) and (ccol + 1) or nil
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
		curln,
		end_ln,
		scan_fn,
		false
	)

	raw = candidates.deduplicate_candidates(raw)

	if config.config.scan_unenclosed_words then
		local fwd, cur_cand, ci = {}, nil, nil
		for _, c in ipairs(raw) do
			if c.lnum == curln then
				if (c.finish - 1) >= ccol then
					if (c.start_col - 1) <= ccol then
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
		local cf = fn.expand("<cfile>")
		local res = utils.resolve_file(cf)
		if utils.is_valid_file(res) then
			table.insert(raw, 1, {
				filename = cf,
				open_path = res,
				lnum = curln,
				finish = ccol,
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
			if #valids >= idx then
				local c = valids[idx]
				local linenr = nil
				if is_gF then
					linenr = (nextfile and user_count > 0 and user_count)
						or c.linenr
						or 1
				end
				if not config.config.use_column_numbers then
					c.colnr = nil
				elseif is_gF and user_count > 0 then
					c.colnr = nil
				end
				try_open_file(c, is_gF, linenr)
			elseif #valids == 0 then
				vim.notify(
					"No valid file targets found",
					vim.log.levels.INFO,
					{ title = "pathfinder.nvim" }
				)
			else
				vim.notify(
					"No file target found (" .. #valids .. " available)",
					vim.log.levels.INFO,
					{ title = "pathfinder.nvim" }
				)
			end
		end
	)
end

--- Jump to the count'th valid file target.
-- Direction: 1 -> next; -1 -> previous.
local function jump_file(direction, count)
	count = count or vim.v.count1

	local buf = api.nvim_get_current_buf()
	local win = api.nvim_get_current_win()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local curln = cursor_pos[1] -- vim.fn.line(".")
	local ccol = cursor_pos[2] + 1 -- vim.fn.col(".")

	-- Scan range: current line to top of document or current line to bottom of document
	local start_ln = (direction == 1) and curln or 1
	local end_ln = (direction == 1) and api.nvim_buf_line_count(buf) or curln

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
			c.lnum == curln
			and c.start_col <= ccol
			and c.finish >= ccol
		)
		if not overlaps then
			if direction == 1 then
				if
					c.lnum > curln or (c.lnum == curln and c.start_col > ccol)
				then
					filtered[#filtered + 1] = c
				end
			else
				if c.lnum < curln or (c.lnum == curln and c.finish < ccol) then
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
		local direc_name = direction == 1 and "next" or "previous"

		if #valids >= count then
			local c = valids[count]
			api.nvim_win_set_cursor(0, { c.lnum, c.start_col - 1 })
		else
			vim.notify(
				string.format(
					"No %s file target found (%d available)",
					direc_name,
					#valids
				),
				vim.log.levels.INFO,
				{ title = "pathfinder.nvim" }
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
