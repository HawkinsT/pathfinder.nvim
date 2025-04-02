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

---Processes a single potential filename string.
-- Strips enclosures, calculates positions, parses filename/line, and creates candidate table.
---@param piece string The string segment to process.
---@param lnum number Line number in the buffer.
---@param base_col number The starting column of `piece` in the original line.
---@param min_col number|nil Minimum column to include candidates from.
---@param escaped_space_count number Number of escaped spaces replaced.
---@return table|nil A candidate table or nil if invalid/before min_col.
local function create_candidate_from_piece(piece, lnum, base_col, min_col, escaped_space_count)
	-- Find leading whitespace to adjust start column accurately
	local piece_leading_ws = piece:match("^(%s*)") or ""
	local trimmed_piece = vim.trim(piece)
	if trimmed_piece == "" then
		return nil -- Ignore empty or whitespace-only pieces
	end

	-- Strip nested enclosures like ('file') or ["file"].
	local inner_str, removed_start_len = strip_nested_enclosures(trimmed_piece, config.config.enclosure_pairs)

	-- Find the start and end of the actual content within the (potentially stripped) string.
	local content_start_offset = inner_str:find("%S") or 1 -- First non-whitespace char
	local content_end_offset = #inner_str - #((inner_str:match("%s*$")) or "") -- Last non-whitespace char

	-- Extract the core string that might be a filename.
	local filename_str = inner_str:sub(content_start_offset, content_end_offset)
	if filename_str == "" then
		return nil -- Ignore if stripping leaves nothing
	end

	-- Calculate precise start and end columns in the original line.
	local cand_start_col = base_col + #piece_leading_ws + removed_start_len + (content_start_offset - 1)
	local filename_length = content_end_offset - content_start_offset + 1
	local cand_finish_col = cand_start_col + filename_length

	-- Only include if the candidate ends at or after the minimum column (e.g. cursor position).
	if not min_col or cand_finish_col >= min_col then
		local filename, linenr = M.parse_filename_and_linenr(filename_str)
		if filename and filename ~= "" then -- Ensure we have a non-empty filename
			return {
				filename = filename,
				lnum = lnum,
				start_col = cand_start_col, -- 1-based start column
				finish = cand_finish_col, -- 1-based inclusive end column
				linenr = linenr, -- Parsed line number (or nil)
				escaped_space_count = escaped_space_count,
			}
		end
	end
	return nil -- Candidate was filtered out or invalid
end

--- Processes a raw string which might contain multiple comma/semicolon/pipe-separated filenames.
---@param raw_str string The raw string (e.g. "'file1.txt', 'file2'").
---@param lnum number The line number in the buffer.
---@param start_col number The starting column of `raw_str` in the original line.
---@param min_col number|nil Minimum column to include candidates from.
---@param base_offset number|nil Optional offset adjustment (e.g., if `raw_str` is from inside delimiters).
---@param escaped_space_count number|nil Number of escaped spaces replaced.
---@return table List of candidate tables.
local function process_candidate_string(raw_str, lnum, start_col, min_col, base_offset, escaped_space_count)
	local results = {}
	-- Adjust base column if an offset (like delimiter length) is provided
	local base = base_offset or start_col
	escaped_space_count = escaped_space_count or 0

	local search_pos = 1
	local found_separator = false
	-- Split the string by common separators: ',', ';', '|'
	while true do
		-- Find the next potential segment (non-separator characters).
		local match_start, match_end = raw_str:find("([^,;|]+)", search_pos)
		if not match_start then
			break -- No more segments found
		end
		found_separator = true -- Indicate that we are processing separated items

		local piece = raw_str:sub(match_start, match_end)
		-- Calculate the actual starting column of this piece in the original line.
		local piece_start_col = base + (match_start - 1)

		-- Process this individual piece using the refactored helper.
		local candidate = create_candidate_from_piece(piece, lnum, piece_start_col, min_col, escaped_space_count)
		if candidate then
			table.insert(results, candidate)
		end

		-- Move search position past the current segment.
		search_pos = match_end + 1
	end

	-- Fallback: If no separators were found, process the entire `raw_str` as a single piece.
	-- This handles cases like `['filename']` or just `filename` without commas etc.
	if not found_separator and search_pos == 1 then
		local candidate = create_candidate_from_piece(raw_str, lnum, base, min_col, escaped_space_count)
		if candidate then
			table.insert(results, candidate)
		end
	end

	return results
