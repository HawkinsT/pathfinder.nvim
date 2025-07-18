local M = {}

local notify = require("pathfinder.notify")

local vim = vim

local default_config = {
	-- Search behaviour:
	file_forward_limit = 0,
	url_forward_limit = 0,
	scan_unenclosed_words = true,
	use_column_numbers = true,
	open_mode = "edit",
	vscode_handling = true,
	reuse_existing_window = true,
	gF_count_behaviour = "nextfile",
	validate_urls = false,

	-- File resolution settings:
	max_path_length = 4096,
	associated_filetypes = {},
	url_providers = {
		"https://github.com/%s.git",
	},
	flake_providers = {
		github = "https://github.com/%s",
		gitlab = "https://gitlab.com/%s",
		sourcehut = "https://git.sr.ht/%s",
	},
	enclosure_pairs = {
		["("] = ")",
		["{"] = "}",
		["["] = "]",
		["<"] = ">",
		['"'] = '"',
		["'"] = "'",
		["`"] = "`",
	},
	url_enclosure_pairs = nil,
	includeexpr = nil,
	ft_overrides = {},

	-- User interaction:
	remap_default_keys = true,
	offer_multiple_options = true,
	pick_from_all_windows = true,
	selection_keys = { "a", "s", "d", "f", "j", "k", "l" },
	tmux_mode = false,
}

-- Active configuration for the current buffer. This will be modified by filetype overrides.
M.config = vim.deepcopy(default_config)

-- Suffix cache for each buffer (used to avoid recomputing extension lists).
M.suffix_cache = {}

-- Compute and cache a sorted list of opening delimiters.
local function update_cached_openings(cfg)
	local openings = {}
	if cfg.enclosure_pairs then
		for opening, _ in pairs(cfg.enclosure_pairs) do
			openings[#openings + 1] = opening
		end
		table.sort(openings, function(a, b)
			return #a > #b
		end)
	end
	cfg._cached_openings = openings
end

function M.set_tmux_mode(enable)
	default_config.tmux_mode = enable
	vim.cmd("redrawstatus!")
	notify.info(
		"Pathfinder: tmux mode " .. (default_config.tmux_mode and "ON" or "OFF")
	)
	return default_config.tmux_mode
end
function M.toggle_tmux_mode()
	return M.set_tmux_mode(not default_config.tmux_mode)
end

-- Returns the configuration for the specified buffer based on its filetype.
function M.get_config_for_buffer(bufnr)
	local current_config = vim.deepcopy(default_config)
	current_config.ft_overrides = default_config.ft_overrides or {}

	local ft = vim.bo[bufnr].filetype
	if ft and ft ~= "" then
		-- Apply built-in ft module settings (overwrite defaults).
		local ft_ok, ft_module = pcall(require, "pathfinder.ft." .. ft)
		if ft_ok and type(ft_module) == "table" and ft_module.config then
			for key, value in pairs(ft_module.config) do
				current_config[key] = vim.deepcopy(value)
			end
		end

		-- Apply user ft_overrides (overwrite defaults and ft module settings).
		local user_override_for_ft = default_config.ft_overrides[ft]
		if user_override_for_ft then
			for key, value in pairs(user_override_for_ft) do
				current_config[key] = vim.deepcopy(value)
			end
		end
	end

	update_cached_openings(current_config)
	return current_config
end

-- Updates the active configuration (M.config) based on defaults, filetype,
-- and ft_overrides (in reverse order of precedence) for the current buffer.
function M.update_config_for_buffer()
	local bufnr = vim.api.nvim_get_current_buf()

	M.config = M.get_config_for_buffer(bufnr)

	-- Apply buffer-local settings based on the finalized config.
	if M.config.includeexpr ~= nil then
		vim.api.nvim_set_option_value(
			"includeexpr",
			M.config.includeexpr,
			{ scope = "local", buf = bufnr }
		)
	end

	M.suffix_cache[bufnr] = nil
end

-- Sets up pathfinder with user configuration.
function M.setup(user_config)
	user_config = user_config or {}

	if user_config.ft_overrides then
		default_config.ft_overrides = user_config.ft_overrides
		user_config.ft_overrides = nil
	end

	default_config = vim.tbl_deep_extend("force", default_config, user_config)

	M.update_config_for_buffer()
end

return M
