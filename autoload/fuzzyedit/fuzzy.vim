" autoload/fuzzyedit/fuzzy.vim
" Fuzzy scoring engine.
"
" Pure module: no dependency on the plugin's state, no disk access.
" Input = a query + a list of paths. Output = a list of results sorted
" by descending score.
"
" --- Performance note -------------------------------------------------
" The very first version of this file was written in plain legacy
" Vimscript, and was far too slow: ~0.5ms per scored file, i.e. more
" than 11 seconds to filter 21,000 files on EVERY keystroke. Cause: the
" legacy Vimscript interpreter, with no compilation.
"
" The hot core (the scoring loop, called once per file in the cache) is
" therefore written in Vim9 (the `:def` keyword), which is COMPILED to
" bytecode on its first call. Measured on this machine: the same
" algorithm goes from 11.3s to about 0.1s on 21,000 files (~110x),
" by compiling not just the score computation but also the collection
" loop and the sort: no part of the hot loop falls back to the legacy
" interpreter between two files.
"
" IMPORTANT: this file does NOT start with `vim9script`. It remains an
" ordinary legacy autoload file, which keeps the historical public API
" (fuzzyedit#fuzzy#score(), fuzzyedit#fuzzy#search()) callable exactly
" as before from the rest of the plugin -- no other file had to be
" changed to benefit from the speedup. Only the internal s:-prefixed
" functions (never exposed) are declared with `:def`. Inside a legacy
" file, `:def` functions calling each other must be addressed explicitly
" by their scope (s:Name), otherwise Vim cannot resolve them at compile
" time -- unlike a full vim9script file, which also resolves global/
" imported names.

" Characters considered "word" separators in a path: a character right
" after one of them starts a new segment (directory, word inside a
" snake_case or kebab-case filename).
let s:separators = '/_-. '

" ===========================================================================
" Compiled core (Vim9 :def) -- private, never called from outside this
" file. See fuzzyedit#fuzzy#score()/search() below for the stable public
" API.
" ===========================================================================

" True if `char` is an ASCII lowercase letter.
def s:IsLower(char: string): bool
  return char =~# '^[a-z]$'
enddef

" True if `char` is an ASCII uppercase letter (used together with
" s:IsLower to detect camelCase boundaries: a lowercase letter followed
" by an uppercase one, like the F in "myFile").
def s:IsUpper(char: string): bool
  return char =~# '^[A-Z]$'
enddef

" Computes the fuzzy score of `item` for the query `query`.
" Returns -1 if `query` does not match `item` (its characters must
" appear in order, not necessarily consecutively, in item -- classic
" subsequence matching).
" Returns an integer >= 0 otherwise, higher = better match.
"
" The score favors, in this order of importance:
"   1. consecutive characters (bonus growing with the length of the
"      run: "abc" typed in one go beats "a-b-c" scattered around)
"   2. word/path-segment starts (right after /, _, -, ., space, or a
"      camelCase boundary, and the very start of the path)
"   3. proximity to the start of the path (the first character matches
"      early)
"   4. short paths (all else equal, the shortest one wins)
"
" Algorithm: a single linear pass over `item` (a greedy subsequence
" search), so O(path length), and even less since it stops as soon as
" all query characters are found. No dynamic programming: faster, at
" the cost of a result that can be slightly suboptimal on very
" ambiguous cases -- a deliberate trade-off in favor of speed, see the
" performance note at the top of this file.
"
" Known and accepted limitation: character-by-character indexing works
" per BYTE (item[i]), which is correct and fast for ASCII paths (the
" vast majority of code repositories). A path containing multi-byte
" characters (UTF-8, accents...) can produce a slightly incorrect
" score; fixing this properly would be expensive for the common case,
" for a rare benefit.
" Core of the score computation, shared by fuzzyedit#fuzzy#score()
" (single, isolated call) and by s:SearchImpl() (called in a loop over
" the whole cache).
"
" `q`/`case_sensitive`/`qlen` are already normalized by the caller: when
" filtering tens of thousands of files for a single query, this
" normalization (smart-case check + tolower of the query) must be
" computed only ONCE for the whole search, never repeated per file --
" this is what motivated extracting this separate function.
def s:ScoreCore(q: string, case_sensitive: bool, qlen: number, item: string): number
  var it = case_sensitive ? item : tolower(item)

  var qi = 0
  var ilen = len(item)
  var score = 0
  var consecutive = 0
  var last_matched_pos = -1
  var first_matched_pos = -1

  var i = 0
  while i < ilen && qi < qlen
    if it[i] ==# q[qi]
      var bonus = 10

      if last_matched_pos == i - 1
        # Consecutive with the previous match: bonus growing with the
        # length of the current run.
        consecutive += 1
        bonus += consecutive * 15
      else
        consecutive = 0
      endif

      if i == 0
        # Very start of the path: the best possible start.
        bonus += 20
      else
        var prev = item[i - 1]
        if stridx(s:separators, prev) >= 0
          # Start of a path segment or word (after /, _, -, ., space).
          bonus += 18
          if prev ==# '/'
            # Extra bonus specific to the start of a path segment,
            # more significant than a plain word separated by _/-.
            bonus += 10
          endif
        elseif s:IsLower(prev) && s:IsUpper(item[i])
          # camelCase boundary ("myFile" -> the F in File).
          bonus += 12
        endif
      endif

      if first_matched_pos < 0
        first_matched_pos = i
      endif

      score += bonus
      last_matched_pos = i
      qi += 1
    endif
    i += 1
  endwhile

  if qi < qlen
    # Incomplete subsequence: the query does not match the item.
    return -1
  endif

  # Minor bonus: a first match close to the start of the path is
  # preferable.
  score += max([0, 20 - first_matched_pos])

  # Short-path bonus: acts as a tie-breaker, never dominating the
  # relevance bonuses above.
  score += max([0, 40 - ilen])

  return score
