local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local config = require("pathfinder.config")
local candidates = require("pathfinder.candidates")
local picker = require("pathfinder.picker")
local visual_select = require("pathfinder.visual_select")
visual_select.set_default_highlights()

local highlight_ns = api.nvim_create_namespace("pathfinder_url_highlight")
local dim_ns = api.nvim_create_namespace("pathfinder_url_dim")

local patterns = {
	url = "[Hh][Tt][Tt][Pp][Ss]?://[%w%-_.%?%/%%:=&]+",
	repo = "^[%w._%-]+/[%w._%-]+$",
}

local function make_validator(pat)
	return function(s)
		return s:match(pat)
	end
end

M.is_valid = {
	url = make_validator(patterns.url),
	repo = make_validator(patterns.repo),
}

-- Checks whether a URL returns a 2xx HTTP status.
local function check_url_exists(url, callback)
	if not url or url == "" then
		vim.schedule(function()
			callback(false)
		end)
		return
	end

	vim.system(
		{
			"curl",
			"-Lso",
			"/dev/null", -- silence output
			"-w",
			"%{http_code}", -- only print the HTTP status
			"--max-time",
			"5", -- curl will give up after 5s
			url,
		},
		{
			text = true, -- capture stdout as a string
			timeout = 6000, -- hard kill after 6s in case of curl timout issues
		},
		vim.schedule_wrap(function(res)
			-- If success, then check if the status code begins with a 2.
			if res.code == 0 then
				local http_code = (res.stdout or ""):match("^%s*(%d%d%d)")
				callback(http_code and http_code:sub(1, 1) == "2")
			else
				callback(false)
			end
		end)
	)
end

local function validate_candidate(cand, callback)
	if M.is_valid.url(cand.url) then
		check_url_exists(cand.url, callback)
	-- For repos, try each provider sequentially until one resolves.
	elseif M.is_valid.repo(cand.url) then
		local provs = config.config.url_providers or {}
		if #provs == 0 then
			vim.schedule(function()
				callback(false)
			end)
			return
		end
		local function try_provider(i)
			if i > #provs then
				vim.schedule(function()
					callback(false)
				end)
			else
				local full = provs[i]:format(cand.url)
				check_url_exists(full, function(ok)
					if ok then
						callback(true)
					else
						try_provider(i + 1)
					end
				end)
			end
		end
		try_provider(1)
	else
		vim.schedule(function()
			callback(false)
		end)
	end
end

-- Check through a list of URLs via curl (from check_url_exists).
-- Open the first one that exists.
local function try_open_urls(urls, on_none)
	local pending = #urls
	local done = false

	local function finish(success, url)
		if done then
			return
		end
		if success then
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
	if M.is_valid.url(candidate) then
		try_open_urls({ candidate }, function()
			vim.notify("URL not accessible: " .. candidate, vim.log.levels.ERROR)
		end)
	elseif M.is_valid.repo(candidate) then
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

function M.scan_line_for_urls(line_text, lnum, physical_lines)
	-- Strip all ANSI CSI sequences for better terminal handling.
	local esc = string.char(27)
	line_text = line_text:gsub(esc .. "%[[%d;]*[ -/]*[@-~]", "")

	--  Use url_enclosure_pairs over enclosure_pairs if available.
	local scan_cfg = config.config
	if config.config.url_enclosure_pairs then
		-- Deep‐clone every config field.
		scan_cfg = vim.deepcopy(config.config)
		-- Then override enclosure pairs.
		scan_cfg.enclosure_pairs = config.config.url_enclosure_pairs

		-- Rebuild delimiter cache so only URL pairs are used.
		local openings = {}
		for o, _ in pairs(scan_cfg.enclosure_pairs) do
			table.insert(openings, o)
		end
		table.sort(openings, function(a, b)
			return #a > #b
		end)
		scan_cfg._cached_openings = openings
	end

	local raw = candidates.scan_line(
		line_text,
		lnum,
		1, -- min_col = 1 to catch whole line
		scan_cfg.scan_unenclosed_words,
		physical_lines,
		scan_cfg
	)

	-- Filter for only actual URLs or owner/repo shortcuts and deduplicate.
	local unique = {}
	local seen = {}
	for _, cand in ipairs(raw) do
		local txt = cand.filename
		if M.is_valid.url(txt) or M.is_valid.repo(txt) then
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

-- Asynchronously filter list of candidates using validate_candidate.
local function filter_valid_candidates(cands, on_done)
	local pending = #cands
	local valids = {}
	if pending == 0 then
		return on_done(valids)
	end
	for _, cand in ipairs(cands) do
		validate_candidate(cand, function(ok)
			if ok then
				table.insert(valids, cand)
			end
			pending = pending - 1
			if pending == 0 then
				on_done(valids)
			end
		end)
	end
end

