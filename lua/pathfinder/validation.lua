local M = {}

local vim = vim

local config = require("pathfinder.config")
local utils = require("pathfinder.utils")

--- Default candidate validator.
-- Checks if the resolved candidate file exists. If not, appends each extension
-- from the combined suffix list until valid file targets are found.
--
-- If multiple valid targets are found and |offer_multiple_options| is enabled,
-- we prompt the user with vim.fn.input. In "auto mode" (auto_select==true),
-- the first option is automatically chosen with no prompt.
function M.default_validate_candidate(candidate, callback, auto_select)
	local resolved = utils.resolve_file(candidate)
	local unique_exts = utils.get_combined_suffixes()
	local valid_candidates = {}
	local seen = {}

	local function check_candidate(path)
		local normalized_file_path = vim.fn.fnamemodify(path, ":p")
		if utils.is_valid_file(normalized_file_path) and not seen[normalized_file_path] then
			table.insert(valid_candidates, normalized_file_path)
			seen[normalized_file_path] = true
			return not (config.config.offer_multiple_options or auto_select)
		end
		return false
	end

	-- First check file candidate locally with and without extensions.
	if check_candidate(resolved) then
		callback(resolved)
		return
	end
	for _, ext in ipairs(unique_exts) do
		if check_candidate(resolved .. ext) then
			callback(resolved .. ext)
			return
		end
	end

	-- Also check the path.
	local path_files = vim.fn.globpath(vim.bo.path, candidate, false, true)
	for _, ext in ipairs(unique_exts) do
		vim.list_extend(path_files, vim.fn.globpath(vim.bo.path, candidate .. ext, false, true))
	end
	for _, file in ipairs(path_files) do
		if check_candidate(file) then
			callback(file)
			return
		end
	end

	-- Also try this again with includeexpr, if set.
	local includeexpr = vim.bo.includeexpr
	if includeexpr and includeexpr ~= "" then
		local expr_with_candidate = includeexpr:gsub("v:fname", vim.inspect(candidate))
		local transformed = vim.fn.eval(expr_with_candidate)
		if transformed and transformed ~= candidate then
			local resolved_transformed = utils.resolve_file(transformed)
			if check_candidate(resolved_transformed) then
				callback(resolved_transformed)
				return
			end
			for _, ext in ipairs(unique_exts) do
				if check_candidate(resolved_transformed .. ext) then
					callback(resolved_transformed .. ext)
					return
				end
			end

			local path_files_transformed = vim.fn.globpath(vim.bo.path, transformed, false, true)
			for _, ext in ipairs(unique_exts) do
				vim.list_extend(path_files_transformed, vim.fn.globpath(vim.bo.path, transformed .. ext, false, true))
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
			vim.ui.select(valid_candidates, {
				prompt = "Multiple targets for " .. candidate .. " (q/Esc=cancel):",
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

--- Collects valid candidates in order. Short-circuits immediately after the
--- count-th valid candidate is found or the user cancels.
function M.collect_valid_candidates_seq(candidates, count, final_callback)
	local valid_candidates = {}
	local user_cancelled = false
	local i = 1

	local function process_next()
		if user_cancelled or i > #candidates then
			return final_callback(valid_candidates, user_cancelled)
		end
		local cinfo = candidates[i]
		local auto_flag = (#valid_candidates < (count - 1))
		M.default_validate_candidate(cinfo.filename, function(open_path)
			if open_path == nil then
				user_cancelled = true
				return final_callback(valid_candidates, user_cancelled)
			elseif open_path and open_path ~= "" then
				table.insert(valid_candidates, { candidate_info = cinfo, open_path = open_path })
				if #valid_candidates == count then
					return final_callback(valid_candidates, user_cancelled)
				end
			end
			i = i + 1
			process_next()
		end, auto_flag)
	end

	process_next()
end

return M
