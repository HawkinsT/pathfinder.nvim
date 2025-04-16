local M = {}

local vim = vim

local config = require("pathfinder.config")
local candidates = require("pathfinder.candidates")
local validation = require("pathfinder.validation")
local core = require("pathfinder.core")
local utils = require("pathfinder.utils")

local visual_select = require("pathfinder.visual_select")
visual_select.set_default_highlights()

local highlight_ns = vim.api.nvim_create_namespace("pathfinder_highlight")
local dim_ns = vim.api.nvim_create_namespace("pathfinder_dim")

local function highlight_candidate(candidate, input_prefix, ns)
	-- Figure out how much of the label is left to show.
	local leftover = candidate.label:sub(#input_prefix + 1)

	local virt_text = {}
	if #leftover > 0 then
		-- First character -> 'PathfinderNextKey'; rest -> 'PathfinderFutureKeys'.
		table.insert(virt_text, { leftover:sub(1, 1), "PathfinderNextKey" })
		if #leftover > 1 then
			table.insert(virt_text, { leftover:sub(2), "PathfinderFutureKeys" })
		end
	end

	-- For each candidate span, highlight it.
	if candidate.file_spans then
		for i, span in ipairs(candidate.file_spans) do
			local opts = {
				hl_group = "PathfinderHighlight",
				end_col = span.finish_col + 1,
				priority = 10001,
			}
			-- Put virt_text on the first span.
			if i == 1 and #virt_text > 0 then
				opts.virt_text = virt_text
				opts.virt_text_pos = "overlay"
			end
			vim.api.nvim_buf_set_extmark(candidate.buf_nr, ns, span.lnum - 1, span.start_col, opts)
		end
	end

	-- If line numbers exist (for gF), highlight them too.
	if candidate.line_nr_spans then
		for _, span in ipairs(candidate.line_nr_spans) do
			vim.api.nvim_buf_set_extmark(candidate.buf_nr, ns, span.lnum - 1, span.start_col, {
				hl_group = "PathfinderNumberHighlight",
				end_col = span.finish_col + 1,
				priority = 10001,
			})
		end
	end
end

local function select_file(is_gF)
	local windows_to_check = visual_select.get_windows_to_check()
	local selection_keys = config.config.selection_keys

	-- 1. Collect raw candidates across visible lines.
	local function collect_candidates()
		local all_visible_candidates = {}
		for _, win_id in ipairs(windows_to_check) do
			local buf_nr = vim.api.nvim_win_get_buf(win_id)
			local cfg = config.get_config_for_buffer(buf_nr)
			local window_start = vim.fn.line("w0", win_id)
			local window_end = vim.fn.line("w$", win_id)

			if not window_start or not window_end or window_start <= 0 or window_end < window_start then
				goto continue
			end

			local line_num = window_start
			while line_num <= window_end do
				-- Skip folded ranges:
				local is_folded = vim.api.nvim_win_call(win_id, function()
					return vim.fn.foldclosed(line_num)
				end)
				if is_folded ~= -1 then
					line_num = vim.fn.foldclosedend(line_num) + 1
				else
					local line_text, merged_end_line_num, physical_lines =
						utils.get_merged_line(line_num, window_end, buf_nr, win_id)
					local line_candidates =
						candidates.scan_line(line_text, line_num, 1, cfg.scan_unenclosed_words, physical_lines, cfg)
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

	-- 2. Validate each candidate in turn.
	local valid_candidates = {}
	local function validate_candidates(index, cand_list)
		if index > #cand_list then
			if #valid_candidates == 0 then
				vim.notify("No valid file candidates found in visible area", vim.log.levels.INFO)
				visual_select.clear_extmarks(windows_to_check, highlight_ns, dim_ns)
				return
			end

			visual_select.assign_labels(valid_candidates, selection_keys)
			local required_length = #valid_candidates[1].label

			-- 3. Hand off to selection loop.
			visual_select.start_selection_loop(
				valid_candidates,
				selection_keys,
				highlight_ns,
				dim_ns,
				function(cand, input_prefix, ns)
					if not is_gF then
						cand.line_nr_spans = nil
					end
					highlight_candidate(cand, input_prefix, ns)
				end,
				function(selected_candidate)
					-- The user finished typing => open the file
					vim.schedule(function()
						vim.api.nvim_set_current_win(selected_candidate.win_id)
						local linenr = selected_candidate.linenr or 1
						core.try_open_file(selected_candidate, is_gF, linenr)
					end)
				end,
				required_length
			)
			return
		end

		local candidate = cand_list[index]
		validation.default_validate_candidate(candidate.filename, function(open_path)
			if open_path and open_path ~= "" then
				local flat_candidate = vim.deepcopy(candidate)
				flat_candidate.open_path = open_path
				table.insert(valid_candidates, flat_candidate)
			end
			validate_candidates(index + 1, cand_list)
		end, true)
	end

	local raw_candidates = collect_candidates()
	raw_candidates = candidates.deduplicate_candidates(raw_candidates)
	validate_candidates(1, raw_candidates)
end

function M.select_file_line()
	select_file(true)
end

function M.select_file()
	select_file(false)
end

return M
