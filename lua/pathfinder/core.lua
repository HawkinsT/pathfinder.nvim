local M = {}

local vim = vim
local api = vim.api

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
				if vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":p") == open_path then
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
	local file_with_path = vim.fn.fnameescape(open_path)
	if type(cmd) == "function" then
		cmd(file_with_path, line_arg)
	else
		if line_arg then
			cmd = cmd .. "+" .. line_arg .. " "
		end
		vim.cmd(cmd .. file_with_path)
	end

	return true
end

local function select_file(is_gF)
	local all_raw = {}

	for _, win in ipairs(visual_select.get_windows_to_check()) do
		if not api.nvim_win_is_valid(win) then
			goto continue
		end

		local buf = api.nvim_win_get_buf(win)
		local cfg = config.get_config_for_buffer(buf)
		local s, e
		api.nvim_win_call(win, function()
			s = vim.fn.line("w0")
			e = vim.fn.line("w$")
		end)

		local scan_fn = function(line_text, lnum, physical_lines)
			return candidates.scan_line(line_text, lnum, 1, cfg.scan_unenclosed_words, physical_lines, cfg)
		end

		-- Wrap validation in the individual buffer’s context.
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
			buf_of_win = function()
				return buf
			end,
			scan_range = function()
				return s, e
			end,
			scan_fn = scan_fn,
			skip_folds = true,
			validate_fn = validate_fn,
			dedupe_fn = candidates.deduplicate_candidates,
		})

		vim.list_extend(all_raw, wins_raw)
		::continue::
	end

	if #all_raw == 0 then
		vim.notify("No valid file candidates in visible windows", vim.log.levels.INFO)
		return
	end

	visual_select.assign_labels(all_raw, config.config.selection_keys)
	visual_select.start_selection_loop(all_raw, highlight_ns, dim_ns, function(cand, prefix, ns)
		if cand.label:sub(1, #prefix) == prefix then
			if not is_gF then
				cand.line_nr_spans = nil
			end
			visual_select.highlight_candidate(cand, prefix, ns)
		end
	end, function(sel)
		api.nvim_set_current_win(sel.win_id)
		vim.cmd("redraw")
		-- try_open_file(sel, is_gF, sel.linenr or 1)
		-- local buf = api.nvim_win_get_buf(sel.win_id)
		api.nvim_win_call(sel.win_id, function()
			validation.validate_candidate(sel.filename, function(chosen_path)
				if chosen_path and chosen_path ~= "" then
					sel.open_path = chosen_path
					try_open_file(sel, is_gF, sel.linenr or 1)
				else
					vim.notify("No file selected or resolved", vim.log.levels.WARN)
				end
			end, false)
		end)
	end, #all_raw[1].label)
end

-- Processes files under the cursor, regardless of if unenclosed or not.
local function process_cursor_file(is_gF, linenr)
	local cword = vim.fn.expand("<cWORD>")
	local filename, parsed_ln = candidates.parse_filename_and_linenr(cword)
	local line_to_use = parsed_ln or linenr

	local resolved = require("pathfinder.utils").resolve_file(filename)
	if not require("pathfinder.utils").is_valid_file(resolved) then
		return false
	end

	return try_open_file({ open_path = resolved, linenr = line_to_use }, is_gF, line_to_use)
end

local function custom_gf(is_gF, count)
	local user_count = count
	local nextfile = config.config.gF_count_behaviour == "nextfile"
	local idx = (nextfile and is_gF) and 1 or ((count == 0) and 1 or count)

	local curln = vim.fn.line(".")
	local ccol = vim.fn.col(".") - 1
	local end_ln = vim.fn.line("$")
	local buf = api.nvim_get_current_buf()
	local win = api.nvim_get_current_win()

	if not config.config.scan_unenclosed_words then
		if (is_gF or (not is_gF and count == 0)) and process_cursor_file(is_gF, count) then
			return
		end
	end

	local scan_fn = function(line, ln, phys)
		local minc = (ln == curln) and ccol or nil
		return candidates.scan_line(line, ln, minc, config.config.scan_unenclosed_words, phys, config.config)
	end

	local raw = candidates.collect_candidates_in_range(buf, win, curln, end_ln, scan_fn, true)

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
		local cf = vim.fn.expand("<cfile>")
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

	validation.collect_valid_candidates_seq(raw, idx, function(valids, cancelled)
		if cancelled then
			return
		end
		if #valids >= idx then
			local c = valids[idx]
			local linenr = nil
			if is_gF then
				linenr = (nextfile and user_count > 0 and user_count) or c.linenr or 1
			end
			try_open_file(c, is_gF, linenr)
		elseif #valids == 0 then
			vim.notify("E447: No valid file targets found", vim.log.levels.ERROR)
		else
			vim.notify("Only " .. #valids .. " file candidate(s) available", vim.log.levels.WARN)
		end
	end)
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
