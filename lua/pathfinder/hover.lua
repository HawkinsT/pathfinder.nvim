local M = {}

local vim = vim
local fn = vim.fn
local api = vim.api
local lsp = vim.lsp.util

local config = require("pathfinder.config")
local notify = require("pathfinder.notify")
local picker = require("pathfinder.picker")
local url = require("pathfinder.url")

local function html_unescape(s)
	-- Exhausting to check every code and I don't want to use an external
	-- library/program, so let's just try to hit all the common ones
	-- (please feel free to add to this with a pull request):
	local entities = {
		["&apos;"] = "'",
		["&quot;"] = '"',
		["&amp;"] = "&",
		["&lt;"] = "<",
		["&gt;"] = ">",
		["&nbsp;"] = " ",
		["&ndash;"] = "–",
		["&mdash;"] = "—",
		["&laquo;"] = "«",
		["&raquo;"] = "»",
		["&iquest;"] = "¿",
		["&iexcl;"] = "¡",
		["&pound;"] = "£",
		["&euro;"] = "€",
		["&yen;"] = "¥",
		["&cent;"] = "¢",
		["&trade"] = "™",
		["&copy"] = "©",
		["&reg"] = "®",
	}
	return s:gsub("(&%a+;)", entities)
end

local function markdown_escape(s)
	local marks =
		{ ["\\"] = "\\\\", ["`"] = "\\`", ["["] = "\\[", ["]"] = "\\]" }
	return s:gsub("([\\%`%[%]])", marks)
end

-- Extract the first meta‐description from HTML, with 'og:description' or
-- 'description' in 'property=' or 'name='.
local function extract_meta_description(html)
	html = html:match("<head>(.*)</head>") or html -- narrow down search area
	html = html:lower()
	local V = "([^'\"]+)"
	local patterns = {
		"<meta%s+[^>]-property=['\"]og:description['\"][^>]-content=['\"]"
			.. V
			.. "['\"]",
		"<meta%s+[^>]-content=['\"]"
			.. V
			.. "['\"][^>]-property=['\"]og:description['\"]",
		"<meta%s+[^>]-name=['\"]og:description['\"][^>]-content=['\"]"
			.. V
			.. "['\"]",
		"<meta%s+[^>]-content=['\"]"
			.. V
			.. "['\"][^>]-name=['\"]og:description['\"]",
		"<meta%s+[^>]-name=['\"]description['\"][^>]-content=['\"]"
			.. V
			.. "['\"]",
		"<meta%s+[^>]-content=['\"]"
			.. V
			.. "['\"][^>]-name=['\"]description['\"]",
		"<meta%s+[^>]-property=['\"]description['\"][^>]-content=['\"]"
			.. V
			.. "['\"]",
		"<meta%s+[^>]-content=['\"]"
			.. V
			.. "['\"][^>]-property=['\"]description['\"]",
	}
	for _, pat in ipairs(patterns) do
		local desc = html:match(pat)
		if desc and #desc > 0 then
			return markdown_escape(html_unescape(desc))
		end
	end
end

-- Find either the captured URL under the cursor, or fall back to <cfile>.
local function get_target_at_cursor()
	local buf = api.nvim_get_current_buf()
	local row, col0 = unpack(api.nvim_win_get_cursor(0))
	local col = col0 + 1
	local encl = config.config.url_enclosure_pairs
		or config.config.enclosure_pairs
		or {}

	-- Scan line for URLs/repos.
	local hits = picker.collect({
		win_ids = { 0 },
		buf = buf,
		start_line = row,
		end_line = row,
		scan_fn = url.scan_line_for_urls,
	})

	local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
	for _, c in ipairs(hits) do
		if c.lnum == row then
			local s, f = c.start_col, c.finish
			local in_url = (col >= s and col <= f)
			if not in_url then
				-- Check for enclosing delimiters.
				for o, cl in pairs(encl) do
					local os, ce = s - #o, f + #cl
					if
						os >= 1
						and col >= os
						and col < s
						and line:sub(os, s - 1) == o
					then
						in_url = true
					end
					if col > f and col <= ce and line:sub(f + 1, ce) == cl then
						in_url = true
					end
					if in_url then
						break
					end
				end
			end
			if in_url then
				return c.url
			end
		end
	end

	-- If nothing found, fallback to cfile.
	return fn.expand("<cfile>")
