local M = {}
local config = require("pathfinder.config")

function M.deduplicate_candidates(candidates)
	local seen = {}
	local unique = {}
	for _, cand in ipairs(candidates) do
		local key = string.format("%d:%d:%s", cand.lnum, cand.finish, cand.filename)
		if not seen[key] then
			table.insert(unique, cand)
			seen[key] = true
		end
	end
	return unique
end

function M.strip_nested_enclosures(str, pairs)
	while true do
		local first = str:sub(1, 1)
		local closing = pairs[first]
		if closing and str:sub(-#closing) == closing then
			str = str:sub(1 + #first, -#closing - 1 or nil)
		else
			break
		end
	end
	return str
end

--stylua: ignore
local patterns = {
    { pattern = "^(.-)%s*%(%s*(%d+)%s*%)%s*$" },    -- e.g. "file (line)"
    { pattern = "^(.-)%s*:%s*(%d+)%s*$" },          -- e.g. "file:line"
    { pattern = "^(.-)%s*@%s*(%d+)%s*$" },          -- e.g. "file @ line"
    { pattern = "^(.-)%s+(%d+)%s*$" },              -- e.g. "file line"
}

function M.parse_filename_and_linenr(str)
	str = str:match("^%s*(.-)%s*$") -- Trim leading/trailing whitespace.
	for _, pat in ipairs(patterns) do
		local filename, linenr_str = str:match(pat.pattern)
		if filename and linenr_str then
			return filename, tonumber(linenr_str)
		end
	end

	if vim.fn.has("win64") == 1 or vim.fn.has("win32") == 1 then
		return str:gsub("[.,;!]+$", ""), nil -- Don't clean up : on Windows.
	end
	return str:gsub("[.,:;!]+$", ""), nil -- Clean up trailing punctuation, no line number.
end

function M.find_next_opening(line, start_pos, openings)
	for pos = start_pos, #line do
		for _, opening in ipairs(openings) do
			local opening_len = #opening
			if pos + opening_len - 1 <= #line and line:sub(pos, pos + opening_len - 1) == opening then
				return pos, opening
			end
		end
	end
	return nil, nil
end

function M.find_closing(line, start_pos, closing)
	local closing_len = #closing
	for pos = start_pos, #line - closing_len + 1 do
		if line:sub(pos, pos + closing_len - 1) == closing then
			return pos
		end
	end
	return nil
end

local function split_candidate_string(str)
	local parts = {}
	for segment in str:gmatch("([^,;|]+)") do
		table.insert(parts, segment)
	end
	return parts
end

--- Processes a candidate string into one or more candidates.
local function process_candidate_string(raw_str, lnum, start_col, finish_col, cand_type, min_col, base_offset)
	local results = {}
	-- base_offset used for calculating boundaries when enclosures used.
	local offset = base_offset or start_col
	local trimmed = vim.trim(raw_str):gsub("^['\"]", ""):gsub("['\"]$", "")
	local parts = split_candidate_string(trimmed)
	if #parts > 1 then
		local idx = 1
		while true do
			local s, e = trimmed:find("([^,;|]+)", idx)
			if not s then
				break
			end
			local piece = trimmed:sub(s, e)
			piece = vim.trim(piece):gsub("^['\"]", ""):gsub("['\"]$", "")
			local filename, linenr = M.parse_filename_and_linenr(piece)
			local cand_start = offset + (s - 1)
			local cand_finish = offset + e
			if not min_col or cand_finish >= min_col then
				table.insert(results, {
					filename = filename,
					lnum = lnum,
					start_col = cand_start,
					finish = cand_finish,
					type = cand_type,
					linenr = linenr,
				})
			end
			idx = e + 1
		end
	else
		local filename, linenr = M.parse_filename_and_linenr(trimmed)
		if not min_col or finish_col >= min_col then
			table.insert(results, {
				filename = filename,
				lnum = lnum,
				start_col = offset,
				finish = offset + #trimmed,
				type = cand_type,
				linenr = linenr,
			})
		end
	end
	return results
end

local function parse_words_in_segment(line, start_pos, end_pos, lnum, min_col, results, current_order)
	local segment = line:sub(start_pos, end_pos)
	local matches = {}

	-- Find all matches of filename-line number patterns.
	for _, pat in ipairs(patterns) do
		local s, e, filename, linenr_str = segment:find(pat.pattern)
		while s do
			local abs_s = start_pos + s - 1
			local abs_e = start_pos + e - 1
			if not min_col or abs_e >= min_col then
				table.insert(matches, {
					filename = filename,
					lnum = lnum,
					start_col = abs_s,
					finish = abs_e,
					type = "word",
					linenr = tonumber(linenr_str),
				})
			end
			s, e, filename, linenr_str = segment:find(pat.pattern, e + 1)
		end
	end

	-- Sort matches by start position.
	table.sort(matches, function(a, b)
		return a.start_col < b.start_col
	end)

	-- Process segments between matches as standalone words.
	local pos = start_pos
	for _, match in ipairs(matches) do
		while pos < match.start_col do
			local word_s, word_e = line:find("%S+", pos)
			if not word_s or word_s >= match.start_col then
				break
			end
			local word_finish = math.min(word_e, match.start_col - 1)
			local word_str = line:sub(word_s, word_finish)
			local candidates = process_candidate_string(word_str, lnum, word_s, word_finish, "word", min_col)
			for _, cand in ipairs(candidates) do
				current_order = current_order + 1
				cand.order = current_order
				table.insert(results, cand)
			end
			pos = word_e + 1
		end
		current_order = current_order + 1
		match.order = current_order
		table.insert(results, match)
		pos = match.finish + 1
	end

	-- Process remaining words after the last match.
	while pos <= end_pos do
		local word_s, word_e = line:find("%S+", pos)
		if not word_s or word_s > end_pos then
			break
		end
		local word_finish = math.min(word_e, end_pos)
		local word_str = line:sub(word_s, word_finish)
		local candidates = process_candidate_string(word_str, lnum, word_s, word_finish, "word", min_col)
		for _, cand in ipairs(candidates) do
			current_order = current_order + 1
			cand.order = current_order
			table.insert(results, cand)
		end
		pos = word_e + 1
	end

	return current_order
end

function M.scan_line(line, lnum, min_col, scan_unenclosed_words)
	local results = {}
	local order = 0
	local pos = 1

	local enclosure_pairs = config.config.enclosure_pairs
	local openings = {}
	for opening, _ in pairs(enclosure_pairs) do
		table.insert(openings, opening)
	end
	table.sort(openings, function(a, b)
		return #a > #b
	end)

	while pos <= #line do
		-- local open_pos, opening = nil, nil
		local open_pos, opening = M.find_next_opening(line, pos, openings)

		if open_pos then
			if scan_unenclosed_words and (open_pos > pos) then
				order = parse_words_in_segment(line, pos, open_pos - 1, lnum, min_col, results, order)
			end

			local closing = enclosure_pairs[opening]
			local content_start = open_pos + #opening
			local close_pos = M.find_closing(line, content_start, closing)
			if close_pos then
				local enclosed_str = line:sub(content_start, close_pos - 1)
				local escaped_spaces
				enclosed_str, escaped_spaces = enclosed_str:gsub("\\ ", " ")
				enclosed_str = M.strip_nested_enclosures(enclosed_str, enclosure_pairs)
				-- For enclosure candidates, use content_start as the base offset.
				local candidates = process_candidate_string(
					enclosed_str,
					lnum,
					open_pos,
					close_pos,
					"enclosures",
					min_col,
					content_start
				)
				for _, cand in ipairs(candidates) do
					order = order + 1
					cand.order = order
					cand.opening_delim = opening
					cand.closing_delim = closing
					cand.no_delimiter_adjustment = true
					cand.escaped_space_count = escaped_spaces
					table.insert(results, cand)
				end
				pos = close_pos + #closing
			else
				pos = open_pos + #opening
			end
		else
			if scan_unenclosed_words then
				order = parse_words_in_segment(line, pos, #line, lnum, min_col, results, order)
			end
			break
		end
	end

	table.sort(results, function(a, b)
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		elseif a.start_col ~= b.start_col then
			return a.start_col < b.start_col
		else
			return (a.order or 0) < (b.order or 0)
		end
	end)
	return results
end

function M.collect_forward_candidates(cursor_line, cursor_col)
	local forward_candidates = {}
	local lines_searched = 0
	local buffer_end = vim.fn.line("$")
	for lnum = cursor_line, buffer_end do
		local forward_limit = config.config.forward_limit
		if forward_limit == -1 then
			forward_limit = vim.fn.winheight(0) - vim.fn.winline() + 1
		end
		if forward_limit and lines_searched >= forward_limit then
			break
		end
		local text = vim.fn.getline(lnum)
		local min_col = (lnum == cursor_line) and cursor_col or nil
		local scan_unenclosed_words = config.config.scan_unenclosed_words
		local line_candidates = M.scan_line(text, lnum, min_col, scan_unenclosed_words)
		vim.list_extend(forward_candidates, line_candidates)
		lines_searched = lines_searched + 1
	end
	return M.deduplicate_candidates(forward_candidates)
end

return M
