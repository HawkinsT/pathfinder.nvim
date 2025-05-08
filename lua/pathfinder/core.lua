local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local candidates = require("pathfinder.candidates")
local config = require("pathfinder.config")
local picker = require("pathfinder.picker")
local validation = require("pathfinder.validation")
local visual_select = require("pathfinder.visual_select")
local utils = require("pathfinder.utils")

visual_select.set_default_highlights()

local highlight_ns = api.nvim_create_namespace("pathfinder_highlight")
local dim_ns = api.nvim_create_namespace("pathfinder_dim")

local function try_open_file(valid_cand, is_gF, linenr)
	local open_path = valid_cand.open_path
	if not open_path or open_path == "" then
		return false
	end

	-- Only set line number if gF specified.
	local line_arg = is_gF and linenr or nil

	if config.config.reuse_existing_window then
		-- Check all windows in all tabs for if the file's already open.
		for _, t in ipairs(api.nvim_list_tabpages()) do
			for _, w in ipairs(api.nvim_tabpage_list_wins(t)) do
				local buf = api.nvim_win_get_buf(w)
				if
					fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
					== open_path
				then
					api.nvim_set_current_tabpage(t)
					api.nvim_set_current_win(w)
					if line_arg then
						api.nvim_win_set_cursor(w, { line_arg, 0 })
					end
					return true
				end
			end
		end
	end

	local cmd = config.config.open_mode
	local file_with_path = fn.fnameescape(open_path)
	if type(cmd) == "function" then
		cmd(file_with_path, line_arg)
	else
		if line_arg then
			cmd = cmd .. "+" .. line_arg .. " "
		end
		vim.cmd(cmd .. " " .. file_with_path)
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
		highlight_ns,
		dim_ns,
		function(cand, prefix, ns)
			if cand.label:sub(1, #prefix) == prefix then
				if not is_gF then
					cand.line_nr_spans = nil
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
local function process_cursor_file(is_gF, linenr)
	local cword = fn.expand("<cWORD>")
	local filename, parsed_ln = candidates.parse_filename_and_linenr(cword)
	local line_to_use = parsed_ln or linenr

	local resolved = require("pathfinder.utils").resolve_file(filename)
	if not require("pathfinder.utils").is_valid_file(resolved) then
		return false
	end

	return try_open_file(
		{ open_path = resolved, linenr = line_to_use },
		is_gF,
		line_to_use
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
		local minc = (ln == curln) and ccol or nil
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

	if config.config.scan_unenclosed_words then
		local fwd, cur_cand, ci = {}, nil, nil
		for _, c in ipairs(raw) do
			if c.lnum == curln then
				if (c.finish - 1) >= ccol then
					if (c.start_col - 1) <= ccol then
						cur_cand, ci = c, #fwd + 1
					end
					table.insert(fwd, c)
				end
			else
				table.insert(fwd, c)
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
					table.insert(filtered, c)
				end
			else
				if c.lnum < curln or (c.lnum == curln and c.finish < ccol) then
					table.insert(filtered, c)
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
