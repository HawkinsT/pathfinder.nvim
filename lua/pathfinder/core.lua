local M = {}

local config = require("pathfinder.config")
local utils = require("pathfinder.utils")
local candidates = require("pathfinder.candidates")
local validation = require("pathfinder.validation")

-- Helper: Build and execute the open command.
local function execute_open_command(open_path, is_gF, linenr)
	local cmd = config.config.open_mode
	if is_gF and linenr then
		cmd = cmd .. "+" .. linenr .. " "
	end
	cmd = cmd .. vim.fn.fnameescape(open_path)
	vim.cmd(cmd)
end

-- Helper: Check if the resolved file is the current file.
local function handle_current_file(is_gF, line, cfile, resolved_cfile)
	local current_file = vim.fn.expand("%:p")
	if resolved_cfile == current_file then
		if is_gF then
			-- If no line is provided, default to line 1.
			-- line = (line == 0) and 1 or line
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

	local current_bufnr = vim.api.nvim_get_current_buf()
	local target_bufnr = vim.fn.bufnr(vim.fn.fnameescape(open_path))
	if target_bufnr ~= -1 and target_bufnr == current_bufnr then
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

-- Processes the file under the cursor when scanning unenclosed words is disabled.
local function process_cursor_file(is_gF, line)
	-- local cfile = vim.fn.expand("<cfile>")
	-- local cfile
	-- if is_gF and line == 0 then
	-- Use <cWORD> for gF so that embedded line numbers (e.g. ":10") are preserved.
	local cfile = vim.fn.expand("<cWORD>")
	-- else
	-- 	cfile = vim.fn.expand("<cfile>")
	-- end

	if line == 0 then
		-- This returns both the cleaned filename and the parsed line number (if any)
		local filename, parsed_line = candidates.parse_filename_and_linenr(cfile)
		if parsed_line then
			cfile = filename
			line = parsed_line
		end
	end

	local resolved_cfile = utils.resolve_file(cfile)
	if not utils.is_valid_file(resolved_cfile) then
		return false
	end

	if handle_current_file(is_gF, line, cfile, resolved_cfile) then
		return true
	end

	-- For the open command, include the count only if is_gF is true.
	execute_open_command(resolved_cfile, is_gF, is_gF and line or nil)
	return true
end

-- Main function handling both gf and gF commands.
local function custom_gf(is_gF, count)
	local user_count = count
	local is_nextfile = config.config.gF_count_behaviour == "nextfile"
	local candidate_index = (is_nextfile and is_gF) and 1 or ((count == 0) and 1 or count)
	local cursor_line = vim.fn.line(".")
	local cursor_col = vim.fn.col(".")

	-- When scanning for unenclosed words is disabled, try to process the file directly.
	-- Special case for handling unenclosed filename under the cursor when scan_unenclosed_words is false.
	if not config.config.scan_unenclosed_words then
		if (is_gF or (not is_gF and count == 0)) and process_cursor_file(is_gF, count) then
			return
		end
	end

	-- Collect forward candidates from the current cursor position.
	local cand_list = candidates.collect_forward_candidates(cursor_line, cursor_col)

	-- For non-gF calls with a count > 1, insert the unenclosed candidate at the beginning.
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
				-- if is_nextfile then
				-- 	linenr = (user_count > 0) and count or (candidate.candidate_info.linenr or 1)
				-- else
				-- 	linenr = candidate.candidate_info.linenr or 1
				-- end
				-- linenr assigned in order: user-supplied count, extracted line number from buffer, or 1
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
