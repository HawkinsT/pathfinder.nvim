local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local config = require("pathfinder.config")

-- Check if given path is a directory.
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

-- CWD check for BSD variants (if lsof fails).
-- Uses procstat (FreeBSD) or fstat (others).
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

-- Get Neovim terminal buffer's CWD.
local function get_terminal_cwd()
	if vim.bo.buftype ~= "terminal" then
		return nil
	end
	local job_id = vim.b.terminal_job_id
	if not job_id then
		return nil
	end
	local ok, pid = pcall(fn.jobpid, job_id)
	if not ok or not pid or pid == 0 then
		return nil
	end

	return try_proc(pid) or try_lsof(pid) or try_bsd(pid) -- returns nil if none worked
end

-- Determine the directory we should regard as the working context.
local function get_context_cwd()
	if vim.bo.buftype == "terminal" then
		return get_terminal_cwd() or fn.getcwd()
	end

	local buf_dir = fn.expand("%:p:h")
	if buf_dir and buf_dir ~= "" then
		return buf_dir
	end

	return fn.getcwd()
end

-- Check if the current environment is Windows (not WSL).
local function is_windows()
	return fn.has("win32") == 1
end

-- Check if the current environment is WSL.
function M.is_wsl()
	return fn.has("wsl") == 1
end

-- Check if the current environment is being run through the VS Code Neovim extension.
function M.is_vscode()
	return vim.g.vscode ~= nil
end

-- Check if `path` is an absolute Unix-like, Windows, or UNC path.
local function is_absolute(path)
	-- Unix-style absolute path.
	if path:sub(1, 1) == "/" then
		return true
	end

	-- UNC path.
	if path:sub(1, 2) == [[\\]] then
		return true
	end

	-- Windows absolute path.
	if is_windows() and path:match("^[A-Za-z]:[\\/]") then
		return true
	end
	return false
end

-- Expand %VAR% in Windows-style paths.
local function expand_windows_env(path)
	if not (is_windows() or M.is_wsl()) then
		return nil
	end

	local var, rest = path:match("^%%([%w_]+)%%[\\/]*(.*)")
	if not var then
		return nil
	end

	local expanded_var
	if is_windows() then
		-- On native Windows, fn.expand is fastest.
		expanded_var = fn.expand("%" .. var .. "%")
	elseif M.is_wsl() then
		-- On WSL fn.expand doesn't work so we must outsource to Windows.
		local ok, lines =
			pcall(fn.systemlist, { "cmd.exe", "/C", "echo", "%" .. var .. "%" })
		if not ok or not lines or #lines == 0 then
			return nil
		end
		-- Take the expansion to be the last non-empty line, as cmd.exe may
		-- print warnings about UNC paths first.
		local val
		for i = #lines, 1, -1 do
			local line =
				lines[i]:gsub("\r", ""):gsub("^%s*", ""):gsub("%s*$", "")
			if line ~= "" then
				val = line
				break
			end
		end

		if not val then
			return nil
		end

		-- Check if cmd.exe failed to expand (so it just echoes the input).
		if val:match("^%%" .. var .. "%%$") then
			return nil
		end
		expanded_var = val
	end

	if not expanded_var or expanded_var == "" then
		return nil
	end

	-- Rebuild the full path.
	local sep = (rest and rest ~= "") and "\\" or ""
	return expanded_var .. sep .. rest
end

function M.wsl_path_to_windows(path)
	local drive, rest = path:match("^/mnt/([A-Za-z])/(.*)")
	if drive then
		rest = rest:gsub("/", "\\")
		return drive:upper() .. ":\\" .. rest
	end
	local ok, out = pcall(fn.system, { "wslpath", "-w", path })
	if ok and type(out) == "string" then
		out = out:gsub("\r?\n$", "")
		if out ~= "" then
			return out
		end
	end
end

-- Convert Windows paths into WSL (e.g. /mnt/...) paths.
local function windows_path_to_wsl(path)
	local ok, out = pcall(fn.system, { "wslpath", "-u", path })
	if ok and type(out) == "string" then
		out = out:gsub("\r?\n$", "") -- remove terminal CR/newline characters
		if out ~= "" then
			return out
		end
	end

	return nil
end

-- Build an ordered list of absolute path candidates (home-expanded,
-- project-root, env/WSL, and context-relative), so callers can try multiple
-- possible interpretations of the same input.
function M.get_absolute_path_candidates(file)
	local candidates = {}
	local seen = {}

	local function add_candidate(path)
		if not path or path == "" then
			return
		end

		local key = path
		local ok, normalized = pcall(fn.fnamemodify, path, ":p")
		if ok and normalized and normalized ~= "" then
			key = normalized
		end

		if not seen[key] then
			candidates[#candidates + 1] = path
			seen[key] = true
		end
	end

	local context_dir = get_context_cwd()
	local sep = is_windows() and "\\" or "/"
	local handled_special = false

	local function append_relative(base, rest)
		if not base or base == "" then
			return
		end
		if rest == "" then
			add_candidate(base)
			return
		end
		local prefix = base
		if prefix:sub(-1) == "\\" or prefix:sub(-1) == "/" then
			add_candidate(prefix .. rest)
		else
			add_candidate(prefix .. sep .. rest)
		end
	end

	if file:sub(1, 1) == "~" then
		-- Preserve standard tilde expansion, but also (optionally) treat "~/"
		-- as project-root relative so we can support ecosystems that overload
		-- the symbol.
		handled_special = true
		local expanded = fn.expand(file)
		if expanded and expanded ~= "" and expanded ~= file then
			add_candidate(expanded)
		end

		if config.config.tilde_as_project_root then
			-- Use the Neovim working directory as project root.
			local project_dir = fn.getcwd()
			if file:match("^~[/\\]") then
				local rest = file:gsub("^~[/\\]+", "")
				append_relative(project_dir, rest)
			elseif file == "~" then
				add_candidate(project_dir)
			end
		end

		-- Also add a literal interpretation, so edge cases of files actually
		-- named "~" or starting with "~" are handled correctly.
		append_relative(context_dir, file)
	end

	-- Unix-style environment variable (e.g. $HOME/path, ${HOME}/path).
	if file:match("^%$[%w_]+") or file:match("^%${[%w_]+}") then
		handled_special = true
		add_candidate(fn.expand(file))
	end

	-- Windows-style environment variable (e.g. %APPDATA%\path), including WSL
	-- shims (e.g. convert C:\... to /mnt/c/... on WSL).
	if file:match("^%%[%w_]+%%") then
		handled_special = true
		local expanded = expand_windows_env(file) or file
		if M.is_wsl() then
			local wsl_path = windows_path_to_wsl(expanded)
			if wsl_path then
				add_candidate(wsl_path)
			end
		end
		add_candidate(expanded)
	end

	-- Translate native Windows paths presented inside WSL shells.
	if M.is_wsl() then
		local wsl_path = windows_path_to_wsl(file)
		if wsl_path then
			handled_special = true
			add_candidate(wsl_path)
		end
	end

	-- Fallback to simple absolute or project-context relative resolution.
	if not handled_special then
		if is_absolute(file) then
			add_candidate(file)
		else
			append_relative(context_dir, file)
		end
	end

	-- Also add the raw input as a file candidate.
	if #candidates == 0 then
		add_candidate(file)
	end

	return candidates
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
