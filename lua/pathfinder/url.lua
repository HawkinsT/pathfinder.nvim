local M = {}

local vim = vim

local config = require("pathfinder.config")
local candidates = require("pathfinder.candidates")
local picker = require("pathfinder.picker")
local visual_select = require("pathfinder.visual_select")
visual_select.set_default_highlights()

local highlight_ns = vim.api.nvim_create_namespace("pathfinder_url_highlight")
local dim_ns = vim.api.nvim_create_namespace("pathfinder_url_dim")

local patterns = {
	url = "https?://[%w%-_.%?%/%%:=&]+",
	repo = "^[%w._%-]+/[%w._%-]+$",
}

local function make_validator(pat)
	return function(s)
		return s:match(pat)
	end
end

local is_valid = {
	url = make_validator(patterns.url),
	repo = make_validator(patterns.repo),
}

local function check_url_exists(url, callback)
	if not url or url == "" then
		vim.schedule(function()
			callback(false)
		end)
		return
	end

	local output = {}
	local cmd = { "curl", "-Lso", "/dev/null", "-w", "%{http_code}", url }
	vim.fn.jobstart(cmd, {
		---@diagnostic disable-next-line: unused-local
		on_stdout = function(_job_id, data, _event)
			for _, line_text in ipairs(data) do
				table.insert(output, line_text)
			end
		end,
		---@diagnostic disable-next-line: unused-local
		on_exit = function(_job_id, exit_code, _event)
			if exit_code == 0 then
				local http_code = table.concat(output)
				local exists = (http_code:sub(1, 1) == "2")
				callback(exists)
			else
				callback(false)
			end
		end,
	})
end

-- Check through a list of URLs via curl (from check_url_exists). Open the
-- first one that exists. If curl is unavailable, then just open the first URL
-- regardless.
local function try_open_urls(urls, on_none)
	local pending = #urls
	local done = false

	local function finish(success, url)
		if done then
			return
		end
		if success or vim.fn.executable("curl") ~= 1 then
			done = true
			vim.schedule(function()
				vim.notify('Opening "' .. url .. '"', vim.log.levels.INFO)
				vim.ui.open(url)
			end)
		elseif pending == 0 then
			vim.schedule(on_none)
		end
	end

	for _, url in ipairs(urls) do
		check_url_exists(url, function(exists)
			pending = pending - 1
			finish(exists, url)
		end)
	end
end

local function open_candidate_url(candidate)
	if is_valid.url(candidate) then
		try_open_urls({ candidate }, function()
			vim.notify("URL not accessible: " .. candidate, vim.log.levels.ERROR)
		end)
	elseif is_valid.repo(candidate) then
		local provs = config.config.url_providers or {}
		if #provs == 0 then
			return vim.notify("No URL providers configured.", vim.log.levels.ERROR)
		end
		local urls = vim.tbl_map(function(fmt)
			return fmt:format(candidate)
		end, provs)
		try_open_urls(urls, function()
			vim.notify("No provider found for " .. candidate, vim.log.levels.ERROR)
		end)
	else
		vim.notify("Not a valid URL or repo: " .. candidate, vim.log.levels.ERROR)
	end
end

local function scan_line_for_urls(line_text, lnum, physical_lines)
	local cfg = config.config

	-- Strip all ANSI CSI sequences for better terminal handling.
	local esc = string.char(27)
	line_text = line_text:gsub(esc .. "%[[%d;]*[ -/]*[@-~]", "")

	--  Use url_enclosure_pairs over enclosure_pairs if available.
	local scan_cfg
	if cfg.url_enclosure_pairs then
		scan_cfg = vim.tbl_extend("force", {}, cfg, {
			enclosure_pairs = cfg.url_enclosure_pairs,
		})
	else
		scan_cfg = cfg
	end

	local raw = candidates.scan_line(
		line_text,
		lnum,
		1, -- min_col = 1 to catch whole line
		scan_cfg.scan_unenclosed_words,
		physical_lines,
		scan_cfg
	)

	-- Filter for only true URLs or owner/repo shortcuts and deduplicate.
	local unique = {}
	local seen = {}
	for _, cand in ipairs(raw) do
		local txt = cand.filename
		if is_valid.url(txt) or is_valid.repo(txt) then
			local key = ("%d:%d:%d"):format(lnum, cand.start_col, cand.finish)
			if not seen[key] then
				seen[key] = true
				cand.url = txt
				table.insert(unique, cand)
			end
		end
	end

	return unique
end

function M.select_url()
	local selection_keys = config.config.selection_keys
	local all = {}

	for _, win in ipairs(visual_select.get_windows_to_check()) do
		if not vim.api.nvim_win_is_valid(win) then
			goto continue
		end

		local buf = vim.api.nvim_win_get_buf(win)
		local s, e
		vim.api.nvim_win_call(win, function()
			s = vim.fn.line("w0")
			e = vim.fn.line("w$")
		end)

		local cands = candidates.collect_candidates_in_range(
			buf,
			win,
			s,
			e,
			scan_line_for_urls,
			true -- skip folds
		)
		vim.list_extend(all, cands)

		::continue::
	end

	all = candidates.deduplicate_candidates(all)
	if #all == 0 then
		vim.notify("No URL candidates found", vim.log.levels.INFO)
		return
	end

	visual_select.assign_labels(all, selection_keys)
	local req = #all[1].label

	visual_select.start_selection_loop(all, highlight_ns, dim_ns, visual_select.highlight_candidate, function(sel)
		open_candidate_url(sel.url)
	end, req)
end

function M.gx()
	local cur = vim.api.nvim_win_get_cursor(0)
	local curln, curcol = cur[1], cur[2] + 1
	local buf = vim.api.nvim_get_current_buf()
	local cfg = config.get_config_for_buffer(buf)

	local limit = (cfg.forward_limit == -1) and (vim.fn.winheight(0) - vim.fn.winline() + 1) or cfg.forward_limit
	local end_ln = math.min(vim.fn.line("$"), curln + limit - 1)

	local raw = picker.collect({
		win_ids = { 0 },
		buf_of_win = function()
			return buf
		end,
		scan_range = function()
			return curln, end_ln
		end,
		scan_fn = scan_line_for_urls,
		skip_folds = false,
		validate_fn = nil,
		dedupe_fn = candidates.deduplicate_candidates,
	})

	local filtered = {}
	for _, c in ipairs(raw) do
		if c.lnum > curln or c.start_col >= curcol then
			table.insert(filtered, c)
		end
	end

	if #filtered == 0 then
		vim.notify("No URL candidates found", vim.log.levels.ERROR)
		return
	end

	table.sort(filtered, function(a, b)
		if a.lnum == b.lnum then
			return a.start_col < b.start_col
		end
		return a.lnum < b.lnum
	end)

	local idx = (vim.v.count == 0) and 1 or vim.v.count
	if idx > #filtered then
		vim.notify("Only " .. #filtered .. " URL candidate(s) available", vim.log.levels.WARN)
		idx = #filtered
	end

	open_candidate_url(filtered[idx].url)
end

return M
