local M = {}

local config = require("pathfinder.config")
local utils = require("pathfinder.utils")
local candidates = require("pathfinder.candidates")
local validation = require("pathfinder.validation")

-- Helper: Switch to an existing window displaying the file, if it exists in any tab.
local function switch_to_file_if_open(filename_and_path, line)
	-- Iterate through all tab pages.
	for _, tabpage_id in ipairs(vim.api.nvim_list_tabpages()) do
		-- Get all windows in the current tab.
		for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(tabpage_id)) do
			local buf_nr = vim.api.nvim_win_get_buf(win_id)
			local buf_name = vim.api.nvim_buf_get_name(buf_nr)
			if buf_name == filename_and_path then
				vim.api.nvim_set_current_tabpage(tabpage_id)
				vim.api.nvim_set_current_win(win_id)
				if line ~= nil then
					vim.api.nvim_win_set_cursor(0, { line, 0 })
				end
				return true
			end
		end
	end
	return false
end

-- Helper: Build and execute the open command.
local function execute_open_command(open_path, is_gF, linenr)
	local cmd = config.config.open_mode
	if type(cmd) == "function" then
		cmd(vim.fn.fnameescape(open_path), (is_gF and linenr) or nil)
	else
		if is_gF and linenr then
			cmd = cmd .. "+" .. linenr .. " "
		end
		cmd = cmd .. vim.fn.fnameescape(open_path)
		vim.cmd(cmd)
	end
end

-- Helper: Check if the resolved file is the current file.
local function handle_current_file(is_gF, line, cfile, resolved_cfile)
	local current_file = vim.fn.expand("%:p")
	if resolved_cfile == current_file then
		if is_gF then
			-- If no line is provided, default to line 1.
			line = (line == 0) and 1 or line
			vim.api.nvim_win_set_cursor(0, { line, 0 })
		else
			vim.notify("File '" .. cfile .. "' is the current file", vim.log.levels.INFO)
		end
		return true
	end
	return false
end

-- Tries to open the file from a valid candidate.
function M.try_open_file(valid_candidate, is_gF, linenr)
	local open_path = valid_candidate.open_path
	if not open_path or open_path == "" then
		return false
	end

	if config.config.reuse_existing_window then
		if switch_to_file_if_open(open_path, is_gF and linenr or nil) then
			return true
		else
			execute_open_command(open_path, is_gF, linenr)
			return true
		end
	else
		local current_bufnr = vim.api.nvim_get_current_buf()
		local target_bufnr = vim.fn.bufnr(vim.fn.fnameescape(open_path))
		if target_bufnr == current_bufnr then
			if is_gF and linenr then
				vim.api.nvim_win_set_cursor(0, { linenr, 0 })
			else
				local cfile = vim.fn.fnamemodify(open_path, ":t")
				vim.notify("File '" .. cfile .. "' is the current file", vim.log.levels.INFO)
			end
			return true
		else
			execute_open_command(open_path, is_gF, linenr)
			return true
		end
	end
end

-- Extracts filename and line number from the current line around the cursor.
local function get_cursor_file_and_line(line_text, cursor_col)
	-- Adjust cursor_col to be 1-based for lua and inclusive of the character under cursor.
	cursor_col = cursor_col + 1
	for _, pat in ipairs(candidates.patterns) do
		local match_start, match_end = line_text:find(pat.pattern)
		while match_start do
			-- Check if cursor is within or immediately after the match.
			if match_start <= cursor_col and cursor_col <= match_end + 1 then
				local match_str = line_text:sub(match_start, match_end)
				local filename, linenr = candidates.parse_filename_and_linenr(match_str)
				if filename then
					return filename, linenr
				end
			end
			match_start, match_end = line_text:find(pat.pattern, match_end + 1)
		end
	end
	-- Fallback: Parse <cWORD> for line number.
	local cfile = vim.fn.expand("<cWORD>")
	local filename, linenr = candidates.parse_filename_and_linenr(cfile)
	return filename, linenr
end

