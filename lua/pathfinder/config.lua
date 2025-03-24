local M = {}

M.default_config = {
	-- Search behaviour
	forward_limit = -1,
	scan_unenclosed_words = true,
	open_mode = "edit",
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
	selection_keys = { "a", "s", "d", "f", "j", "k", "l" },
}

--- Active configuration for the current buffer. This will be modified by filetype overrides.
M.config = vim.deepcopy(M.default_config)

--- Suffix cache for each buffer (used to avoid recomputing extension lists).
M.suffix_cache = {}

function M.update_config_for_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	M.config = vim.deepcopy(M.default_config)

	local ft = vim.bo.filetype
	if ft and ft ~= "" then
		local ok, ft_module = pcall(require, "pathfinder.ft." .. ft)
		if ok and ft_module and ft_module.config then
			if ft_module.config.enclosure_pairs then
				M.config.enclosure_pairs = vim.deepcopy(ft_module.config.enclosure_pairs)
			end
			M.config = vim.tbl_deep_extend("force", M.config, ft_module.config)
		end
	end

	if ft and M.config.ft_overrides[ft] then
		local override = M.config.ft_overrides[ft]
		if override.enclosure_pairs then
			M.config.enclosure_pairs = vim.deepcopy(override.enclosure_pairs)
		end
		M.config = vim.tbl_deep_extend("force", M.config, override)
	end

	if M.config.includeexpr ~= "" then
		vim.opt_local.includeexpr = M.config.includeexpr
	end

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