end

-- Build a minimal, deduplicated list of URLs to try.
local function build_url_candidates(target)
	local set = {}

	-- If it's a repo (owner/repo), map through url_providers.
	if url.is_valid.repo(target) then
		for _, fmt in ipairs(config.config.url_providers or {}) do
			set[fmt:format(target)] = true
		end
	end

	-- If it's a flake (prefix:address), map through flake_providers.
	if url.is_valid.flake(target) then
		local full = url.flake_to_url(target)
		if full then
			set[full] = true
		end
	end

	-- If it's already a valid URL, then we're good.
	if url.is_valid.url(target) then
		set[target] = true
	end

	-- Else, try prefixing it with https:// and http://.
	if not target:match("^https?://") then
		for _, p in ipairs({ "https://", "http://" }) do
			local u = p .. target
			if url.is_valid.url(u) then
				set[u] = true
			end
		end
	end

	-- Convert URL keys into list.
	local out = {}
	for u in pairs(set) do
		out[#out + 1] = u
	end
	return out
end

-- Helper to show a floating preview for a given link's description.
local function show_desc(link, desc)
	local orig_buf = api.nvim_get_current_buf()
	local md = lsp.convert_input_to_markdown_lines({
		("**%s**"):format(link),
		desc,
	})
	local _, float_win = lsp.open_floating_preview(md, "markdown", {
		border = "rounded",
		focusable = false,
		close_events = {
			"CursorMoved",
			"CursorMovedI",
			"BufHidden",
			"WinClosed",
		},
		max_width = 80,
		max_height = 20,
	})

	-- Below here is all just code for safely mapping escape to close the float.
	local float_buf = api.nvim_win_get_buf(float_win)
	local group = api.nvim_create_augroup(
		"PathfinderHoverDescCleanup" .. float_win,
		{ clear = true }
	)

	local function cleanup()
		pcall(vim.keymap.del, "n", "<Esc>", { buffer = orig_buf })
		api.nvim_del_augroup_by_id(group)
	end

	api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
		group = group,
		buffer = float_buf,
		once = true,
		callback = cleanup,
	})

	api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(float_win),
		once = true,
		callback = cleanup,
	})

	-- One-shot <Esc> mapping in the original buffer to close float.
	vim.keymap.set("n", "<Esc>", function()
		-- Immediately remove keymap so next <Esc> is user's.
		vim.keymap.del("n", "<Esc>", { buffer = orig_buf })
		api.nvim_feedkeys(
			api.nvim_replace_termcodes("<Esc>", true, false, true),
			"m",
			false
		)
		vim.schedule(function()
			if api.nvim_win_is_valid(float_win) then
				api.nvim_win_close(float_win, true)
			end
		end)
	end, {
		buffer = orig_buf,
		silent = true,
		nowait = true,
	})
end

function M.hover_description()
	local target = get_target_at_cursor()
	local urls = build_url_candidates(target)
	if #urls == 0 then
		return
	end

	local pending = #urls
	local processes = {}
	local done = false

	for _, link in ipairs(urls) do
		local KILOBYTES_TO_DOWNLOAD = 100
		local bytes_to_download = KILOBYTES_TO_DOWNLOAD * 1024
		local curl_cmd = {
			"curl",
			"--max-time",
			"5",
			"-fsL",
			"--range",
			string.format("0-%d", bytes_to_download - 1),
			link,
		}
		local proc = vim.system(
			curl_cmd,
			{
				text = true, -- capture stdout as a string
				timeout = 6000, -- hard kill after 6s in case of curl timeout issues
			},
			vim.schedule_wrap(function(res)
				pending = pending - 1

				if done then
					return
				end

				-- On success, grab and display the first non-empty description.
				if res.code == 0 then
					local ok, desc =
						pcall(extract_meta_description, res.stdout or "")
					if ok and desc and #desc > 0 then
						done = true
						-- Kill all the other outstanding curl jobs.
						for _, p in ipairs(processes) do
							p:kill("SIGKILL")
						end
						show_desc(link, desc)
						return
					end
				end

				if pending == 0 and not done then
					vim.schedule(function()
						notify.info("Couldn't retrieve a description")
					end)
				end
			end)
		)

		processes[#processes + 1] = proc
	end
end

return M
