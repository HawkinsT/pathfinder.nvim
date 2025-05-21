local M = {}

local vim = vim

local config = require("pathfinder.config")
local utils = require("pathfinder.utils")

local patterns = {
	{ pattern = "(%S-)%s*[%s,:@%(]%s*(%d+)%s*[,:]?%s*(%d*)" },
	{ pattern = "(%S-)%s*[,:@%(]?%s*line%s*(%d+)[,:]?%s*column%s*(%d*)" },
	{ pattern = "(%S-)%s*[,:@%(]?%s*line%s*(%d+)" },
	{ pattern = "(%S-)%s*[,:@%(]?%s*on%s*line%s*(%d+)[,:]?%s*column%s*(%d*)" },
	{ pattern = "(%S-)%s*[,:@%(]?%s*on%s*line%s*(%d+)" },
}

local trailing_patterns = {
	{ pattern = "^,?%s*line%s+(%d+)[,:]?%s*column%s*(%d*)" }, -- e.g. ", line 168, column 10"
	{ pattern = "^,?%s*line%s+(%d+)" }, -- e.g. ", line 168"
}

-- If URI, convert to normal file path.
local function normalize_filename(fname)
	local ok, local_path = pcall(vim.uri_to_fname, fname)
	if ok then
		return local_path
	end
	return fname
end