enddef

" Normalizes `query` (smart-case + optional tolower) and delegates to
" s:ScoreCore(). Used for a single, isolated score (fuzzyedit#fuzzy#
" score()); s:SearchImpl() does this normalization only once for a
" whole search rather than calling this function per file.
def s:ScoreImpl(query: string, item: string): number
  if len(query) == 0
    return 0
  endif
  if len(query) > len(item)
    return -1
  endif
  var case_sensitive = query =~# '\u'
  var q = case_sensitive ? query : tolower(query)
  return s:ScoreCore(q, case_sensitive, len(q), item)
enddef

" Compares two {'path', 'score'} results for sorting: descending score
" first, then shortest path, then alphabetical order -- for a fully
" deterministic result (Vim's sort is not guaranteed to be stable).
def s:CompareResults(a: dict<any>, b: dict<any>): number
  if a.score != b.score
    return b.score - a.score
  endif
  var la = len(a.path)
  var lb = len(b.path)
  if la != lb
    return la - lb
  endif
  if a.path ==# b.path
    return 0
  endif
  return a.path <# b.path ? -1 : 1
enddef

" Filters + scores + sorts `items` against `query`, entirely in
" compiled Vim9 (no round-trip to the legacy interpreter between two
" files in the cache): this is what makes the performance difference.
" The query normalization (smart-case + tolower) is computed only ONCE
" here, then reused for every file via s:ScoreCore().
def s:SearchImpl(query: string, items: list<string>): list<dict<any>>
  var case_sensitive = query =~# '\u'
  var q = case_sensitive ? query : tolower(query)
  var qlen = len(q)

  var results: list<dict<any>> = []
  for it in items
    if qlen > len(it)
      continue
    endif
    var sc = s:ScoreCore(q, case_sensitive, qlen, it)
    if sc >= 0
      add(results, {'path': it, 'score': sc})
    endif
  endfor
  sort(results, s:CompareResults)
  return results
enddef

" ===========================================================================
" Public API -- stable, called by the rest of the plugin (fuzzyedit.vim).
" These are plain legacy wrappers around the compiled core above.
" ===========================================================================

function! fuzzyedit#fuzzy#score(query, item) abort
  return s:ScoreImpl(a:query, a:item)
endfunction

" Filters and sorts `items` (list of paths) against `query`.
" Returns a list of dictionaries {'path': ..., 'score': ...}, sorted by
" descending score, excluding entries with a score of -1.
"
" If `query` is empty, all items are returned with a neutral score (0),
" in their original order (the cache is already sorted alphabetically
" by cache.vim): this is the "default" list shown before the user
" starts filtering.
"
" `prev` (optional, unused for now): reserved for a future incremental
" narrowing when `query` extends the previous query. The signature is
" already stable so it won't break callers once that optimization is
" added.
function! fuzzyedit#fuzzy#search(query, items, ...) abort
  if empty(a:query)
    return map(copy(a:items), {_, path -> {'path': path, 'score': 0}})
  endif
  return s:SearchImpl(a:query, a:items)
endfunction
