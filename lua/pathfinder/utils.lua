local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local config = require("pathfinder.config")

local function is_dir(path)
	local ok, stat = pcall(vim.uv.fs_stat, path)
	return ok and stat and stat.type == "directory"
end

-- CWD check for Linux (or WSL/Cygwin) using /proc filesystem.
local function try_proc(pid)
	local proc = "/proc/" .. pid .. "/cwd"
	local cwd = vim.uv.fs_realpath and vim.uv.fs_realpath(proc)
		or fn.resolve(proc)
	if cwd and is_dir(cwd) then
		return cwd
	end
end

-- CWD check for macOS and some BSD systems using lsof.
local function try_lsof(pid)
	local ok, lines =
		pcall(fn.systemlist, { "lsof", "-a", "-d", "cwd", "-p", pid, "-Fn" })
	if not ok or type(lines) ~= "table" then
		return nil
	end
	for _, l in ipairs(lines) do
		local dir = l:match("^n(.+)")
		if dir and is_dir(dir) then
			return dir
		end
	end
end

-- CWD check for BSD variants (if lsof fails): use procstat (FreeBSD) or fstat (others).
local function try_bsd(pid)
	local osname = vim.uv.os_uname().sysname
	local cmd = (osname == "FreeBSD") and { "procstat", "-f", pid }
		or { "fstat", "-p", pid }

	local ok, lines = pcall(fn.systemlist, cmd)
	if not ok or type(lines) ~= "table" then
		return nil
	end
	for _, l in ipairs(lines) do
		local dir = l:match("%s+cwd%s+(%S+)")
		if dir and is_dir(dir) then
			return dir
		end
	end
end

-- Get the terminal's current working directory.
local function get_terminal_cwd()
	if vim.bo.buftype ~= "terminal" then
		return nil
	end
	local job_id = vim.b.terminal_job_id
	if not job_id then
		return nil
	end
	local pid = fn.jobpid(job_id)
	if not pid or pid == 0 then
		return nil
	end

	return try_proc(pid) or try_lsof(pid) or try_bsd(pid) -- returns nil if none worked
end

local function is_windows()
	return fn.has("win32") == 1
end

-- Handle Unix-like absolute paths, Windows UNC paths and Windows drive letter
-- paths.
local function is_absolute(path)
	if path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" then
		return true
	end
	if is_windows() and path:match("^[A-Za-z]:") then
		return true
	end
	return false
end

function M.resolve_file(file)
	if file == "~" or file:match("^~[/\\]") or file:match("^~[%w_]+[/\\]") then
		return fn.expand(file)
	end

	if is_absolute(file) then
		return file
	end

	local current_dir
	if vim.bo.buftype == "terminal" then
		current_dir = get_terminal_cwd()
	else
		current_dir = fn.expand("%:p:h")
	end
	if not current_dir or current_dir == "" then
		current_dir = fn.getcwd()
	end
	return current_dir .. "/" .. file
end

function M.is_valid_file(filename)
	if not filename or filename == "" then
		return false
	end
	local ok, stat = pcall(vim.uv.fs_stat, filename)
	return ok and stat and stat.type == "file"
end

function M.get_combined_suffixes()
	local bufnr = api.nvim_get_current_buf()
	if config.suffix_cache[bufnr] then
		return config.suffix_cache[bufnr]
	end
	local ext_list = {}

	if config.config.associated_filetypes then
		for _, ext in ipairs(config.config.associated_filetypes) do
			ext_list[#ext_list + 1] = ext
		end
	end

	---@type any
	local suffixes = vim.bo.suffixesadd
	if type(suffixes) == "string" then
		suffixes = vim.split(suffixes, ",", { plain = true, trimempty = true })
	end
	if type(suffixes) == "table" then
		for _, ext in ipairs(suffixes) do
			ext_list[#ext_list + 1] = ext
		end
	end

	local seen = {}
	local unique_exts = {}
	for _, ext in ipairs(ext_list) do
		if not seen[ext] then
			unique_exts[#unique_exts + 1] = ext
			seen[ext] = true
		end
	end

	config.suffix_cache[bufnr] = unique_exts
	return unique_exts
end

-- For terminal buffers, return a merged logical line from hard-wrapped
-- physical lines. Else, return the current line unmodified (assumes
-- soft-wrapping).
function M.get_merged_line(start_lnum, end_lnum, buf_nr, win_id)
	buf_nr = buf_nr or api.nvim_get_current_buf()
	win_id = win_id or api.nvim_get_current_win()

	-- Non-terminal: single-line fast path.
	if vim.bo[buf_nr].buftype ~= "terminal" then
		local lines =
			api.nvim_buf_get_lines(buf_nr, start_lnum - 1, start_lnum, false)
		local text = lines[1] or ""
		return text,
			start_lnum,
			{ { lnum = start_lnum, start_pos = 1, length = #text } }
	end

	-- Terminal: batch-fetch all lines at once.
	local screen_width = api.nvim_win_get_width(win_id)
	local raw_lines =
		api.nvim_buf_get_lines(buf_nr, start_lnum - 1, end_lnum, false)

	local parts = {}
	local physical_lines = {}
	local pos = 1
	local lnum = start_lnum

	for _, line in ipairs(raw_lines) do
		local len = #line
		parts[#parts + 1] = line
		physical_lines[#physical_lines + 1] = {
			lnum = lnum,
			start_pos = pos,
			length = len,
		}

		pos = pos + len
		lnum = lnum + 1

		-- Stop as soon as the visual line isn't wrapping.
		if len < screen_width then
			break
		end
	end

	local merged = table.concat(parts)
	return merged, lnum - 1, physical_lines
end

return M
