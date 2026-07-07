# revl — a Lisp REPL / mini-IDE

`revl` is a dedicated Common Lisp environment built on
[**revision**](https://github.com/lispnik/revision), a CLOS-native text-mode UI
framework.  It uses an in-process, micros-style backend (the same operation set
Lem gets from micros, but built directly on SBCL built-ins with zero external
deps), so the running TUI *is* the Lisp image being driven.  The IDE is a
Turbo-Vision-style desktop — a menu bar, a status bar, and overlapping windows: a
REPL with a SLIME `sldb`-style debugger, a syntax-highlighting editor, a git-aware
project tree, an object inspector, an HTML browser, and code-intelligence tools
(completion, paredit, source navigation, tracing / stepping / profiling, and a
live HyperSpec lookup).

## Requirements

- **SBCL** — uses SBCL-specific introspection, threads, and `sb-introspect`.
- The **[revision](https://github.com/lispnik/revision) framework** (the CLOS-native
  toolkit) cloned as a sibling project at `../revision` (it is not on
  ocicl).  `./systems/revision` symlinks to it so ASDF resolves it from this
  project; `make` also adds the project tree to the source registry, so the build
  works without any global config:

  ```sh
  git clone git@github.com:lispnik/revision.git   # alongside this revl checkout
  ```
- The **[revision-term](https://github.com/lispnik/revision-term)** widget (also a
  sibling, `./systems/revision-term`) backs the **Terminal** window (Tools ▸ Terminal).
  It is the one component with third-party requirements — **CFFI**,
  `cffi-callback-closures`, and the **libvterm** C library (e.g. `brew install libvterm`).
- The **[revision-manpage](https://github.com/lispnik/revision-manpage)** widget (a
  sibling checkout) backs the **Man page** window (Tools ▸ Man page…).  It shells out to
  **`mandoc`** (ships with macOS/BSD; `apt install mandoc` on Linux) to convert a manual
  page to HTML and renders it with revision's HTML view; no Lisp dependencies.
- The **[revision-hexdump](https://github.com/lispnik/revision-hexdump)** widget (a
  sibling checkout) backs the **Hex editor** window (Tools ▸ Hex editor…): an editable
  offset·hex·ASCII view of any file; no external dependencies.
- **Otherwise, no external Lisp dependencies** — the rest of the IDE builds and runs on
  SBCL + revision alone.  revl's framework-agnostic Lisp logic lives in a shared
  `revl-logic` system, and the binary is dumped from the `revl` system.

## Building & running

```sh
make            # build ./revl
make run        # build and run
make test       # headless SBCL/IDE-feature suite (36) + end-to-end pty smoke suite (46)
make clean      # remove the binary and this project's fasl cache

# or directly, without make (from this directory):
sbcl --eval '(asdf:make :revl)' --quit     # -> ./revl
```

`asdf:make` uses the `program-op` / `build-pathname` / `entry-point` settings in
`revl.asd` to dump a self-contained `./revl` binary that runs on the **revision**
CLOS-native framework (reactive metaclass, CLOS event dispatch, named commands +
keymaps, a layout DSL, MOP persistence, a worker→UI bridge — see
[`../revision/revision/README.md`](../revision/revision/README.md)).

## Structure

revl is an **application on the revision toolkit** — revision is a reusable framework
that knows nothing about Lisp IDEs; revl is what you build on it.  Three parts:

- **`ide/`** — the IDE windows (REPL, `sldb` debugger, object inspector, git project
  tree, browsers, editor menus, HyperSpec / docs) in revl's own **`revl`** package, on
  top of `revision`'s public API.  They join the desktop through revision's window /
  menu **plugin registry** (`*window-builders*` / `*extra-menus*`), so the toolkit stays
  IDE-agnostic.
- **`logic/`** — [`revl-logic`](revl-logic.asd), the framework-agnostic Lisp logic (sexp
  analysis for paredit, the in-process REPL backend, git/grep, profiling, the CLHS map)
  — no view code, testable on its own.
- **`src/main.lisp`** — installs that logic into `revision`'s editor extension hooks and
  launches the desktop.

The demo below tours the IDE: the full menu bar, the **threaded REPL** (background
evaluation + Tab-completion), a syntax-highlighting **editor** with a line-number
gutter, **rename-symbol**, the **call tree**, live **colour-theme** switching, the
**emoji palette**, and **window tiling** — with the rest (paredit, source navigation,
the debugger, tracing / stepping / profiling, the inspector, HyperSpec) detailed below:

![revl on the revision kernel: a tour of the threaded REPL, Tab-completion, the editor with a line-number gutter, rename-symbol, the call tree, colour-theme switching, the emoji palette, and window tiling](media/tv2-ide.gif)

At a glance — the tools it ships (each detailed below):

- **REPL** — threaded per-listener evaluation, **completion** (prefix +
  **fuzzy**), CL history variables, sticky package, arglist echo, persistent
  history / transcript / session, and **presentations** (double-click a printed
  result to inspect the live object).
- **Debugger** (SLIME `sldb`-style, across the worker thread) — restart menu, a
  **readable backtrace** (machinery hidden, calls with arguments, `file:line`,
  condition header, inline locals, search), and **frame ops**: return-from /
  restart / disassemble / eval-in / view-source.  **Break on entry** stops a
  function's next call here; `break`/`cerror`/`invoke-debugger` route here too.
- **Navigate** — **go-to-definition** with an **Alt-,** pop-back stack,
  **cross-reference** (who calls / references / binds / sets / macroexpands),
  and class / package / ASDF-system / function browsers.
- **Understand** — a drillable **object inspector** (back *and* forward history),
  an **interactive macro stepper** (expand any subform in place), describe /
  documentation / disassemble, a **call tree** (watch functions; live
  args/results as a navigable tree), statistical + deterministic **profilers**,
  a **thread monitor**, and HyperSpec lookup/browsing plus the SBCL, ECL, and
  CCL manuals.  Any object list or table — the package / class / ASDF-system
  browsers, the package table, the thread monitor — opens its focused row's object
  in the inspector with **Alt-I**.
- **Edit** — Lisp syntax highlighting + `cl-indent` auto-indent, **eval** and
  **compile** the defun/region (compile with **navigable compiler notes**),
  in-buffer **symbol completion**, **comment region**, **paredit** structural
  edits (wrap / splice / raise / transpose / slurp / barf both ways / kill sexp),
  **rename symbol**, **reorder args**, templates, and
  find / replace / incremental-search.

**REPL core**

- **Threaded evaluation (one worker thread per listener).** Each REPL window
  evaluates on its own `sb-thread` worker, so the UI never freezes: output
  streams into the transcript live as it is produced, multiple REPL windows run
  concurrently, and a long/infinite computation can be aborted with **Ctrl-C**
  (Edit ▸ Interrupt eval).
- **Tab completion** against the current package; multiple candidates pop up in a
  list, a common prefix is filled in, and `pkg:`/`pkg::` tokens are supported.
  When nothing prefix-matches it falls back to **fuzzy (flex) completion** —
  `mvb` → `multiple-value-bind` — ranked by word-boundary alignment.
- **Per-listener history variables & sticky package.** `*`/`**`/`***`,
  `/`/`//`/`///`, `+`/`++`/`+++` follow standard CL REPL semantics and are kept
  per window (bound with `progv` around evaluation, so concurrent REPLs never
  clobber one another or the global `cl:*`); `(in-package …)` sticks and the
  prompt reflects the current package.
- **Persistent history, transcript, file loading.** Input history is saved to
  `~/.revl_history`; Up/Down recall it, **Ctrl-R** searches it.  File ▸ Load
  file (F7) loads a `.lisp` file with captured output; Save transcript writes the
  buffer; Save/Restore session reopens your REPL windows and their packages.
- **Arglist echo & a live status line.** As you type, the status line shows the
  operator's lambda list (via `sb-introspect`), e.g. `(mapcar function list
  &rest more-lists)`; otherwise it shows the current package, thread count and
  busy state.
- **Presentations.** Every value the REPL prints is a live object, not just
  text: **double-click a result** to open the inspector on the actual object and
  drill into its structure (SLY-style).
- **Live self-modification.** The IDE is itself a Common Lisp image, so you can
  redefine it *from its own REPL* with no rebuild or restart — `handle-event`,
  `draw`, commands, palettes are all ordinary generic functions.  For example,
  a `defmethod handle-event :before` on the application class binds a brand-new
  key (here Alt-G) that fires on the very next keystroke:

  ![Bind a new key live: a defmethod typed at the REPL makes Alt-G pop a dialog instantly](media/repl-live-keybinding.gif)

  ![Double-click a printed REPL result to inspect the live object](media/repl-presentations.gif)

**The debugger (SLIME `sldb`-style, across the worker-thread boundary)**

A signalled error pops an "Error — pick a restart" dialog while the worker stays
parked with its stack live:

- Pick a restart to invoke it on the worker's own stack; **`USE-VALUE` /
  `STORE-VALUE`** prompt for a Lisp form so the computation can *resume* past the
  error, not just unwind.  Abort returns to a fresh prompt.
- **Backtrace** opens a frame browser built for reading.  It **hides
  debugger/runtime machinery** by default (the signalling chain, the evaluator,
  the worker loop), shows the **condition** in its header, and **marks (►) and
  focuses** the frame that *signalled* the error; **`a`** toggles the full stack.
  Each row is a **call form with its arguments** — e.g. `(parse "oops")`, via
  `sb-debug`'s `frame-call` — followed by a **`file:line`** locator.  **`/`** and
  **`n`** search the stack.

  ![Readable backtrace: machinery hidden, condition header, calls with arguments and file:line, `a` reveals the full stack](media/backtrace-readable.gif)

- **Inline locals.** Press Enter on a frame to expand its **local variables**
  (captured live via `sb-di`) right under it; Enter on a local opens the **object
  inspector** on its value, which you can **drill into** (a `TOutline` tree —
  slots, conses, vectors, hash-table entries, arbitrarily deep).

  ![Expanding a frame's locals inline; eval a form in the frame with `x`](media/backtrace-locals.gif)

- **Frame ops** in the backtrace browser:
  - **`r`** *returns from the frame* — unwind the worker's live stack to that
    frame and make it return a value you type (`sb-debug`'s
    `unwind-to-frame-and-call`), so you can step past a bad call without
    restarting the computation.
  - **`c`** *restarts the frame* — unwind to it and re-run it with the same
    arguments (best-effort; arguments can be optimized away).
  - **`v`** *views the source* — jump to the frame's definition in an editor.
  - **`d`** *disassembles* the frame's own (live) function — works for methods,
    closures and anonymous code, not just named functions.
  - **`x`** *evaluates a form in the frame* — with the frame's locals bound.

  ![Returning a value from a frame: the computation resumes past the error](media/debugger-frame-ops.gif)

  ![Restarting a frame: a transient failure succeeds when the frame is re-run](media/backtrace-restart-frame.gif)

  ![Jump to a frame's source with `v`](media/backtrace-goto-source.gif)

**Code-intelligence tools (Lisp menu)**

- **Inspect `*`** (F8) or **Inspect expr…** — a `TOutline` tree of any value;
  Enter (or `i`) on a node drills into that value (re-rooting in place, with a
  breadcrumb), **Backspace** goes back and **`f`** goes forward again, and `g`
  jumps to its definition (for symbols, classes and named functions).

  ![Inspecting a value and drilling into a nested element](media/inspector-drill.gif)

  Inspecting a **symbol** shows its whole namespace — name, home package, value,
  function / macro / special-operator, the class it names, plist and
  documentation — each cell drillable:

  ![Inspecting a symbol: value, plist and documentation as a drillable tree](media/inspect-symbol.gif)
- **Object clipboard** (Window ▸ Object clipboard) — a LispWorks-style place to
  park **live objects** (not text) and move them between tools.  **Clip** the
  REPL's last value (`*`) from the Lisp menu / right-click, or press **`c`** in
  an Inspector to clip the object under inspection (drill in first to clip a
  nested value).  The clipboard window lists each object by type and printed
  value; on a row, **Enter/`i`** re-inspects it, **`d`** removes it, **`p`**
  pastes it back into the REPL as a live `(clip N)` reference that evaluates to
  the very same object, and **`/`** fuzzy-filters the list.  Clipped objects are held by strong references (so they
  stay alive — and pinned against GC — until you remove them).

  ![Object clipboard: clip a live value, inspect it, paste it back as (clip N)](media/object-clipboard.gif)
- **Macroexpand** — an interactive macro stepper (Emacs `macrostep` /
  SLIME-style).  The form is navigable: put the cursor on **any** subform and
  expand *just that macro, in place* (`e`), so the surrounding code stays put and
  reads as ordinary source.  `Tab` jumps to the next expandable position, `m`
  fully expands the subform, `M` expands every macro in the form
  (`sb-cltl2:macroexpand-all`), `u` undoes and `0` resets, and `o`/`c` send the
  result to an editor / the clipboard.

  ![Interactive macro stepper: expand a macro at the cursor in place, Tab to the next, M to expand all](media/macroexpand-step.gif)

  ![Expanding every macro in the form at once with `M` (macroexpand-all)](media/macroexpand-all.gif)

- **Describe**, **Documentation**, **Disassemble** — into scrollable windows.
- **Trace / Untrace** — toggle `trace` on a function (output streams into the
  REPL as it is called); Untrace-all lists and clears the traced set.
- **Call tree** (Lisp ▸ Profile/trace ▸ Call tree) — *watch* functions
  (`sb-int:encapsulate`) so every call/return is recorded with its **live** args
  and result, shown as a depth-indented tree; each row is a presentation (Enter
  inspects the arguments or the result).

  ![Watching a function records a navigable, depth-indented call tree](media/call-tree.gif)

- **Break on entry** (Lisp ▸ Profile/trace) — arm a function so its next call
  stops in the cross-thread debugger (navigable backtrace + frame ops; CONTINUE
  resumes).  `(break)`, `cerror` and `invoke-debugger` route there too.

  ![Break on entry: the next call stops in the debugger; CONTINUE resumes](media/break-on-entry.gif)

- **Cross-reference** (Lisp ▸ Navigate) — who **calls / references / binds / sets
  / macroexpands** a symbol, in one navigable results window (Enter jumps to the
  site, **`/` fuzzy-filters** the hits); plus go-to-definition with an **Alt-,**
  pop-back stack.

  ![Who-sets: find every place a variable is assigned, jump to the source](media/xref-who-sets.gif)
- **Symbol browser** (Apropos) — a modeless, LispWorks-style window with a live
  **Filter** field and a list of matching symbols, each tagged with what it is
  shown in sortable **Package / Symbol / Type** columns (function / macro /
  generic-function / variable / constant / class / package).  Click a header or
  press `s` / `r` to sort; press Enter to (re)load the candidate pool with
  apropos, then **type in the Filter to narrow it live with fuzzy (flex)
  matching** — `outstr` finds `WITH-OUTPUT-TO-STRING`.  Enter describes the
  focused symbol, `i` inspects it, and the window stays open.

One `FUZZY-FILTER-MIXIN` powers fuzzy filtering everywhere it appears — the
Symbol Browser's live Filter field, every modal picker (window list, Classes,
Packages, …), the `/`-filtered results windows (cross-reference, profiler,
method browser, …) and `/`-pruned trees (class hierarchy, call graph, project
source).  Press **`/`** to start a fuzzy search; it never interferes with other
keys:

![Fuzzy filtering across the IDE: the Symbol Browser, the window-list and Classes/Packages/Systems pickers, the cross-reference and method-browser results windows, and the class-hierarchy tree — all driven by one mixin, started with /](media/fuzzy-tour.gif)
- **Class browser** — a **fuzzy-filtered** list of every class (type to filter, e.g.
  `strout` finds `STRING-OUTPUT-STREAM`); Enter shows its precedence list / slots /
  subclasses, and per-row keys act on the focused class: **`d`** describes it, **`i`**
  inspects the class object (Alt-I too), **`g`** goes to its source.  (The Function
  browser shares the same **`d`** / **`g`** keys.)
- **Package browser** — a fuzzy-filtered list (`/` to filter); OK / Enter
  switches the listener's current package, Inspect opens it in the inspector.
- **ASDF System browser** (load on Enter), **Load buffer** (evaluate an editor
  window into the REPL).
- **HyperSpec lookup** — opens the browser on the Common Lisp HyperSpec page
  for the symbol at the cursor (resolved via the HyperSpec's `Map_Sym.txt`);
  prompts, prefilled, when there is no symbol or it is not a standard one.
- **Profiler** — statistical (`sb-sprof`) and deterministic (`sb-profile`).
  Runs on the worker thread so the UI stays live, then shows the results in a
  sortable `TTableView` grid (Self% / Cumul% / Samples / Function — click a
  header or press `s`/`r` to re-sort, **`/` to fuzzy-filter by name**); **Enter**
  jumps to a function's source and **`g`** opens the call-graph as a `TOutline`
  tree (which, like the class-hierarchy and project-source trees, also takes
  **`/`** to prune to matching nodes and their ancestors).

![The revl statistical profiler: sortable results table and call-graph outline](media/profiler.gif)

![The class browser: Goto def jumps to source, Inspect opens the object inspector](media/class-browser.gif)

**Editing & windows**

- **Lisp syntax highlighting** in editor windows — comments, strings, `#\chars`
  and `:keywords` are coloured, and the paren matching the one at the cursor is
  highlighted.  Editor windows use the classic Turbo Vision **blue** background
  (the REPL keeps its input colours).

  ![Classic blue editor with Lisp syntax highlighting and a selection](media/blue-editor.gif)  **Auto-indent** follows Emacs `cl-indent`: per-operator specs
  give each form's distinguished arguments a deeper indent and the body two
  columns, ordinary calls align under their first argument, binding/literal and
  quoted/backquoted lists align under their first element, `loop` clauses align
  under the first clause (a `when`/`if` clause body indents two further), and
  user macros with a `&body` argument are indented like special forms (looked up
  live in the image).  **Tab** re-indents the current line (or the
  selected lines) — or, when the cursor follows a symbol, **completes** it (see
  below); **Alt-Q** re-indents the whole top-level form.  **Undo /
  redo** (Undo = **Alt+Bksp** or Ctrl-Z, Redo = Ctrl-Y; also on the Edit menu and
  the right-click context menu).
