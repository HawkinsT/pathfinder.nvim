local M = {}

local vim = vim

M.version = "0.6.1"

local required_nvim_version = { major = 0, minor = 9, patch = 0 }

--- Checks Neovim version compatibility.
---@return boolean True if version is compatible, false otherwise.
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

-- Initialize the plugin immediately on module load
if ensure_neovim_version() then
	local config = require("pathfinder.config")
	local core = require("pathfinder.core")
	local url = require("pathfinder.url")

	M.setup = config.setup
	M.gf = core.gf
	M.gF = core.gF
	M.gx = url.gx
	M.next_file = core.next_file
	M.prev_file = core.prev_file
	M.select_file = core.select_file
	M.select_file_line = core.select_file_line
	M.select_url = url.select_url

	local function setup_autocommands()
		vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "VimEnter" }, {
			pattern = "*",
			callback = config.update_config_for_buffer,
		})
	end

    --stylua: ignore
	local function setup_keymaps()
		if config.config.remap_default_keys then
			vim.keymap.set("n", "gf", M.gf, { silent = true, desc = "Enhanced go to file" })
			vim.keymap.set("n", "gF", M.gF, { silent = true, desc = "Enhanced go to file (line)" })
            vim.keymap.set("n", "gx", M.gx, { silent = true, desc = "Open URL/Git repository" })
			vim.keymap.set("n", "]f", M.next_file, { silent = true, desc = "Jump to next valid file name" })
			vim.keymap.set("n", "[f", M.prev_file, { silent = true, desc = "Jump to previous valid file name" })
			vim.keymap.set(
                "n",
                "<leader>gf",
                M.select_file,
                { silent = true, desc = "Visual file selection" }
            )
			vim.keymap.set(
				"n",
				"<leader>gF",
				M.select_file_line,
				{ silent = true, desc = "Visual file selection (line)" }
			)
			vim.keymap.set(
                "n",
                "<leader>gx",
                M.select_url,
                { silent = true, desc = "Visual URL/Git repository selection" }
            )
		end
	end

	load_filetype_handlers()
	setup_autocommands()
	setup_keymaps()
else
	local function nop() end
	M.setup = nop
	M.gf = nop
	M.gF = nop
	M.gx = nop
	M.next_file = nop
	M.prev_file = nop
	M.select_file = nop
	M.select_file_line = nop
	M.select_url = nop
end

return M
