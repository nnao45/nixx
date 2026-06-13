# nixx — write raw bash inside pure Nix (string-mode).
#
# Shell bodies live in Nix indented strings ('' ... '').  Everything is raw
# bash EXCEPT one rule that Nix imposes and cannot be automated away (Nix
# evaluates the string before nixx ever sees it):
#
#     bash ${VAR}   must be written   ''${VAR}     (prefix the $ with '')
#     a literal ''  must be written   '''
#
# A lone $VAR (no braces) is raw.  And unlike comment-mode, */ is totally
# fine here:  for d in */ , sed 's*/*x*' , etc. all work.
#
#   tasks = nixx.mkTasks { vars = { inherit port; }; } {
#     dev = nixx.task { env.NODE_ENV = "development"; cwd = "./frontend"; } (nixx.sh ''
#       for d in */; do echo "$d"; done       # */ ok, $d raw
#       echo "editor is ''${EDITOR:-vi}"        # ${} needs '' prefix
#       npm run dev -- --port @nix(port)        # explicit Nix value
#       greet @nix:q(message)                   # shell-quoted Nix value
#     '');
#     test = nixx.sh ''
#       cargo test --workspace
#     '';
#   };
let
  inherit (builtins)
    replaceStrings split filter isString isAttrs length elemAt concatStringsSep
    stringLength substring match head tail foldl' genList attrNames toString readFile;

  splitLines = s: filter isString (split "\n" s);
  isBlank = l: match "[[:space:]]*" l != null;
  chopNL = s:
    let n = stringLength s; in
    if n > 0 && substring (n - 1) 1 s == "\n" then substring 0 (n - 1) s else s;

  reverse = xs: genList (i: elemAt xs (length xs - 1 - i)) (length xs);
  dropStart = p: xs:
    if xs == [ ] then [ ] else if p (head xs) then dropStart p (tail xs) else xs;
  dropEnd = p: xs: reverse (dropStart p (reverse xs));

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


  # ---- per-language safe quoting ----
  # Each turns a Nix value into a valid string LITERAL in the target language,
  # so interpolated values can't break out of the string or inject code.

  # bash / sh: POSIX single-quote.  it's -> 'it'\''s'
  shq = v: "'" + replaceStrings [ "'" ] [ "'\\''" ] (toString v) + "'";

  # python: produces a "double-quoted" python string literal.
  pyq = v:
    let
      s = toString v;
      esc = replaceStrings
        [ "\\" "\"" "\n" "\t" "\r" ]
        [ "\\\\" "\\\"" "\\n" "\\t" "\\r" ]
        s;
    in
    "\"" + esc + "\"";

  # js / ts: JSON-style double-quoted literal (valid JS string).
  jsq = v:
    let
      s = toString v;
      esc = replaceStrings
        [ "\\" "\"" "\n" "\t" "\r" ]
        [ "\\\\" "\\\"" "\\n" "\\t" "\\r" ]
        s;
    in
    "\"" + esc + "\"";

  # If a var is a filesystem path, copy it into the store so the generated
  # script is reproducible (a bare path would point at the author's checkout
  # and break under `nix build`). Non-path values pass through unchanged.
  storeIfPath = name: v:
    if builtins.isPath v
    then builtins.path { path = v; name = baseNameOf (toString v); }
    else v;

  # Interpolation markers, longest-first so e.g. @sh:q( is matched before @nix(.
  #   @nix(x)   -> raw value (toString)
  #   @nix:q(x) -> shell-quoted (back-compat alias of @sh:q)
  #   @sh:q(x)  -> bash/sh string literal
  #   @py:q(x)  -> python string literal
  #   @js:q(x)  -> js/ts string literal
  substVars = vars: text:
    let
      ks = attrNames vars;
      resolved = builtins.mapAttrs storeIfPath vars;
      # order matters: quoted forms (longer) before the bare @nix(  form.
      froms = builtins.concatLists (map
        (k: [
          "@sh:q(${k})"
          "@py:q(${k})"
          "@js:q(${k})"
          "@nix:q(${k})"
          "@nix(${k})"
        ])
        ks);
      tos = builtins.concatLists (map
        (k: [
          (shq resolved.${k})
          (pyq resolved.${k})
          (jsq resolved.${k})
          (shq resolved.${k})
          (toString resolved.${k})
        ])
        ks);
    in
    if ks == [ ] then text else replaceStrings froms tos text;

  # ---- block constructors ----
  # A block carries its language as `__lang`, so a single runApplication can
  # dispatch to the right builder. `mkBlock` is the shared core; the named
  # constructors below are sugar so the language reads naturally at the call
  # site: `nixx.bun ''...''`, `nixx.py ''...''`, etc.
  # keep rawBody so line-mapping can count blank lines dedent will drop,
  # and indent so col-mapping can re-add stripped leading columns.
  mkBlock = lang: body:
    let d = dedentInfo body;
    in {
      __sh = true;
      __lang = lang;
      requirements = [ ];
      env = { };
      cwd = null;
      description = null; # one-line summary shown by the runner's --list
      inherit (d) text indent; rawBody = body;
    };

  sh = mkBlock "bash"; # bash (default)
  py = mkBlock "python"; # python (lint: ruff)
  uv = mkBlock "python-uv"; # python + uv inline deps
  bun = mkBlock "bun"; # typescript/js via bun
  ts = mkBlock "typescript"; # typescript via tsx
  node = mkBlock "node"; # node (deps via Nix-supplied node_modules)
  deno = mkBlock "deno"; # deno (npm:/jsr: inline deps)
  ruby = mkBlock "ruby";
  lua = mkBlock "lua";

  task = opts: blk:
    assert (blk.__sh or false) || throw "nixx.task: second arg must be a nixx block (e.g. nixx.sh ''...'')";
    assert (!(opts ? needs)) || throw
      "nixx.task: `needs` was renamed to `deps` (prerequisite tasks). For PATH packages use `requirements`.";
    blk // {
      requirements = opts.requirements or [ ]; # packages whose /bin join PATH
      env = opts.env or { };
      cwd = opts.cwd or null;
      strict = opts.strict or false; # prepend `set -euo pipefail` to this task
      deps = opts.deps or [ ]; # just-style: run these prerequisite tasks first
      description = opts.description or blk.description or null; # shown by --list
    };

  normalize = v:
    if isAttrs v && (v.__sh or false) then v
    else throw "nixx: value must be a nixx block (e.g. nixx.sh ''...'', nixx.bun ''...'')";

  # ---- runner generation ----
  # defaultDeps: task names run before EVERY task (except the default-dep tasks
  # themselves), e.g. a `setup` task that exports NIX_CONFIG. Because the runner
  # is one bash process, an `export` in such a task persists into every later
  # task body and any child interpreter it spawns.
  mkRunnerText = name: defaultDeps: full:
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
        in
        if lang == "bash" || lang == "sh" then indentBody body + "\n"
        else if lang == "python" then via "python3"
        else if lang == "python-uv" then via "uv run --no-project -"
        else if lang == "node" then via "node --input-type=module"
        else if lang == "bun" then via "bun run -"
        else if lang == "typescript" then via "tsx"
        else if lang == "deno" then via "deno run -A -"
        else if lang == "ruby" then via "ruby"
        else if lang == "lua" then via "lua -"
        else via "cat"; # unknown: just echo it (safe fallback)
      fnFor = n:
        let
          t = full.${n};
          lang = t.__lang or "bash";
          isBash = lang == "bash" || lang == "sh";
          reqs = t.requirements or [ ];
          pathLine = if reqs == [ ] then "" else
          "  export PATH=" + shq (concatStringsSep ":" (map (d: "${toString d}/bin") reqs)) + ":\"$PATH\"\n";
          envLines = concatStringsSep ""
            (map (k: "  export ${k}=" + shq t.env.${k} + "\n") (attrNames t.env));
          cwdLine = if t.cwd == null then "" else "  cd -- " + shq t.cwd + "\n";
          # strict only meaningful for bash bodies
          strictLine = if (t.strict or false) && isBash then "  set -euo pipefail\n" else "";
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
        in
        "task_${n}() {\n" + guard + depsLines + strictLine + pathLine + envLines + cwdLine
        + bodyRun + "}\n";
      # dispatcher used by needs: maps a task name to its function.
      dispatch = "_nixx_run() {\n  case \"$1\" in\n"
        + concatStringsSep "" (map (n: "    ${n}) task_${n} ;;\n") names)
        + "    *) echo \"unknown task: $1\" >&2; return 1 ;;\n  esac\n}\n";
      cases = concatStringsSep "\n" (map (n: "  ${n}) shift; task_${n} \"$@\" ;;") names);
      # `--list` output: `just`-style, descriptions aligned in a second column.
      descOf = n: full.${n}.description or null;
      maxNameLen = foldl' (a: n: let l = stringLength n; in if l > a then l else a) 0 names;
      padName = n: n + concatStringsSep "" (genList (_: " ") (maxNameLen - stringLength n));
      listLine = n:
        let d = descOf n;
        in
        if d == null || d == ""
        then "  printf '  %s\\n' " + shq n
        else "  printf '  %s   %s\\n' " + shq (padName n) + " " + shq d;
      listBody = concatStringsSep "\n" (map listLine names);
    in
    ''
      #!/usr/bin/env bash
      # generated by nixx (${name})
      set -euo pipefail
      _NIXX_DONE=""

      ${dispatch}
      ${concatStringsSep "\n" (map fnFor names)}
      case "''${1:-}" in
      ${cases}
        ""|-l|--list|help)
          echo "available tasks:"
      ${listBody}
          ;;
        *) echo "unknown task: $1" >&2; exit 1 ;;
      esac
    '';

  mkTasks = { name ? "tasks", vars ? { }, defaultDeps ? [ ] }: taskAttrs:
    let
      full = builtins.mapAttrs
        (_: v: let b = normalize v; in b // { text = substVars vars b.text; })
        taskAttrs;
      # resolve the source line where each task's body starts, for shellcheck remap
      lineOf = n:
        let pos = builtins.unsafeGetAttrPos n taskAttrs;
        in if pos == null then null
        else bodyStartLine pos.file pos.line (full.${n}.rawBody or "");
      fileOf = n:
        let pos = builtins.unsafeGetAttrPos n taskAttrs;
        in if pos == null then null else pos.file;
    in
    {
      tasks = full;
      runner = mkRunnerText name defaultDeps full;
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
          })
        (attrNames full);
    };

  # mkScript: compile ONE block to a standalone executable script.
  # No function wrapper, so a user shebang stays at byte 0 (a real shebang).
  # If the block has no shebang, we prepend one; `strict` adds set -euo pipefail.
  # runtimeInputs adds their /bin to PATH (like writeShellApplication).
  #   nixx.mkScript { strict = true; runtimeInputs = [ pkgs.jq ]; } (nixx.sh '' ... '')
  # Language profiles: shebang + how to lint. `linter` is the argv that
  # receives the script path; `lineRe`/`colRe` describe how to parse its
  # output (handled by nixx-check). bash stays the default.
  langProfiles = {
    bash = { shebang = "#!/usr/bin/env bash"; strict = true; pathStyle = "bash"; };
    python = { shebang = "#!/usr/bin/env python3"; strict = false; pathStyle = "py"; };
    python-uv = { shebang = "#!/usr/bin/env -S uv run --script"; strict = false; pathStyle = "uv"; };
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
  };

  # PEP 723 inline metadata block for uv. deps is a list of strings like
  # [ "requests" "rich>=13" ]; pythonReq is an optional ">=3.11" constraint.
  pep723 = { deps ? [ ], pythonReq ? null }:
    if deps == [ ] && pythonReq == null then [ ] else
    [ "# /// script" ]
    ++ (if pythonReq == null then [ ] else [ ("# requires-python = " + "\"" + pythonReq + "\"") ])
    ++ [ ("# dependencies = [" + concatStringsSep ", " (map (d: "\"" + d + "\"") deps) + "]") ]
    ++ [ "# ///" ];

  # mkScript: compile ONE block to a standalone executable script.
  # `lang` picks a profile (shebang + strict default). An explicit `shebang`
  # still overrides. For bash, runtimeInputs are injected as PATH export; for
  # python-uv, `deps`/`pythonReq` become a PEP 723 header that uv resolves.
  #   nixx.mkScript { lang = "python"; vars = { port = 3000; }; } (nixx.sh '' ... '')
  #   nixx.mkScript { lang = "python-uv"; deps = [ "requests" ]; } (nixx.sh '' ... '')
  mkScript =
    { lang ? null
    , vars ? { }
    , shebang ? null
    , strict ? null
    , runtimeInputs ? [ ]
    , deps ? [ ]
    , pythonReq ? null
    }: blk:
    let
      b = normalize blk;
      # lang priority: explicit arg > block's own __lang tag > bash
      lang' = if lang != null then lang else (b.__lang or "bash");
      prof = langProfiles.${lang'} or langProfiles.bash;
      shebang' = if shebang != null then shebang else prof.shebang;
      strict' = if strict != null then strict else prof.strict;
      text = substVars vars b.text;
      ls = splitLines text;
      hasShebang = ls != [ ] && match "#!.*" (head ls) != null;
      head' = if hasShebang then head ls else shebang';
      rest = if hasShebang then tail ls else ls;
      # bash-only preamble: strict mode + PATH from runtimeInputs
      strictLine = if strict' && prof.pathStyle == "bash" then [ "set -euo pipefail" ] else [ ];
      pathLine =
        if runtimeInputs == [ ] || prof.pathStyle != "bash" then [ ] else
        [ ("export PATH=" + shq (concatStringsSep ":" (map (d: "${toString d}/bin") runtimeInputs)) + ":\"$PATH\"") ];
      # uv-only preamble: PEP 723 inline metadata (must come right after shebang)
      uvHeader = if prof.pathStyle == "uv" then pep723 { inherit deps pythonReq; } else [ ];
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
        (_: v: let b = normalize v; in b // { text = substVars vars b.text; })
        scriptAttrs;
      lineOf = n:
        let pos = builtins.unsafeGetAttrPos n scriptAttrs;
        in if pos == null then null
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
        (n: _:
          mkScript { inherit lang vars; } scriptAttrs.${n})
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

in
{
  inherit sh py uv bun ts node deno ruby lua mkBlock
    task mkTasks mkScript mkScripts shq dedent langProfiles;
}
