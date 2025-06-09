local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local candidates = require("pathfinder.candidates")
local config = require("pathfinder.config")
local notify = require("pathfinder.notify")
local picker = require("pathfinder.picker")
local visual_select = require("pathfinder.visual_select")

visual_select.set_default_highlights()

local messages = {
	none = "URL candidate not found",
	none_valid = "Valid URL candidate not found",
	none_count = "%s URL target not found (%d available)",
	none_valid_count = "Valid %s URL target not found (%d available)",
}

local patterns = {
	url = "[Hh][Tt][Tt][Pp][Ss]?://[%w%-_.%?%/%%:=&]+",
	repo = "^[%w._%-]+/[%w._%-]+$",
	flake = "^([%w._%-]+):(.+)$",
}

local function make_validator(pat)
	return function(s)
		return s:match(pat) ~= nil
	end
end

M.is_valid = {
	url = make_validator(patterns.url),
	repo = make_validator(patterns.repo),
	flake = function(s)
		local prefix = s:match(patterns.flake)
		if not prefix then
			return false
		end
		local providers = config.config.flake_providers or {}
		return providers[prefix] ~= nil
	end,
}

function M.flake_to_url(s)
	local prefix, rest = s:match(patterns.flake)
	if not prefix then
		return nil
	end
	local providers = config.config.flake_providers or {}
	local fmt = providers[prefix]
	return fmt and fmt:format(rest) or nil
end

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
			timeout = 6000, -- hard kill after 6s in case of curl timeout issues
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

	-- Handle flakes.
	elseif M.is_valid.flake(cand.url) then
		local prefix, rest = cand.url:match(patterns.flake)
		local provs = config.config.flake_providers or {}
		local fmt = provs[prefix]
		if not fmt then
			-- Unknown flake provider.
			vim.schedule(function()
				callback(false)
			end)
		else
			local full = fmt:format(rest)
			check_url_exists(full, callback)
		end
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
				notify.info('Opening "' .. url .. '"')
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

local function try_open_with_error(urls, error_message)
	try_open_urls(urls, function()
		notify.error(error_message)
	end)
end

function M.open_candidate_url(candidate)
	if M.is_valid.url(candidate) then
		try_open_with_error({ candidate }, "URL not accessible: " .. candidate)
		return
	end

	if M.is_valid.repo(candidate) then
		local provs = config.config.url_providers or {}
		if vim.tbl_isempty(provs) then
			return notify.error("No URL providers configured.")
		end

		local urls = vim.tbl_map(function(fmt)
			return fmt:format(candidate)
		end, provs)

		try_open_with_error(urls, "No provider found for " .. candidate)
		return
	end

	if M.is_valid.flake(candidate) then
		local prefix, rest = candidate:match(patterns.flake)
		local provs = config.config.flake_providers or {}
		local fmt = provs[prefix]

		if not fmt then
			return notify.error("Flake not found: " .. prefix)
		end

		local url = fmt:format(rest)
		try_open_with_error({ url }, "Flake not accessible: " .. url)
		return
	end

	notify.error("Not a valid URL, repo, or flake: " .. candidate)
end