-- Merge duplicate candidates by same file and line.
function M.deduplicate_candidates(candidates)
	-- Try to merge candidate into an existing group entry; return true on merge.
	local function merge_into(group, cand)
		for _, existing in ipairs(group) do
			if math.abs(cand.start_col - existing.start_col) <= 2 then
				-- Fill in missing line/column metadata if available.
				if not existing.linenr and cand.linenr then
					existing.linenr = cand.linenr
					existing.line_nr_spans = cand.line_nr_spans
				end
				if not existing.colnr and cand.colnr then
					existing.colnr = cand.colnr
					existing.col_nr_spans = cand.col_nr_spans
				end
				-- Extend finish/spans if this candidate covers a larger region.
				if cand.finish > existing.finish then
					existing.finish = cand.finish
					existing.spans = cand.spans
				end
				return true
			end
		end
		return false
	end

	-- Group by line number and filename, merging as we go.
	local merged = {}
	for _, cand in ipairs(candidates) do
		local key = string.format("%d:%s", cand.lnum, cand.filename)
		local group = merged[key]
		if not group then
			merged[key] = { cand }
		elseif not merge_into(group, cand) then
			group[#group + 1] = cand
		end
	end

	-- Flatten groups into unique list.
	local unique = {}
	for _, group in pairs(merged) do
		for _, cand in ipairs(group) do
			unique[#unique + 1] = cand
		end
	end

	-- Sort by line then column.
	table.sort(unique, function(a, b)
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		end
		return a.start_col < b.start_col
	end)

	return unique
end

-- Remove matching nested delimiters, e.g. [[foo]], returning trimmed text and
-- offset due to stripped starting characters.
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

-- Parse ", line X, column Y" patterns after an enclosure, returning numeric
-- line, column, and consumed length.
local function parse_trailing_line_col_number(str)
	for _, pat in ipairs(trailing_patterns) do
		local match_s, match_e, line_str, column_str = str:find(pat.pattern)
		if match_s then
			return tonumber(line_str), tonumber(column_str), match_e
		end
	end
	return nil, nil
end

-- Extract filename, line, and column from string, stripping escaped spaces and
-- trailing punctuation.
function M.parse_filename_and_position(str)
	-- Unescape escaped spaces.
	str = str:gsub("\\ ", " ")

	for _, pat in ipairs(patterns) do
		local filename, linenr_str, colnr_str = str:match(pat.pattern)
		if filename and linenr_str then
			-- Clean up trailing punctuation.
			filename = vim.trim(filename):gsub("[.,:;!]+$", "")
			local ln = tonumber(linenr_str)
			local col = (colnr_str ~= "") and tonumber(colnr_str) or nil
			return filename, ln, col
		end
	end
	-- If no match, return the trimmed string; don't return line/column number.
	local cleaned = str:gsub("[.,:;!]+$", "")
	return vim.trim(cleaned), nil, nil
end

-- Find the next opening delimiter in a line from given starting position.
local function find_next_opening(line, start_pos, openings)
	for pos = start_pos, #line do
		for _, opening in ipairs(openings) do
			local opening_len = #opening
			if
				pos + opening_len - 1 <= #line
				and line:sub(pos, pos + opening_len - 1) == opening
			then
				return pos, opening
			end
		end
	end
	return nil, nil
end

-- Find closing delimiter matching opener from given starting position.
local function find_closing(line, start_pos, closing)
	local closing_len = #closing
	for pos = start_pos, #line - closing_len + 1 do
		if line:sub(pos, pos + closing_len - 1) == closing then
			return pos
		end
	end
	return nil
end

-- Convert absolute start/finish into per-physical-line spans (for
-- wrapped/soft-wrapped lines).
local function calculate_spans(start, finish, phys_lines, lnum)
	if not phys_lines then
		-- Fallback for non-terminal buffers or missing phys_lines to single span.
		return {
			{ lnum = lnum, start_col = start - 1, finish_col = finish - 1 },
		}
	end
	local spans = {}
	for _, pl in ipairs(phys_lines) do
		local pl_start = pl.start_pos
		local pl_end = pl.start_pos + pl.length - 1
		if pl_start <= finish and pl_end >= start then
			local span_start = math.max(start, pl_start)
			local span_end = math.min(finish, pl_end)
			-- Convert to 0-based columns for Neovim API.
			local line_start_col = span_start - pl_start
			local line_finish_col = span_end - pl_start
			spans[#spans + 1] = {
				lnum = pl.lnum,
				start_col = line_start_col,
				finish_col = line_finish_col,
			}
		end
	end
	return spans
end

-- Processes a single potential filename string.
-- Strips enclosures, calculates positions, parses filename/line/column, and
-- creates candidate table.
local function create_candidate_from_piece(
	piece,
	lnum,
	base_col,
	min_col,
	escaped_space_count,
	phys_lines,
	cfg
)
	local piece_leading_ws = piece:match("^(%s*)") or ""
	local trimmed_piece = vim.trim(piece)
	if trimmed_piece == "" then
		return nil
	end

	local inner_str, removed_start_len =
		strip_nested_enclosures(trimmed_piece, cfg.enclosure_pairs)
	local content_start_offset = inner_str:find("%S") or 1
	local content_end_offset = #inner_str - #((inner_str:match("%s*$")) or "")
	local filename_str = inner_str:sub(content_start_offset, content_end_offset)
	if filename_str == "" then
		return nil
	end

	local cand_start_col = base_col
		+ #piece_leading_ws
		+ removed_start_len
		+ (content_start_offset - 1)
	local filename_length = content_end_offset - content_start_offset + 1
	local cand_finish_col = cand_start_col
		+ filename_length
		+ escaped_space_count

	if not min_col or cand_finish_col >= min_col then
		local filename, linenr, colnr =
			M.parse_filename_and_position(filename_str)
		if filename and filename ~= "" then
			local candidate = {
				filename = normalize_filename(filename),
				lnum = lnum,
				start_col = cand_start_col,
				finish = cand_finish_col,
				linenr = linenr,
				colnr = colnr,
				escaped_space_count = escaped_space_count,
			}
			candidate.spans = calculate_spans(
				cand_start_col,
				cand_finish_col - 1,
				phys_lines,
				lnum
			)
			local file_sub_start = filename_str:find(filename, 1, true)
			if file_sub_start then
				local file_col_start = cand_start_col + file_sub_start - 1
				local file_col_end = file_col_start
					+ #filename
					- 1
					+ escaped_space_count
				candidate.target_spans = calculate_spans(
					file_col_start,
					file_col_end,
					phys_lines,
					lnum
				)
			end
			if linenr then
				local linenr_str = tostring(linenr)
				local ln_sub_start = filename_str:find(linenr_str, 1, true)
				if ln_sub_start then
					local ln_col_start = cand_start_col + ln_sub_start - 1
					local ln_col_end = ln_col_start + #linenr_str - 1
					candidate.line_nr_spans = calculate_spans(
						ln_col_start,
						ln_col_end,
						phys_lines,
						lnum
					)
				end
			end
			if colnr then
				local cstr = tostring(colnr)
				local idx = filename_str:find(":" .. cstr, 1, true)
					or filename_str:find(cstr, 1, true)
				if idx then
					local abs_s = cand_start_col + idx - 1
					local abs_e = abs_s + #cstr - 1
					candidate.col_nr_spans =
						calculate_spans(abs_s, abs_e, phys_lines, lnum)
				end
			end
			return candidate
		end
	end
	return nil
end

-- Processes a raw string which might contain multiple
-- comma/semicolon/pipe-separated filenames.
local function process_candidate_string(
	raw_str,
	lnum,
	start_col,
	min_col,
	base_offset,
	escaped_space_count,
	phys_lines,
	cfg
)
	local results = {}
	base_offset = base_offset or start_col
	escaped_space_count = escaped_space_count or 0

	-- Build separator info.
	local seps = ",;|"
	local sep_class = "[" .. seps .. "]"
	local sep_pattern = "([^" .. seps .. "]+)"
	local anchor_pattern = "()" .. sep_pattern

	-- Fast-path if no separators.
	if not string.find(raw_str, sep_class) then
		local candidate = create_candidate_from_piece(
			raw_str,
			lnum,
			base_offset,
			min_col,
			escaped_space_count,
			phys_lines,
			cfg
		)
		if candidate then
			results[#results + 1] = candidate
		end
		return results
	end

	-- Split and get start positions.
	for match_start, piece in string.gmatch(raw_str, anchor_pattern) do
		local piece_start_col = base_offset + (match_start - 1)
		local candidate = create_candidate_from_piece(
			piece,
			lnum,
			piece_start_col,
			min_col,
			escaped_space_count,
			phys_lines,
			cfg
		)
		if candidate then
			results[#results + 1] = candidate
		end
	end

	return results
end

-- Processes a single word, adds candidates to results, and updates order.
local function process_word_segment(
	word_str,
	lnum,
	word_start_col,
	min_col,
	results,
	current_order,
	phys_lines,
	cfg
)
	local candidates = process_candidate_string(
		word_str,
		lnum,
		word_start_col,
		min_col,
		nil,
		0,
		phys_lines,
		cfg
	)
	for _, cand in ipairs(candidates) do
		current_order = current_order + 1
		cand.order = current_order
		results[#results + 1] = cand
	end
	return current_order
end

--- Build a structured-match result and highlight exact subspans (filename,
--- line, column).
---@param line string full original line
---@param s_abs number absolute start col (1-based)
---@param e_abs number absolute end col (1-based inclusive)
---@param lnum number logical line number
---@param filename string matched filename
---@param linenr_str string matched line digits
---@param colnr_str string matched column digits
---@param phys_lines table physical-lines for span calc
local function build_match(
	line,
	s_abs,
	e_abs,
	lnum,
	filename,
	linenr_str,
	colnr_str,
	phys_lines
)
	local match = {
		filename = normalize_filename(filename),
		lnum = lnum,
		start_col = s_abs,
		finish = e_abs,
		linenr = tonumber(linenr_str),
		colnr = tonumber(colnr_str),
	}

	match.spans = calculate_spans(s_abs, e_abs - 1, phys_lines, lnum)

	local slice = line:sub(s_abs, e_abs)

	-- Filename highlight.
	do
		local rel = slice:find(filename, 1, true)
		if rel then
			local cs = s_abs + rel - 1
			match.target_spans =
				calculate_spans(cs, cs + #filename - 1, phys_lines, lnum)
		end
	end

	-- Line number highlight.
	if linenr_str and linenr_str ~= "" then
		local rel = slice:find(linenr_str, 1, true)
		if rel then
			local cs = s_abs + rel - 1
			match.line_nr_spans =
				calculate_spans(cs, cs + #linenr_str - 1, phys_lines, lnum)
		end
	end

	-- Column number highlight.
	if colnr_str and colnr_str ~= "" then
		local rel = slice:find(colnr_str, 1, true)
		if rel then
			local cs = s_abs + rel - 1
			match.col_nr_spans =
				calculate_spans(cs, cs + #colnr_str - 1, phys_lines, lnum)
		end
	end

	return match
end

-- Scan the substring from start_pos to end_pos for explicit
-- filename-line-column patterns, turn each into a structured match entry, and
-- return them (in order) along with the updated order counter.
local function collect_structured_matches(
	line,
	start_pos,
	end_pos,
	lnum,
	min_col,
	phys_lines,
	order
)
	-- Quick bail if no numbers (no chance of filename:line patterns).
	if not line:sub(start_pos, end_pos):find("%d") then
		return {}, order
	end

	local out = {}
	for _, pat in ipairs(patterns) do
		local off = start_pos
		while off <= end_pos do
			local s, e, fn, ln_str, col_str = line:find(pat.pattern, off)
			if not s or s > end_pos then
				break
			end
			if (not min_col or e >= min_col) and fn ~= "" and ln_str then
				order = order + 1
				local m = build_match(
					line,
					s,
					e,
					lnum,
					fn,
					ln_str,
					col_str,
					phys_lines
				)
				m.order = order
				out[#out + 1] = m
			end
			off = (e > off) and (e + 1) or (off + 1)
		end
	end
	table.sort(out, function(a, b)
		return a.start_col < b.start_col
	end)
	return out, order
end

-- Walk the plain-text region [seg_start, seg_end], split it into standalone
-- words, and for each word invoke `process_word_segment` so any
-- file/line/column candidates get extracted and ordered.
local function collect_free_words(
	line,
	seg_start,
	seg_end,
	lnum,
	min_col,
	phys_lines,
	cfg,
	results,
	order
)
	local pos = seg_start
	while pos <= seg_end do
		local ws, we = line:find("%S+", pos)
		if not ws or ws > seg_end then
			break
		end
		local finish = math.min(we, seg_end)
		if not min_col or finish >= min_col then
			order = process_word_segment(
				line:sub(ws, finish),
				lnum,
				ws,
				min_col,
				results,
				order,
				phys_lines,
				cfg
			)
		end
		pos = finish + 1
	end
	return order
end

function M.scan_line(line, lnum, min_col, scan_words, phys_lines, cfg)
	cfg = cfg or config.config
	local results = {}
	local order = 0
	local len = #line
	local openings = cfg._cached_openings or {}
	local enclosure_of = cfg.enclosure_pairs

	-- Whole-line structured matches.
	if scan_words then
		local struct_matches
		struct_matches, order = collect_structured_matches(
			line,
			1,
			len,
			lnum,
			min_col,
			phys_lines,
			order
		)
		vim.list_extend(results, struct_matches)
	end

	-- Scan line left-to-right, respecting enclosures.
	local pos = 1
	while pos <= len do
		-- Skip any already‐matched chunks.
		local skipped = false
		for _, m in ipairs(results) do
			if pos >= m.start_col and pos <= m.finish then
				pos = m.finish + 1
				skipped = true
				break
			end
		end

		if not skipped then
			-- Try to find the next opening delimiter.
			local open_pos, opener = find_next_opening(line, pos, openings)
			if not open_pos then
				-- If no more delimiters, finish by harvesting unenclosed words.
				if scan_words then
					order = collect_free_words(
						line,
						pos,
						len,
						lnum,
						min_col,
						phys_lines,
						cfg,
						results,
						order
					)
				end
				break
			end

			-- Harvest any unenclosed word segment before that opening.
			if scan_words and open_pos > pos then
				order = collect_free_words(
					line,
					pos,
					open_pos - 1,
					lnum,
					min_col,
					phys_lines,
					cfg,
					results,
					order
				)
			end

			-- Find matching closer.
			local closer = enclosure_of[opener]
			local content_start = open_pos + #opener
			local close_pos = find_closing(line, content_start, closer)
			if not close_pos then
				-- Skip unmatched open enclosure.
				pos = content_start
			else
				-- Process enclosed content.
				local enclosed = line:sub(content_start, close_pos - 1)
				local esc_spaces = 0
				if enclosed:find("\\ ", 1, true) then
					enclosed = enclosed:gsub("\\ ", function()
						esc_spaces = esc_spaces + 1
						return " "
					end)
				end

				local cand = process_candidate_string(
					enclosed,
					lnum,
					open_pos,
					min_col,
					content_start,
					esc_spaces,
					phys_lines,
					cfg
				)
				for _, c in ipairs(cand) do
					order = order + 1
					c.order = order
					c.type = "enclosures"
					c.spans = calculate_spans(
						c.start_col,
						c.finish - 1,
						phys_lines,
						lnum
					)
					results[#results + 1] = c
				end

				-- Handle trailing line/column after enclosure.
				local tail = line:sub(close_pos + #closer)
				local ln, col, consumed = parse_trailing_line_col_number(tail)
				if ln then
					local ln_s, ln_e = tail:find("(%d+)")
					for _, c in ipairs(cand) do
						c.linenr = ln
						c.colnr = col
						if ln_s and ln_e then
							local abs_s = close_pos + #closer + ln_s - 1
							local abs_e = close_pos + #closer + ln_e - 1
							c.line_nr_spans =
								calculate_spans(abs_s, abs_e, phys_lines, lnum)
						end
						if col then
							local cs, ce = tail:find("(%d+)", (ln_e or 0) + 1)
							if cs and ce then
								local s_abs = close_pos + #closer + cs - 1
								local e_abs = close_pos + #closer + ce - 1
								c.col_nr_spans = calculate_spans(
									s_abs,
									e_abs,
									phys_lines,
									lnum
								)
							end
						end
					end
					pos = close_pos + #closer + consumed
				else
					pos = close_pos + #closer
				end
			end
		end
	end

	-- Final ordering.
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

-- Process and collect scan_fn results.
local function collect(
	buf_nr,
	win_id,
	scan_fn,
	text,
	line,
	phys_lines,
	collected
)
	local candidates = scan_fn(text, line, phys_lines)
	for _, cand in ipairs(candidates) do
		cand.buf_nr = buf_nr
		cand.win_id = win_id
		collected[#collected + 1] = cand
	end
end

local function get_fold_ranges(win_id, start_line, end_line)
	return vim.api.nvim_win_call(win_id, function()
		local ranges = {}
		local l = start_line
		while l <= end_line do
			local fc = vim.fn.foldclosed(l)
			if fc ~= -1 then
				local fe = vim.fn.foldclosedend(l)
				ranges[#ranges + 1] = { start = fc, finish = fe }
				l = fe + 1
			else
				l = l + 1
			end
		end
		return ranges
	end)
end

function M.collect_candidates_in_range(
	buf_nr,
	win_id,
	start_line,
	end_line,
	scan_fn,
	skip_fold
)
	local collected = {}

	-- Process a single logical line (merge hard wraps if terminal buffer).
	local function process_chunk(line)
		local text, new_end, phys_lines =
			utils.get_merged_line(line, end_line, buf_nr, win_id)
		collect(buf_nr, win_id, scan_fn, text, line, phys_lines, collected)
		return new_end + 1
	end

	-- Don't skip folded ranges.
	local function run_flat()
		local line = start_line
		while line <= end_line do
			line = process_chunk(line)
		end
	end

	-- Skip folded ranges.
	local function run_skip_folds()
		local fold_ranges = get_fold_ranges(win_id, start_line, end_line)
		table.sort(fold_ranges, function(a, b)
			return a.start < b.start
		end)

		local idx, line = 1, start_line
		while line <= end_line do
			local rng = fold_ranges[idx]
			if rng and line >= rng.start and line <= rng.finish then
				line = rng.finish + 1
				idx = idx + 1
			else
				line = process_chunk(line)
			end
		end
	end

	if skip_fold and win_id and vim.api.nvim_win_is_valid(win_id) then
		run_skip_folds()
	else
		run_flat()
	end

	return collected
end

return M