- **Text selection** — drag with the mouse, or hold **Shift** with any
  navigation key (Left/Right, Up/Down, Home/End, PgUp/PgDn, and Ctrl-Left/Right
  by word) to extend the selection; a plain navigation key collapses it.
  **Select all** (Ctrl-A, also on the Edit and context menus).  The selection
  is drawn as a clear reverse-video highlight, and **Cut / Copy / Paste**
  (the CUA keys **Shift+Del / Ctrl+Ins / Shift+Ins**, with Ctrl-X/C/V as a fallback,
  or the Edit / context menus) and typing operate on it.  The
  clipboard is shared, so you can copy in one window and paste into another.

  ![Shift with navigation keys extends the (reverse-video) text selection](media/shift-selection.gif)

  ![Edit ▸ Select all highlights the whole buffer; typing replaces it](media/select-all.gif)

  ![Copy a mouse selection in one window and paste it into another](media/copy-paste.gif)

![Lisp auto-indent and Alt-Q reflow in an editor window](media/auto-indent.gif)

  Typing a `loop` clause by clause (no leading spaces) shows the `cl-indent` `loop`
  rule live: `for` / `when` / `else` / `finally` clauses align under the first clause,
  and a `when` / `else` clause body (the `collect …`) indents two columns further.

  ![LOOP auto-indent: for/when/else/finally clauses align under the first clause; when and else clause bodies indent two columns further](media/loop-indent.gif)