end

---Processes a single word, adds candidates to results, and updates order.
---@param word_str string The word string to process.
---@param lnum number Line number.
---@param word_start_col number Starting column of the word.
---@param min_col number|nil Minimum column requirement.
---@param results table The table to add results to.
---@param current_order number The current order counter.
---@return number The updated order counter.
local function process_word_segment(word_str, lnum, word_start_col, min_col, results, current_order)
	local candidates = process_candidate_string(word_str, lnum, word_start_col, min_col)
	for _, cand in ipairs(candidates) do
		current_order = current_order + 1
		cand.order = current_order
		table.insert(results, cand)
	end
	return current_order
end

-- Parses words within a specific segment of a line (e.g. between delimiters or outside them).
-- It first looks for structured patterns (like file:line) and then treats remaining text as words.
local function parse_words_in_segment(line, start_pos, end_pos, lnum, min_col, results, current_order)
	-- Ensure segment boundaries are valid.
	if start_pos > end_pos then
		return current_order
	end
	local segment = line:sub(start_pos, end_pos)
	local structured_matches = {}

	-- 1. Find all occurrences of structured patterns (e.g. file:line) within the segment.
	for _, pat in ipairs(M.patterns) do
		local search_offset = 1
		while search_offset <= #segment do
			local match_s, match_e, filename, linenr_str = segment:find(pat.pattern, search_offset)
			if not match_s then
				break -- No more matches for this pattern in the rest of the segment.
			end
			-- Calculate absolute positions in the original line.
			local abs_start_col = start_pos + match_s - 1
			local abs_finish_col = start_pos + match_e - 1 -- Make finish inclusive
			-- Check against minimum column requirement
			if not min_col or abs_finish_col >= min_col then
				if filename and filename ~= "" and linenr_str then -- Ensure valid components
					table.insert(structured_matches, {
						filename = filename,
						lnum = lnum,
						start_col = abs_start_col,
						finish = abs_finish_col,
						linenr = tonumber(linenr_str),
					})
				end
			end
			-- Continue searching after the current match.
			search_offset = match_e + 1
		end
	end

	-- 2. Sort the structured matches by their starting position.
	table.sort(structured_matches, function(a, b)
		return a.start_col < b.start_col
	end)

	-- 3. Process words in the gaps *between* or *around* the structured matches.
	local current_parse_pos = start_pos
	for _, match in ipairs(structured_matches) do
		-- Process words before the current structured match.
		if current_parse_pos < match.start_col then
			local word_search_start = current_parse_pos
			while word_search_start < match.start_col do
				-- Find the next non-whitespace word chunk.
				local word_s, word_e = line:find("%S+", word_search_start)
				-- Stop if no word found or it starts at or after the structured match.
				if not word_s or word_s >= match.start_col then
					break
				end
				-- Ensure the word ends before the structured match begins.
				local word_finish_col = math.min(word_e, match.start_col - 1)
				local word_str = line:sub(word_s, word_finish_col)
				-- Process this word using the helper.
				current_order = process_word_segment(word_str, lnum, word_s, min_col, results, current_order)
				-- Advance search position for the next word.
				word_search_start = word_finish_col + 1
			end
		end

		-- Add the structured match itself to the results.
		current_order = current_order + 1
		match.order = current_order
		table.insert(results, match)

		-- Update the position to parse after this match.
		current_parse_pos = match.finish + 1
	end

	-- 4. Process any remaining words after the last structured match (or all words if no matches).
	local word_search_start = current_parse_pos
	while word_search_start <= end_pos do
		local word_s, word_e = line:find("%S+", word_search_start)
		-- Stop if no more words or word starts beyond the segment end.
		if not word_s or word_s > end_pos then
			break
		end
		-- Ensure the word ends within the segment.
		local word_finish_col = math.min(word_e, end_pos)
		local word_str = line:sub(word_s, word_finish_col)
		-- Process this word using the helper.
		current_order = process_word_segment(word_str, lnum, word_s, min_col, results, current_order)
		-- Advance search position.
		word_search_start = word_finish_col + 1
	end

	return current_order -- Return the final order count
