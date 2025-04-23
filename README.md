# Pathfinder: Enhanced File Navigation for Neovim

**Pathfinder** is a Neovim plugin that enhances the built-in `gf`, `gF`, and `gx` commands as a highly customizable, multiline, drop-in replacement. It also provides an [EasyMotion](https://github.com/easymotion/vim-easymotion)-like file picker, making file hopping effortless.

---

## What is Pathfinder?

Pathfinder enhances Neovim's native file navigation by extending `gf` (go to file) and `gF` (go to file with line number), as well as adding a targeted file selection mode with `<leader>gf`; but you can customize or disable these default keymaps as needed. It’s designed to give developers more control and precision when navigating codebases.

---

## Key Features

- **Enhanced `gf` and `gF`**: Navigate to the count'th file after the cursor.
- **Enhanced `gx`**: Navigate to the count'th URL or Git repo after the cursor.
- **Multiline Awareness**: Scans beyond the current line with configurable limits.
- **Compatibility**: Retains standard `gf` and `gF` behaviour, including `suffixesadd` and `includeexpr`.
- **Smarter File Resolving**: Resolves complex file patterns `gf` and `gF` may miss.
- **Smarter URL Resolving**: Resolves `username/repo` combinations against a list of URLs.
- **Enclosure Support**: Recognize file paths and URLs between user-specified multi-character delimiters.
- **Interactive Selection**: Choose from multiple matches with a simple prompt when ambiguity emerges.
- **Flexible Opening Modes**: Open files in the current buffer, splits, tabs, or even external programs.
- **Quick File Picker**: Use `select_file()` to jump to any visible file in the buffer, mapped to `<leader>gf` by default.
- **Quick File Picker with line**: Use `select_file_line()` to jump to any visible file with line in the buffer, mapped to `<leader>gF` by default.
- **Quick URL Picker**: Use `select_url()` to jump to any visible URL or online git repository, mapped to `<leader>gx` by default.

---

## Installation

Install Pathfinder using your preferred Neovim plugin manager. For example:

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{ 'HawkinsT/pathfinder.nvim' }
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```lua
Plug 'HawkinsT/pathfinder.nvim'
```

After installation, you can optionally configure Pathfinder (see below) or start using it straight away with the default settings, no setup function required.

---

## Basic Usage

Pathfinder works out of the box by enhancing `gf`, `gF`, and `gx`. Here’s how it behaves:

- **`gf`**: Opens the next valid file after the cursor. Use `[count]gf` to jump to the _count'th_ file.
- **`gF`**: Opens the next file and places the cursor at the _count'th_ line.
- **`gx`**: Opens the next valid URL after the cursor. Use `[count]gx` to jump to the _count'th_ URL.
- **Examples**:
  - `2gf` → Opens the second valid file after the cursor.
  - `10gF` → Opens the next valid file after the cursor at line 10.
  - `eval.c:20` → Opens `eval.c` at line 20 when used with `gF`.

If multiple files match (e.g. `eval.c` and `eval.h`), Pathfinder prompts you to choose, unless configured to always select the first match.

For a more visual workflow, you may use the `select_file()`, `select_file_line()`, and `select_url()` functions, mapped to `<leader>gf`, `leader<gF>`, and `leader<gx>` by default; inspired by the likes of [EasyMotion](https://github.com/easymotion/vim-easymotion) and [Hop](https://github.com/hadronized/hop.nvim).

This displays all visible files or web links buffer or across all visible windows, letting you pick one with minimal key presses.

---

## Configuration

Unless you wish to override the default settings, no setup is required. If you do, the Pathfinder defaults may be modified by calling `require('pathfinder').setup()` in your Neovim config. As an example, here is the default configuration. You only need to specify setup keys that you wish to override:

```lua
require('pathfinder').setup({
	-- Search behaviour
	forward_limit = -1, -- Search the entire visible buffer
	scan_unenclosed_words = true, -- Include plain-text (non-delimited) file paths
	open_mode = "edit", -- Open files in the current buffer (:edit), accepts string or function
    reuse_existing_window = true, -- If file is already open, go to its active window (don't reopen)
	gF_count_behaviour = "nextfile", -- [count]gF will open the next file at line `count`

	-- File resolution settings
	associated_filetypes = {}, -- File extensions that should be tried (also see `suffixesadd`)
    url_providers = { -- List of software forges to try when resolving username/repo links
		"https://github.com/%s.git",
	},
	enclosure_pairs = { -- Define all file path delimiters to search between
		["("] = ")",
		["{"] = "}",
		["["] = "]",
		["<"] = ">",
		['"'] = '"',
		["'"] = "'",
		["`"] = "`",
	},
	url_enclosure_pairs = nil, -- If set, this will supersede enclosure_pairs for URL picking
	includeexpr = "", -- Helper function to set `includeexpr`
	ft_overrides = {}, -- Filetype-specific settings

	-- User interaction
	remap_default_keys = true, -- Remap `gf`, `gF`, and `<leader>gf` to Pathfinder's functions
	offer_multiple_options = true, -- If multiple valid files with the same name are found, prompt for action
	pick_from_all_windows = true, -- Provide `select_file()` and `select_file_line()` targets across all visible windows
	selection_keys = { "a", "s", "d", "f", "j", "k", "l" }, -- Keys to use for selection in `select_file()` and `select_file_line()`
})
```

Filetype-specific overrides may be specified like so:

```lua
require('pathfinder').setup({
    ft_overrides = {
        lua = {
            associated_filetypes = { ".lua", ".tl" },
            enclosure_pairs = {
                ["'"] = "'",
                ['"'] = '"',
                ['[['] = ']]',
            },
            includeexpr = "substitute(v:fname,'\\.\\w*','','')",
        },
    },
})
```

The colour scheme used by select_file() may be changed using the following highlight groups:

```lua
vim.api.nvim_set_hl(0, "PathfinderDim", { fg = "#808080", bg = "none" })
vim.api.nvim_set_hl(0, "PathfinderHighlight", { fg = "#DDDDDD", bg = "none" })
vim.api.nvim_set_hl(0, "PathfinderNumberHighlight", { fg = "#00FF00", bg = "none" })
vim.api.nvim_set_hl(0, "PathfinderNextKey", { fg = "#FF00FF", bg = "none" })
vim.api.nvim_set_hl(0, "PathfinderFutureKeys", { fg = "#BB00AA", bg = "none" })

```

### Highlights

- **`forward_limit`**: Set the forward search limit to a specific number of lines. Set to `1` for single-line search or `-1` for the visible buffer area.
- **`open_mode`**: Use any command to open files, e.g. `"edit"`, `"split"`, or supply a function which takes two arguments; filename and line number (optional).
- **`ft_overrides`**: Customize per-filetype.
- **`remap_default_keys`**: Set to `false` to use custom mappings:
  ```lua
    vim.keymap.set('n', 'gf', require('pathfinder').gf)
    vim.keymap.set('n', 'gF', require('pathfinder').gF)
    vim.keymap.set('n', 'gx', require('pathfinder').gx)
    vim.keymap.set('n', '<leader>gf', require('pathfinder').select_file)
    vim.keymap.set('n', '<leader>gF', require('pathfinder').select_file_line)
    vim.keymap.set('n', '<leader>gx', require('pathfinder').select_url)
  ```

---

## Contributing

Found a bug? Want to add support for a filetype? All contributions are welcome! Please submit any bug reports, feature requests, or pull requests as you see fit.

---

## Requirements

Neovim ≥ 0.9.0

---

## Full Documentation

For a full list of features, configuration options, and usage, check the [vimdoc](doc/pathfinder.txt) included in the repository.
