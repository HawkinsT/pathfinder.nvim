local M = {}

local vim = vim
local api = vim.api
local fn = vim.fn

local candidates = require("pathfinder.candidates")
local config = require("pathfinder.config")
local core = require("pathfinder.core")
local notify = require("pathfinder.notify")
local picker = require("pathfinder.picker")
local url = require("pathfinder.url")
local utils = require("pathfinder.utils")
local visual_select = require("pathfinder.visual_select")

local function tmux_display(target, fmt)
	local out =
		fn.systemlist({ "tmux", "display-message", "-p", "-t", target, fmt })
	if vim.v.shell_error ~= 0 or not out or not out[1] then
		return nil
	end
	return vim.trim(out[1])
end

-- Get the last accessed (i.e. not Neovim) tmux pane and its cwd.
local function get_last_pane()
	local target = tmux_display("!", "#{pane_id}")
	if not target or target == "" or target == vim.env.TMUX_PANE then
		return nil, nil
	end
	local cwd = tmux_display(target, "#{pane_current_path}")
	if cwd == "" then
		cwd = nil
	end
	return target, cwd
end

local function capture_and_prepare_tmux_content(pane_id)
	local scroll_pos = tonumber(tmux_display(pane_id, "#{scroll_position}"))
		or 0
	local tmux_pane_height = tonumber(tmux_display(pane_id, "#{pane_height}"))

	local neovim_height = vim.o.lines

	-- Capture enough lines above the visible region so the total height
	-- matches the Neovim window when the tmux pane is shorter.
	local extra_lines_needed = math.max(0, neovim_height - tmux_pane_height)

	-- Start from the bottom visible line and work upwards.
	local start_pos = -(scroll_pos + extra_lines_needed)
	local end_pos = -(scroll_pos - tmux_pane_height + 1)

	local captured = fn.systemlist({
		"tmux",
		"capture-pane",
		"-pJ",
		"-S",
		tostring(start_pos),
		"-E",
		tostring(end_pos),
		"-t",
		pane_id,
	})

	if vim.v.shell_error ~= 0 then
		return nil
	end

	if not captured or #captured == 0 then
		return nil, true
	end

	local non_empty = false
	for _, line in ipairs(captured) do
		if line ~= "" then
			non_empty = true
			break
		end
	end
	if not non_empty then
		return nil, true
	end

	local esc = string.char(27)
	for i, line in ipairs(captured) do
		captured[i] = line:gsub(esc .. "%[[%d;]*[ -/]*[@-~]", "")
	end

	return captured, false
end

local function create_hidden_buffer_with_content(content)
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "delete"
	vim.bo[buf].buflisted = false
	api.nvim_buf_set_lines(buf, 0, -1, false, content)
	return buf
end

local function create_picker_window(buf_id)
	local user_cmdheight = vim.o.cmdheight
	vim.o.cmdheight = 0

	local win = api.nvim_open_win(buf_id, true, {
		relative = "editor",
		row = 0,
		col = 0,
		width = vim.o.columns,
		height = vim.o.lines,
		style = "minimal",
		border = "none",
		noautocmd = true,
	})
	vim.bo[buf_id].bufhidden = "hide"
	return win, user_cmdheight
end

local function setup_picker_cleanup(win, buf, old_cmdheight, augroup_name)
	local group = api.nvim_create_augroup(augroup_name, { clear = true })
	api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(win),
		once = true,
		callback = function()
			vim.o.cmdheight = old_cmdheight
		end,
	})
	vim.schedule(function()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_delete(buf, { force = true })
		end
	end)
end

local function make_tmux_file_validator(pane_cwd)
	pane_cwd = fn.fnamemodify(pane_cwd, ":p")
	return function(cand)
		local raw_path = fn.expand(cand.filename)
		local norm_path = vim.fs.normalize(raw_path)
		local full_path = fn.isabsolutepath(norm_path) == 1 and norm_path
			or (pane_cwd .. "/" .. norm_path)
		if utils.is_valid_file(full_path) then
			cand.open_path = full_path
			return true
		end
		return false
	end
end

