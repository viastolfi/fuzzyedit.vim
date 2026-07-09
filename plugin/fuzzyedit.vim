" plugin/fuzzyedit.vim
" Entry point of the FuzzyEdit plugin.
"
" FuzzyEdit adds a fuzzy search directly inside the :edit command line: a
" popup shows the best matching files while you type, without ever
" leaving the command line. No external dependency (no fzf, no fd
" required, no C code).

if exists('g:loaded_fuzzyedit')
  finish
endif
let g:loaded_fuzzyedit = 1

" --- Compatibility ----------------------------------------------------
" popup_create() has been available since Vim 8.2 (+popupwin). We refuse
" to load the plugin on an older version rather than crash later on a
" missing popup_*() call.
if !has('popupwin')
  echomsg 'fuzzyedit: Vim 8.2+ with +popupwin is required, plugin disabled.'
  finish
endif

" --- User options -------------------------------------------------------
" All overridable from the vimrc BEFORE the plugin loads.
" We use get(g:, ..., default) rather than direct assignments so we
" never overwrite a choice the user already made.

" Maximum number of results shown in the popup.
let g:fuzzyedit_max_results = get(g:, 'fuzzyedit_max_results', 15)

" Glob patterns ignored when building the file cache.
let g:fuzzyedit_ignore_patterns = get(g:, 'fuzzyedit_ignore_patterns', [
      \ '.git/*', '.hg/*', '.svn/*',
      \ 'node_modules/*', 'target/*', 'build/*', 'dist/*',
      \ '*.o', '*.pyc', '*.class',
      \ ])

" Project root markers, tested in this order while walking up parent
" directories from the current directory.
let g:fuzzyedit_root_markers = get(g:, 'fuzzyedit_root_markers', [
      \ '.git', '.hg', '.svn', 'Makefile', 'package.json', 'Cargo.toml', 'go.mod',
      \ ])

" Watched cmdline commands: the popup only activates if the typed
" command matches one of these.
let g:fuzzyedit_commands = get(g:, 'fuzzyedit_commands', ['e', 'edit'])

" --- User commands --------------------------------------------------------
" Forces a rebuild of the file cache for the current project.
command! -bar FuzzyEditRebuildCache
      \ call fuzzyedit#cache#build(fuzzyedit#project_root(), v:true)

" Shows diagnostic information useful when things feel slow: detected
" project root, scan backend used and number of cached files, then
" timing of the last processed keystroke (size of the actually scanned
" universe, whether narrowing was active, search time vs popup time).
" Run this right after typing a :e search that felt slow (the timing
" reflects the LAST keystroke, so stay in cmdline mode long enough to
" notice the lag, then Esc before running this command). See
" |fuzzyedit-troubleshooting|.
command! -bar FuzzyEditStatus call s:show_status()

function! s:show_status() abort
  let l:info = fuzzyedit#debug()
  echohl Title | echo 'FuzzyEdit -- diagnostic' | echohl None
  echo 'Project root       : ' . (empty(l:info.root) ? '(no active session)' : l:info.root)

  if !empty(l:info.cache)
    echo printf('Cache              : backend=%s, %d files, built in %d ms',
          \ l:info.cache.backend, l:info.cache.count, l:info.cache.build_ms)
  else
    echo 'Cache              : (not yet built for this root)'
  endif

  if !empty(l:info.last_update)
    let l:u = l:info.last_update
    echo printf('Last query         : "%s" (narrowed=%s)', l:u.query, l:u.narrowed ? 'yes' : 'no')
    echo printf('Scanned universe   : %d files -> %d results', l:u.universe_size, l:u.result_count)
    echo printf('Search time        : %d ms', l:u.search_ms)
    echo printf('Popup time         : %d ms', l:u.popup_ms)
  else
    echo 'Last query         : (none yet, type :e ... then rerun :FuzzyEditStatus)'
  endif
endfunction

" --- Autocommands -----------------------------------------------------------
" The pattern for these three events is the command-line type (":" for
" Ex commands). We only care about that mode.
augroup fuzzyedit
  autocmd!
  autocmd CmdlineEnter   : call fuzzyedit#start()
  autocmd CmdlineChanged : call fuzzyedit#update()
  autocmd CmdlineLeave   : call fuzzyedit#stop()
augroup END

" --- Keyboard navigation -----------------------------------------------------
" Global mappings, always active in command-line mode (":", but also "/"
" and "?"). They only do something when our popup is actually shown
" (checked inside each on_*() function); in every other case -- search,
" command history, normal completion on a non-watched command -- they
" return the original key untouched and are completely transparent.
"
" cnoremap (not cmap): avoids any interaction with other user mappings
" on the same keys, which would otherwise stay inactive while our popup
" is open, as expected.
" <Tab>/<S-Tab> are NOT mapped here unlike the others: <Tab> is Vim's
" 'wildchar' (native cmdline completion trigger). Keeping a permanent
" cnoremap <expr> <Tab> -- even one whose fallback branch returns
" "\<Tab>" -- permanently breaks wildchar completion for EVERY command
" (":set wi<Tab>", ":color <Tab>", ...), not just :e: once Vim resolves
" the key through a mapping, the returned "\<Tab>" is reinserted as a
" plain character, it no longer re-triggers the special wildchar
" handling, so it just inserts a literal Tab instead of completing.
" These two are installed/removed dynamically instead, only while our
" popup is actually visible: see s:enable_tab_mapping()/
" s:disable_tab_mapping() in popup.vim, called from show()/close().
cnoremap <expr> <Down>  fuzzyedit#cmdline#on_next("\<Down>")
cnoremap <expr> <C-n>   fuzzyedit#cmdline#on_next("\<C-n>")
cnoremap <expr> <Up>    fuzzyedit#cmdline#on_prev("\<Up>")
cnoremap <expr> <C-p>   fuzzyedit#cmdline#on_prev("\<C-p>")
cnoremap <expr> <CR>    fuzzyedit#cmdline#on_cr()
cnoremap <expr> <Esc>   fuzzyedit#cmdline#on_esc()