-- Processes the file under the cursor when scanning unenclosed words is disabled.
local function process_cursor_file(is_gF, line)
	local line_text = vim.fn.getline(".")
	local cursor_col = vim.fn.col(".") - 1
	local filename, parsed_line = get_cursor_file_and_line(line_text, cursor_col)
	if parsed_line then
		line = parsed_line
	end

	local resolved_cfile = utils.resolve_file(filename)
	if not utils.is_valid_file(resolved_cfile) then
		return false
	end

	if config.config.reuse_existing_window then
		if switch_to_file_if_open(resolved_cfile, is_gF and line or nil) then
			return true
		else
			execute_open_command(resolved_cfile, is_gF, is_gF and line or nil)
			return true
		end
	else
		if handle_current_file(is_gF, line, filename, resolved_cfile) then
			return true
		end
		execute_open_command(resolved_cfile, is_gF, is_gF and line or nil)
		return true
	end
end

-- Main function handling gf/gF.
local function custom_gf(is_gF, count)
	local user_count = count
	local is_nextfile = config.config.gF_count_behaviour == "nextfile"
	local candidate_index = (is_nextfile and is_gF) and 1 or ((count == 0) and 1 or count)
	local cursor_line = vim.fn.line(".")
	local cursor_col = vim.fn.col(".") - 1

	if vim.bo.buftype == "terminal" and cursor_line > 1 then
		local screen_width = vim.o.columns
		-- If the previous line fills the screen, assume we're in a wrapped candidate.
		while cursor_line > 1 and #vim.fn.getline(cursor_line - 1) >= screen_width do
			cursor_line = cursor_line - 1
			cursor_col = 1 -- reset column so we always scan from the start of the candidate.
		end
	end

	-- When scanning for unenclosed words is disabled, try to process the file directly.
	if not config.config.scan_unenclosed_words then
		if (is_gF or (not is_gF and count == 0)) and process_cursor_file(is_gF, count) then
			return
		end
	end

	-- Collect forward candidates from the current cursor position.
	local cand_list = candidates.collect_forward_candidates(cursor_line, cursor_col)

	-- If scan_unenclosed_words is true, filter and reorder candidates.
	if config.config.scan_unenclosed_words then
		local forward_candidates = {}
		local cursor_candidate = nil
		local cursor_idx = nil

		-- Identify the candidate under or nearest to the cursor and collect forward candidates.
		for _, cand in ipairs(cand_list) do
			local cand_start = cand.start_col - 1 -- 0-based
			local cand_end = cand.finish - 1
			if cand.lnum == cursor_line then
				-- Only include candidates at or ahead of the cursor on the current line.
				if cand_end >= cursor_col then
					-- Check if this is the candidate under the cursor.
					if cursor_col >= cand_start and cursor_col <= cand_end + 1 then
						cursor_candidate = cand
						cursor_idx = #forward_candidates + 1 -- Index it will have after insertion.
					end
					table.insert(forward_candidates, cand)
				end
			else
				-- Include all candidates from subsequent lines.
				table.insert(forward_candidates, cand)
			end
		end

		-- Reorder so the cursor candidate (if any) is first.
		if cursor_candidate and cursor_idx and cursor_idx > 1 then
			table.remove(forward_candidates, cursor_idx)
			table.insert(forward_candidates, 1, cursor_candidate)
		end

		cand_list = forward_candidates
	end

	-- For non-gF calls with a count > 1, insert the unenclosed candidate at the beginning (if applicable).
	if not config.config.scan_unenclosed_words and not is_gF and count > 1 then
		local cfile = vim.fn.expand("<cfile>")
		if utils.is_valid_file(utils.resolve_file(cfile)) then
			table.insert(cand_list, 1, {
				filename = cfile,
				linenr = nil,
				finish = cursor_col,
				lnum = cursor_line,
			})
		end
	end

	validation.collect_valid_candidates_seq(cand_list, candidate_index, function(valids, user_cancelled)
		if user_cancelled then
			return
		end

		if #valids >= candidate_index then
			local candidate = valids[candidate_index]
			local linenr = nil
			if is_gF then
				linenr = (is_nextfile and user_count > 0 and count) or candidate.candidate_info.linenr or 1
			end
			M.try_open_file(candidate, is_gF, linenr)
		else
			vim.notify("E447: No valid file targets found in cwd or path", vim.log.levels.ERROR)
		end
	end)
end

function M.gf()
	custom_gf(false, vim.v.count)
end

function M.gF()
	custom_gf(true, vim.v.count)
end

return M
