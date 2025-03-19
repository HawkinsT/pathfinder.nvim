---@tag pathfinder.tex
---@brief [[
--- TeX filetype handler for pathfinder.nvim.
--- This module defines TeX-specific defaults.
---
--- User-specified (ft_overrides) will take precedence.

--- Module loaded automatically when filetype is "tex".
---@brief ]]

local M = {}

--- TeX-specific default configuration.
---@class TeXConfig
---@field enclosure_pairs (table) Custom enclosure pairs for TeX (overwrite defaults).
---@field associated_filetypes (table) Ordered list of file extensions to try before `suffixesadd`.
M.config = {
	enclosure_pairs = {
		["{"] = "}",
	},
	associated_filetypes = { ".tex", ".sty", ".cls", ".bib" },
}

return M