local function select_from_tmux_pane(opts)
	local pane_id, pane_cwd = get_last_pane()
	if not pane_id then
		return false
	end

	local captured_content, pane_empty =
		capture_and_prepare_tmux_content(pane_id)
	if pane_empty then
		notify.warn(opts.messages.empty_pane)
		return true
	end
	if not captured_content then
		notify.warn(opts.messages.capture_failed)
		return true
	end

	local temp_buf = create_hidden_buffer_with_content(captured_content)
	local cfg_for_temp_buf = config.get_config_for_buffer(temp_buf)

	local collected = picker.collect({
		win_ids = { 0 },
		buf = temp_buf,
		start_line = 1,
		end_line = #captured_content,
		scan_fn = function(line_text, lnum_idx, phys_lines)
			return opts.pane_processor_fn(
				line_text,
				lnum_idx,
				phys_lines,
				cfg_for_temp_buf,
				pane_cwd
			)
		end,
		skip_folds = false,
		validate_fn = (opts.picker_collect_validator_fn and pane_cwd)
				and opts.picker_collect_validator_fn(pane_cwd)
			or nil,
	})

	if vim.tbl_isempty(collected) then
		api.nvim_buf_delete(temp_buf, { force = true })
		notify.info(opts.messages.no_candidates_initial)
		return false
	end

	local function launch_visual_selection(final_list)
		if vim.tbl_isempty(final_list) then
			if api.nvim_buf_is_valid(temp_buf) then
				api.nvim_buf_delete(
					temp_buf,
					{ force = true, ignore_errors = true }
				)
			end
			notify.info(opts.messages.no_candidates_after_validation)
			return
		end

		local win, old_cmdheight = create_picker_window(temp_buf)
		for _, c in ipairs(final_list) do
			c.bufnr = temp_buf
			c.win_id = win
		end

		visual_select.assign_labels(final_list, config.config.selection_keys)
		visual_select.start_selection_loop(
			final_list,
			opts.highlighter_fn_details.highlight_ns,
			opts.highlighter_fn_details.dim_ns,
			function(cand, prefix, ns)
				if cand.label:sub(1, #prefix) == prefix then
					opts.highlighter_fn_details.func(
						cand,
						prefix,
						ns,
						opts.selection_context_opts
					)
				end
			end,
			function(sel)
				vim.schedule(function()
					opts.on_candidate_selected_fn(
						sel,
						opts.selection_context_opts
					)
				end)
			end,
			#final_list[1].label
		)

		setup_picker_cleanup(
			win,
			temp_buf,
			old_cmdheight,
			opts.cleanup_augroup_name
		)
	end

	if opts.perform_async_validation and opts.async_validator_fn then
		opts.async_validator_fn(collected, launch_visual_selection, temp_buf)
	else
		launch_visual_selection(collected)
	end

	return true
end

function M.toggle()
	config.config.tmux_mode = not config.config.tmux_mode
	notify.info(
		("pathfinder.nvim: tmux_mode = %s"):format(
			vim.inspect(config.config.tmux_mode)
		)
	)
end

function M.is_enabled()
	return config.config.tmux_mode and vim.env.TMUX_PANE ~= nil
end

function M.select_file(is_gF)
	local selection_opts = {
		is_gF = is_gF,
		use_column_numbers = config.config.use_column_numbers,
	}

	return select_from_tmux_pane({
		pane_processor_fn = function(line_text, lnum_idx, phys_lines, buf_cfg)
			return candidates.scan_line(
				line_text,
				lnum_idx,
				1,
				buf_cfg.scan_unenclosed_words,
				phys_lines,
				buf_cfg
			)
		end,
		picker_collect_validator_fn = make_tmux_file_validator,
		async_validator_fn = nil,
		on_candidate_selected_fn = function(sel, s_opts)
			core.try_open_file(sel, s_opts.is_gF)
		end,
		selection_context_opts = selection_opts,
		highlighter_fn_details = {
			func = function(cand, prefix, ns, s_opts)
				if not s_opts.is_gF then
					cand.line_nr_spans = nil
				end
				if not (s_opts.is_gF and s_opts.use_column_numbers) then
					cand.col_nr_spans = nil
				end
				visual_select.highlight_candidate(cand, prefix, ns)
			end,
			highlight_ns = visual_select.HIGHLIGHT_NS,
			dim_ns = visual_select.DIM_NS,
		},
		messages = {
			empty_pane = "tmux pane is empty",
			capture_failed = "Failed to capture tmux pane content",
			no_candidates_initial = "No valid file targets in tmux pane",
			no_candidates_after_validation = "No valid file targets in tmux pane",
		},
		cleanup_augroup_name = "PathfinderTmuxFileCleanup",
		perform_async_validation = false,
	})
end

function M.select_url()
	return select_from_tmux_pane({
		pane_processor_fn = function(
			line_text,
			lnum_idx,
			phys_lines,
			cfg_for_tmux_scan
		)
			return url.scan_line_for_urls(
				line_text,
				lnum_idx,
				phys_lines,
				cfg_for_tmux_scan
			)
		end,
		picker_collect_validator_fn = nil,
		async_validator_fn = function(cands_raw, on_done)
			url.filter_valid_candidates(cands_raw, on_done)
		end,
		on_candidate_selected_fn = function(sel)
			url.open_candidate_url(sel.url)
		end,
		selection_context_opts = {},
		highlighter_fn_details = {
			func = visual_select.highlight_candidate,
			highlight_ns = visual_select.HIGHLIGHT_NS,
			dim_ns = visual_select.DIM_NS,
		},
		messages = {
			empty_pane = "tmux pane is empty",
			capture_failed = "Failed to capture tmux pane content",
			no_candidates_initial = "No URL candidates in tmux pane",
			no_candidates_after_validation = "No valid URL candidates in tmux pane after validation",
		},
		cleanup_augroup_name = "PathfinderTmuxURLCleanup",
		perform_async_validation = config.config.validate_urls,
	})
end

return M