![Lisp syntax highlighting in an editor window](media/syntax-highlight.gif)
- **Eval from an editor** — Lisp ▸ Eval defun (the top-level form at the cursor)
  and Eval region (the selection) submit into a REPL.
- **Compile with navigable notes** (SLIME `C-c C-c`) — Lisp ▸ Compile defun (the
  form at the cursor) or Compile buffer compiles *without loading* and lists the
  compiler warnings/notes in a window; **Enter on a note jumps to the offending
  source** (located precisely by matching the symbol named in the message), and
  **`/` fuzzy-filters** the notes.

  ![Compile the form at point and jump to each compiler note](media/compile-defun-notes.gif)

- **Symbol completion in editor buffers** — **Tab** after a symbol prefix
  completes it against the buffer's package (a popup picker for multiple
  candidates), reusing the REPL's completion backend.

  ![Tab completion and comment toggling in an editor buffer](media/editor-productivity.gif)

- **Comment region** (Edit ▸ Comment region) toggles `;;` over the selected lines
  or the current line.
- **Structural editing** (Edit ▸ Structural) — paredit-style **wrap** the form at
  the cursor in `()`, **splice** (remove the enclosing parens), **raise** (replace
  the enclosing form with the one at point), **transpose** (swap the sexp at point
  with its sibling — works on args and `let` bindings), **slurp / barf** in both
  directions (the form absorbs / expels a sexp at either end), and **kill sexp**
  (delete the form at point).

  ![Slurp pulls the next form in; barf pushes the last form out](media/paredit-slurp-barf.gif)

