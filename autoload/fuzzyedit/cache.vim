" autoload/fuzzyedit/cache.vim
" Building and memoizing the list of files in a project.
"
" The cache is indexed by project root (string -> list): navigating
" between several projects during the same Vim session does not trigger
" a needless rebuild. Each root is scanned only once, until an explicit
" call to :FuzzyEditRebuildCache.
"
" Paths are stored RELATIVE to the project root (e.g. 'src/main.c'):
" this is the format shown in the popup and scored by the fuzzy engine.
" It is up to the caller (the :edit integration, step 8) to recombine
" them with the root to obtain an openable path.

" s:cache = {project_root: [relative paths...]}
let s:cache = {}

" s:meta = {project_root: {'backend': ..., 'build_ms': ..., 'count': ...}}
" Diagnostic metadata (see fuzzyedit#cache#info()): plays no part in any
" functional logic, used only by :FuzzyEditStatus so it can quickly
" determine, on a user's machine, which backend was used and how many
" files/how much time the last scan took -- without needing to reproduce
" the issue remotely.
let s:meta = {}

" Returns the cached file list for `root`.
" Builds the cache if it does not exist yet for this root.
function! fuzzyedit#cache#get(root) abort
  if !has_key(s:cache, a:root)
    call fuzzyedit#cache#build(a:root)
  endif
  return get(s:cache, a:root, [])
endfunction

" Runs `cmd` (a complete shell string, already "cd"-ed into the right
" directory) and returns its output as lines, or [] on failure (missing
" command, error, timeout...). Never assumes the command exists: it is
" up to the caller to check executable(...) beforehand.
function! s:run(cmd) abort
  let l:out = systemlist(a:cmd)
  if v:shell_error != 0
    return []
  endif
  return l:out
endfunction

" Lists all files under `root` via `git ls-files` (git repos only).
" --cached lists tracked files, --others lists untracked but non-ignored
" files, --exclude-standard applies .gitignore (at every level of the
" repo), .git/info/exclude, and the user's global excludesfile. This is
" the most reliable backend for respecting .gitignore: no reimplementing
" its syntax (negation '!', anchoring '/', directory patterns...) is
" needed, git handles it natively. Files inside .git itself are never
" listed by ls-files (it is not a tracked file from git's point of view).
function! s:scan_with_git(root) abort
  let l:cmd = 'cd ' . shellescape(a:root)
        \ . ' && git ls-files --cached --others --exclude-standard'
  return s:run(l:cmd)
endfunction

" Lists all files under `root` via `fd` (fast, respects .gitignore by
" default). Paths returned relative to `root`.
function! s:scan_with_fd(root) abort
  let l:cmd = 'cd ' . shellescape(a:root)
        \ . ' && fd --type f --hidden --strip-cwd-prefix --exclude .git .'
  return s:run(l:cmd)
endfunction

" Lists all files under `root` via `find` (POSIX, nearly universal on
" Unix). We already exclude .git at the `find` level to avoid walking a
" large .git directory just to filter it out afterwards; other
" exclusions are handled uniformly via g:fuzzyedit_ignore_patterns (see
" s:apply_ignore_patterns).
function! s:scan_with_find(root) abort
  let l:cmd = 'cd ' . shellescape(a:root)
        \ . " && find . -path './.git' -prune -o -type f -print"
  let l:out = s:run(l:cmd)
  " find prefixes each result with "./": strip it to stay consistent
  " with the relative paths produced by fd/globpath.
  return map(l:out, {_, p -> substitute(p, '^\./', '', '')})
endfunction

" Lists all files under `root` in pure Vimscript, with no external
" dependency: the only backend guaranteed to be available everywhere
" (including Windows without Unix tools). Slower on very large trees,
" but functional.
function! s:scan_with_globpath(root) abort
  let l:entries = globpath(a:root, '**', 0, 1)
  let l:files = filter(l:entries, {_, p -> !isdirectory(p)})
  let l:prefix = '^' . escape(a:root, '\/.*$^~[]') . '/\?'
  return map(l:files, {_, p -> substitute(p, l:prefix, '', '')})
