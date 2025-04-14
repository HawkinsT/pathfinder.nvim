local M = {}

local config = require("pathfinder.config")
local candidates = require("pathfinder.candidates")
local validation = require("pathfinder.validation")
local core = require("pathfinder.core")
local utils = require("pathfinder.utils")

local function set_default_highlight(group, default_opts)
	local ok, current_hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
	if not ok or vim.tbl_isempty(current_hl) then
		vim.api.nvim_set_hl(0, group, default_opts)
	end
end

local function select_file(is_gF)
	local candidate_highlight_group = "PathfinderHighlight"
	local line_nr_highlight_group = "PathfinderNumberHighlight"
	local dim_group = "PathfinderDim"
	local next_key_group = "PathfinderNextKey"
	local future_key_group = "PathfinderFutureKeys"

	set_default_highlight(candidate_highlight_group, { fg = "#DDDDDD", bg = "none" })
	set_default_highlight(dim_group, { fg = "#808080", bg = "none" })
	set_default_highlight(next_key_group, { fg = "#FF00FF", bg = "none" })
	set_default_highlight(future_key_group, { fg = "#BB00AA", bg = "none" })
	set_default_highlight(line_nr_highlight_group, { fg = "#00FF00", bg = "none" })

	local highlight_ns = vim.api.nvim_create_namespace("pathfinder_highlight")
	local dim_ns = vim.api.nvim_create_namespace("pathfinder_dim")
	local current_tabpage = vim.api.nvim_get_current_tabpage()
	local selection_keys = config.config.selection_keys

	local windows_to_check = {}

	if config.config.pick_from_all_windows then
		windows_to_check = vim.api.nvim_tabpage_list_wins(current_tabpage)
	else
		windows_to_check = { vim.api.nvim_get_current_win() }
	end

	local function collect_candidates()
		local all_visible_candidates = {}

		for _, win_id in ipairs(windows_to_check) do
			local buf_nr = vim.api.nvim_win_get_buf(win_id)
			local window_start = vim.fn.line("w0", win_id)
			local window_end = vim.fn.line("w$", win_id)

			-- Shouldn't ever occur but defence against possible edge cases.
			if not window_start or not window_end or window_start <= 0 or window_end < window_start then
				goto continue
			end

			local line_num = window_start
			while line_num <= window_end do
				-- Don't scan folded blocks.
				if vim.fn.foldclosed(line_num) ~= -1 then
					line_num = vim.fn.foldclosedend(line_num) + 1
				else
					local line_text, merged_end_line_num, physical_lines =
						utils.get_merged_line(line_num, window_end, buf_nr)
					local scan_unenclosed_words = config.config.scan_unenclosed_words
					local line_candidates =
						candidates.scan_line(line_text, line_num, 1, scan_unenclosed_words, physical_lines)
					for _, candidate in ipairs(line_candidates) do
						candidate.merged_end_line_num = merged_end_line_num
						candidate.buf_nr = buf_nr
						candidate.win_id = win_id
						table.insert(all_visible_candidates, candidate)
					end
					line_num = merged_end_line_num + 1
				end
			end
			::continue::
		end

		return all_visible_candidates
	end

	local function update_highlights(active_candidates, input_prefix)
		-- Clear previous highlights in all affected buffers
		local seen_buffers = {}
		for _, candidate in ipairs(active_candidates) do
			local buf_nr = candidate.candidate_info.buf_nr
			if not seen_buffers[buf_nr] then
				vim.api.nvim_buf_clear_namespace(buf_nr, highlight_ns, 0, -1)
				vim.api.nvim_buf_clear_namespace(buf_nr, dim_ns, 0, -1)
				seen_buffers[buf_nr] = true
			end
		end

		-- Dim all visible lines in checked windows
		for _, win_id in ipairs(windows_to_check) do
			local buf_nr = vim.api.nvim_win_get_buf(win_id)
			local window_start = vim.fn.line("w0", win_id)
			local window_end = vim.fn.line("w$", win_id)
			for line = window_start, window_end do
				local line_text = vim.fn.getbufline(buf_nr, line)[1] or ""
				vim.api.nvim_buf_set_extmark(buf_nr, dim_ns, line - 1, 0, {
					end_col = #line_text,
					hl_group = dim_group,
					hl_eol = true,
					priority = 10000,
				})
			end
		end

		for _, candidate in ipairs(active_candidates) do
			local ci = candidate.candidate_info
			local display_label = input_prefix and candidate.label:sub(#input_prefix + 1) or candidate.label
			local virt_text = {}
			if #display_label > 0 then
				table.insert(virt_text, { display_label:sub(1, 1), next_key_group })
				if #display_label > 1 then
					table.insert(virt_text, { display_label:sub(2), future_key_group })
				end
			end

			local buf_nr = ci.buf_nr

			-- Highlight all spans of the candidate.
			if ci.file_spans then
				for i, span in ipairs(ci.file_spans) do
					local opts = {
						hl_group = candidate_highlight_group,
						end_col = span.finish_col + 1,
						priority = 10001,
					}
					-- Add virtual text only to the first span.
					if i == 1 and #virt_text > 0 then
						opts.virt_text = virt_text
						opts.virt_text_pos = "overlay"
					end
					vim.api.nvim_buf_set_extmark(buf_nr, highlight_ns, span.lnum - 1, span.start_col, opts)
				end
			end

			if is_gF and ci.line_nr_spans then
				for _, span in ipairs(ci.line_nr_spans) do
					vim.api.nvim_buf_set_extmark(buf_nr, highlight_ns, span.lnum - 1, span.start_col, {
						hl_group = line_nr_highlight_group,
						end_col = span.finish_col + 1,
						priority = 10001,
					})
				end
			end
		end
		vim.cmd("redraw")
	end

	local function assign_labels(candidate_count)
		local function calculate_minimum_label_length(num_candidates)
			local length = 1
			local max_combinations = 0
			while true do
				max_combinations = 1
				for i = 1, length do
					max_combinations = max_combinations * (#selection_keys - i + 1)
				end
				if max_combinations >= num_candidates then
					return length
				end
				length = length + 1
			end
		end

		local label_length = calculate_minimum_label_length(candidate_count)

		local function generate_spread_labels()
			local result = {}
			local index = 1
			for i = 1, candidate_count do
				local label = ""
				local available_keys = vim.deepcopy(selection_keys)

				local first_key_index = ((i - 1) % #available_keys) + 1
				label = label .. available_keys[first_key_index]
				table.remove(available_keys, first_key_index)

				for _ = 2, label_length do
					local next_key = available_keys[((index - 1) % #available_keys) + 1]
					label = label .. next_key
					for j, key in ipairs(available_keys) do
						if key == next_key then
							table.remove(available_keys, j)
							break
						end
					end
					index = index + 1
				end

				table.insert(result, label)
			end
			return result
		end

		return generate_spread_labels()
	end

	local function cancel_selection()
		local seen_buffers = {}
		for _, candidate in ipairs(collect_candidates()) do
			local buf_nr = candidate.buf_nr
			if not seen_buffers[buf_nr] then
				vim.api.nvim_buf_clear_namespace(buf_nr, highlight_ns, 0, -1)
				vim.api.nvim_buf_clear_namespace(buf_nr, dim_ns, 0, -1)
				seen_buffers[buf_nr] = true
			end
		end
	end

	local function process_user_input(active_candidates)
		local labels = assign_labels(#active_candidates)
		for i, candidate in ipairs(active_candidates) do
			candidate.label = labels[i]
		end

		update_highlights(active_candidates, nil)
		local user_input = ""
		local required_length = #labels[1]

		local function get_matching_candidates(input)
			local matches = {}
			for _, candidate in ipairs(active_candidates) do
				if candidate.label:sub(1, #input) == input then
					table.insert(matches, candidate)
				end
			end
			return matches
		end

		while #user_input < required_length do
			local _, key = pcall(vim.fn.getchar)
			local backspace_termcode = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
			local is_backspace = key == 8 or key == 127 or (type(key) == "string" and key == backspace_termcode)
			if is_backspace then
				if #user_input == 0 then
					cancel_selection()
					return
				end
				user_input = user_input:sub(1, -2)
				local matching_candidates = get_matching_candidates(user_input)
				update_highlights(matching_candidates, user_input)
			else
				local key_code = type(key) == "number" and key or string.byte(key)
				local char = vim.fn.nr2char(key_code)

				user_input = user_input .. char
				local matching_candidates = get_matching_candidates(user_input)

				if not vim.tbl_contains(selection_keys, char) or #matching_candidates == 0 then
					cancel_selection()
					-- If the user presses a command key, feed it to Neovim immediately.
					if char == "/" or char == "?" or char == ":" then
						local term_char = vim.api.nvim_replace_termcodes(char, true, false, true)
						vim.api.nvim_feedkeys(term_char, "n", false)
					end
					-- Else just cancel on all other invalid keys.
					break
				elseif #matching_candidates == 1 and #user_input == required_length then
					local seen_buffers = {}
					for _, candidate in ipairs(active_candidates) do
						local buf_nr = candidate.candidate_info.buf_nr
						if not seen_buffers[buf_nr] then
							vim.api.nvim_buf_clear_namespace(buf_nr, highlight_ns, 0, -1)
							vim.api.nvim_buf_clear_namespace(buf_nr, dim_ns, 0, -1)
							seen_buffers[buf_nr] = true
						end
					end
					vim.cmd("redraw")
					vim.schedule(function()
						local selected_candidate = matching_candidates[1]
						vim.api.nvim_set_current_win(selected_candidate.candidate_info.win_id)
						local linenr = selected_candidate.candidate_info.linenr
						core.try_open_file(selected_candidate, is_gF, linenr or 1)
					end)
					break
				elseif #user_input < required_length then
					update_highlights(matching_candidates, user_input)
				end
			end
		end
	end

	local valid_candidates = {}
	local function validate_candidates(index, cand_list)
		if index > #cand_list then
			if #valid_candidates == 0 then
				vim.notify("No valid file candidates found in visible area", vim.log.levels.INFO)
				return
			end
			process_user_input(valid_candidates)
			local seen_buffers = {}
			for _, candidate in ipairs(cand_list) do
				local buf_nr = candidate.buf_nr
				if not seen_buffers[buf_nr] then
					vim.api.nvim_buf_clear_namespace(buf_nr, highlight_ns, 0, -1)
					vim.api.nvim_buf_clear_namespace(buf_nr, dim_ns, 0, -1)
					seen_buffers[buf_nr] = true
				end
			end
			return
		end

		local candidate = cand_list[index]
		validation.default_validate_candidate(candidate.filename, function(open_path)
			if open_path and open_path ~= "" then
				table.insert(valid_candidates, { candidate_info = candidate, open_path = open_path })
			end
			validate_candidates(index + 1, cand_list)
		end, true)
	end

	local cand_list = collect_candidates()
	cand_list = candidates.deduplicate_candidates(cand_list)
	validate_candidates(1, cand_list)
end

function M.select_file_line()
	select_file(true)
end

function M.select_file()
	select_file(false)
end

return M
