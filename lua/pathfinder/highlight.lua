local M = {}

local config = require("pathfinder.config")
local candidates = require("pathfinder.candidates")
local validation = require("pathfinder.validation")
local core = require("pathfinder.core")

local function set_default_highlight(group, default)
	local ok, current = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
	if not ok or vim.tbl_isempty(current) then
		vim.api.nvim_set_hl(0, group, default)
	end
end

function M.select_file()
	local candidate_highlight_group = "EnhancedGFHighlight"
	local dim_group = "EnhancedGFDim"
	local next_key_group = "EnhancedGFNextKey"
	local future_key_group = "EnhancedGFFutureKeys"

	set_default_highlight(candidate_highlight_group, { fg = "#DDDDDD", bg = "none" })
	set_default_highlight(dim_group, { fg = "#808080", bg = "none" })
	set_default_highlight(next_key_group, { fg = "#FF00FF", bg = "none" })
	set_default_highlight(future_key_group, { fg = "#BB00AA", bg = "none" })

	local highlight_ns = vim.api.nvim_create_namespace("pathfinder-highlight")
	local dim_ns = vim.api.nvim_create_namespace("pathfinder-dim")
	local current_buffer = vim.api.nvim_get_current_buf()
	local window_start = vim.fn.line("w0")
	local window_end = vim.fn.line("w$")
	local selection_keys = config.config.selection_keys

	local function collect_candidates(win_start, win_end)
		local all_candidates = {}
		for line_num = win_start, win_end do
			local line_text = vim.fn.getline(line_num)
			local line_candidates = candidates.gather_line_candidates(line_text, line_num, 1)
			if config.config.scan_unenclosed_words then
				local word_candidates = candidates.gather_word_candidates(line_text, line_num, 1)
				for _, candidate in ipairs(word_candidates) do
					table.insert(line_candidates, candidate)
				end
			end
			for _, candidate in ipairs(line_candidates) do
				table.insert(all_candidates, candidate)
			end
		end
		return all_candidates
	end

	local function update_highlights(active_candidates, input_prefix)
		vim.api.nvim_buf_clear_namespace(current_buffer, highlight_ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(current_buffer, dim_ns, 0, -1)

		for line = window_start, window_end do
			local line_text = vim.fn.getline(line)
			vim.api.nvim_buf_set_extmark(current_buffer, dim_ns, line - 1, 0, {
				end_col = #line_text,
				hl_group = dim_group,
				hl_eol = true,
				priority = 10000,
			})
		end

		for _, candidate in ipairs(active_candidates) do
			local start_col = candidate.candidate_info.start_col - 1
			local finish_col = candidate.candidate_info.finish

			if candidate.candidate_info.type == "enclosures" and candidate.candidate_info.opening_delim then
				start_col = start_col + #candidate.candidate_info.opening_delim
				if candidate.candidate_info.closing_delim then
					finish_col = finish_col - #candidate.candidate_info.closing_delim
				end
			end

			local display_label = input_prefix and candidate.label:sub(#input_prefix + 1) or candidate.label
			local virt_text = {}
			if #display_label > 0 then
				table.insert(virt_text, { display_label:sub(1, 1), next_key_group })
				if #display_label > 1 then
					table.insert(virt_text, { display_label:sub(2), future_key_group })
				end
			end

			vim.api.nvim_buf_set_extmark(current_buffer, highlight_ns, candidate.candidate_info.lnum - 1, start_col, {
				virt_text = virt_text,
				virt_text_pos = "overlay",
				hl_group = candidate_highlight_group,
				end_col = finish_col,
				priority = 10001,
			})
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
		vim.notify("Selection cancelled", vim.log.levels.INFO)
		vim.api.nvim_buf_clear_namespace(current_buffer, highlight_ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(current_buffer, dim_ns, 0, -1)
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
					vim.api.nvim_buf_clear_namespace(current_buffer, highlight_ns, 0, -1)
					vim.api.nvim_buf_clear_namespace(current_buffer, dim_ns, 0, -1)
					vim.cmd("redraw")
					vim.schedule(function()
						core.try_open_file(
							matching_candidates[1],
							false,
							matching_candidates[1].candidate_info.lnenr or 1
						)
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
			vim.api.nvim_buf_clear_namespace(current_buffer, highlight_ns, 0, -1)
			vim.api.nvim_buf_clear_namespace(current_buffer, dim_ns, 0, -1)
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

	local cand_list = collect_candidates(window_start, window_end)
	cand_list = candidates.deduplicate_candidates(cand_list)
	validate_candidates(1, cand_list)
end

return M
