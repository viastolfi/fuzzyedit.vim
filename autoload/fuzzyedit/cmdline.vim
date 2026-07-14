" autoload/fuzzyedit/cmdline.vim
" Command-line parsing + keyboard glue for the popup.
"
" This file contains two clearly distinct families of functions:
"
"   - parse(): PURE, no I/O, no side effect, no internal call to
"     getcmdline(). You pass it a string, it returns a structured
"     result. Trivially testable:
"       call fuzzyedit#cmdline#parse('e src/ma')
"
"   - the on_*() functions below: NOT pure, meant exclusively to serve
"     as the right-hand side of `cnoremap <expr>` mappings (see
"     plugin/fuzzyedit.vim). They have a deliberate side effect
"     (feedkeys(), closing the popup): this is the only place in the
"     plugin where modifying the command line is allowed and expected,
"     since it is never the CmdlineChanged event but a direct response
"     to a key pressed by the user.

" Analyzes `cmdline` (the raw content returned by getcmdline(), WITHOUT
" the ':' prompt character) and determines whether it is a watched
" command (g:fuzzyedit_commands, or `commands` if explicitly provided
" for tests).
"
" Returns a dictionary:
"   {'matched': v:false, 'cmd': '', 'bang': v:false, 'arg': ''}
" or, for example for 'e src/ma':
"   {'matched': v:true, 'cmd': 'e', 'bang': v:false, 'arg': 'src/ma'}
"
" `arg` is the path fragment already typed after the command (and its
" optional '!'), with leading/trailing extra spaces stripped.
"
" Vim accepts unambiguous abbreviations of a command (":e", ":ed",
" ":edi" and ":edit" all refer to :edit). We therefore consider a
" command to be watched as soon as the typed word is a prefix of at
" least one entry in the command list.
function! fuzzyedit#cmdline#parse(cmdline, ...) abort
  let l:commands = get(a:000, 0, get(g:, 'fuzzyedit_commands', ['e', 'edit']))
  let l:no_match = {'matched': v:false, 'cmd': '', 'bang': v:false, 'arg': ''}

  " Group 1 = command word (letters), group 2 = optional '!',
  " group 3 = argument (everything else, trailing spaces stripped by \s*$).
  let l:m = matchlist(a:cmdline, '^\s*\(\a\+\)\(!\?\)\%(\s\+\(.\{-}\)\)\?\s*$')
  if empty(l:m)
    return l:no_match
  endif

  let l:typed = l:m[1]
  " String comparison: explicitly convert to v:true/v:false rather
  " than returning the Number 0/1 produced by ==#.
  let l:bang = l:m[2] ==# '!' ? v:true : v:false
  let l:arg = l:m[3]

  for l:candidate in l:commands
    if len(l:typed) > 0 && len(l:typed) <= len(l:candidate)
          \ && l:candidate[: len(l:typed) - 1] ==# l:typed
      return {'matched': v:true, 'cmd': l:candidate, 'bang': l:bang, 'arg': l:arg}
    endif
  endfor

  return l:no_match
endfunction

" ===========================================================================
" Keyboard glue -- called only from `cnoremap <expr>` mappings.
"
" Principle shared by on_next()/on_prev()/on_tab()/on_cr()/on_esc(): if
" our popup is not shown, the pressed key has nothing to do with us
" (the user is typing some other command, browsing history, etc.) -- we
" then return the literal sequence of the original key, which Vim then
" processes normally, exactly as if our mapping didn't exist. If the
" popup is shown, we perform our own action and return an empty string
" (nothing to insert: the effect already happened via the function call
" or feedkeys()).
" ===========================================================================

" Moves the selection down (Down / Ctrl-N).
function! fuzzyedit#cmdline#on_next(fallback) abort
  if !fuzzyedit#popup#is_visible()
    return a:fallback
  endif
  call fuzzyedit#nav_next()
  return ''
endfunction

" Moves the selection up (Up / Ctrl-P).
function! fuzzyedit#cmdline#on_prev(fallback) abort
  if !fuzzyedit#popup#is_visible()
    return a:fallback
  endif
  call fuzzyedit#nav_prev()
  return ''
endfunction

" Tab: plain alias of Down/Ctrl-N (moves the selection down, WITHOUT
" touching the typed text or the command line). Many users naturally
" navigate with Tab rather than the arrow keys: might as well make it
" equivalent rather than forcing one specific key. Only Enter (on_cr(),
" below) completes the text AND opens the file: Tab never does anything
" but move the highlight.
function! fuzzyedit#cmdline#on_tab() abort
  if !fuzzyedit#popup#is_visible()
    return "\<Tab>"
  endif
  call fuzzyedit#nav_next()
  return ''
endfunction

" Shift-Tab: alias of Up/Ctrl-P, symmetrical with Tab above.
function! fuzzyedit#cmdline#on_shift_tab() abort
  if !fuzzyedit#popup#is_visible()
    return "\<S-Tab>"
  endif
  call fuzzyedit#nav_prev()
  return ''
endfunction

" Enter: replaces the typed text with the path of the selected file,
" then immediately submits the resulting command (the <CR> is part of
" the keys "replayed" by feedkeys, after the text replacement). This is
" the ONLY moment the command-line text is modified: Tab/Shift-Tab/
" arrows only ever move the highlight (see on_tab()/on_shift_tab()/
" on_next()/on_prev() above).
function! fuzzyedit#cmdline#on_cr() abort
  if !fuzzyedit#popup#is_visible()
    return "\<CR>"
  endif
  return fuzzyedit#accept()
endfunction

" Esc: closes only the popup, without leaving the command line. If the
" popup is not shown, aborts the command line (equivalent to a plain
" Escape typed by the user, see the NOTE inside about why <C-c> rather
" than <Esc> is actually returned to achieve that).
function! fuzzyedit#cmdline#on_esc() abort
  if !fuzzyedit#popup#is_visible()
    " NOTE: returning "\<Esc>" here would NOT abort the command-line.
    " Per `:help c_<Esc>`, <Esc> only aborts when directly typed by the
    " user; when it reaches the command line as the result of a mapping
    " (which is exactly our case: this whole function is the RHS of a
    " `cnoremap <expr> <Esc>`), Vim instead treats it like <CR> and
    " EXECUTES the typed command -- the very opposite of what a user
    " pressing Esc expects, and the actual cause of the reported bug
    " (the current buffer got replaced by whatever half-typed path was
    " on the command line). <C-c> has no such special case: it always
    " aborts the command-line, whether typed directly or replayed
    " through a mapping, so it's the correct fallback here.
    return "\<C-c>"
  endif
  call fuzzyedit#popup#close()
  return ''
endfunction
