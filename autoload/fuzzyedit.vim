" autoload/fuzzyedit.vim
" Central orchestrator of the plugin.
"
" This module glues the other ones together:
"   cmdline.vim  -> pure parsing of getcmdline()
"   cache.vim    -> project file list (memoized)
"   fuzzy.vim    -> pure fuzzy scoring/sorting
"   popup.vim    -> display, no other module touches popup_*()
"
" No global variable: all the live state of the search session lives in
" the script-local dictionary s:state, recreated on every command-line
" entry (CmdlineEnter).

" State of the current search session.
"   active   : bool  - v:true if the typed command is watched (:e, ...)
"   cmd      : string - resolved command ('e' or 'edit'), used to rebuild
"              the command line on Enter (nav_complete_text)
"   bang     : bool  - v:true if a '!' follows the command (":e!")
"   root     : string - project root detected for this session
"   query    : string - last analyzed path fragment
"   results  : list   - [{'path': ..., 'score': ...}] sorted by desc score
"   selected : number - current index in results (for navigation)

" Returns a fresh copy of the default state (session not yet qualified).
function! s:new_state() abort
  return {
        \ 'active': v:false,
        \ 'cmd': '',
        \ 'bang': v:false,
        \ 'root': '',
        \ 'query': '',
        \ 'results': [],
        \ 'selected': 0,
        \ }
endfunction

" Initialized with the same shape as s:new_state() as soon as the plugin
" loads, NOT an empty dictionary: fuzzyedit#state()/fuzzyedit#debug() can
" legitimately be called before the very first command-line session
" (CmdlineEnter), for example from :FuzzyEditStatus right after
" installing the plugin. An empty dictionary would make any dotted
" access (s:state.root) crash with E716.
let s:state = s:new_state()

" Last timing of fuzzyedit#update() (see fuzzyedit#debug() and
" :FuzzyEditStatus). Purely informational, never affects the plugin's
" behavior -- used only for performance diagnostics.
let s:last_timing = {}

" v:true while accept() is replaying the completed command line via
" feedkeys() (see accept() below). Enter completes the text by doing
" "\<C-u>" . full_path . "\<CR>": Vim reinserts that string into the
" command line one character at a time, which fires CmdlineChanged for
" every intermediate substring exactly like real typing would. Without
" this guard, update() would treat each of those intermediate states as
" a brand new query, re-run a full cache search and reopen/repaint the
" popup on partial versions of the path we just chose, immediately
" before CmdlineLeave closes it -- the visible multi-redraw "blinking"
" on Enter. Reset in stop() (CmdlineLeave), i.e. once the replayed
" command line has actually been submitted.
let s:replaying = v:false

" Number of entries actually shown in the popup (bounded by
" g:fuzzyedit_max_results): this is the valid navigation range for
" nav_next()/nav_prev()/nav_complete_text(), never the full
" len(s:state.results) (which can be much larger than what is visible).
function! s:displayed_count() abort
  return min([len(s:state.results), get(g:, 'fuzzyedit_max_results', 15)])
endfunction

" Called on CmdlineEnter. We don't yet know whether the typed command is
" one we care about (the command buffer is empty at this point): we just
" reset the state. The actual qualification happens in update().
function! fuzzyedit#start() abort
  let s:state = s:new_state()
endfunction

