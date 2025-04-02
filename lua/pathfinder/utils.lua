local M = {}

local config = require("pathfinder.config")

-- Helper function to get the terminal's current working directory.
local function get_terminal_cwd()
	if vim.bo.buftype ~= "terminal" then
		return nil
	end

	local job_id = vim.b.terminal_job_id
	if not job_id then
		return nil
	end

	local pid = vim.fn.jobpid(job_id)
	if not pid then
		return nil
	end

	-- Check for Linux (or WSL/Cygwin) using /proc filesystem.
	if vim.fn.isdirectory("/proc/") == 1 then
		local cwd = vim.fn.resolve("/proc/" .. pid .. "/cwd")
		if cwd and vim.fn.isdirectory(cwd) == 1 then
			return cwd
		end
	end

	-- Fallback: use lsof (covers macOS and some BSD systems).
	local lsof = io.popen("lsof -a -d cwd -p " .. pid .. " -Fn 2>/dev/null")
	if lsof then
		local result = lsof:read("*a")
		lsof:close()
		local cwd = result:match("^n(.+)")
		if cwd and vim.fn.isdirectory(cwd) == 1 then
			return cwd
		end
	end

	-- For BSD variants (if lsof fails): use procstat (FreeBSD) or fstat (others).
	if vim.fn.has("bsd") == 1 then
		local uv = vim.uv or vim.loop
		local osname = uv.os_uname().sysname
		local cmd = (osname == "FreeBSD") and ("procstat -f " .. pid .. " | awk '$5 == \"cwd\" {print $NF}'")
			or ("fstat -p " .. pid .. " | awk '$6 == \"cwd\" {print $NF}'")
		local handle = io.popen(cmd)
		if handle then
			local result = handle:read("*a")
			handle:close()
			local cwd = result:gsub("%s+$", "")
			if cwd and vim.fn.isdirectory(cwd) == 1 then
				return cwd
			end
		end
	end

	-- Couldn't resolve terminal cwd.
	return nil
end

function M.resolve_file(file)
	if file:sub(1, 1) == "~" then
		return vim.fn.expand(file)
	elseif file:sub(1, 1) == "/" or file:sub(2, 2) == ":" then
		return file
	end
	local current_dir
	if vim.bo.buftype == "terminal" then
		current_dir = get_terminal_cwd()
	else
		current_dir = vim.fn.expand("%:p:h")
	end
	if not current_dir or current_dir == "" then
		current_dir = vim.fn.getcwd()
	end
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

--- Returns a merged 'logical' line from physical lines in a terminal buffer.
--- For non-terminal buffers it returns the current line unmodified.
function M.get_merged_line(start_lnum, end_lnum)
	if vim.bo.buftype ~= "terminal" then
		return vim.fn.getline(start_lnum), start_lnum
	end

	local merged = ""
	local lnum = start_lnum
	local screen_width = vim.o.columns

	while lnum <= end_lnum do
		local line = vim.fn.getline(lnum)
		merged = merged .. line
		-- Stop merging if the line is shorter than the screen width (end of logical line)
		if #line < screen_width then
			break
		end
		lnum = lnum + 1
	end

	return merged, lnum
end

return M