endfunction

" Removes from `paths` every entry matching at least one pattern from
" g:fuzzyedit_ignore_patterns. glob2regpat() is a native Vim function
" that converts a glob-style pattern ('*.o', 'node_modules/*') into a
" Vim regular expression: this is what lets us apply the same patterns
" identically regardless of which scan backend was used.
function! s:apply_ignore_patterns(paths) abort
  let l:patterns = get(g:, 'fuzzyedit_ignore_patterns', [])
  if empty(l:patterns)
    return a:paths
  endif
  let l:regexes = map(copy(l:patterns), {_, pat -> glob2regpat(pat)})
  return filter(a:paths, {_, p -> !s:matches_any(p, l:regexes)})
endfunction

function! s:matches_any(path, regexes) abort
  for l:re in a:regexes
    if a:path =~# l:re
      return v:true
    endif
  endfor
  return v:false
endfunction

" (Re)builds the cache for `root`.
"   `force`   (optional, default v:false): rebuilds even if a cache
"             already exists for this root (used by
"             :FuzzyEditRebuildCache).
"   `backend` (optional): forces 'git', 'fd', 'find' or 'globpath' instead
"             of the automatic detection. Mostly reserved for tests and
"             diagnostics (lets you verify each backend in isolation
"             even when several tools are installed on the machine).
function! fuzzyedit#cache#build(root, ...) abort
  let l:force = get(a:000, 0, v:false)
  let l:backend = get(a:000, 1, '')

  if !l:force && has_key(s:cache, a:root)
    return
  endif

  if empty(l:backend)
    " Priority: git ls-files (respects .gitignore natively, without
    " reimplementing its syntax) > fd (also respects .gitignore) >
    " find (only ignores .git) > globpath (no native exclusion).
    " g:fuzzyedit_ignore_patterns applies on top, regardless of the
    " backend, for exclusions the user wants to force even outside a
    " git repo (or in addition to .gitignore).
    if isdirectory(a:root . '/.git') && executable('git')
      let l:backend = 'git'
    elseif executable('fd')
      let l:backend = 'fd'
    elseif executable('find')
      let l:backend = 'find'
    else
      let l:backend = 'globpath'
    endif
  endif

  let l:t0 = reltime()

  if l:backend ==# 'git'
    let l:files = s:scan_with_git(a:root)
  elseif l:backend ==# 'fd'
    let l:files = s:scan_with_fd(a:root)
  elseif l:backend ==# 'find'
    let l:files = s:scan_with_find(a:root)
  else
    let l:files = s:scan_with_globpath(a:root)
  endif

  let l:files = s:apply_ignore_patterns(l:files)
  let s:cache[a:root] = sort(l:files)

  " Diagnostic metadata only (see fuzzyedit#cache#info() and
  " :FuzzyEditStatus): never consulted by the plugin's logic.
  let s:meta[a:root] = {
        \ 'backend': l:backend,
        \ 'build_ms': float2nr(round(reltimefloat(reltime(l:t0)) * 1000.0)),
        \ 'count': len(s:cache[a:root]),
        \ }
endfunction

" Returns the diagnostic metadata of the last scan for `root`
" ({'backend', 'build_ms', 'count'}), or an empty dictionary if the
" cache has never been built for this root yet. Used by
" :FuzzyEditStatus to help diagnose slowdowns without having to
" reproduce the issue (which backend was chosen, how many files were
" found, how long the scan took).
function! fuzzyedit#cache#info(root) abort
  return get(s:meta, a:root, {})
endfunction

" Clears the cache entirely (all roots combined). Useful for unit tests
" to start from a clean state between two cases.
function! fuzzyedit#cache#clear() abort
  let s:cache = {}
  let s:meta = {}
endfunction