" Called on CmdlineChanged on every keystroke.
" IMPORTANT: read-only use of getcmdline()/getcmdpos(). NEVER call
" setcmdline() here, it is forbidden by the Vim documentation for this
" event (undefined behavior / risk of event recursion). The navigation
" functions (nav_next, nav_complete_text, ...) are called from keyboard
" mappings, NOT from this event: that is what authorizes them to modify
" the command line (via feedkeys in cmdline.vim), unlike update().
"
" `a:1` (optional) allows injecting a test command line without actually
" being in cmdline mode: this makes the function trivially testable with
" simple calls like `call fuzzyedit#update('e src/ma')`. In normal
" operation (from the autocommand), no argument is passed and
" getcmdline() is used.
function! fuzzyedit#update(...) abort
  if s:replaying
    " See s:replaying above: ignore every CmdlineChanged fired while
    " accept() is replaying the completed path, until CmdlineLeave.
    return
  endif

  let l:cmdline = get(a:000, 0, getcmdline())
  let l:parsed = fuzzyedit#cmdline#parse(l:cmdline)

  if !l:parsed.matched
    " No longer (or not) a watched command: close any open popup and
    " go back to the inactive state, without recomputing anything.
    if s:state.active
      call fuzzyedit#popup#close()
      let s:state = s:new_state()
      " popup_close() alone leaves stale pixels on screen: unlike a
      " normal buffer redraw, Vim does not repaint the (now empty)
      " popup area on its own right after CmdlineChanged fires here,
      " so the suggestion list visually lingers over the command line
      " until some unrelated redraw happens to occur. Same reasoning
      " as the explicit `redraw` already done in nav_next()/nav_prev()
      " below, just triggered from the parsing side instead of a
      " keyboard mapping.
      redraw
    endif
    return
  endif

  " First qualifying keystroke of the session: detect the project root
  " only once per session (avoids a repeated scan on every character
  " typed, cf. cache.vim which also memoizes per root).
  if !s:state.active
    let s:state.active = v:true
    let s:state.root = fuzzyedit#project_root()
  endif

  let l:previous_query = s:state.query
  let l:previous_results = s:state.results
  let l:new_query = l:parsed.arg

  " --- Incremental narrowing ---------------------------------------------
  " When the query GROWS while keeping the same prefix (the normal case
  " when the user types without backtracking: "m" -> "ma" -> "mai"), any
  " file candidate for the new query necessarily already matched the
  " previous query: a subsequence match for "mai" trivially implies a
  " match for its prefix "ma" (just ignore the last retained position).
  " The reverse is false (a file that matched "ma" does not necessarily
  " match "mai"), which is why this is only valid for a query that GROWS,
  " never one that shrinks.
  "
  " In this specific case, we can therefore rerun fuzzy#search() on the
  " (small) result of the previous search instead of rescanning the
  " whole cache (potentially tens of thousands of files): the starting
  " set is already filtered, often several orders of magnitude smaller
  " by the 2nd or 3rd keystroke. The score itself is always recomputed
  " in full for the complete query (never reused as-is): only the
  " search UNIVERSE is reduced, never the scoring logic itself.
  "
  " As soon as this isn't the case (deletion, prefix change, first query
  " of the session after a CmdlineEnter, empty previous query) we fall
  " back unconditionally to the full cache: correctness before
  " optimization.
  let l:can_narrow = !empty(l:previous_query)
        \ && len(l:new_query) > len(l:previous_query)
        \ && l:new_query[: len(l:previous_query) - 1] ==# l:previous_query

  if l:can_narrow
    let l:universe = map(copy(l:previous_results), {_, r -> r.path})
  else
    let l:universe = fuzzyedit#cache#get(s:state.root)
  endif

  " Diagnostic timing (see fuzzyedit#debug() and :FuzzyEditStatus):
  " negligible cost (one extra reltime() per keystroke), but lets us
  " determine on a user's machine whether a slowdown comes from the
  " SEARCH itself (universe too large, narrowing inactive) or from
  " SOMEWHERE ELSE (popup, redraw, another plugin on CmdlineChanged,
  " etc.) without needing to reproduce the issue.
  let l:t_search = reltime()

  let s:state.cmd = l:parsed.cmd
  let s:state.bang = l:parsed.bang
  let s:state.query = l:new_query
  let s:state.results = fuzzyedit#fuzzy#search(l:new_query, l:universe)
  " The query changed: the old selected index no longer makes sense
  " (the candidates at that position may have changed entirely), so we
  " always go back to the best match.
  let s:state.selected = 0

  let l:search_ms = float2nr(round(reltimefloat(reltime(l:t_search)) * 1000.0))
  let l:t_popup = reltime()

  " popup#update() already handles every case: creates the popup if it
  " didn't exist yet, closes it if results is empty, otherwise updates
  " its content -- a single call site is enough here.
  call fuzzyedit#popup#update(s:state.results, s:state.selected)
  " Explicit redraw for the same reason as the one in the "no longer a
  " watched command" branch above: when results becomes empty this call
  " closes the popup, and without a redraw the now-empty popup area
  " stays visually stale on screen until an unrelated redraw happens.
  " Harmless no-op cost otherwise (popup content already up to date).
  redraw

  let s:last_timing = {
        \ 'root': s:state.root,
        \ 'query': l:new_query,
        \ 'narrowed': l:can_narrow,
        \ 'universe_size': len(l:universe),
        \ 'result_count': len(s:state.results),
        \ 'search_ms': l:search_ms,
        \ 'popup_ms': float2nr(round(reltimefloat(reltime(l:t_popup)) * 1000.0)),
        \ }
