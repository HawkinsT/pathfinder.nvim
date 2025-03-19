local M = {}

local config = require("pathfinder.config")
local utils = require("pathfinder.utils")
local candidates = require("pathfinder.candidates")
local validation = require("pathfinder.validation")

function M.try_open_file(valid_candidate, is_gF, linenr)
	local open_path = valid_candidate.open_path
	if open_path and open_path ~= "" then
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
			local cmd = config.config.open_mode
			if is_gF and linenr then
				cmd = cmd .. "+" .. linenr .. " "
			end
			cmd = cmd .. vim.fn.fnameescape(open_path)
			vim.cmd(cmd)
			return true
		end
	end
	return false
end

local function handle_current_file(is_gF, count, cfile, resolved_cfile)
	local current_file = vim.fn.expand("%:p")
	if resolved_cfile == current_file then
		if is_gF then
			vim.api.nvim_win_set_cursor(0, { count, 0 })
		else
			vim.notify("File '" .. cfile .. "' is the current file", vim.log.levels.INFO)
		end
		return true
	end
	return false
end

local function open_resolved_file(is_gF, count, resolved_cfile)
	if is_gF then
		vim.cmd(config.config.open_mode .. "+" .. count .. " " .. vim.fn.fnameescape(resolved_cfile))
	elseif count == 1 then
		vim.cmd(config.config.open_mode .. " " .. vim.fn.fnameescape(resolved_cfile))
	end
end

local function custom_gf(is_gF, count)
	local user_count = count
	count = (count == 0) and 1 or count
	local cursor_line = vim.fn.line(".")
	local cursor_col = vim.fn.col(".")
	local cfile, valid_cfile = "", false

	if not config.config.scan_unenclosed_words then
		cfile = vim.fn.expand("<cfile>")
		local resolved_cfile = utils.resolve_file(cfile)
		valid_cfile = utils.is_valid_file(resolved_cfile)

		if valid_cfile and handle_current_file(is_gF, count, cfile, resolved_cfile) then
			return
		elseif valid_cfile then
			open_resolved_file(is_gF, count, resolved_cfile)
			return
		end
	end

	local cand_list = candidates.collect_forward_candidates(cursor_line, cursor_col)

	if not config.config.scan_unenclosed_words and valid_cfile and not is_gF and count > 1 then
		table.insert(cand_list, 1, {
			filename = cfile,
			linenr = nil,
			finish = cursor_col,
			lnum = cursor_line,
		})
	end

	local is_nextfile = config.config.gF_count_behaviour == "nextfile"
	local target_index = (is_nextfile and is_gF) and 1 or count

	validation.collect_valid_candidates_seq(cand_list, target_index, function(valids, user_cancelled)
		if user_cancelled then
			return
		end

		if #valids >= target_index then
			local candidate = valids[target_index]
			local linenr = nil
			if is_nextfile and is_gF then
				linenr = (user_count > 0) and count or (candidate.candidate_info.linenr or 1)
			elseif is_gF then
				linenr = candidate.candidate_info.linenr or 1
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
