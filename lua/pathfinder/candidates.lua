local M = {}
local config = require("pathfinder.config")
local utils = require("pathfinder.utils")

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

local function strip_nested_enclosures(str, pairs)
	local removed = 0
	while true do
		local first = str:sub(1, 1)
		local closing = pairs[first]
		if closing and str:sub(-#closing) == closing then
			str = str:sub(1 + #first, -#closing - 1 or nil)
			removed = removed + #first
		else
			break
		end
	end
	return str, removed
end

--stylua: ignore
M.patterns = {
    { pattern = "(%S+)%s*%(%s*(%d+)%s*%)" },          -- e.g. "file (line)"
    { pattern = "(%S+)%s*:%s*(%d+)%s*:%s*(%d+)%S*" }, -- e.g. "file:line:column"
    { pattern = "(%S+)%s*:%s*(%d+)%S*" },             -- e.g. "file:line"
    { pattern = "(%S+)%s*@%s*(%d+)%S*" },             -- e.g. "file @ line"
    { pattern = "(%S+)%s+(%d+)%S*" },                 -- e.g. "file line"
}

function M.parse_filename_and_linenr(str)
	str = str:gsub("\\ ", " ")

	for _, pat in ipairs(M.patterns) do
		local filename, linenr_str = str:match(pat.pattern)
		if filename and linenr_str then
			filename = vim.trim(filename)
			filename = filename:gsub("[.,:;!]+$", "")
			return filename, tonumber(linenr_str)
		end
	end
	-- If no match, return the trimmed string without line number.
	local cleaned = str:gsub("[.,:;!]+$", "")
	return vim.trim(cleaned), nil
end

local function find_next_opening(line, start_pos, openings)
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

local function find_closing(line, start_pos, closing)
	local closing_len = #closing
	for pos = start_pos, #line - closing_len + 1 do
		if line:sub(pos, pos + closing_len - 1) == closing then
			return pos
		end
	end
	return nil
end

--- Processes a candidate string into one or more file candidates.
---@param raw_str string The raw string to process (e.g. "'some\ file.txt','file2'").
---@param lnum number The line number in the buffer where this string appears.
---@param start_col number The starting column of the raw string in the original line.
---@param min_col number|nil Minimum column to include candidates from (nil means no limit).
---@param base_offset number|nil Optional offset for the start position (e.g. after an opening delimiter).
---@param escaped_space_count number|nil Number of escaped spaces replaced in the original string.
---@return table A list of candidate tables with filename, positions, and metadata.
local function process_candidate_string(raw_str, lnum, start_col, min_col, base_offset, escaped_space_count)
	local results = {}
	local base = base_offset or start_col
	escaped_space_count = escaped_space_count or 0

	local search_pos = 1
	while true do
		local match_start, match_end = raw_str:find("([^,;|]+)", search_pos)
		if not match_start then
			break
		end

		local piece = raw_str:sub(match_start, match_end)
		local piece_leading = piece:match("^(%s*)") or ""
		local trimmed_piece = vim.trim(piece)
		local inner_str, inner_removed = strip_nested_enclosures(trimmed_piece, config.config.enclosure_pairs)
		local start_pos = inner_str:find("%S") or 1
		local end_pos = #inner_str - #(inner_str:match("%s*$") or "")
		local filename_str = inner_str:sub(start_pos, end_pos)
		local cand_start = base + (match_start - 1) + #piece_leading + inner_removed + (start_pos - 1)
		local filename_length = end_pos - start_pos + 1
		local cand_finish = cand_start + filename_length

		if not min_col or cand_finish >= min_col then
			local filename, linenr = M.parse_filename_and_linenr(filename_str)
			table.insert(results, {
				filename = filename,
				lnum = lnum,
				start_col = cand_start,
				finish = cand_finish,
				linenr = linenr,
				escaped_space_count = escaped_space_count,
			})
		end
		search_pos = match_end + 1
	end

	if search_pos == 1 then
		local piece_leading = raw_str:match("^(%s*)") or ""
		local trimmed_str = vim.trim(raw_str)
		local inner_str, inner_removed = strip_nested_enclosures(trimmed_str, config.config.enclosure_pairs)
		local start_pos = inner_str:find("%S") or 1
		local end_pos = #inner_str - #(inner_str:match("%s*$") or "")
		local filename_str = inner_str:sub(start_pos, end_pos)
		local cand_start = base + #piece_leading + inner_removed + (start_pos - 1)
		local filename_length = end_pos - start_pos + 1
		local cand_finish = cand_start + filename_length

		local filename, linenr = M.parse_filename_and_linenr(filename_str)
		table.insert(results, {
			filename = filename,
			lnum = lnum,
			start_col = cand_start,
			finish = cand_finish,
			linenr = linenr,
			escaped_space_count = escaped_space_count,
		})
	end

	return results
end

local function parse_words_in_segment(line, start_pos, end_pos, lnum, min_col, results, current_order)
	local segment = line:sub(start_pos, end_pos)
	local matches = {}

	-- Find all matches of filename-line number patterns.
	for _, pat in ipairs(M.patterns) do
		local match_start, match_end, filename, linenr_str = segment:find(pat.pattern)
		while match_start do
			local abs_s = start_pos + match_start - 1
			local abs_e = start_pos + match_end
			if not min_col or abs_e >= min_col then
				table.insert(matches, {
					filename = filename,
					lnum = lnum,
					start_col = abs_s,
					finish = abs_e,
					linenr = tonumber(linenr_str),
				})
			end
			match_start, match_end, filename, linenr_str = segment:find(pat.pattern, match_end + 1)
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
			local candidates = process_candidate_string(word_str, lnum, word_s, min_col)
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
		local candidates = process_candidate_string(word_str, lnum, word_s, min_col)
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
		local open_pos, opening = find_next_opening(line, pos, openings)

		if open_pos then
			if scan_unenclosed_words and (open_pos > pos) then
				order = parse_words_in_segment(line, pos, open_pos - 1, lnum, min_col, results, order)
			end

			local closing = enclosure_pairs[opening]
			local content_start = open_pos + #opening
			local close_pos = find_closing(line, content_start, closing)

			if close_pos then
				local enclosed_str = line:sub(content_start, close_pos - 1)
				-- Handle escaped spaces if necessary.
				local escaped_space_count
				enclosed_str, escaped_space_count = enclosed_str:gsub("\\ ", " ")
				local candidates =
					process_candidate_string(enclosed_str, lnum, open_pos, min_col, content_start, escaped_space_count)
				for _, cand in ipairs(candidates) do
					order = order + 1
					cand.order = order
					cand.opening_delim = opening
					cand.closing_delim = closing
					cand.no_delimiter_adjustment = true
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
	local lnum = cursor_line

	while lnum <= buffer_end do
		local forward_limit = config.config.forward_limit
		if forward_limit == -1 then
			forward_limit = vim.fn.winheight(0) - vim.fn.winline() + 1
		end
		if forward_limit and lines_searched >= forward_limit then
			break
		end

		-- Use the shared utility to merge wrapped lines in terminal buffers.
		local line_text, merged_end = utils.get_merged_line(lnum, buffer_end)
		local min_col = (lnum == cursor_line) and cursor_col or nil
		local scan_unenclosed_words = config.config.scan_unenclosed_words
		local line_candidates = M.scan_line(line_text, lnum, min_col, scan_unenclosed_words)
		vim.list_extend(forward_candidates, line_candidates)
		lines_searched = lines_searched + 1

		-- Advance lnum to the line after the merged block.
		lnum = merged_end + 1
	end

	return M.deduplicate_candidates(forward_candidates)
end

return M
