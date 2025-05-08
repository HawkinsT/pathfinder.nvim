local ver = require("pathfinder.version")

-- Disable functions and warn if required Neovim version not met.
local compatible, current = ver.is_compatible()
if not compatible then
	vim.schedule(function()
		ver.notify(current)
	end)
	local nop = function() end
	return {
		setup = nop,
		gf = nop,
		gF = nop,
		gx = nop,
		next_file = nop,
		prev_file = nop,
		next_url = nop,
		prev_url = nop,
		select_file = nop,
		select_file_line = nop,
		select_url = nop,
		hover_description = nop,
	}
end

local M = {}

-- Plugin version.
M.version = "0.7.3"

local vim = vim

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

-- Load all filetype handlers from ./ft/<filetype>.lua.
local function load_filetype_handlers()
	local plugin_root =
		vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	local ft_dir = plugin_root .. "/ft"
	for name, type in vim.fs.dir(ft_dir) do
		if type == "file" and name:match("%.lua$") then
			local ft_name = name:gsub("%.lua$", "")
			local module_name = "pathfinder.ft." .. ft_name
			local ok, err = pcall(require, module_name)
			if not ok then
				vim.notify(
					string.format(
						"pathfinder.nvim: Failed to load filetype handler %s: %s",
						module_name,
						err
					),
					vim.log.levels.WARN,
					{ title = "pathfinder.nvim" }
				)
			end
		end
	end
end

local function setup_keymaps()
	if not config.config.remap_default_keys then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local map = function(lhs, rhs, desc)
		vim.keymap.set(
			"n",
			lhs,
			rhs,
			{ silent = true, buffer = bufnr, desc = desc }
		)
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

-- Autocommands to update config and keys on buffer/filetype enter.
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

return M
