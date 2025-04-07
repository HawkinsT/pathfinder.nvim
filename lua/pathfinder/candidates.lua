local M = {}
local config = require("pathfinder.config")
local utils = require("pathfinder.utils")

function M.deduplicate_candidates(candidates)
	local merged = {}
	for _, cand in ipairs(candidates) do
		-- Group by line number and filename.
		local key = string.format("%d:%s", cand.lnum, cand.filename)
		if not merged[key] then
			merged[key] = { cand }
		else
			local group = merged[key]
			local found = false
			for _, existing in ipairs(group) do
				-- Merge candidates if their start columns are nearly identical.
				if math.abs(cand.start_col - existing.start_col) <= 2 then
					found = true
					-- If overlapping candidate lacks a valid line number and
					-- the other has one, assign it.
					if not existing.linenr and cand.linenr then
						existing.linenr = cand.linenr
						existing.line_nr_spans = cand.line_nr_spans
					end
					-- Update finish and spans if this candidate covers a larger region.
					if cand.finish > existing.finish then
						existing.finish = cand.finish
						existing.spans = cand.spans
					end
					break
				end
			end
			if not found then
				table.insert(group, cand)
			end
		end
	end

	local unique = {}
	for _, group in pairs(merged) do
		for _, cand in ipairs(group) do
			table.insert(unique, cand)
		end
	end

	table.sort(unique, function(a, b)
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		else
			return a.start_col < b.start_col
		end
	end)
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

--stylua: ignore
M.trailing_patterns = {
    { pattern = "^%s*,?%s*line%s+(%d+)" },  -- e.g. ", line 168"
}

function M.parse_trailing_line_number(str)
	for _, pat in ipairs(M.trailing_patterns) do
		local match_s, match_e, line_str = str:find(pat.pattern)
		if match_s then
			return tonumber(line_str), match_e
		end
	end
	return nil, nil
end

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

local function calculate_spans(start, finish, physical_lines, lnum)
	if not physical_lines then
		-- Fallback for non-terminal buffers or missing physical_lines to single span.
		return { { lnum = lnum, start_col = start - 1, finish_col = finish - 1 } }
	end
	local spans = {}
	for _, pl in ipairs(physical_lines) do
		local pl_start = pl.start_pos
		local pl_end = pl.start_pos + pl.length - 1
		if pl_start <= finish and pl_end >= start then
			local span_start = math.max(start, pl_start)
			local span_end = math.min(finish, pl_end)
			-- Convert to 0-based columns for Neovim API.
			local line_start_col = span_start - pl_start
			local line_finish_col = span_end - pl_start
			table.insert(spans, { lnum = pl.lnum, start_col = line_start_col, finish_col = line_finish_col })
		end
	end
	return spans
end

