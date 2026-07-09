# fuzzyedit.vim

Fuzzy file search integrated directly into the `:edit` command line.

FuzzyEdit adds a fuzzy file finder to Vim's command line: as you type
`:e ...`, a popup below the command line shows the best matching files in
the current project, updated on every keystroke. There is no separate
window or buffer to open, close, or navigate out of: you stay in
command-line mode the whole time.

```
:e ma
▶ src/main.c
  src/main_test.c
  app/main.rs
  Makefile
```

## Features

- Pure Vimscript, no C code, no external binary required.
- Uses only Vim's public APIs (`popup_*()`, cmdline autocommands,
  `systemlist()`/`globpath()`).
- Works without `fd` (falls back to `find`, then to a pure Vimscript
  `globpath()` scan if neither is available).
- Uses `git ls-files` when available, so `.gitignore`d files and
  directories (`node_modules`, `target`, `build`, ...) are excluded
  automatically in git repositories.
- Fuzzy scoring engine with no external dependency (no fzf), favoring
  consecutive characters, word/path-segment starts, camelCase
  boundaries, and short paths.
- Stays fluid on projects with tens of thousands of files, thanks to a
  memoized file cache and a scoring core compiled with Vim9 `:def`.
- Keyboard-only navigation (arrows, Tab, Enter, Escape); you never leave
  the command line.

## Requirements

- Vim 8.2 or newer, compiled with `+popupwin`.
- No other dependency. `git` and `fd` are optional and used
  automatically when available in `$PATH`.

## Installation

Using Vim's native package support (no plugin manager required):

```sh
git clone <this-repo-url> ~/.vim/pack/plugins/start/fuzzyedit
vim -u NONE -i NONE -es -c "helptags ~/.vim/pack/plugins/start/fuzzyedit/doc" -c "qa!"
```

With a plugin manager (vim-plug, packer.nvim-style managers for Vim,
minpac, etc.), add the repository as you would any other plugin and
run its install/update command.

## Usage

Type `:edit` (or `:e`) followed by a fragment of the filename you are
looking for. A popup appears below the command line with up to
`g:fuzzyedit_max_results` suggestions, sorted by relevance.

| Key                    | Action                                    |
|-------------------------|-------------------------------------------|
| `<Down>` / `<C-n>` / `<Tab>`   | Select the next result            |
| `<Up>` / `<C-p>` / `<S-Tab>`   | Select the previous result        |
| `<CR>`                  | Open the selected file                    |
| `<Esc>`                 | Close the popup (keeps the command line)  |

## Commands

- `:FuzzyEditRebuildCache` — force a rebuild of the file cache for the
  current project.
- `:FuzzyEditStatus` — show a diagnostic (project root, cache backend,
  file count, last query timing) useful for troubleshooting slowdowns.

## Configuration

```vim
let g:fuzzyedit_max_results = 15
let g:fuzzyedit_ignore_patterns = ['.git/*', 'node_modules/*', ...]
let g:fuzzyedit_root_markers = ['.git', '.hg', '.svn', 'Makefile', ...]
let g:fuzzyedit_commands = ['e', 'edit']
```

See `:help fuzzyedit` for the full documentation, including the
architecture, the scoring algorithm, and performance notes.

## Disclaimer

This plugin was developed for the most part with the help of an AI
coding assistant. Review the code before relying on it in your own
workflow, and report any issue you find.

## License

Distributed under the GNU General Public License v3.0 (GPL-3.0). See
the `LICENSE` file for details.