end

function M.scan_line(line, lnum, min_col, scan_unenclosed_words)
	local results = {}
	local order = 0 -- Order counter for preserving relative order of candidtes in the line.
	local pos = 1 -- Current parsing position in the line.

	local enclosure_pairs = config.config.enclosure_pairs
	local openings = config.config._cached_openings or {}

	while pos <= #line do
		-- Find the next opening delimiter at or after the current position.
		local open_pos, opening = find_next_opening(line, pos, openings)

		if open_pos then
			-- If scanning unenclosed words is enabled, parse the segment before this opening delimiter.
			if scan_unenclosed_words and (open_pos > pos) then
				order = parse_words_in_segment(line, pos, open_pos - 1, lnum, min_col, results, order)
			end

			-- Find the corresponding closing delimiter for the found opening one.
			local closing = enclosure_pairs[opening]
			local content_start_pos = open_pos + #opening
			local close_pos = find_closing(line, content_start_pos, closing)

			if close_pos then
				-- Found a matching pair, process the content inside.
				local enclosed_str = line:sub(content_start_pos, close_pos - 1)
				local escaped_space_count = 0
				-- Handle escaped spaces within the enclosed string.
				if enclosed_str:find("\\ ", 1, true) then
					enclosed_str = enclosed_str:gsub("\\ ", function()
						escaped_space_count = escaped_space_count + 1
						return " "
					end)
				end

				-- Process the content within the delimiters.
				local candidates_in_enclosure = process_candidate_string(
					enclosed_str,
					lnum,
					open_pos, -- Original start column of the opening delimiter.
					min_col,
					content_start_pos, -- Base offset is the start of the content.
					escaped_space_count
				)
				-- Add valid candidates found inside the enclosure.
				for _, cand in ipairs(candidates_in_enclosure) do
					order = order + 1
					cand.order = order
					-- Flag to potentially adjust highlight extmarks later.
					cand.no_delimiter_adjustment = false -- Default to allow adjustment.
					cand.type = "enclosures" -- Mark type for potential special handling.
					table.insert(results, cand)
				end
				-- Move parsing position past the closing delimiter.
				pos = close_pos + #closing
			else
				-- No closing delimiter found, treat the opening delimiter as plain text.
				-- and continue scanning from after it.
				-- If scanning unenclosed, parse the opening delimiter itself as a word.
				if scan_unenclosed_words then
					order =
						parse_words_in_segment(line, open_pos, open_pos + #opening - 1, lnum, min_col, results, order)
				end
				pos = open_pos + #opening -- Move past the unmatched opening delimiter.
			end
		else
			-- No more opening delimiters found on the rest of the line.
			-- If scanning unenclosed words, parse the remaining part of the line.
			if scan_unenclosed_words then
				order = parse_words_in_segment(line, pos, #line, lnum, min_col, results, order)
			end
			-- Reached the end of the line processing
			break
		end
	end

	-- Sort the final results primarily by line, then start column, then original parse order.
	table.sort(results, function(a, b)
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		elseif a.start_col ~= b.start_col then
			return a.start_col < b.start_col
		else
			-- Fallback to parse order if start columns are identical.
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