---Processes a single potential filename string.
-- Strips enclosures, calculates positions, parses filename/line, and creates candidate table.
---@param piece string The string segment to process.
---@param lnum number Line number in the buffer.
---@param base_col number The starting column of `piece` in the original line.
---@param min_col number|nil Minimum column to include candidates from.
---@param escaped_space_count number Number of escaped spaces replaced.
---@return table|nil A candidate table or nil if invalid/before min_col.
local function create_candidate_from_piece(piece, lnum, base_col, min_col, escaped_space_count, physical_lines)
	local piece_leading_ws = piece:match("^(%s*)") or ""
	local trimmed_piece = vim.trim(piece)
	if trimmed_piece == "" then
		return nil
	end

	local inner_str, removed_start_len = strip_nested_enclosures(trimmed_piece, config.config.enclosure_pairs)
	local content_start_offset = inner_str:find("%S") or 1
	local content_end_offset = #inner_str - #((inner_str:match("%s*$")) or "")
	local filename_str = inner_str:sub(content_start_offset, content_end_offset)
	if filename_str == "" then
		return nil
	end

	local cand_start_col = base_col + #piece_leading_ws + removed_start_len + (content_start_offset - 1)
	local filename_length = content_end_offset - content_start_offset + 1
	local cand_finish_col = cand_start_col + filename_length + escaped_space_count

	if not min_col or cand_finish_col >= min_col then
		local filename, linenr = M.parse_filename_and_linenr(filename_str)
		if filename and filename ~= "" then
			local candidate = {
				filename = filename,
				lnum = lnum,
				start_col = cand_start_col,
				finish = cand_finish_col,
				linenr = linenr,
				escaped_space_count = escaped_space_count,
			}
			candidate.spans = calculate_spans(cand_start_col, cand_finish_col - 1, physical_lines, lnum)
			local file_sub_start = filename_str:find(filename, 1, true)
			if file_sub_start then
				local file_col_start = cand_start_col + file_sub_start - 1
				local file_col_end = file_col_start + #filename - 1 + escaped_space_count
				candidate.file_spans = calculate_spans(file_col_start, file_col_end, physical_lines, lnum)
			end
			if linenr then
				local linenr_str = tostring(linenr)
				local ln_sub_start = filename_str:find(linenr_str, 1, true)
				if ln_sub_start then
					local ln_col_start = cand_start_col + ln_sub_start - 1
					local ln_col_end = ln_col_start + #linenr_str - 1
					candidate.line_nr_spans = calculate_spans(ln_col_start, ln_col_end, physical_lines, lnum)
				end
			end
			return candidate
		end
	end
	return nil
end

--- Processes a raw string which might contain multiple comma/semicolon/pipe-separated filenames.
---@param raw_str string The raw string (e.g. "'file1.txt', 'file2'").
---@param lnum number The line number in the buffer.
---@param start_col number The starting column of `raw_str` in the original line.
---@param min_col number|nil Minimum column to include candidates from.
---@param base_offset number|nil Optional offset adjustment (e.g., if `raw_str` is from inside delimiters).
---@param escaped_space_count number|nil Number of escaped spaces replaced.
---@return table List of candidate tables.
local function process_candidate_string(
	raw_str,
	lnum,
	start_col,
	min_col,
	base_offset,
	escaped_space_count,
	physical_lines
)
	local results = {}
	local base = base_offset or start_col
	escaped_space_count = escaped_space_count or 0

	local search_pos = 1
	local found_separator = false
	while true do
		local match_start, match_end = raw_str:find("([^,;|]+)", search_pos)
		if not match_start then
			break
		end
		found_separator = true
		local piece = raw_str:sub(match_start, match_end)
		local piece_start_col = base + (match_start - 1)
		local candidate =
			create_candidate_from_piece(piece, lnum, piece_start_col, min_col, escaped_space_count, physical_lines)
		if candidate then
			table.insert(results, candidate)
		end
		search_pos = match_end + 1
	end

	if not found_separator and search_pos == 1 then
		local candidate = create_candidate_from_piece(raw_str, lnum, base, min_col, escaped_space_count, physical_lines)
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
local function process_word_segment(word_str, lnum, word_start_col, min_col, results, current_order, physical_lines)
	local candidates = process_candidate_string(word_str, lnum, word_start_col, min_col, nil, 0, physical_lines)
	for _, cand in ipairs(candidates) do
		current_order = current_order + 1
		cand.order = current_order
		table.insert(results, cand)
	end
	return current_order
end

