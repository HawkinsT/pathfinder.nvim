local M = {}

local vim = vim

M.version = "0.7.0"

local required_nvim_version = { major = 0, minor = 10, patch = 0 }

local function ensure_neovim_version()
	local current_nvim_version = vim.version()
	for _, key in ipairs({ "major", "minor", "patch" }) do
		if current_nvim_version[key] < required_nvim_version[key] then
			local required_str = string.format(
				"%d.%d.%d",
				required_nvim_version.major,
				required_nvim_version.minor,
				required_nvim_version.patch
			)
			local current_str = string.format(
				"%d.%d.%d",
				current_nvim_version.major,
				current_nvim_version.minor,
				current_nvim_version.patch
			)
			vim.notify(
				string.format(
					"pathfinder.nvim: Incompatible Neovim version (%s < %s).\n" .. "Plugin functionality is disabled.",
					current_str,
					required_str
				),
				vim.log.levels.WARN,
				{ title = "pathfinder.nvim: Version Check" }
			)
			return false
		elseif current_nvim_version[key] > required_nvim_version[key] then
			return true
		end
	end
	return true
end

-- Load all custom filetype handlers from ./ft/<filetype>.lua.
local function load_filetype_handlers()
	local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	local ft_dir = plugin_root .. "/ft"
	for name, type in vim.fs.dir(ft_dir) do
		if type == "file" and name:match("%.lua$") then
			local ft_name = name:gsub("%.lua$", "")
			local module_name = "pathfinder.ft." .. ft_name
			local ok, err = pcall(require, module_name)
			if not ok then
				vim.notify(
					string.format("Failed to load filetype handler %s: %s", module_name, err),
					vim.log.levels.WARN
				)
			end
		end
	end
end

-- Initialize the plugin immediately on module load.
if ensure_neovim_version() then
	local config = require("pathfinder.config")
	local core = require("pathfinder.core")
	local hover = require("pathfinder.hover")
	local url = require("pathfinder.url")

	M.setup = config.setup
	M.gf = core.gf
	M.gF = core.gF
	M.gx = url.gx
	M.next_file = core.next_file
	M.prev_file = core.prev_file
	M.next_url = url.next_url
	M.prev_url = url.prev_url
	M.select_file = core.select_file
	M.select_file_line = core.select_file_line
	M.select_url = url.select_url
	M.hover_description = hover.hover_description

	local function setup_keymaps()
		local bufnr = vim.api.nvim_get_current_buf()
		if not config.config.remap_default_keys then
			return
		end

		local map = function(lhs, rhs, desc)
			vim.keymap.set("n", lhs, rhs, { silent = true, buffer = bufnr, desc = desc })
		end

		map("gf", M.gf, "Enhanced go to file")
		map("gF", M.gF, "Enhanced go to file (line)")
		map("gx", M.gx, "Open URL/Git repository")
		map("]f", M.next_file, "Jump to next valid file name")
		map("[f", M.prev_file, "Jump to previous valid file name")
		map("]u", M.next_url, "Jump to next valid URL")
		map("[u", M.prev_url, "Jump to previous valid URL")
		map("<leader>gf", M.select_file, "Visual file selection")
		map("<leader>gF", M.select_file_line, "Visual file selection (line)")
		map("<leader>gx", M.select_url, "Visual URL/Git repository selection")
	end

	local function setup_autocommands()
		vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "VimEnter" }, {
			pattern = "*",
			callback = function()
				config.update_config_for_buffer()
				setup_keymaps()
			end,
		})
	end

	load_filetype_handlers()
	setup_autocommands()
else
	local function nop() end
	M.setup = nop
	M.gf = nop
	M.gF = nop
	M.gx = nop
	M.next_file = nop
	M.prev_file = nop
	M.next_url = nop
	M.prev_url = nop
	M.select_file = nop
	M.select_file_line = nop
	M.select_url = nop
	M.hover_description = nop
end

return M
