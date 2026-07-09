" autoload/fuzzyedit/popup.vim
" Exclusive wrapper around Vim's popup_*() API.
"
" No other module in the plugin calls popup_create()/popup_settext()/
" popup_move()/popup_close() directly: everything goes through the
" functions below. This centralizes the popup id bookkeeping and lets us
" change the display implementation later without touching the rest of
" the code.

" Id of the currently open popup, 0 if none.
let s:popup_id = 0

" The command line always occupies the last screen line(s): nothing can
" be physically displayed "below" it. So we anchor the popup right ABOVE
" the cmdline (its bottom edge touches the cmdline's top edge): visually
" this gives the desired effect, a suggestion list anchored where the
" user is typing.
"
" Returns the popup_create()/popup_move() options {line, col, ...} to
" display `nb_lines` lines of width `width`.
function! s:geometry(nb_lines, width) abort
  " 'line' = screen line (1-indexed) of the popup's TOP edge.
  " The BOTTOM edge (line + nb_lines - 1) must land exactly on
  " &lines - &cmdheight, the line just above the cmdline.
  let l:line = &lines - &cmdheight - a:nb_lines + 1
  return {
        \ 'line': max([1, l:line]),
        \ 'col': 1,
        \ 'minwidth': a:width,
        \ 'maxwidth': a:width,
        \ 'minheight': a:nb_lines,
        \ 'maxheight': a:nb_lines,
        \ }
endfunction

" Builds the text lines shown in the popup: a "> " marker in front of
" the selected entry (visible even without colors), 2 spaces in front of
" the others, to keep all paths aligned.
function! s:build_lines(results, selected) abort
  let l:lines = []
  for l:i in range(len(a:results))
    let l:marker = l:i == a:selected ? '> ' : '  '
    call add(l:lines, l:marker . a:results[l:i].path)
  endfor
  return l:lines
endfunction

" Popup width needed to display `lines` without truncation, bounded
" between a readable minimum width and the screen width.
function! s:required_width(lines) abort
  let l:longest = 10
  for l:line in a:lines
    let l:longest = max([l:longest, strdisplaywidth(l:line)])
  endfor
  " -2 to leave a margin on the right edge of the screen.
  return min([l:longest, &columns - 2])
endfunction

" Highlights line `selected` (0-indexed) in the popup, via the popup
" window's internal cursor + the 'cursorline' option. This works on
" both Vim 8.2 and 9.x without depending on +textprop.
function! s:highlight_selection(selected) abort
  call win_execute(s:popup_id, 'call cursor(' . (a:selected + 1) . ', 1)')
endfunction

" Creates (or reuses) the popup to display `results`
" ([{'path': ..., 'score': ...}]), with entry `selected` (index into
" results) highlighted. No effect if `results` is empty (an existing
" popup is then closed: nothing to show).
function! fuzzyedit#popup#show(results, selected) abort
  if empty(a:results)
    call fuzzyedit#popup#close()
    return
  endif

  let l:max = get(g:, 'fuzzyedit_max_results', 15)
  let l:visible = a:results[: l:max - 1]
  let l:lines = s:build_lines(l:visible, a:selected)
  let l:width = s:required_width(l:lines)
  let l:opts = s:geometry(len(l:lines), l:width)

  let l:opts.cursorline = v:true
  let l:opts.wrap = v:false
  let l:opts.scrollbar = v:false
  let l:opts.zindex = 200
  " Non-focusable popup: it must never steal focus from cmdline mode,
  " or it would break user input.
  let l:opts.focusable = v:false

  if s:popup_id > 0
    call popup_close(s:popup_id)
  endif
  let s:popup_id = popup_create(l:lines, l:opts)
  call s:highlight_selection(a:selected)
endfunction

" Updates the text, size and highlight of an already-open popup without
" recreating it (avoids flicker on every keystroke). If no popup is
" open, behaves like show(). If `results` is empty, closes the popup.
function! fuzzyedit#popup#update(results, selected) abort
  if empty(a:results)
    call fuzzyedit#popup#close()
    return
  endif

  if s:popup_id <= 0
    call fuzzyedit#popup#show(a:results, a:selected)
    return
  endif

  let l:max = get(g:, 'fuzzyedit_max_results', 15)
  let l:visible = a:results[: l:max - 1]
  let l:lines = s:build_lines(l:visible, a:selected)
  let l:width = s:required_width(l:lines)
  let l:opts = s:geometry(len(l:lines), l:width)

  call popup_settext(s:popup_id, l:lines)
  call popup_move(s:popup_id, l:opts)
  call s:highlight_selection(a:selected)
endfunction

" Closes the popup if it is open. No effect if already closed.
function! fuzzyedit#popup#close() abort
  if s:popup_id > 0
    call popup_close(s:popup_id)
    let s:popup_id = 0
  endif
endfunction

" True if a popup is currently displayed. Used by the navigation
" mappings (Ctrl-N/Ctrl-P/Tab/Enter) to know whether they should act.
function! fuzzyedit#popup#is_visible() abort
  return s:popup_id > 0 ? v:true : v:false
endfunction