endfunction

" Called on CmdlineLeave: closes an open popup and cleans up the state.
function! fuzzyedit#stop() abort
  call fuzzyedit#popup#close()
  let s:state = s:new_state()
  let s:replaying = v:false
endfunction

" Detects the project root by walking up the tree from the current
" buffer's directory (or getcwd() if the buffer is unnamed / does not
" correspond to a file on disk), looking for a marker
" (g:fuzzyedit_root_markers). Falls back to getcwd() if no marker is
" found before the filesystem root.
"
" `a:1` (optional): forced starting directory, to allow deterministic
" unit tests without depending on the real current buffer.
function! fuzzyedit#project_root(...) abort
  let l:dir = get(a:000, 0, '')
  if empty(l:dir)
    let l:bufdir = fnamemodify(bufname('%'), ':p:h')
    let l:dir = (!empty(bufname('%')) && isdirectory(l:bufdir)) ? l:bufdir : getcwd()
  endif

  let l:markers = get(g:, 'fuzzyedit_root_markers', [])
  let l:previous = ''

  " fnamemodify(dir, ':h') on '/' (or 'C:\' on Windows) returns the same
  " value: that's our stop condition for the upward walk.
  while l:dir !=# l:previous
    for l:marker in l:markers
      let l:candidate = l:dir . '/' . l:marker
      if isdirectory(l:candidate) || filereadable(l:candidate)
        return l:dir
      endif
    endfor
    let l:previous = l:dir
    let l:dir = fnamemodify(l:dir, ':h')
  endwhile

  return getcwd()
endfunction

" Exposes the internal state read-only. Used by the navigation mappings
" (cmdline.vim) and by tests.
function! fuzzyedit#state() abort
  return s:state
endfunction

" Gathers the information useful to diagnose a slowdown: detected root,
" backend/duration/file count of the last cache scan for this root, and
" timing of the last update() (size of the search universe actually
" scanned, whether narrowing was active, time spent in scoring vs in the
" popup). Used by :FuzzyEditStatus -- see |fuzzyedit-troubleshooting|.
function! fuzzyedit#debug() abort
  let l:root = get(s:last_timing, 'root', s:state.root)
  return {
        \ 'root': l:root,
        \ 'cache': fuzzyedit#cache#info(l:root),
        \ 'last_update': s:last_timing,
        \ }
endfunction

