local M = {}

local vim = vim

M.default_config = {
	-- Search behaviour
	forward_limit = -1,
	scan_unenclosed_words = true,
	open_mode = "edit",
	reuse_existing_window = true,
	gF_count_behaviour = "nextfile",

	-- File resolution settings
	associated_filetypes = {},
	enclosure_pairs = {
		["("] = ")",
		["{"] = "}",
		["["] = "]",
		["<"] = ">",
		['"'] = '"',
		["'"] = "'",
		["`"] = "`",
	},
	includeexpr = "",
	ft_overrides = {},

	-- User interaction
	remap_default_keys = true,
	offer_multiple_options = true,
	pick_from_all_windows = true,
	selection_keys = { "a", "s", "d", "f", "j", "k", "l" },
}

--- Active configuration for the current buffer. This will be modified by filetype overrides.
M.config = vim.deepcopy(M.default_config)

--- Suffix cache for each buffer (used to avoid recomputing extension lists).
M.suffix_cache = {}

--- Helper to compute and cache the sorted list of opening delimiters.
local function update_cached_openings(cfg)
	local openings = {}
	if cfg.enclosure_pairs then
		for opening, _ in pairs(cfg.enclosure_pairs) do
			table.insert(openings, opening)
		end
		table.sort(openings, function(a, b)
			return #a > #b
		end)
	end
	cfg._cached_openings = openings
end

--- Returns the configuration for the specified buffer based on its filetype.
function M.get_config_for_buffer(bufnr)
	local current_config = vim.deepcopy(M.default_config)
	current_config.ft_overrides = M.default_config.ft_overrides or {}

	local ft = vim.bo[bufnr].filetype
	if ft and ft ~= "" then
		-- Apply built-in ft module settings (overwrite defaults).
		local ft_ok, ft_module = pcall(require, "pathfinder.ft." .. ft)
		if ft_ok and ft_module and ft_module.config then
			for key, value in pairs(ft_module.config) do
				current_config[key] = vim.deepcopy(value)
			end
		end

		-- Apply user ft_overrides (overwrite defaults and ft module settings).
		local user_override_for_ft = M.default_config.ft_overrides[ft]
		if user_override_for_ft then
			for key, value in pairs(user_override_for_ft) do
				current_config[key] = vim.deepcopy(value)
			end
		end
	end

	-- Update derived/cached values
	update_cached_openings(current_config)
	return current_config
end

--- Updates the active configuration (M.config) based on defaults, filetype,
--- and ft_overrides (in reverse order of precedence) for the current buffer.
function M.update_config_for_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	local current_config = vim.deepcopy(M.default_config)
	current_config.ft_overrides = M.default_config.ft_overrides or {}

	local ft = vim.bo[bufnr].filetype
	if ft and ft ~= "" then
		-- Apply built-in ft module settings (overwrite defaults).
		local ft_ok, ft_module = pcall(require, "pathfinder.ft." .. ft)
		if ft_ok and ft_module and ft_module.config then
			for key, value in pairs(ft_module.config) do
				current_config[key] = vim.deepcopy(value)
			end
		end

		-- Apply user ft_overrides (overwrite defaults and ft module settings).
		local user_override_for_ft = M.default_config.ft_overrides[ft]
		if user_override_for_ft then
			for key, value in pairs(user_override_for_ft) do
				current_config[key] = vim.deepcopy(value)
			end
		end
	end

	-- Finalize active config.
	M.config = current_config

	-- Apply buffer-local settings based on the finalized config.
	local includeexpr_target = M.config.includeexpr
	if includeexpr_target and includeexpr_target ~= "" then
		vim.api.nvim_set_option_value("includeexpr", includeexpr_target, { scope = "local", buf = bufnr })
	else
	end

	-- Update derived/cached values
	update_cached_openings(M.config)
	M.suffix_cache[bufnr] = nil
end

--- Sets up pathfinder with user configuration.
---@param user_config? table Optional table with configuration overrides.
function M.setup(user_config)
	user_config = user_config or {}

	if user_config.ft_overrides then
		M.default_config.ft_overrides = user_config.ft_overrides
		user_config.ft_overrides = nil
	end

	M.default_config = vim.tbl_deep_extend("force", M.default_config, user_config)

	M.update_config_for_buffer()
end

return M