function M.select_url()
	local selection_keys = config.config.selection_keys
	local all = {}

	-- Collect URL candidates.
	for _, win in ipairs(visual_select.get_windows_to_check()) do
		if api.nvim_win_is_valid(win) then
			local buf = api.nvim_win_get_buf(win)
			local s = fn.line("w0", win)
			local e = fn.line("w$", win)

			local cands = candidates.collect_candidates_in_range(
				buf,
				win,
				s,
				e,
				M.scan_line_for_urls,
				true -- skip folds
			)
			vim.list_extend(all, cands)
		end
	end

	all = candidates.deduplicate_candidates(all)

	if #all == 0 then
		vim.notify(
			"No URL candidates found",
			vim.log.levels.INFO,
			{ title = "pathfinder.nvim" }
		)
		return
	end

	-- Show the picker once we have a final list.
	local function launch(cands)
		if #cands == 0 then
			vim.notify(
				"No valid URL candidates found",
				vim.log.levels.INFO,
				{ title = "pathfinder.nvim" }
			)
			return
		end

		visual_select.assign_labels(cands, selection_keys)
		visual_select.start_selection_loop(
			cands,
			highlight_ns,
			dim_ns,
			visual_select.highlight_candidate,
			function(sel)
				open_candidate_url(sel.url)
			end,
			#cands[1].label
		)
	end

	if config.config.validate_urls then
		filter_valid_candidates(all, launch)
	else
		launch(all)
	end
end

-- Return the {first, last} line to scan.
local function get_scan_range(buf, direction, use_limit)
	local lim = config.config.forward_limit
	local cur_line = api.nvim_win_get_cursor(0)[1]
	local max_line = api.nvim_buf_line_count(buf)
	if direction == 1 then
		local start = cur_line
		if use_limit and lim ~= 0 then
			local n = (lim == -1) and (api.nvim_win_get_height(0) - api.nvim_win_get_position(0)[1]) or lim
			return start, math.min(max_line, start + n - 1)
		end
		return start, max_line
	else
		local finish = cur_line
		if use_limit and lim ~= 0 then
			local n = (lim == -1) and cur_line or lim
			return math.max(1, finish - n + 1), finish
		end
		return 1, finish
	end
end

-- Sort file list starting closest to cursor (line and column) based on direction.
local function cmp_direction(direction)
	return function(a, b)
		local dl = (a.lnum - b.lnum) * direction
		if dl ~= 0 then
			return dl < 0
		end
		return ((a.start_col - b.start_col) * direction) < 0
	end
end

--- Jump to the count'th URL target with optional URL validation.
-- direction: 1 -> next; -1 -> previous
-- use_limit: true -> use config forward_limit
-- action: callback, e.g. jump or open
-- count: if not supplied defaults to vim.v.count or 1
-- validate: true -> check URLs resolve and skip on failure (can be slow)
local function jump_url(direction, use_limit, action, count, validate)
	count = count or vim.v.count1

	local buf = api.nvim_get_current_buf()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local curln = cursor_pos[1] -- vim.fn.line(".")
	local ccol = cursor_pos[2] + 1 -- vim.fn.col(".")

	local first, last = get_scan_range(buf, direction, use_limit)

	-- Collect and deduplicate raw candidates.
	local raw = picker.collect({
		win_ids = { 0 },
		buf = buf,
		start_line = first,
		end_line = last,
		scan_fn = M.scan_line_for_urls,
	})
	local all = candidates.deduplicate_candidates(raw)
	if #all == 0 then
		return vim.notify("No URL candidates found", vim.log.levels.INFO)
	end

	-- Filter out candidates relative to cursor.
	local filtered = {}
	for _, c in ipairs(all) do
		-- Filter before cursor for direction == 1, or
		-- filter after cursor for direction == -1.
		local dl = (c.lnum - curln) * direction
		local dc = (c.start_col - ccol) * direction
		if dl > 0 or (dl == 0 and dc > 0) or (dl == 0 and dc == 0 and use_limit) then
			filtered[#filtered + 1] = c
		end
	end
	if #filtered == 0 then
		local msg = direction == 1 and "No next URL found" or "No previous URL found"
		return vim.notify(msg, vim.log.levels.INFO)
	end

	-- Sort according to direction.
	table.sort(filtered, cmp_direction(direction))

	-- If not validating URLs, return action (jump/open) on specified raw candidate.
	if not validate then
		if count > #filtered then
			vim.notify(string.format("Only %d URL candidates found", #filtered), vim.log.levels.INFO)
			return
		end
		return action(filtered[count])
	end

	-- Asynchronously validate each URL but preserve order.
	local pending = #filtered
	local valids = {}
	for i, cand in ipairs(filtered) do
		validate_candidate(cand, function(ok)
			if ok then
				valids[#valids + 1] = { i = i, cand = cand }
			end
			pending = pending - 1
			if pending == 0 then
				table.sort(valids, function(a, b)
					return a.i < b.i
				end)
				if #valids >= count then
					action(valids[count].cand)
				else
					vim.notify(string.format("Only %d valid URL candidates found", #valids), vim.log.levels.INFO)
				end
			end
		end)
	end
end

function M.gx()
	jump_url(1, true, function(c)
		open_candidate_url(c.url)
	end, nil, false)
end

function M.next_url(count)
	jump_url(1, false, function(c)
		api.nvim_win_set_cursor(0, { c.lnum, c.start_col - 1 })
	end, count, config.config.validate_urls)
end

function M.prev_url(count)
	jump_url(-1, false, function(c)
		api.nvim_win_set_cursor(0, { c.lnum, c.start_col - 1 })
	end, count, config.config.validate_urls)
end

return M