" --- Navigation (Down/Ctrl-N/Tab, Up/Ctrl-P/Shift-Tab) ----------------------
" Move the current selection and refresh the popup. No effect if no
" result is displayed (called only when fuzzyedit#popup#is_visible() is
" true, see cmdline.vim).
"
" IMPORTANT: these functions are called from `cnoremap <expr>` mappings
" (see cmdline.vim#on_next()/on_prev()/on_tab()/on_shift_tab()), NOT from
" CmdlineChanged. Vim only redraws the screen (and thus the popup)
" automatically AFTER CmdlineChanged events -- not after evaluating an
" <expr> mapping, which merely returns a string to be "typed". Without
" the explicit `redraw` below, the selection would change correctly
" internally (the right file does end up opening on Enter) but the
" displayed highlight would stay frozen on the old line until some other
" reason triggers a screen redraw -- hence the systematic `redraw` right
" after popup_update() here.
function! fuzzyedit#nav_next() abort
  let l:count = s:displayed_count()
  if l:count == 0
    return
  endif
  let s:state.selected = (s:state.selected + 1) % l:count
  call fuzzyedit#popup#update(s:state.results, s:state.selected)
  redraw
endfunction

function! fuzzyedit#nav_prev() abort
  let l:count = s:displayed_count()
  if l:count == 0
    return
  endif
  let s:state.selected = (s:state.selected - 1 + l:count) % l:count
  call fuzzyedit#popup#update(s:state.results, s:state.selected)
  redraw
endfunction

" Combines a project root and a relative path (as stored in the cache,
" cf. cache.vim) into a path ready to be inserted into :edit.
"
" The cache stores paths RELATIVE TO THE PROJECT ROOT, but the user may
" have typed :e from a working directory DIFFERENT from that root
" (buffer opened from a subdirectory, project opened somewhere other
" than its root, etc.): :edit always resolves its relative arguments
" against the current working directory (cwd), never against the
" project root. We must therefore:
"   1. rebuild an absolute path (root + relative path);
"   2. re-simplify it relative to the cwd when possible (':.'), to keep
"      a short display in the command line rather than a full absolute
"      path -- exactly what a user would type by hand if they already
"      knew the file.
"
" `a:1` (optional): forced cwd, to make the function testable without
" depending on the Vim process's real :cd (fnamemodify(x, ':.') always
" uses the real current working directory, which would make this
" impossible to test deterministically without this override).
function! fuzzyedit#resolve_path(root, relpath, ...) abort
  let l:absolute = simplify(fnamemodify(a:root, ':p') . a:relpath)
  if a:0 == 0
    return fnamemodify(l:absolute, ':.')
  endif
  let l:cwd = simplify(fnamemodify(a:1, ':p'))
  if l:absolute[: len(l:cwd) - 1] ==# l:cwd
    return l:absolute[len(l:cwd) :]
  endif
  return l:absolute
endfunction

" Builds the complete command line matching the currently selected
" entry (used only by Enter, cf. cmdline.vim#on_cr()). Returns an empty
" string if no selection is available (nothing to complete).
function! fuzzyedit#nav_complete_text() abort
  if s:displayed_count() == 0
    return ''
  endif
  let l:relpath = s:state.results[s:state.selected].path
  let l:target = fuzzyedit#resolve_path(s:state.root, l:relpath)
  return s:state.cmd . (s:state.bang ? '!' : '') . ' ' . fnameescape(l:target)
endfunction

" Enter handling (cf. cmdline.vim#on_cr(), the only caller). Builds the
" completed command line, closes the popup right away (rather than
" waiting for the CmdlineLeave triggered by the replayed <CR> below),
" flips s:replaying so the CmdlineChanged events fired while the text is
" being retyped are ignored by update() (see s:replaying above), then
" replays the completed line followed by <CR> to actually submit it.
" Returns the string cmdline.vim#on_cr() must return to Vim ('' here:
" the effect already happened through feedkeys()/popup#close()).
function! fuzzyedit#accept() abort
  let l:newline = fuzzyedit#nav_complete_text()
  if empty(l:newline)
    return "\<CR>"
  endif
  call fuzzyedit#popup#close()
  let s:replaying = v:true
  call feedkeys("\<C-u>" . l:newline . "\<CR>", 'n')
  return ''
endfunction