- **Rename symbol** (Edit ▸ Rename symbol) — whole-token rename across every open
  editor buffer, with a preview of the occurrences and a confirm before applying.
  Defaults to **code only** (skips strings and comments) and consults the running
  image (`who-calls` / `who-references` / `who-binds` / `who-sets`) to warn when
  other, unopened files also reference the symbol.

  ![Rename a symbol across the buffer with a preview and confirm](media/rename-symbol.gif)

- **Reorder args** (Edit ▸ Reorder args) — reads a function's lambda list from the
  running image, asks for a new order of its required parameters (by name or
  1-based index), then rewrites the positional arguments at every direct call site
  in the open buffers, with a preview and confirm.  `apply` / `funcall` / `#'`
  uses and the definition site are left untouched.
- **Insert template** (Edit ▸ Insert template) — `defun` / `defclass` /
  `defmethod` / `loop` / `handler-case` / … skeletons, indented to the cursor.
- **Go-to-definition pop-back** — **Alt-.** jumps to a definition; **Alt-,** pops
  back to where you came from (a navigation stack across jumps).  Source paths
  are resolved even when the binary has been moved away from its sources.

  ![Go to definition jumps to the symbol's source file](media/jump-to-source.gif)
- **Find / Find-next** (Ctrl-F / Ctrl-L) in the focused REPL transcript *or
  editor window*, with **case-sensitive / whole-word / backward** options, plus
  **Replace** — all-at-once or **query-replace** (confirm each match).
  **Incremental search** (type-to-jump, Down for next), **Go to line**, and a
  **word-wrap** toggle round out the editor.

  ![Incremental search in an editor window](media/isearch.gif)

  ![Find and Replace in an editor window](media/find-replace.gif)

  **Right-click context menu**,
  **open a file in an editor window** via a reusable file dialog — type a path or
  browse: Enter on a directory descends into it, Enter on `..` goes back up, Enter
  on a file opens it.
- **Editor gutter** — file editor windows carry a left margin with optional
  **line numbers** (Options ▸ Line numbers; the current line is highlighted) and
  a **git diff** mark on each line added (green bar), changed (yellow bar), or
  deleted (red mark) relative to git `HEAD`.  Signs recompute when the file is
  loaded or saved, and refresh on idle so external git operations (commit,
  checkout, stage) show up too.  Files outside a repository show just the line
  numbers.

  ![Editor gutter: line numbers plus added / changed / deleted git marks](media/git-gutter.gif)
- **Scroll bars on both axes** — the editor, REPL and text windows carry a
  vertical scroll bar on the right and a horizontal one along the bottom (right
  of the editor's position indicator); long unwrapped lines scroll sideways and
  the proportional thumb tracks the view.  The same goes for the **table**,
  **list**, **outline** and **HTML** windows — and the **modal pickers**, whose
  bar sits on the list's bottom edge, above the OK/Cancel buttons, so a long
  window title or class name scrolls into view.  A wide table, long list item or
  deep tree scrolls horizontally, dropping the leftmost column/text and revealing
  the rightmost.

  ![A long line scrolls sideways; the horizontal scroll bar's thumb tracks the view](media/horizontal-scrollbar.gif)

  ![Scrolling a wide table sideways: the Package column slides off as Type comes into view](media/table-hscroll.gif)

  ![Scrolling a list sideways: long method labels slide left to reveal their trailing specializer](media/list-hscroll.gif)

  ![Scrolling a modal picker: a long window-list title slides to reveal the rest, the buttons staying put](media/picker-hscroll.gif)
- **Options:** theme picker (`TColorDialog`), pretty-print toggle, eval-timing
  toggle (`; N ms`), auto-close parens, **line numbers**, and a **DOS mouse
  cursor** — an experimental reverse-video software pointer that follows the
  mouse the way Turbo Vision drew it on text-mode displays (it asks the terminal
  for hover motion via `?1003h`; most modern terminals still draw their own
  arrow on top, which there is no portable way to hide).

  ![Experimental DOS-style software mouse cursor following the pointer](media/dos-mouse.gif)
- **Thread monitor** (F9, Window ▸ Threads) lists the worker threads with
  Refresh / Kill; new REPL (F2), Clear (F3), Tile (F4), Cascade (F5), Next (F6),
  Close (Window ▸ Close), Help (F1).
- **Project manager** (Window ▸ Projects, **Alt-P**) — a persistent, git-aware,
  multi-root file explorer (the IDE "sidebar").  Add any number of project roots
  (**A**, a directory picker); each becomes an expandable tree of its files.
  - **Git-aware file list.** Files come from what **git tracks** (`git ls-files`)
    plus **untracked-but-not-ignored** files (`ls-files --others`), so build
    artifacts and ignored files never appear; a non-git directory falls back to
    every file on disk.  Each file carries an open/closed bullet (● open in an
    editor, ○ not) and a status tag — **`[M]`** modified, **`[+]`** staged,
    **`[?]`** untracked, **`[L]`** loaded into the image — and a matching row
    tint; folders containing changes are tinted too.
  - **Lazy + tidy.** Directories load their children **on first expand**, so the
    tree scales to large repos; directories with `.lisp` files expand by default
    while doc / asset directories stay folded.  **`/`** fuzzy-filters the whole
    tree (auto-expanding matches), and **S** cycles the file sort order
    **name → type → recent**.
  - **Open & evaluate.** **Enter** opens (or focuses) the file in an editor;
    **O** opens every file under a node; **L** loads / **C** compiles-and-loads
    the file into the running image.  **Reveal current file** (Window menu)
    expands the tree to whatever the focused editor is showing.
  - **File operations** (single keys, or a **right-click** context menu):
    **N** new file, **K** new folder, **M** rename, **D** delete (folders
    recursively, with a confirm) — refusing to touch an item that is open in an
    editor, or a project root.
  - **Find in files.** **F** greps the focused root (`git grep`, else
    `grep -rnI`) and lists matches in a fuzzy-filterable picker; choosing one
    jumps to that file and line.
  - **Git status.** **`g`** (or right-click ▸ Git status) opens the Magit-style **Git
    status** window for the project root that owns the focused item — stage / unstage /
    diff / commit there.  With several roots, it operates on whichever root the selection
    belongs to.
  - **Persistent & live.** Roots **and which folders are expanded** persist to
    `~/.revl_projects`; the window reopens itself on startup, single-instance
    (Alt-P focuses it).  It auto-refreshes on idle, so files created/changed
    outside the IDE (and git state) show up on their own — like the editor's git
    gutter.  **R** removes a root from the list (files on disk untouched), **G**
    rescans now.  (Distinct from File ▸ Open System…, which browses one ASDF
    system's component tree.)

  ![The project manager in action: two repos as roots, git status badges, lazy expand, sort, find-in-files, new file and reveal](media/project-manager.gif)
- **Numbered windows** — each window is assigned the lowest free number 1–9
  (shown in its frame, classic TV style); **Alt-1…9** jumps straight to that
  window.
- **Zoom** (F5) toggles the active window between its size and the full desktop;
  **Size/Move** (Ctrl-F5) enters interactive keyboard move (arrows) / resize
  (Shift+arrows), Enter or Esc to finish.
- **Window list** (Window ▸ List, Alt-0) — a picker of every open window
  (numbered, the active one marked); press **`/`** to fuzzy-filter the list, Enter
  / OK raises and focuses the chosen window, like the classic Turbo Vision IDE's
  Alt-0.  (The same `/`-to-filter mixin powers every modal picker — snippet
  inserter, method / trace / profiler choosers, …)
- **Close** (Window ▸ Close, Alt-F3, or the **[✕]** box) closes the active window; a
  modified editor first prompts Save / Discard / Cancel so you don't lose unsaved changes
  — and for a never-saved buffer, choosing Save brings up the Save As dialog.  **Esc**
  dismisses *transient* windows (pickers, output, dialogs) but never silently discards an
  editor: on a clean editor it does nothing, and on an unsaved one it raises the same
  Save/Discard/Cancel prompt.  Close all prompts per unsaved editor.

![Window ▸ Close prompts to save; an unsaved buffer gets a Save As dialog](media/close-confirm.gif)

![Window list (Alt-0): pick any open window to raise it](media/window-list.gif)
- **HyperSpec browser** (Help ▸ HyperSpec / browse…) — a `THtmlView` hypertext
  control that renders the simple, CSS/JS-free HTML used by references like the
  Common Lisp HyperSpec.  Tab / Shift-Tab move between links, Enter (or a click)
  follows one, and a Back / Forward history is kept — Ctrl-B (or Backspace) goes
  Back, Ctrl-F goes Forward, Ctrl-R reloads (Alt-←/→ work too where the terminal
  sends them).  Back / Forward (and the history list) restore the scroll position
  you had on each page, so returning to a long document lands where you left off
  — even for `#anchor` jumps within a single page.  `/` searches the page
  (find-in-page) with `n` / `N` to jump
  between highlighted hits.  Help ▸ Browser history pops up the
  visited-page list (current marked) so you can jump straight to any of them.
  Remote pages are fetched with `curl` (no in-image TLS needed); local files
  are read directly.  The Help menu also opens the online SBCL, ECL, and CCL
  manuals in the same browser.

The **Open** dialog has a live type-ahead **Filter** (it narrows the list as you
type and auto-selects the first match, so Enter opens it), a current-directory
**breadcrumb**, and a **Hidden**-files toggle.

![Open in editor: the type-ahead Filter narrows the list; Enter opens the file into an editor](media/open-in-editor.gif)

![Browsing directories in the file dialog: the breadcrumb path, "../", and a Hidden-files toggle](media/file-dialog-nav.gif)

**Saving** is a distinct dialog: a **Name** field pre-filled with a suggested
filename, the active file **mask shown as a hint** (`(*.lisp)`), a **New folder**
button, and an **overwrite confirmation** before it replaces an existing file.

![Save dialog: the (*.lisp) mask hint, a suggested file name, and overwrite confirmation](media/file-dialog-save.gif)

- **Emoji palette** (Tools ▸ Emoji palette) — a read-only, scrollable list of
  emoji, each labelled with its Unicode name straight from SBCL's `CHAR-NAME`.
  Type to filter by name (`heart`, `rocket`, …); **Enter** or a click copies the
  glyph to the revision clipboard (paste with Ctrl-V) and, via **OSC 52**, to the
  terminal's system clipboard so you can paste it into any other app.

![Emoji palette: filter by Unicode name and copy a glyph to the clipboard](media/emoji-palette.gif)
- **Terminal** (Tools ▸ Terminal) — a real terminal window inside the IDE, backed by the
  reusable **[revision-term](https://github.com/lispnik/revision-term)** widget: it runs a
  child process (your `$SHELL`, `vi`, `top`, …) on a pseudo-terminal, emulates it with
  **libvterm**, and renders the live screen into a revision view — full 24-bit colour,
  text styles, wide CJK/emoji.  **Ctrl-\\** closes it; **Shift-PgUp/PgDn** scrolls the
  scrollback.

  ![The Terminal window: a live shell inside revl running ls, a coloured git log, and uname / sbcl --version](media/terminal.gif)
- **Man page** (Tools ▸ Man page…) — a manual-page viewer, backed by the reusable
  **[revision-manpage](https://github.com/lispnik/revision-manpage)** widget: it shells out
  to **`mandoc -T html`** to convert a page and renders it with the HTML view.  Prompts for
  a page (`grep`, `printf 3`, or the `man`-style `3 printf`); **SEE ALSO** cross-references
  are clickable and reload the referenced page in place, and section anchors scroll.
- **Hex editor** (Tools ▸ Hex editor…) — an editable hex view of any file, backed by the
  reusable **[revision-hexdump](https://github.com/lispnik/revision-hexdump)** widget: the
  classic offset·hex·ASCII columns, edited **in place** (Tab switches the hex/ASCII pane,
  hex digits or printable keys overwrite the byte, Ctrl-S saves — the file keeps its size).
- **Git status** (Tools ▸ Git status) — a Magit-style, keyboard-driven view of the working
  tree: the current branch in the title and the changes grouped into **Staged** /
  **Unstaged** / **Untracked** sections, each file expandable to its diff.  Keys act on the
  focused file: **`s`** stage, **`u`** unstage, **`k`** discard (with confirm), **`c`**
  commit (prompts for a message), **`g`** refresh, and **Enter** expands/collapses the diff.
  Open it for the default project root from the Tools menu, or **for any project root from
  the Project manager** (press **`g`**, or the Git chip / right-click ▸ Git status) — it
  operates on the root that owns the focused item.  Single-instance: re-opening re-targets,
  raises, and refreshes it.  The git porcelain lives in `revl-logic` (over plain `git`), so
  there is no new dependency.

![Browsing the Common Lisp HyperSpec in the THtmlView control](media/hyperspec.gif)

![HyperSpec lookup of the symbol at the cursor](media/hyperspec-lookup.gif)

![Starting from the HyperSpec index and following a link](media/hyperspec-index.gif)

![Help ▸ SBCL manual opens the SBCL User Manual in the browser](media/sbcl-manual.gif)

![Back / Forward through the browser history](media/browser-history.gif)

![Back / Forward restore your scroll position in a long document](media/browser-back-scroll.gif)

![The Browser history window — jump straight to any visited page](media/browser-history-window.gif)

## Notes

`asdf:make` dumps a standalone executable; run `make clean` to remove the binary
and this project's fasl cache.

Jump-to-source (go-to-definition, xref, compiler notes) uses the source pathnames
SBCL recorded at build time (via `sb-introspect`), so those features resolve when the
binary runs alongside the sources it was built from.

The mouse works throughout: click/drag a scroll bar, double-click a list item,
drag a title bar, drag the bottom-right corner to resize, click `[×]`/`[↑]`, and
the wheel scrolls.  **F10** opens the menu bar (or **Alt+letter**), **Alt-1..9**
select a window, **Alt-X** quits, and **resizing the terminal** reflows the UI.

## License

MIT.  Built on the [revision](https://github.com/lispnik/revision) framework.