-- Parses words within a specific segment of a line (e.g. between delimiters or outside them).
-- It first looks for structured patterns (like file:line) and then treats remaining text as words.
local function parse_words_in_segment(line, start_pos, end_pos, lnum, min_col, results, current_order, physical_lines)
	if start_pos > end_pos then
		return current_order
	end
	local segment = line:sub(start_pos, end_pos)
	local structured_matches = {}

	for _, pat in ipairs(M.patterns) do
		local search_offset = 1
		while search_offset <= #segment do
			local match_s, match_e, filename, linenr_str = segment:find(pat.pattern, search_offset)
			if not match_s then
				break
			end
			local abs_start_col = start_pos + match_s - 1
			local abs_finish_col = start_pos + match_e - 1
			if not min_col or abs_finish_col >= min_col then
				if filename and filename ~= "" and linenr_str then
					local matched_text = segment:sub(match_s, match_e)
					local match_item = {
						filename = filename,
						lnum = lnum,
						start_col = abs_start_col,
						finish = abs_finish_col,
						linenr = tonumber(linenr_str),
					}
					local file_sub_start = matched_text:find(filename, 1, true)
					if file_sub_start then
						local file_col_start = abs_start_col + file_sub_start - 1
						local file_col_end = file_col_start + #filename - 1
						match_item.file_spans = calculate_spans(file_col_start, file_col_end, physical_lines, lnum)
					end
					if linenr_str then
						local ln_sub_start = matched_text:find(linenr_str, 1, true)
						if ln_sub_start then
							local ln_col_start = abs_start_col + ln_sub_start - 1
							local ln_col_end = ln_col_start + #linenr_str - 1
							match_item.line_nr_spans = calculate_spans(ln_col_start, ln_col_end, physical_lines, lnum)
						end
					end
					table.insert(structured_matches, match_item)
				end
			end
			search_offset = match_e + 1
		end
	end

	table.sort(structured_matches, function(a, b)
		return a.start_col < b.start_col
	end)

	local current_parse_pos = start_pos
	for _, match in ipairs(structured_matches) do
		if current_parse_pos < match.start_col then
			local word_search_start = current_parse_pos
			while word_search_start < match.start_col do
				local word_s, word_e = line:find("%S+", word_search_start)
				if not word_s or word_s >= match.start_col then
					break
				end
				local word_finish_col = math.min(word_e, match.start_col - 1)
				local word_str = line:sub(word_s, word_finish_col)
				current_order =
					process_word_segment(word_str, lnum, word_s, min_col, results, current_order, physical_lines)
				word_search_start = word_finish_col + 1
			end
		end

		current_order = current_order + 1
		match.order = current_order
		match.spans = calculate_spans(match.start_col, match.finish - 1, physical_lines, lnum)
		table.insert(results, match)

		current_parse_pos = match.finish + 1
	end

	local word_search_start = current_parse_pos
	while word_search_start <= end_pos do
		local word_s, word_e = line:find("%S+", word_search_start)
		if not word_s or word_s > end_pos then
			break
		end
		local word_finish_col = math.min(word_e, end_pos)
		local word_str = line:sub(word_s, word_finish_col)
		current_order = process_word_segment(word_str, lnum, word_s, min_col, results, current_order, physical_lines)
		word_search_start = word_finish_col + 1
	end

	return current_order
end