function M.scan_line_for_urls(line_text, lnum, physical_lines, base_cfg)
	-- Strip all ANSI CSI sequences for better terminal handling.
	local esc = string.char(27)
	line_text = line_text:gsub(esc .. "%[[%d;]*[ -/]*[@-~]", "")

	-- Use buffer-specific config if available (e.g. for url_enclosure_pairs),
	-- else use the default config.
	local scan_cfg = vim.deepcopy(base_cfg or config.config)

	-- Rebuild delimiter cache so only URL pairs are used (if defined).
	if scan_cfg.url_enclosure_pairs then
		scan_cfg.enclosure_pairs = scan_cfg.url_enclosure_pairs
		local openings = {}
		if scan_cfg.enclosure_pairs then
			for opening, _ in pairs(scan_cfg.enclosure_pairs) do
				openings[#openings + 1] = opening
			end
			table.sort(openings, function(a, b)
				return #a > #b
			end)
		end
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
		local url = txt:match(patterns.url) -- handle, e.g. git+https://...
			or (M.is_valid.repo(txt) and txt)
			or (M.is_valid.flake(txt) and txt)

		-- If http(s) URL found inside a larger string, narrow the spans.
		if url then
			local s, e = txt:find(patterns.url)
			if s and e then
				for _, span in ipairs(cand.target_spans) do
					local orig = span.start_col
					-- Shift each span so it covers only the http(s)... part.
					span.start_col = orig + s - 1
					span.finish_col = orig + e - 1
				end
			end
		end

		if url then
			local key = ("%d:%d:%d"):format(lnum, cand.start_col, cand.finish)
			if not seen[key] then
				seen[key] = true
				cand.url = url
				unique[#unique + 1] = cand
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
				valids[#valids + 1] = cand
			end
			pending = pending - 1
			if pending == 0 then
				on_done(valids)
			end
		end)
	end
end

function M.select_url()
	local tmux = require("pathfinder.tmux")

	if tmux.is_enabled() then
		local tmux_result = tmux.select_url()
		if tmux_result == true then
			return
		end
	end

	local all = {}

	-- Collect URL candidates.
	for _, win in ipairs(visual_select.get_windows_to_check()) do
		if api.nvim_win_is_valid(win) then
			local buf = api.nvim_win_get_buf(win)
			local s = fn.line("w0", win)
			local e = fn.line("w$", win)

			local scan_fn = function(
				line_text_iter,
				lnum_iter,
				physical_lines_iter
			)
				local buffer_specific_cfg = config.get_config_for_buffer(buf)
				return M.scan_line_for_urls(
					line_text_iter,
					lnum_iter,
					physical_lines_iter,
					buffer_specific_cfg
				)
			end

			local cands = candidates.collect_candidates_in_range(
				buf,
				win,
				s,
				e,
				scan_fn,
				true -- skip folds
			)
			vim.list_extend(all, cands)
		end
	end

	all = candidates.deduplicate_candidates(all)

	if #all == 0 then
		notify.info(messages.none)
		return
	end

	-- Show the picker once we have a final list.
	local function launch(cands)
		if #cands == 0 then
			notify.info(messages.none_valid)
			return
		end

		visual_select.assign_labels(cands, config.config.selection_keys)
		visual_select.start_selection_loop(
			cands,
			visual_select.HIGHLIGHT_NS,
			visual_select.DIM_NS,
			visual_select.highlight_candidate,
			function(sel)
				M.open_candidate_url(sel.url)
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
-- use_limit: true -> use `url_forward_limit`
-- action: callback, e.g. jump or open
-- count: if not supplied defaults to vim.v.count or 1
-- validate: true -> check URLs resolve and skip on failure (can be slow)
local function jump_url(direction, use_limit, action, count, validate)
	count = count or vim.v.count1

	local buf = api.nvim_get_current_buf()
	local win = api.nvim_get_current_win()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local cursor_row = cursor_pos[1] -- vim.fn.line(".")
	local cursor_col = cursor_pos[2] + 1 -- vim.fn.col(".")
	local lim = config.config.url_forward_limit
	local start_ln, end_ln

	-- Determine scan range based on direction and `url_forward_limit`.
	if direction == 1 then
		start_ln = cursor_row
		end_ln = (lim == 0) and api.nvim_buf_line_count(buf)
			or (lim == -1) and fn.line("w$", win)
			or math.min(api.nvim_buf_line_count(buf), cursor_row + lim - 1)
	else
		end_ln = cursor_row
		start_ln = (lim == 0) and 1
			or (lim == -1) and fn.line("w0", win)
			or math.max(1, cursor_row - lim + 1)
	end

	-- Collect and deduplicate raw candidates.
	local all = picker.collect({
		win_ids = { 0 },
		buf = buf,
		start_line = start_ln,
		end_line = end_ln,
		scan_fn = M.scan_line_for_urls,
	})

	all = candidates.deduplicate_candidates(all)
	if #all == 0 then
		return notify.info(messages.none)
	end

	-- Filter out candidates at and before/after the cursor (based on direction).
	local filtered = {}
	for _, c in ipairs(all) do
		local dl = (c.lnum - cursor_row) * direction
		local dc = (c.start_col - cursor_col) * direction
		if
			dl > 0
			or (dl == 0 and dc > 0)
			or (dl == 0 and dc == 0 and use_limit)
		then
			filtered[#filtered + 1] = c
		end
	end

	-- Sort according to direction.
	table.sort(filtered, cmp_direction(direction))

	local direc_name = direction == 1 and "Forward" or "Backward"

	-- If not validating URLs, return action (jump/open) on specified raw candidate.
	if not validate then
		if count > #filtered then
			notify.info(
				string.format(messages.none_count, direc_name, #filtered)
			)
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
				elseif #valids == 0 then
					return notify.info(messages.none)
				else
					notify.info(
						string.format(
							messages.none_valid_count,
							direc_name,
							count,
							#valids
						)
					)
				end
			end
		end)
	end
end

function M.gx()
	jump_url(1, true, function(c)
		M.open_candidate_url(c.url)
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
