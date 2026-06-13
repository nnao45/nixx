# nixx.nix — write raw shell inside pure Nix. No preprocessor, no codegen.
#
# Core trick: Nix comments are opaque to the parser (zero interpolation,
# zero escaping), and builtins.unsafeGetAttrPos gives us file:line of every
# attribute. We re-read our own source and extract the `/*sh ... */` block
# that follows each attribute — with exact line numbers preserved, so
# shellcheck diagnostics can be mapped back onto the original .nix file.
#
# Canonical style:
#
#   tasks = nixx.mkTasks { vars = { inherit port; }; } {
#     dev = nixx.task { env.NODE_ENV = "development"; } /*sh
#       npm run dev -- --port @nix(port)
#     */ "";
#     test = /*sh
#       cargo test --workspace
#     */ "";
#   };
let
  inherit (builtins)
    readFile substring stringLength split elemAt length foldl' filter
    isString isAttrs match concatStringsSep genList unsafeGetAttrPos head
    tail mapAttrs attrNames attrValues replaceStrings toString;

  # ---------- string toolkit ----------

  splitLines = s: filter isString (split "\n" s);
  countNL = s: length (splitLines s) - 1;

  lineOffset = src: n:
    let ls = splitLines src;
    in foldl' (acc: i: acc + stringLength (elemAt ls i) + 1) 0 (genList (i: i) (n - 1));

  indexOf = re: s:
    let parts = split re s;
    in if length parts < 2 then null else stringLength (head parts);

  isBlank = l: match "[[:space:]]*" l != null;

  chopNL = s:
    let n = stringLength s;
    in if n > 0 && substring (n - 1) 1 s == "\n" then substring 0 (n - 1) s else s;

  # POSIX-shell-safe single quoting:  it's  ->  'it'\''s'
  escapeShellArg = v: "'" + replaceStrings ["'"] ["'\\''"] (toString v) + "'";

  # ---------- block extraction ----------

  # body = everything between "/*sh" and "*/".
  # Line 1 of the result corresponds EXACTLY to markerLine + 1.
  dedent = body:
    let
      ls = splitLines body;
      content = tail ls;                       # drop remainder of the /*sh line
      n = length content;
      content' =                                # drop only the final indent-line before */
        if n > 0 && isBlank (elemAt content (n - 1))
        then genList (i: elemAt content i) (n - 1)
        else content;
      nonBlank = filter (l: !(isBlank l)) content';
      indentOf = l: stringLength (head (match "([[:space:]]*).*" l));
      mi = foldl' (a: l: let i = indentOf l; in if a == null || i < a then i else a) null nonBlank;
      mi' = if mi == null then 0 else mi;
      strip = l: if isBlank l then "" else substring mi' (stringLength l - mi') l;
    in {
      text = concatStringsSep "\n" (map strip content') + "\n";
      indent = mi';
    };

  extractMeta = file: line:
    let
      src = readFile file;
      off = lineOffset src line;
      rest = substring off (stringLength src - off) src;
      start = indexOf "/\\*sh" rest;
      afterMarker = substring (start + 4) (stringLength rest - start - 4) rest;
      end = indexOf "\\*/" afterMarker;
      markerLine = countNL (substring 0 (off + start) src) + 1;
      d = dedent (substring 0 end afterMarker);
    in
    if start == null then
      throw "nixx: no /*sh ... */ block found after ${toString file}:${toString line}"
    else if end == null then
      throw "nixx: unterminated /*sh block after ${toString file}:${toString line}"
    else
      { inherit (d) text indent; file = toString file; line = markerLine + 1; };

  # ---------- @nix() interpolation ----------

  # @nix(name)   -> raw value
  # @nix:q(name) -> shell-quoted value (safe for spaces/quotes)
  substVars = vars: text:
    let ks = attrNames vars;
    in if ks == [] then text else
      replaceStrings
        (map (k: "@nix:q(${k})") ks ++ map (k: "@nix(${k})") ks)
        (map (k: escapeShellArg vars.${k}) ks ++ map (k: toString vars.${k}) ks)
        text;

  # ---------- public: plain blocks ----------

  shBlocksMeta = vars: attrs:
    mapAttrs
      (name: _:
        let
          pos = unsafeGetAttrPos name attrs;
          m = extractMeta pos.file pos.line;
        in m // { inherit name; text = substVars vars m.text; })
      attrs;

  shBlocks = attrs: mapAttrs (_: m: m.text) (shBlocksMeta { } attrs);

  # ---------- public: tasks with options ----------

  # task { deps, env, cwd } /*sh ... */ "";
  # `task opts` returns a function that eats the "" placeholder.
  task = opts: _placeholder: {
    __nixxTask = true;
    deps = opts.deps or [ ];
    env = opts.env or { };
    cwd = opts.cwd or null;
  };

  normalize = v:
    if isAttrs v && v.__nixxTask or false
    then v
    else { deps = [ ]; env = { }; cwd = null; };

  mkRunnerText = name: full:
    let
      names = attrNames full;
      fnFor = n:
        let
          t = full.${n};
          pathLine =
            if t.deps == [ ] then "" else
            "  export PATH=" + escapeShellArg (concatStringsSep ":" (map (d: "${toString d}/bin") t.deps)) + ":\"$PATH\"\n";
          envLines = concatStringsSep ""
            (map (k: "  export ${k}=" + escapeShellArg t.env.${k} + "\n") (attrNames t.env));
          cwdLine = if t.cwd == null then "" else "  cd -- " + escapeShellArg t.cwd + "\n";
          body = concatStringsSep "\n"
            (map (l: if l == "" then "" else "  " + l) (splitLines (chopNL t.text)));
        in
        "task_${n}() {\n" + pathLine + envLines + cwdLine + body + "\n}\n";
      cases = concatStringsSep "\n" (map (n: "  ${n}) shift; task_${n} \"$@\" ;;") names);
    in
    ''
      #!/usr/bin/env bash
      # generated by nixx (${name})
      set -euo pipefail

      ${concatStringsSep "\n" (map fnFor names)}
      case "''${1:-}" in
      ${cases}
        ""|-l|--list|help)
          echo "available tasks:"
          printf '  %s\n' ${concatStringsSep " " names} ;;
        *)
          echo "unknown task: $1" >&2
          exit 1 ;;
      esac
    '';

  mkTasks = { name ? "tasks", vars ? { } }: taskAttrs:
    let
      metas = shBlocksMeta vars taskAttrs;
      cfg = mapAttrs (_: normalize) taskAttrs;
      full = mapAttrs (n: m: cfg.${n} // m) metas;
    in
    {
      tasks = full;
      runner = mkRunnerText name full;
      # machine-readable, for `nixx-check` (shellcheck line remapping)
      meta = map (n: { inherit (full.${n}) name file line indent text; }) (attrNames full);
    };

in
{
  inherit shBlocks shBlocksMeta task mkTasks escapeShellArg;
}
