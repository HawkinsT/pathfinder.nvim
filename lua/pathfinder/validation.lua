local M = {}

local vim = vim
local fn = vim.fn

local config = require("pathfinder.config")
local utils = require("pathfinder.utils")

-- Checks if the resolved candidate file exists. If not, appends each extension
-- from the combined suffix list until valid file targets are found.
--
-- If multiple valid targets are found and |offer_multiple_options| is enabled,
-- then prompt the user with vim.fn.input. If auto_select == true, the first
-- option is automatically chosen with no prompt.
function M.validate_candidate(candidate, callback, auto_select)
	local unique_exts = utils.get_combined_suffixes()
	local ui_select = vim.schedule_wrap(vim.ui.select)
	local buf_path = vim.bo.path
	local includeexpr = vim.bo.includeexpr

	local abs_path_candidate = utils.get_absolute_path(candidate)
	local valid_candidates = {}
	local seen = {}

	local function check_candidate(path)
		local normalized_file_path = fn.fnamemodify(path, ":p")
		if
			utils.is_valid_file(normalized_file_path)
			and not seen[normalized_file_path]
		then
			valid_candidates[#valid_candidates + 1] = normalized_file_path
			seen[normalized_file_path] = true
			return auto_select or not config.config.offer_multiple_options
		end
		return false
	end

	-- First check file candidate locally with and without extensions.
	if check_candidate(abs_path_candidate) then
		callback(abs_path_candidate)
		return
	end
	for _, ext in ipairs(unique_exts) do
		if check_candidate(abs_path_candidate .. ext) then
			callback(abs_path_candidate .. ext)
			return
		end
	end

	-- Also check the path.
	local path_files = fn.globpath(buf_path, candidate, false, true)
	for _, ext in ipairs(unique_exts) do
		vim.list_extend(
			path_files,
			fn.globpath(buf_path, candidate .. ext, false, true)
		)
	end
	for _, file in ipairs(path_files) do
		if check_candidate(file) then
			callback(file)
			return
		end
	end

	-- Also try this again with includeexpr, if set.
	if includeexpr and includeexpr ~= "" then
		local expr_with_candidate =
			includeexpr:gsub("v:fname", vim.inspect(candidate))
		local transformed = fn.eval(expr_with_candidate)
		if transformed and transformed ~= candidate then
			local abs_path_candidate = utils.get_absolute_path(transformed)
			if check_candidate(abs_path_candidate) then
				callback(abs_path_candidate)
				return
			end
			for _, ext in ipairs(unique_exts) do
				if check_candidate(abs_path_candidate .. ext) then
					callback(abs_path_candidate .. ext)
					return
				end
			end

			local path_files_transformed =
				fn.globpath(buf_path, transformed, false, true)
			for _, ext in ipairs(unique_exts) do
				vim.list_extend(
					path_files_transformed,
					fn.globpath(buf_path, transformed .. ext, false, true)
				)
			end
			for _, file in ipairs(path_files_transformed) do
				if check_candidate(file) then
					callback(file)
					return
				end
			end
		end
	end

	-- File opening/prompt logic.
	if #valid_candidates == 0 then
		callback("")
	elseif #valid_candidates == 1 or auto_select then
		callback(valid_candidates[1])
	elseif config.config.offer_multiple_options then
		local ok, _ = pcall(function()
			-- Wrap to avoid some plugins that overwrite vim.ui.select, e.g.
			-- telescope, not gaining focus.
			ui_select(valid_candidates, {
				prompt = "Multiple targets for "
					.. candidate
					.. " (q/Esc=cancel):",
				format_item = function(item)
					return item
				end,
			}, function(choice)
				vim.cmd("redraw")
				callback(choice)
			end)
		end)
		if not ok then
			vim.cmd("redraw")
			callback(nil)
		end
	end
end

-- Collects valid candidates in order. Short-circuits immediately after the
-- count-th valid candidate is found or the user cancels.
function M.collect_valid_candidates_seq(candidates, count, final_callback)
	local valids = {}
	local cancelled = false
	local i = 1

	local function process_next()
		local c = candidates[i]
		i = i + 1
		local force = c._force_auto
		local auto_flag = force or (#valids < (count - 1))
		M.validate_candidate(c.filename, function(open_path)
			if open_path == nil then
				cancelled = true
			elseif open_path ~= "" then
				c.open_path = open_path
				valids[#valids + 1] = c
			end
			if cancelled or #valids == count or i > #candidates then
				final_callback(valids, cancelled)
			else
				vim.schedule(process_next)
			end
		end, auto_flag)
	end

	if #candidates == 0 then
		final_callback({}, false)
	else
		process_next()
	end
end

return M
