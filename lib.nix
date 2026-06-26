# nixx — write raw bash (and node/ts/perl/...) inside pure Nix.
#
# Bodies live in Nix indented strings ('' ... ''). nixx reads each task/script
# body from SOURCE rather than evaluating it (see scanOpen + materializeRaw
# below), so a shell ${VAR}, a JS template `${x}`, a perl ${name} — anything in
# the ${} family — survives VERBATIM with no '' prefix. The one rule Nix imposes
# is a single line of ceremony at the call site:
#
#     with inputs.nixx.lib.for pkgs;   # un-prefixes the constructors AND defers
#                                  # Nix's static undefined-var check (any `with`
#                                  # makes the scope dynamic; the source-read
#                                  # body never forces it).
#
# Then ${VAR} is just shell. A literal ''${...} still works too (the escape is
# replayed). To inject an actual Nix value, use the explicit markers @nix(x)
# (raw) / @sh:q(x) (shell-quoted) — native Nix ${...} interpolation does NOT run
# in a source-read body (that's the whole point: ${} is the language's, not
# Nix's). To pass a value into a non-bash body, use `env`.
#
# A body built programmatically (`bash someVar`, not a literal ''...'') has no
# source to read, so it falls back to ordinary evaluation — there ${VAR} would
# need the old ''${VAR} escape. The guard tells the two apart automatically.
#
#   with inputs.nixx.lib.for pkgs;
#   tasks = mkTasks { vars = { inherit port; }; } {
#     dev = bash ''
#       for d in */; do echo "$d"; done       # */ ok, $d raw
#       echo "editor is ${EDITOR:-vi}"          # ${} needs NO '' prefix
#       npm run dev -- --port @nix(port)        # explicit Nix value
#       greet @sh:q(message)                    # shell-quoted Nix value
#     '' { env.NODE_ENV = "development"; cwd = "./frontend"; };
#     test = bash ''
#       cargo test --workspace
#     '';
#   };
let
  inherit (builtins)
    replaceStrings split filter isString isAttrs length elemAt concatStringsSep
    stringLength substring match head tail foldl' genList attrNames toString readFile;

  splitLines = s: filter isString (split "\n" s);
  nlCount = s: length (filter isString (split "\n" s)) - 1; # newlines in s
  isBlank = l: match "[[:space:]]*" l != null;
  chopNL = s:
    let n = stringLength s; in
    if n > 0 && substring (n - 1) 1 s == "\n" then substring 0 (n - 1) s else s;

  reverse = xs: genList (i: elemAt xs (length xs - 1 - i)) (length xs);
  dropStart = p: xs:
    if xs == [ ] then [ ] else if p (head xs) then dropStart p (tail xs) else xs;
  dropEnd = p: xs: reverse (dropStart p (reverse xs));

  # merge a list of attrsets left-to-right (rightmost keys win)
  mergeAttrs = xs: foldl' (a: b: a // b) { } xs;
  # { key = value; } only when value isn't null — keeps generated config clean
  optionalAttr = k: v: if v == null then { } else { ${k} = v; };

  # strip surrounding blank lines + common leading indentation
  dedentInfo = s:
    let
      trimmed = dropEnd isBlank (dropStart isBlank (splitLines s));
      io = l: stringLength (head (match "([[:space:]]*).*" l));
      nb = filter (l: !(isBlank l)) trimmed;
      mi = foldl' (a: l: let i = io l; in if a == null || i < a then i else a) null nb;
      mi' = if mi == null then 0 else mi;
      strip = l: if isBlank l then "" else substring mi' (stringLength l) l;
    in
    {
      text = if trimmed == [ ] then "" else concatStringsSep "\n" (map strip trimmed) + "\n";
      indent = mi'; # how many leading columns were stripped (for col remap)
    };
  dedent = s: (dedentInfo s).text;

  # How many leading lines dedent dropped (blank lines at the top of the body).
  leadingBlanks = s: length (splitLines s) - length (dropStart isBlank (splitLines s));

  # Given the file + the line where the attr is defined, find the line where
  # the body's FIRST non-blank content lives in the original source. This is
  # what shellcheck line 1 corresponds to. We read the source, scan from the
  # attr line for the opening '', then skip blank lines dedent would drop.
  bodyStartLine = file: attrLine: rawBody:
    let
      src = readFile file;
      srcLines = splitLines src;
      # 0-indexed slice from attrLine onward
      fromAttr = genList (i: elemAt srcLines (attrLine - 1 + i))
        (length srcLines - attrLine + 1);
      # find the line containing the opening ''  (relative to attrLine)
      hasOpen = l: match ".*''.*" l != null;
      openRel = foldl'
        (acc: i:
          if acc != null then acc
          else if hasOpen (elemAt fromAttr i) then i else acc)
        null
        (genList (i: i) (length fromAttr));
      openAbs = attrLine + (if openRel == null then 0 else openRel);
      # the '' might be at end of line (body starts next line) — assume next line
      firstBodyAbs = openAbs + 1;
    in
    firstBodyAbs + leadingBlanks rawBody;


  # ------------------------------------------------------------------
  # Reading a block body from SOURCE instead of evaluating it.
  #
  # Nix's hardest darkness: inside ''...'' (or "..."), ${VAR} is an
  # antiquotation, so a bare ${VAR} is a syntax/scope error unless the name is
  # bound in Nix. nixx defeats this by NEVER forcing the body: the thunk is left
  # untouched, and the literal text is recovered from the source file (readFile +
  # the attr's position from unsafeGetAttrPos). So a shell ${HOME}, a JS template
  # `${x}`, a perl ${name} — all survive verbatim.
  #
  # The remaining wall is Nix's STATIC undefined-variable check, which fires on
  # ${name} in a literal even when the string is never forced. That check is
  # deferred to runtime (i.e. never, for an unforced body) once the literal is
  # under a `with` — and `with inputs.nixx.lib.for pkgs;` is already that `with`. So
  # the full incantation is:
  #
  #     with inputs.nixx.lib.for pkgs;
  #     mkTasks { } { dev = bash '' echo ${HOME}; npm run dev ''; }
  #
  # The scanner below faithfully replays Nix's own indented-string escapes
  # (''' -> '', ''$ -> $, ''\n -> newline, ''\\ -> \) so the source-read body is
  # lexically an ordinary Nix string — just one that is never evaluated.

  # ---- the source-read guard ----
  # scanOpen finds where THIS attr's body '' opens, so a block built from a
  # literal `bash ''...''` is read from source (shell ${VAR} survives verbatim),
  # while a programmatic body (`bash someVar`, or a cross-file re-wrap inside a
  # writer) is left for ordinary evaluation. The rule: the body is the first ''
  # outside any `{ }` opts block, occurring BEFORE the `;` that terminates this
  # binding (at brace+paren depth 0). Parens are transparent so a parenthesized
  # `(bash ''...'')` still source-reads. Returns the '' offset
  # or null (no literal body → caller falls back to the evaluated .text).
  skipStr = s: n: i: # i just past opening "; returns past closing "
    if i >= n then i
    else
      let c = substring i 1 s; in
      if c == "\\" then skipStr s n (i + 2)
      else if c == "\"" then i + 1
      else skipStr s n (i + 1);
  skipLine = s: n: i: # skip a # comment to just past the newline
    if i >= n then i
    else if substring i 1 s == "\n" then i + 1
    else skipLine s n (i + 1);
  # bd = brace depth (opts), pd = paren/bracket depth. '' counts only at bd==0;
  # the terminating ; counts only at bd==0 && pd==0.
  scanOpen = s: start:
    let
      n = stringLength s;
      go = i: bd: pd:
        if i >= n then null
        else
          let c = substring i 1 s; c2 = if i + 1 < n then substring i 2 s else ""; in
          if c == "\"" then go (skipStr s n (i + 1)) bd pd
          else if c == "#" then go (skipLine s n (i + 1)) bd pd
          else if c2 == "''" && bd == 0 then i           # this attr's body
          else if c2 == "''" then go (i + 2) bd pd       # '' inside opts: skip, ignore
          else if c == "{" then go (i + 1) (bd + 1) pd
          else if c == "}" then go (i + 1) (bd - 1) pd
          else if c == "(" || c == "[" then go (i + 1) bd (pd + 1)
          else if c == ")" || c == "]" then go (i + 1) bd (pd - 1)
          else if c == ";" && bd == 0 && pd == 0 then null   # binding ends, no body
          else go (i + 1) bd pd;
    in
    go start 0 0;

  # scanSemi — like scanOpen, but returns the offset of the `;` that terminates
  # this binding (depth 0), skipping strings, `#` comments and `{ opts }`. A
  # rawsh body is sought AFTER this `;`, so multi-line `rawsh { opts };` works
  # (the attr position alone points only at the attr-name line).
  scanSemi = s: start:
    let
      n = stringLength s;
      go = i: bd: pd:
        if i >= n then null
        else
          let c = substring i 1 s; in
          if c == "\"" then go (skipStr s n (i + 1)) bd pd
          else if c == "#" then go (skipLine s n (i + 1)) bd pd
          else if c == "{" then go (i + 1) (bd + 1) pd
          else if c == "}" then go (i + 1) (bd - 1) pd
          else if c == "(" || c == "[" then go (i + 1) bd (pd + 1)
          else if c == ")" || c == "]" then go (i + 1) bd (pd - 1)
          else if c == ";" && bd == 0 && pd == 0 then i
          else go (i + 1) bd pd;
    in
    go start 0 0;

  # scan a ''...'' body starting just past the opening ''. Replays Nix escapes
  # and stops at the closing ''. Returns the literal body text.
  scanBody = src: i: acc:
    let n = stringLength src; in
    if i >= n then acc
    else if i + 1 < n && substring i 2 src == "''" then
      let after = substring (i + 2) 1 src; in      # char right after the two quotes
      if after == "'" then scanBody src (i + 3) (acc + "''")              # '''  -> ''
      else if after == "$" then scanBody src (i + 3) (acc + "$")          # ''$  -> $
      else if after == "\\" then # ''\X -> escape
        let
          e = substring (i + 3) 1 src;
          o =
            if e == "n" then "\n"
            else if e == "t" then "\t"
            else if e == "r" then "\r"
            else if e == "\\" then "\\"
            else e;
        in
        scanBody src (i + 4) (acc + o)
      else acc                                                            # bare '' -> close
    else scanBody src (i + 1) (acc + substring i 1 src);

  # given (file, line, col) from unsafeGetAttrPos, return the attr's raw body
  # text — or null if this binding has no literal '' (a programmatic body or a
  # cross-file re-wrap). Slice the source from the attr's line onward, start the
  # guard at the attr's column (so multiple attrs on one line don't bleed), find
  # this binding's opening '', scan to its close.
  rawBodyFromSource = file: line: col:
    let
      src = readFile file;
      lines = splitLines src;
      from = genList (i: elemAt lines (line - 1 + i)) (length lines - line + 1);
      suffix = concatStringsSep "\n" from;
      open = scanOpen suffix (col - 1);
    in
    if open == null then null else scanBody suffix (open + 2) "";

  # rawBodyFromComment — the escape-light *escape hatch*. A `rawsh` block has no
  # '' string; its body lives in the `#|`-prefixed Nix line-comments that follow
  # the attr. Nix never parses inside a comment, so the shell-only forms that the
  # parse-wall would otherwise force an '' onto (${#x} ${x[@]} ${x^^} ${x%pat}
  # ${arr[-1]} …) survive VERBATIM, with zero escaping. Line comments have no
  # closing delimiter, so unlike a `/* */` block they can never be cut short by a
  # `*/` glob in the shell. Returns the joined body, or null if no `#|` follows.
  rawBodyFromComment = file: line: col:
    let
      lines = splitLines (readFile file);
      total = length lines;
      # find the 0-based line index of this binding's terminating `;` by char-
      # scanning from the attr position (so `rawsh { opts };` over several lines
      # is handled); fall back to the attr line if no `;` is seen.
      from = genList (i: elemAt lines (line - 1 + i)) (total - line + 1);
      suffix = concatStringsSep "\n" from;
      n = stringLength suffix;
      semiOff = scanSemi suffix (col - 1);
      # From just past this binding's `;`, skip whitespace and ordinary `#`
      # comments; the body starts iff the next real token is `#|`. Any other
      # token (a sibling binding on the same line, real code) means this attr has
      # no body — so an empty `a = rawsh;` can never capture a sibling's `#|`,
      # even same-line, while a `## note` on the `;` line stays harmless.
      markAfter = i:
        if i >= n then null
        else
          let c = substring i 1 suffix; in
          if c == " " || c == "\t" || c == "\n" || c == "\r" then markAfter (i + 1)
          else if substring i 2 suffix == "#|" then i
          else if c == "#" then markAfter (skipLine suffix n (i + 1))
          else null;
      markOff = if semiOff == null then null else markAfter (semiOff + 1);
      startLine =
        if markOff == null then null
        else (line - 1) + nlCount (substring 0 markOff suffix);
      markRe = "([[:space:]]*)#\\|[[:space:]]?(.*)";
      isMark = i: i < total && match markRe (elemAt lines i) != null;
      bodyOf = i: elemAt (match markRe (elemAt lines i)) 1;
      collect = i: if isMark i then [ (bodyOf i) ] ++ collect (i + 1) else [ ];
    in
    if startLine == null then null else concatStringsSep "\n" (collect startLine);

  # rawBodyLine — the 1-based source line of a rawsh body's first `#|` (same scan
  # as rawBodyFromComment). Used for diagnostics: failure file:line should point
  # at the body, not the attr/opts line that bodyStartLine's `''`-search returns.
  rawBodyLine = file: line: col:
    let
      lines = splitLines (readFile file);
      from = genList (i: elemAt lines (line - 1 + i)) (length lines - line + 1);
      suffix = concatStringsSep "\n" from;
      n = stringLength suffix;
      semiOff = scanSemi suffix (col - 1);
      markAfter = i:
        if i >= n then null
        else
          let c = substring i 1 suffix; in
          if c == " " || c == "\t" || c == "\n" || c == "\r" then markAfter (i + 1)
          else if substring i 2 suffix == "#|" then i
          else if c == "#" then markAfter (skipLine suffix n (i + 1))
          else null;
      markOff = if semiOff == null then null else markAfter (semiOff + 1);
    in
    if markOff == null then null else line + nlCount (substring 0 markOff suffix);


  # ---- per-language safe quoting ----
  # Each turns a Nix value into a valid string LITERAL in the target language,
  # so interpolated values can't break out of the string or inject code.

  # bash / sh: POSIX single-quote.  it's -> 'it'\''s'
  shq = v: "'" + replaceStrings [ "'" ] [ "'\\''" ] (toString v) + "'";

  # If a var is a filesystem path, copy it into the store so the generated
  # script is reproducible (a bare path would point at the author's checkout
  # and break under `nix build`). Non-path values pass through unchanged.
  storeIfPath = name: v:
    if builtins.isPath v
    then builtins.path { path = v; name = baseNameOf (toString v); }
    else v;

  # Interpolation markers, longest-first so @sh:q( is matched before @nix(.
  #   @nix(x)  -> raw value (toString) — for paths/derivations/numbers
  #   @sh:q(x) -> bash/sh shell-quoted string literal — for arbitrary strings
  # To pass a value into a non-bash body, use `env` instead (see mkTasks).
  substVars = vars: text:
    let
      ks = attrNames vars;
      resolved = builtins.mapAttrs storeIfPath vars;
      # order matters: the quoted form (longer) before the bare @nix( form.
      froms = builtins.concatLists (map
        (k: [
          "@sh:q(${k})"
          "@nix(${k})"
        ])
        ks);
      tos = builtins.concatLists (map
        (k: [
          (shq resolved.${k})
          (toString resolved.${k})
        ])
        ks);
    in
    if ks == [ ] then text else replaceStrings froms tos text;

  # ---- block constructors ----
  # A block carries its language as `__lang`, so mkApps can
  # dispatch to the right builder. `mkBlock` is the shared core; the named
  # constructors below are sugar so the language reads naturally at the call
  # site: `nixx.bun ''...''`, `nixx.py ''...''`, etc.
  # keep rawBody so line-mapping can count blank lines dedent will drop,
  # and indent so col-mapping can re-add stripped leading columns.
  #
  # Per-app language options can be attached by CALLING the block as a function:
  #   validate = bun ''...'' { compile = true; };
  #   report   = uv  ''...'' { projectRoot = ./.; };
  #
  # This works via `__functor`: bash ''body'' returns a block that is also
  # callable, so `(bash ''body'') { opts }` (or without parens via Nix's
  # left-to-right application: `bash ''body'' { opts }`) merges opts top-level
  # WITHOUT ever forcing the body string. That avoids the core hazard:
  # builtins.isAttrs/builtins.typeOf are strict, and a body like ''echo ${HOME}''
  # under `with for pkgs;` throws when forced by a type check — but the body
  # thunk is kept lazy here and only overwritten by materializeRaw (source-read)
  # before anyone accesses it.
  mkBlock = lang: body:
    let
      d = dedentInfo body;
      block = {
        __sh = true;
        __lang = lang;
        # task-relevant defaults, so a bare block IS a complete task (opts are
        # merged on top via __functor — there is no separate `task` wrapper):
        env = { };
        cwd = null;
        deps = [ ]; # just-style prerequisite task names
        group = null; # group label for the runner's --list
        description = null; # one-line summary shown by the runner's --list
        inherit (d) text indent; rawBody = body;
        # calling the block as a function attaches per-block options, the one
        # idiom shared by mkApps and mkTasks:
        #   validate = bun ''...'' { compile = true; };          # mkApps opt
        #   deploy   = sh  ''...'' { env.E = "x"; cwd = ./d; };  # mkTasks opts
        # opts merge top-level; mkApps/mkTasks each read the keys they care
        # about. `packages` is global-only, so it is rejected here.
        __functor = _self: opts:
          if opts ? packages
          then throw "nixx: per-block `packages` is not supported; use mkApps { packages = [...]; } { … } (or writers.mkTasks { packages = [...]; } { … }) to set PATH globally."
          else block // opts;
      };
    in
    block;

  # mkRawBlock — like mkBlock but the body is sourced from `#|` comment lines
  # (see rawBodyFromComment), not a '' string. The `__rawsh` flag survives the
  # opts functor (block // opts), so `rawsh { deps = [ … ]; }` still works.
  mkRawBlock = lang:
    let
      block = {
        __sh = true;
        __lang = lang;
        __rawsh = true;
        env = { };
        cwd = null;
        deps = [ ];
        group = null;
        description = null;
        text = "";
        indent = 0;
        rawBody = "";
        __functor = _self: opts:
          if opts ? packages
          then throw "nixx: per-block `packages` is not supported; set it globally on mkApps/mkTasks."
          else block // opts;
      };
    in
    block;

  sh = mkBlock "bash"; # bash (default)
  bash = mkBlock "bash"; # alias of sh, reads naturally next to node/perl/...
  # rawsh — escape-free escape hatch: write the body in `#|` comment lines so
  # parse-wall forms (${#x} ${arr[@]} ${x^^} …) need no '' escape. See the
  # `rawBodyFromComment` note. Usage:
  #   process = rawsh;
  #     #| for f in ${FILES[@]}; do echo "${#f}: ${f^^}"; done
  rawsh = mkRawBlock "bash";
  py = mkBlock "python"; # python (lint: ruff)
  uv = mkBlock "python-uv"; # python + uv inline deps
  bun = mkBlock "bun"; # typescript/js via bun
  ts = mkBlock "typescript"; # typescript via tsx
  node = mkBlock "node"; # node (deps via Nix-supplied node_modules)
  deno = mkBlock "deno"; # deno (npm:/jsr: inline deps)
  perl = mkBlock "perl"; # perl ($VAR / ${VAR} survive source-read like bash)
  ruby = mkBlock "ruby";
  lua = mkBlock "lua";
  moonbit = mkBlock "moonbit"; # moonbit (compiled + run via moon)

  # parallel: declare that a set of named tasks should run concurrently.
  # The listed tasks are spawned as background subshells; the parallel task
  # waits for all of them and returns the first non-zero exit code (if any).
  # Supports deps / description / group / env opts via __functor, same as blocks.
  #
  #   dev = parallel [ "frontend" "backend" ];
  #   dev = parallel [ "frontend" "backend" ] { deps = [ "setup" ]; };
  parallel = tasks:
    let
      self = {
        __sh = true;
        __lang = "parallel";
        __parallel = true;
        parallel = tasks;
        text = "";
        rawBody = "";
        indent = 0;
        env = { };
        cwd = null;
        deps = [ ];
        group = null;
        description = null;
        __functor = _self: opts:
          if opts ? packages
          then throw "nixx: per-block `packages` is not supported; use mkApps { packages = [...]; } { … } (or writers.mkTasks { packages = [...]; } { … }) to set PATH globally."
          else self // opts;
      };
    in
    self;

  normalize = v:
    if isAttrs v && (v.__sh or false) then v
    else throw "nixx: value must be a nixx block or parallel task (e.g. nixx.sh ''...'', nixx.bun ''...'', nixx.parallel [ ... ])";

  # materializeRaw — read a block's body from SOURCE at `pos` (unsafeGetAttrPos)
  # instead of forcing the never-evaluated Nix string, so shell/JS ${VAR} in the
  # body survives verbatim. The guard (scanOpen) decides per block: a literal
  # `bash ''...''` is source-read; a programmatic body (`bash var`) or a
  # cross-file re-wrap (a writer's `{ main = block; }`) has no literal '' for
  # this binding, so `raw` is null and we keep the block for ordinary evaluation.
  # The body is UNSUBSTITUTED — callers apply @nix()/@sh:q() vars themselves.
  materializeRaw = pos: b:
    let
      raw =
        if pos == null then null
        else if (b.__rawsh or false) then rawBodyFromComment pos.file pos.line (pos.column or 1)
        else rawBodyFromSource pos.file pos.line (pos.column or 1);
    in
    if raw == null then b
    else
      let d = dedentInfo raw; in
      b // { inherit (d) text indent; rawBody = raw; };

  # ---- runner generation ----
  # defaultDeps: task names run before EVERY task (except the default-dep tasks
  # themselves), e.g. a `setup` task that exports NIX_CONFIG. Because the runner
  # is one bash process, an `export` in such a task persists into every later
  # task body and any child interpreter it spawns.
  # envCheckDefault is the global env-check mode (false | true) used as
  # the fallback for any task that doesn't set its own `envCheck` block opt.
  mkRunnerText = name: defaultDeps: full: envCheckHookText: envCheckDefault:
    let
      names = attrNames full;
      indentBody = t: concatStringsSep "\n"
        (map (l: if l == "" then "" else "  " + l) (splitLines (chopNL t)));
      # inside a function-wrapped task, a shebang is meaningless (not byte 0),
      # so we drop a leading #!... line to avoid a misleading dead comment.
      stripShebang = txt:
        let ls = splitLines txt; in
        if ls != [ ] && match "#!.*" (head ls) != null
        then concatStringsSep "\n" (tail ls)
        else txt;
      # how to run a task body of a given language from within the bash runner.
      # bash runs inline (indented to match the function); others are piped to
      # their interpreter via a heredoc. Heredoc bodies must NOT be re-indented
      # (Python is indentation-sensitive), so they're emitted at column 0.
      langRunner = lang: body:
        let
          eot = "NIXX_EOT_${name}";
          raw = chopNL body; # no extra indentation for heredoc content
          via = interp:
            "  ${interp} <<'${eot}'\n" + raw + "\n${eot}\n";
          # viaArgs: like via, but forwards the task's positional args ("$@") to
          # the interpreter. The cmd must already include the stdin flag (e.g. "-")
          # so that the interpreter reads the heredoc body as the script, not as a
          # filename, leaving "$@" to become the script's argv.
          viaArgs = cmd:
            "  ${cmd} \"$@\" <<'${eot}'\n" + raw + "\n${eot}\n";
        in
        if lang == "bash" || lang == "sh" then indentBody body + "\n"
        else if lang == "python" then viaArgs "python3 -"
        else if lang == "python-uv" then viaArgs "uv run --no-project -"
        else if lang == "node" then via "node --input-type=module"
        else if lang == "bun" then viaArgs "bun run -"
        else if lang == "typescript" then via "tsx"
        else if lang == "deno" then viaArgs "deno run -A -"
        else if lang == "perl" then viaArgs "perl -"
        else if lang == "ruby" then viaArgs "ruby -"
        else if lang == "lua" then viaArgs "lua -"
        else if lang == "moonbit" then
        # moonbit is compiled: write a minimal project to a temp dir and run via moon.
          let
            eot = "NIXX_EOT_${name}";
            modEot = "NIXX_MOD_${name}";
            pkgEot = "NIXX_PKG_${name}";
          in
          "  _nixx_moon_tmp=$(mktemp -d)\n"
          + "  trap 'rm -rf \"$_nixx_moon_tmp\"' RETURN\n"
          + "  mkdir -p \"$_nixx_moon_tmp/src/main\"\n"
          + "  cat > \"$_nixx_moon_tmp/moon.mod.json\" <<'${modEot}'\n"
          + "{\"name\":\"nixx-task\",\"version\":\"0.1.0\",\"source\":\"src\"}\n"
          + "${modEot}\n"
          + "  cat > \"$_nixx_moon_tmp/src/main/moon.pkg.json\" <<'${pkgEot}'\n"
          + "{\"is-main\":true}\n"
          + "${pkgEot}\n"
          + "  cat > \"$_nixx_moon_tmp/src/main/main.mbt\" <<'${eot}'\n"
          + raw + "\n${eot}\n"
          + "  ( cd \"$_nixx_moon_tmp\" && moon run src/main -- \"$@\" )\n"
        else via "cat"; # unknown: just echo it (safe fallback)
      fnFor = n:
        let
          t = full.${n};
          isParallel = t.__parallel or false;
          lang = t.__lang or "bash";
          isBash = lang == "bash" || lang == "sh";
          envLines = concatStringsSep ""
            (map (k: "  export ${k}=" + shq t.env.${k} + "\n") (attrNames t.env));
          cwdLine = if t.cwd == null then "" else "  cd -- " + shq t.cwd + "\n";
          # The runner is ONE bash process so env exports persist across tasks
          # (the point). cwd and shell options are volatile state we normalize at
          # each task's entry instead, so a dep's `cd` or `set +u` can't leak in:
          #   - re-assert strict mode for every bash body (always set -euo pipefail);
          #   - reset cwd to the runner's invocation dir before any per-task `cwd`.
          strictLine = if isBash then "  set -euo pipefail\n" else "";
          resetCwdLine = "  cd -- \"$_NIXX_CWD\"\n";
          # just-style deps: run each prerequisite task (once) before this body.
          # defaultDeps run first for every task, except the default-dep tasks
          # themselves (so they don't depend on each other / loop).
          deps = (if builtins.elem n defaultDeps then [ ] else defaultDeps) ++ (t.deps or [ ]);
          depsLines = concatStringsSep ""
            (map (dep: "  _nixx_run " + dep + "\n") deps);
          # run-once guard: a task body executes at most once per invocation.
          guard = "  case \" $_NIXX_DONE \" in *\" ${n} \"*) return 0 ;; esac\n"
            + "  _NIXX_DONE=\"$_NIXX_DONE ${n}\"\n";
          bodyRun = langRunner lang (stripShebang t.text);
          envCheckCall =
            let
              # per-task envCheck (true | false) overrides the global default;
              # bad values are rejected so typos fail loudly.
              # true  — always check before this task
              # false — check only when the runner is invoked with --env-check
              ecv = t.envCheck or envCheckDefault;
              alwaysCheck =
                if ecv == true then true
                else if ecv == false then false
                else throw "nixx: task '${n}' envCheck must be true | false";
            in
            if envCheckHookText != "" && isBash && !isParallel
            then
              let
                eot = "_NIXX_CHK_${name}_${n}";
                checkBody = chopNL (stripShebang t.text);
                callLines =
                  "  _nixx_env_check " + shq n + " <<'" + eot + "'\n"
                  + checkBody + "\n"
                  + eot + "\n";
              in
              if alwaysCheck then callLines
              else
                "  if [[ \"$_NIXX_ENV_CHECK\" == \"1\" ]]; then\n"
                + callLines
                + "  fi\n"
            else "";
          # parallel task: spawn each listed task in a subshell, wait for all.
          parallelFn =
            let
              pts = t.parallel;
              spawnLines = concatStringsSep ""
                (map (pt: "  ( task_${pt} ) & _nixx_pids+=($!)\n") pts);
              waitLine =
                if pts == [ ] then ""
                else "  for _p in \"$" + "{_nixx_pids[@]}\"; do wait \"$_p\" || _nixx_ret=$?; done\n";
            in
            "task_${n}() {\n"
            + guard
            + depsLines
            + envLines
            + "  local _nixx_pids=() _nixx_ret=0\n"
            + spawnLines
            + waitLine
            + "  return \"$_nixx_ret\"\n"
            + "}\n";
        in
        if isParallel then parallelFn
        else "task_${n}() {\n" + guard + depsLines + strictLine + envLines
          + resetCwdLine + cwdLine + envCheckCall + bodyRun + "}\n";
      # dispatcher used by needs: maps a task name to its function.
      dispatch = "_nixx_run() {\n  case \"$1\" in\n"
        + concatStringsSep "" (map (n: "    ${n}) task_${n} ;;\n") names)
        + "    *) echo \"unknown task: $1\" >&2; return 1 ;;\n  esac\n}\n";
      cases = concatStringsSep "\n" (map (n: "  ${n}) shift; task_${n} \"$@\" ;;") names);
      # `--list` output: `just`-style, descriptions aligned in a second column.
      # When any task has a `group`, output uses group headers instead of the
      # flat "available tasks:" header; tasks are padded per-group.
      descOf = n: full.${n}.description or null;
      groupOf = n: full.${n}.group or null;
      ungroupedNames = filter (n: groupOf n == null) names;
      hasAnyGroup = length ungroupedNames < length names;
      # unique groups in definition order
      allGroups = foldl'
        (acc: n:
          let g = groupOf n; in
          if g == null || builtins.elem g acc then acc
          else acc ++ [ g ]
        ) [ ]
        names;
      namesInGroup = g: filter (n: groupOf n == g) names;
      maxLenOf = ns: foldl' (a: n: let l = stringLength n; in if l > a then l else a) 0 ns;
      padNameIn = ns: n:
        let len = maxLenOf ns; in
        n + concatStringsSep "" (genList (_: " ") (len - stringLength n));
      listLineFor = padFn: n:
        let d = descOf n; in
        if d == null || d == ""
        then "  printf '  %s\\n' " + shq n
        else "  printf '  %s   %s\\n' " + shq (padFn n) + " " + shq d;
      groupSection = g:
        let
          gNames = namesInGroup g;
          padFn = padNameIn gNames;
        in
        "  printf '%s\\n' " + shq (g + ":") + "\n" +
        concatStringsSep "\n" (map (listLineFor padFn) gNames);
      ungroupedSection =
        let padFn = padNameIn ungroupedNames; in
        concatStringsSep "\n" (map (listLineFor padFn) ungroupedNames);
      # flat mode: all tasks in order, global padding, preceded by a header.
      # grouped mode: ungrouped tasks first (if any), then each group under its
      # header, sections separated by a blank line.
      listBody =
        if !hasAnyGroup then
          "    echo \"available tasks:\"\n" +
          concatStringsSep "\n" (map (listLineFor (padNameIn names)) names)
        else
          let
            sections =
              (if ungroupedNames != [ ] then [ ungroupedSection ] else [ ])
              ++ map groupSection allGroups;
          in
          concatStringsSep "\n  printf '\\n'\n" sections;
      # `--env-list <task>` reports the env a task requires (using the same
      # classifier as env-check, in list mode) and exits, without running deps or
      # the body. One case per task: bash tasks feed their body to the classifier,
      # other languages just say there's nothing to analyse.
      envListCases = concatStringsSep "\n" (map
        (n:
          let
            t = full.${n};
            lang = t.__lang or "bash";
            isParallel = t.__parallel or false;
            eot = "_NIXX_LIST_${name}_${n}";
          in
          if (lang == "bash" || lang == "sh") && !isParallel
          then
            "    ${n}) _nixx_env_check " + shq n + " <<'" + eot + "'\n"
            + chopNL (stripShebang t.text) + "\n" + eot + "\n      ;;"
          else
            "    ${n}) printf 'nixx-env [%s]: no shell env analysis (%s task)\\n' "
            + shq n + " " + shq lang + " ;;")
        names);
      flagPreamble =
        if envCheckHookText != "" then ''
          _NIXX_ENV_CHECK=0
          if [[ "''${1:-}" == "--env-check" ]]; then _NIXX_ENV_CHECK=1; shift; fi
          if [[ "''${1:-}" == "--env-list" ]]; then
            _NIXX_ENV_MODE=list; shift
            case "''${1:-}" in
          ${envListCases}
            ""|-l|--list|help) echo "usage: ${name} --env-list <task>" >&2; exit 1 ;;
            *) echo "unknown task: ''${1:-}" >&2; exit 1 ;;
            esac
            exit 0
          fi
        '' else "";
    in
    ''
      #!/usr/bin/env bash
      # generated by nixx (${name})
      set -euo pipefail
      _NIXX_DONE=""
      _NIXX_CWD="$PWD"

      ${envCheckHookText}
      ${flagPreamble}
      ${dispatch}
      ${concatStringsSep "\n" (map fnFor names)}
      case "''${1:-}" in
      ${cases}
        ""|-l|--list|help)
      ${listBody}
          ;;
        *) echo "unknown task: $1" >&2; exit 1 ;;
      esac
    '';

  mkTasks =
    { name ? "tasks"
    , vars ? { }
    , defaultDeps ? [ ]
    , env ? { }
    , envCheckHookText ? ""
    , envCheckDefault ? false
    }: taskAttrs:
    let
      full = builtins.mapAttrs
        (n: v:
          let
            b = normalize v;
            pos = builtins.unsafeGetAttrPos n taskAttrs;
            m = materializeRaw pos b; # literal '' bodies: read from source here
          in
          m // { text = substVars vars m.text; env = env // b.env; })
        taskAttrs;
      # resolve the source line where each task's body starts, for shellcheck remap
      lineOf = n:
        if full.${n}.__parallel or false then null
        else
          let pos = builtins.unsafeGetAttrPos n taskAttrs;
          in if pos == null then null
          else if full.${n}.__rawsh or false then rawBodyLine pos.file pos.line (pos.column or 1)
          else bodyStartLine pos.file pos.line (full.${n}.rawBody or "");
      fileOf = n:
        let pos = builtins.unsafeGetAttrPos n taskAttrs;
        in if pos == null then null else pos.file;
    in
    {
      tasks = full;
      runner = mkRunnerText name defaultDeps full envCheckHookText envCheckDefault;
      meta = map
        (n:
          let
            srcLine = lineOf n;
            srcFile = fileOf n;
            bodyText = full.${n}.text;
            bodyLines = splitLines bodyText;
            # Nix strips a COMMON indent from indented strings. Recover it as:
            #   (indent of body line 1 in source) - (indent of body line 1 in text)
            srcIndentL1 =
              if srcLine == null || srcFile == null then 0
              else
                let
                  ls = splitLines (readFile srcFile);
                  bl = if srcLine <= length ls then elemAt ls (srcLine - 1) else "";
                in
                stringLength (head (match "([[:space:]]*).*" bl));
            textIndentL1 =
              if bodyLines == [ ] then 0
              else stringLength (head (match "([[:space:]]*).*" (head bodyLines)));
            commonIndent = srcIndentL1 - textIndentL1;
          in
          {
            name = n;
            text = bodyText;
            file = srcFile;
            line = srcLine; # source line of body line 1
            indent = commonIndent; # columns Nix stripped (add back uniformly)
            description = full.${n}.description or null;
            group = full.${n}.group or null;
          })
        (attrNames full);
    };

  # mkScript: compile ONE block to a standalone executable script.
  # No function wrapper, so a user shebang stays at byte 0 (a real shebang).
  # If the block has no shebang, we prepend one; `strict` adds set -euo pipefail.
  # packages adds their /bin to PATH (like writeShellApplication).
  #   nixx.mkScript { strict = true; packages = [ pkgs.jq ]; } (nixx.sh '' ... '')
  # Language profiles: shebang + how to lint. `linter` is the argv that
  # receives the script path; `lineRe`/`colRe` describe how to parse its
  # output (handled by nixx-check). bash stays the default.
  langProfiles = {
    bash = { shebang = "#!/usr/bin/env bash"; strict = true; pathStyle = "bash"; };
    python = { shebang = "#!/usr/bin/env python3"; strict = false; pathStyle = "py"; };
    python-uv = { shebang = "#!/usr/bin/env -S uv run --script"; strict = false; pathStyle = "uv"; };
    perl = { shebang = "#!/usr/bin/env perl"; strict = false; pathStyle = "none"; };
    ruby = { shebang = "#!/usr/bin/env ruby"; strict = false; pathStyle = "none"; };
    lua = { shebang = "#!/usr/bin/env lua"; strict = false; pathStyle = "none"; };
    # node: deps come from a Nix-supplied node_modules via NODE_PATH (set by
    # writeNodeApplication / an explicit shebang). No clean runtime-inline deps
    # like uv, so dependency supply is Nix's job, not an inline header.
    node = { shebang = "#!/usr/bin/env node"; strict = false; pathStyle = "none"; };
    # deno DOES support inline deps (npm:/jsr: specifiers in imports), making it
    # the closest node-world analog to python-uv. Pair with `deno run`.
    deno = { shebang = "#!/usr/bin/env -S deno run -A"; strict = false; pathStyle = "none"; };
    # bun: runs TS directly (no compile step), auto-installs deps from bare
    # imports (the node-world analog of uv inline deps), AND can compile to a
    # self-contained binary via `bun build --compile` for full reproducibility.
    # TS type annotations use `{ }` not `${ }`, so the only ${} tax is template
    # literals — interfaces/generics/annotations are written 100% raw.
    bun = { shebang = "#!/usr/bin/env bun"; strict = false; pathStyle = "none"; };
    typescript = { shebang = "#!/usr/bin/env tsx"; strict = false; pathStyle = "none"; };
    # moonbit is compiled, not interpreted: the shebang is a marker stripped by
    # writeMoonBitApplication (tail -n +2). MoonBit comments use //, so // works.
    moonbit = { shebang = "// moonbit"; strict = false; pathStyle = "none"; };
  };

  # PEP 723 inline metadata block for uv. requirements is a list of strings like
  # [ "requests" "rich>=13" ]; pythonReq is an optional ">=3.11" constraint.
  pep723 = { requirements ? [ ], pythonReq ? null }:
    if requirements == [ ] && pythonReq == null then [ ] else
    [ "# /// script" ]
    ++ (if pythonReq == null then [ ] else [ ("# requires-python = " + "\"" + pythonReq + "\"") ])
    ++ [ ("# dependencies = [" + concatStringsSep ", " (map (d: "\"" + d + "\"") requirements) + "]") ]
    ++ [ "# ///" ];

  # mkScript: compile ONE block to a standalone executable script.
  # `lang` picks a profile (shebang + strict default). An explicit `shebang`
  # still overrides. For bash, packages are injected as PATH export; for
  # python-uv, `requirements`/`pythonReq` become a PEP 723 header that uv resolves.
  #   nixx.mkScript { lang = "python"; vars = { port = 3000; }; } (nixx.sh '' ... '')
  #   nixx.mkScript { lang = "python-uv"; requirements = [ "requests" ]; } (nixx.sh '' ... '')
  mkScript =
    { lang ? null
    , vars ? { }
    , shebang ? null
    , strict ? null
    , packages ? [ ]
    , requirements ? [ ]
    , pythonReq ? null
    }: blk:
    let
      b = normalize blk;
      # lang priority: explicit arg > block's own __lang tag > bash
      lang' = if lang != null then lang else (b.__lang or "bash");
      prof = langProfiles.${lang'} or langProfiles.bash;
      shebang' = if shebang != null then shebang else prof.shebang;
      strict' = if strict != null then strict else prof.strict;
      # b.text is already source-read when this block came through
      # mkTasks/mkScripts; a directly-built standalone block forces its
      # evaluated body here (so a bare ${VAR} would need `with for pkgs` and a
      # source position — i.e. build it through mkScripts).
      text = substVars vars b.text;
      ls = splitLines text;
      hasShebang = ls != [ ] && match "#!.*" (head ls) != null;
      head' = if hasShebang then head ls else shebang';
      rest = if hasShebang then tail ls else ls;
      # bash-only preamble: strict mode + PATH from packages
      strictLine = if strict' && prof.pathStyle == "bash" then [ "set -euo pipefail" ] else [ ];
      pathLine =
        if packages == [ ] || prof.pathStyle != "bash" then [ ] else
        [ ("export PATH=" + shq (concatStringsSep ":" (map (d: "${toString d}/bin") packages)) + ":\"$PATH\"") ];
      # uv-only preamble: PEP 723 inline metadata (must come right after shebang)
      uvHeader = if prof.pathStyle == "uv" then pep723 { inherit requirements pythonReq; } else [ ];
      bodyLines = uvHeader ++ strictLine ++ pathLine ++ rest;
    in
    head' + "\n" + concatStringsSep "\n" bodyLines
    + (if bodyLines == [ ] then "" else "\n");

  # mkScripts: like mkTasks but for standalone scripts of any language.
  # Each attr value is `nixx.sh ''...''` optionally wrapped to carry a lang.
  # Returns { scripts = name->text; meta = [...] } where meta feeds nixx-check
  # with the language so it can pick the right linter (shellcheck/ruff/...).
  #   nixx.mkScripts { lang = "python"; } { build = nixx.sh ''...''; }
  mkScripts = { lang ? "bash", vars ? { } }: scriptAttrs:
    let
      full = builtins.mapAttrs
        (n: v:
          let b = normalize v; pos = builtins.unsafeGetAttrPos n scriptAttrs; in
          materializeRaw pos b)
        scriptAttrs;
      lineOf = n:
        let pos = builtins.unsafeGetAttrPos n scriptAttrs;
        in if pos == null then null
        else if full.${n}.__rawsh or false then rawBodyLine pos.file pos.line (pos.column or 1)
        else bodyStartLine pos.file pos.line (full.${n}.rawBody or "");
      fileOf = n:
        let pos = builtins.unsafeGetAttrPos n scriptAttrs;
        in if pos == null then null else pos.file;
      indentOf = n:
        let
          srcLine = lineOf n;
          srcFile = fileOf n;
          bodyLines = splitLines full.${n}.text;
          srcL1 =
            if srcLine == null || srcFile == null then 0
            else
              let
                ls = splitLines (readFile srcFile);
                bl = if srcLine <= length ls then elemAt ls (srcLine - 1) else "";
              in
              stringLength (head (match "([[:space:]]*).*" bl));
          txtL1 =
            if bodyLines == [ ] then 0
            else stringLength (head (match "([[:space:]]*).*" (head bodyLines)));
        in
        srcL1 - txtL1;
    in
    {
      scripts = builtins.mapAttrs
        (n: v:
          mkScript { inherit lang vars; } v)   # v = materialized block (source-read)
        full;
      meta = map
        (n: {
          name = n; inherit lang;
          text = full.${n}.text;
          file = fileOf n;
          line = lineOf n;
          indent = indentOf n;
        })
        (attrNames full);
    };

  # shellHook: source-read one bash block and return its body text.
  # This is the escape-free primitive for Nix APIs that want a raw bash string:
  #
  #   pkgs.mkShell {
  #     shellHook = shellHook {
  #       hook = bash ''
  #         echo ${HOME}
  #       '';
  #     };
  #   }
  #
  # Prefer the conventional `hook` attr, but accept any single attr so wrappers
  # can read naturally, e.g. runCommand "x" {} { build = bash ''...''; }.
  # A reserved `vars` attr enables @nix()/@sh:q() interpolation in the body,
  # matching mkTasks/mkScript; it is stripped before the single-block detection.
  shellHook = hookAttrs:
    let
      vars = hookAttrs.vars or { };
      blockAttrs = removeAttrs hookAttrs [ "vars" ];
      names = attrNames blockAttrs;
      name =
        if blockAttrs ? hook then "hook"
        else if length names == 1 then head names
        else throw "nixx.shellHook: expected `{ hook = bash ''...''; }` or a single bash block attr";
    in
    (mkTasks { inherit vars; } blockAttrs).tasks.${name}.text;

  # ---- process-compose config generation (pure) ----
  # processCompose turns a set of nixx bash blocks into a process-compose config
  # attrset — the input to `process-compose -f <json> up`, which supplies the
  # orchestration process-compose is built for: concurrent startup, depends_on
  # readiness gating, ordered graceful shutdown, restart policies, and liveness/
  # readiness probes. Bodies are source-read (shell ${VAR} survives verbatim),
  # then writers.processCompose serializes the attrset to JSON and runs it.
  #
  # `disable_env_expansion` is set so process-compose does NOT envsubst the
  # command — a shell ${VAR} reaches bash raw and expands from the process
  # environment (the same model as every other nixx bash block).
  #
  # Per-process options attach via the block functor (same idiom as mkTasks):
  #   cwd         path|string                         -> working_dir
  #   env         attrset { K = V; }                   -> environment [ "K=V" ]
  #   depends_on  [ "db" ]                             -> depends_on { db.condition = process_healthy }
  #   readiness   { exec="pg_isready"; }
  #               { http={ port=5432; host?; path?; scheme?; }; timing...; }
  #                                                      -> readiness_probe
  #   restart     "on_failure" | "exit_on_failure" | "always" | "no"
  #                                                      -> availability.restart
  #   description string                               -> description
  #   namespace   string                               -> namespace
  #   shutdown    attrset { signal; timeout_seconds; command; } -> shutdown
  #
  # lib.processCompose is pure; writers.processCompose wraps it with pkgs into a
  # runnable derivation (+ devShell), mirroring the mkTasks split.
  processCompose =
    { vars ? { }
    , env ? { }
    }: procAttrs:
    let
      validRestart = [ "on_failure" "exit_on_failure" "always" "no" ];
      # nixx `env` attrset -> process-compose `environment` list of "K=V"
      asEnvList = e: map (k: k + "=" + toString e.${k}) (attrNames e);
      # nixx `depends_on` [ names ] -> pc `depends_on` { name.condition = process_healthy }
      dependsMap = ds:
        builtins.listToAttrs
          (map (d: { name = d; value = { condition = "process_healthy"; }; }) ds);
      # nixx `readiness` shorthand -> pc `readiness_probe`
      readinessProbe = r:
        if !(isAttrs r) then
          throw "nixx.processCompose: readiness must be an attrset"
        else if r ? exec then
          mergeAttrs [{ exec = { command = r.exec; }; } (probeTiming r)]
        else if r ? http then
          mergeAttrs [{ http_get = httpGet r.http; } (probeTiming r)]
        else
          throw "nixx.processCompose: readiness needs `exec` or `http`";
      httpGet = h:
        if !(h ? port) then
          throw "nixx.processCompose: readiness.http needs `port`"
        else
          mergeAttrs [
            { port = toString h.port; }
            (optionalAttr "host" (h.host or null))
            (optionalAttr "path" (h.path or null))
            (optionalAttr "scheme" (h.scheme or null))
          ];
      probeTiming = r:
        mergeAttrs
          (map (k: optionalAttr k (r.${k} or null))
            [
              "initial_delay_seconds"
              "period_seconds"
              "timeout_seconds"
              "success_threshold"
              "failure_threshold"
            ]);
      restartWord = rs:
        if builtins.elem rs validRestart then rs
        else throw ''nixx.processCompose: restart must be "on_failure" | "exit_on_failure" | "always" | "no"'';
      # source-read each block's body, then map its opts to a pc process entry
      processes = builtins.mapAttrs
        (n: v:
          let
            b = normalize v;
            pos = builtins.unsafeGetAttrPos n procAttrs;
            m = materializeRaw pos b;
            command = substVars vars m.text;
            rs = m.restart or null;
            rd = m.readiness or null;
            ds = m.depends_on or [ ];
            c = m.cwd or null;
            avail = if rs == null then null else { restart = restartWord rs; };
          in
          mergeAttrs [
            { inherit command; }
            (optionalAttr "working_dir" (if c == null then null else toString c))
            { environment = asEnvList (env // m.env); }
            (optionalAttr "depends_on" (if ds == [ ] then null else dependsMap ds))
            (optionalAttr "readiness_probe" (if rd == null then null else readinessProbe rd))
            (optionalAttr "availability" avail)
            (optionalAttr "description" (m.description or null))
            (optionalAttr "namespace" (m.namespace or null))
            (optionalAttr "shutdown" (m.shutdown or null))
          ])
        procAttrs;
    in
    {
      # disable_env_expansion: keep shell ${VAR} raw (bash expands from env).
      # is_strict: reject unknown keys so mapping typos fail loudly at startup.
      config = {
        version = "0.5";
        is_strict = true;
        disable_env_expansion = true;
        inherit processes;
      };
      inherit processes;
      meta = map (n: { name = n; }) (attrNames procAttrs);
    };

in
{
  inherit sh bash py uv bun ts node deno perl ruby lua moonbit rawsh mkBlock parallel
    mkTasks mkScript mkScripts shellHook processCompose shq dedent langProfiles;
}
