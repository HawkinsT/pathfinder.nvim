local M = {}

local config = require("pathfinder.config")

function M.resolve_file(file)
	if file:sub(1, 1) == "~" then
		return vim.fn.expand(file)
	elseif file:sub(1, 1) == "/" or file:sub(2, 2) == ":" then
		return file
	end
	local current_dir = vim.fn.expand("%:p:h")
	return current_dir .. "/" .. file
end

function M.is_valid_file(filename)
	if not filename or filename == "" then
		return false
	end
	local stat = vim.uv.fs_stat(filename)
	return (stat and stat.type == "file") or false
end

function M.get_combined_suffixes()
	local bufnr = vim.api.nvim_get_current_buf()
	if config.suffix_cache[bufnr] then
		return config.suffix_cache[bufnr]
	end
	local ext_list = {}

	if config.config.associated_filetypes then
		for _, ext in ipairs(config.config.associated_filetypes) do
			table.insert(ext_list, ext)
		end
	end

	---@type any
	local suffixes = vim.bo.suffixesadd
	if type(suffixes) == "string" then
		suffixes = vim.split(suffixes, ",", { plain = true, trimempty = true })
	end
	if type(suffixes) == "table" then
		for _, ext in ipairs(suffixes) do
			table.insert(ext_list, ext)
		end
	end

	local seen = {}
	local unique_exts = {}
	for _, ext in ipairs(ext_list) do
		if not seen[ext] then
			table.insert(unique_exts, ext)
			seen[ext] = true
		end
	end

	config.suffix_cache[bufnr] = unique_exts
	return unique_exts
end

return M
