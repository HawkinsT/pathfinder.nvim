local M = {}

local config = require("pathfinder.config")

function M.deduplicate_candidates(candidates)
	local seen = {}
	local unique = {}
	for _, cand in ipairs(candidates) do
		local key = string.format("%d:%d", cand.lnum, cand.finish)
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

function M.parse_filename_and_linenr(str)
	str = str:match("^%s*(.-)%s*$")

    -- stylua: ignore
    local patterns = {
        { sep = "filename (line)", pattern = "^(.-)%s*%(%s*(%d+)%s*%)%s*$" },
        { sep = "filename:line",   pattern = "^(.-)%s*:%s*(%d+)%s*$" },
        { sep = "filename @ line", pattern = "^(.-)%s*@%s*(%d+)%s*$" },
        { sep = "filename line",   pattern = "^(.-)%s+(%d+)%s*$" },
    }

	for _, p in ipairs(patterns) do
		local filename, linenr_str = str:match(p.pattern)
		if filename and linenr_str then
			return filename, tonumber(linenr_str)
		end
	end

	return str:gsub("[.,:;!]+$", ""), nil
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

function M.gather_line_candidates(line, lnum, min_col)
	local candidates = {}
	local enclosure_pairs = config.config.enclosure_pairs
	local openings = {}

	for opening, _ in pairs(enclosure_pairs) do
		table.insert(openings, opening)
	end
	table.sort(openings, function(a, b)
		return #a > #b
	end)

	local pos = 1
	while pos <= #line do
		local opening_pos, opening = M.find_next_opening(line, pos, openings)
		if not opening_pos then
			break
		end

		local closing = enclosure_pairs[opening]
		local start_index = opening_pos + #opening
		local closing_pos = M.find_closing(line, start_index, closing)

		if closing_pos then
			local candidate_str = line:sub(start_index, closing_pos - 1)
			candidate_str = candidate_str:gsub("\\ ", " ")
			candidate_str = M.strip_nested_enclosures(candidate_str, enclosure_pairs)
			local filename, linenr = M.parse_filename_and_linenr(candidate_str)
			local finish_col = closing_pos + #closing - 1

			if (not min_col) or (finish_col >= min_col) then
				table.insert(candidates, {
					filename = filename,
					linenr = linenr,
					finish = finish_col,
					lnum = lnum,
					start_col = opening_pos,
					type = "enclosures",
					opening_delim = opening,
					closing_delim = closing,
				})
			end
			pos = closing_pos + #closing
		else
			pos = opening_pos + #opening
		end
	end
	return candidates
end

function M.gather_word_candidates(line, lnum, min_col)
	local candidates = {}
	local pos = min_col or 1

	while pos <= #line do
		local start_col, end_col = line:find("%S+", pos)
		if not start_col then
			break
		end

		local candidate_str = line:sub(start_col, end_col)
		pos = end_col + 1

		while candidate_str:sub(-1) == "\\" and pos <= #line and line:sub(pos, pos) == " " do
			candidate_str = candidate_str:sub(1, -2)
			pos = pos + 1
			local next_start, next_end = line:find("%S+", pos)
			if not next_start then
				break
			end
			candidate_str = candidate_str .. " " .. line:sub(next_start, next_end)
			pos = next_end + 1
		end

		local filename, linenr = M.parse_filename_and_linenr(candidate_str)

		if (not min_col) or (end_col >= min_col) then
			table.insert(candidates, {
				filename = filename,
				linenr = linenr,
				finish = pos - 1,
				lnum = lnum,
				start_col = start_col,
				type = "word",
			})
		end
	end

	return candidates
end

function M.filter_overlapping_candidates(enclosure_candidates, word_candidates)
	local filtered = {}
	for _, wc in ipairs(word_candidates) do
		local overlap = false
		for _, ec in ipairs(enclosure_candidates) do
			if not (wc.finish < ec.start_col or wc.start_col > ec.finish) then
				overlap = true
				break
			end
		end
		if not overlap then
			table.insert(filtered, wc)
		end
	end
	return filtered
end

--- Collects and deduplicates file candidates from the buffer.
-- Iterates from the current line to the buffer's end (or until the forward
-- limit is reached) and extracts file candidate information.
function M.collect_forward_candidates(cursor_line, cursor_col)
	local forward_candidates = {}
	local lines_searched = 0
	local buffer_end = vim.fn.line("$")

	for lnum = cursor_line, buffer_end do
		local forward_limit = config.config.forward_limit
		if forward_limit == -1 then
			forward_limit = vim.fn.winheight(0) - vim.fn.winline()
		end
		if forward_limit and lines_searched >= forward_limit then
			break
		end

		local text = vim.fn.getline(lnum)
		local min_col = (lnum == cursor_line) and cursor_col or nil

		local enclosure_candidates = M.gather_line_candidates(text, lnum, min_col)
		local word_candidates = config.config.scan_unenclosed_words and M.gather_word_candidates(text, lnum, min_col)
			or {}

		if #enclosure_candidates > 0 then
			word_candidates = M.filter_overlapping_candidates(enclosure_candidates, word_candidates)
		end

		vim.list_extend(forward_candidates, enclosure_candidates)
		vim.list_extend(forward_candidates, word_candidates)
		lines_searched = lines_searched + 1
	end

	table.sort(forward_candidates, function(a, b)
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		else
			return a.start_col < b.start_col
		end
	end)

	return M.deduplicate_candidates(forward_candidates)
end

return M