function M.scan_line(line, lnum, min_col, scan_unenclosed_words, physical_lines)
	local results = {}
	local order = 0

	-- 1. Match structured patterns across the entire line.
	for _, pat in ipairs(M.patterns) do
		local search_offset = 1
		while search_offset <= #line do
			local match_s, match_e, filename, linenr_str = line:find(pat.pattern, search_offset)
			if not match_s then
				break
			end
			local abs_start_col = match_s
			local abs_finish_col = match_e
			if not min_col or abs_finish_col >= min_col then
				if filename and filename ~= "" and linenr_str then
					local candidate = {
						filename = filename,
						lnum = lnum,
						start_col = abs_start_col,
						finish = abs_finish_col,
						linenr = tonumber(linenr_str),
						order = order + 1,
						type = "structured",
					}
					-- Calculate spans for the entire match:
					candidate.spans = calculate_spans(abs_start_col, abs_finish_col - 1, physical_lines, lnum)
					-- File spans:
					local matched_text = line:sub(match_s, match_e)
					local file_start = matched_text:find(filename, 1, true)
					if file_start then
						local file_col_start = abs_start_col + file_start - 1
						local file_col_end = file_col_start + #filename - 1
						candidate.file_spans = calculate_spans(file_col_start, file_col_end, physical_lines, lnum)
					end

					-- Line number spans:
					local ln_start = matched_text:find(linenr_str, 1, true)
					if ln_start then
						local ln_col_start = abs_start_col + ln_start - 1
						local ln_col_end = ln_col_start + #linenr_str - 1
						candidate.line_nr_spans = calculate_spans(ln_col_start, ln_col_end, physical_lines, lnum)
					end
					table.insert(results, candidate)
					order = order + 1
				end
			end
			search_offset = match_e + 1
		end
	end

	-- 2: Process remaining text with enclosures, skipping already matched regions.
	local pos = 1
	local enclosure_pairs = config.config.enclosure_pairs
	local openings = config.config._cached_openings or {}

	while pos <= #line do
		local is_matched = false
		for _, res in ipairs(results) do
			if pos >= res.start_col and pos <= res.finish then
				pos = res.finish + 1
				is_matched = true
				break
			end
		end
		if is_matched then
			goto continue
		end

		local open_pos, opening = find_next_opening(line, pos, openings)
		if open_pos then
			if scan_unenclosed_words and (open_pos > pos) then
				order = parse_words_in_segment(line, pos, open_pos - 1, lnum, min_col, results, order, physical_lines)
			end
			local closing = enclosure_pairs[opening]
			local content_start_pos = open_pos + #opening
			local close_pos = find_closing(line, content_start_pos, closing)
			if close_pos then
				local enclosed_str = line:sub(content_start_pos, close_pos - 1)
				local escaped_space_count = 0
				if enclosed_str:find("\\ ", 1, true) then
					enclosed_str = enclosed_str:gsub("\\ ", function()
						escaped_space_count = escaped_space_count + 1
						return " "
					end)
				end
				local candidates_in_enclosure = process_candidate_string(
					enclosed_str,
					lnum,
					open_pos,
					min_col,
					content_start_pos,
					escaped_space_count,
					physical_lines
				)
				for _, cand in ipairs(candidates_in_enclosure) do
					order = order + 1
					cand.order = order
					cand.type = "enclosures"
					cand.spans = calculate_spans(cand.start_col, cand.finish - 1, physical_lines, lnum)
					table.insert(results, cand)
				end

				-- Handle trailing line numbers.
				local trailing_text = line:sub(close_pos + #closing)
				local line_number, consumed = M.parse_trailing_line_number(trailing_text)
				if line_number then
					for _, cand in ipairs(candidates_in_enclosure) do
						cand.linenr = line_number
						local tmatch_s = trailing_text:find("%d+")
						if tmatch_s then
							local abs_ln_start = close_pos + #closing + tmatch_s - 1
							local abs_ln_end = abs_ln_start + #tostring(line_number) - 1
							cand.line_nr_spans = calculate_spans(abs_ln_start, abs_ln_end, physical_lines, lnum)
						end
					end
					pos = close_pos + #closing + (consumed or 0)
				else
					pos = close_pos + #closing
				end
			else
				pos = open_pos + #opening
			end
		else
			-- No more opening delimiters found on the rest of the line.
			-- If scanning unenclosed words, parse the remaining part of the line.
			if scan_unenclosed_words then
				order = parse_words_in_segment(line, pos, #line, lnum, min_col, results, order, physical_lines)
			end
			break
		end
		::continue::
	end

	-- Sort the final results primarily by line, then start column, then original parse order.
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

		local line_text, merged_end, physical_lines = utils.get_merged_line(lnum, buffer_end)
		local min_col = (lnum == cursor_line) and cursor_col or nil
		local scan_unenclosed_words = config.config.scan_unenclosed_words
		local line_candidates = M.scan_line(line_text, lnum, min_col, scan_unenclosed_words, physical_lines)
		vim.list_extend(forward_candidates, line_candidates)
		lines_searched = lines_searched + 1
		lnum = merged_end + 1 -- Advance lnum to the next line after the merged block.
	end

	return M.deduplicate_candidates(forward_candidates)
end

return M
