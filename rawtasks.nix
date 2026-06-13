# rawtasks.nix — raw heredoc blocks in PURE Nix syntax, no preprocessor.
#
# Trick: comments are invisible to the Nix parser (no interpolation, no
# escaping), and builtins.unsafeGetAttrPos tells us where an attribute was
# defined. So we read our own source file back and extract the /* ... */
# block that follows the attribute. 100% legal Nix, LSP-clean, zero codegen.
let
  inherit (builtins)
    readFile substring stringLength split elemAt length foldl' filter
    isString match concatStringsSep genList unsafeGetAttrPos head tail
    mapAttrs attrNames attrValues replaceStrings toString;

  # ---- tiny string toolkit -------------------------------------------------

  splitLines = s: filter isString (split "\n" s);

  # byte offset of the start of 1-based line `n` in `src`
  lineOffset = src: n:
    let ls = splitLines src;
    in foldl' (acc: i: acc + stringLength (elemAt ls i) + 1) 0 (genList (i: i) (n - 1));

  # index of first regex match in s, or null
  indexOf = re: s:
    let parts = split re s;
    in if length parts < 2 then null else stringLength (head parts);

  isBlank = l: match "[[:space:]]*" l != null;

  reverse = xs: genList (i: elemAt xs (length xs - 1 - i)) (length xs);

  dropWhile = p: xs:
    if xs == [] then [] else if p (head xs) then dropWhile p (tail xs) else xs;

  # strip surrounding blank lines + common indentation
  dedent = s:
    let
      trimmed = reverse (dropWhile isBlank (reverse (dropWhile isBlank (splitLines s))));
      indentOf = l: stringLength (head (match "([[:space:]]*).*" l));
      nonBlank = filter (l: !(isBlank l)) trimmed;
      minIndent = foldl' (a: l: let i = indentOf l; in if a == null || i < a then i else a) null nonBlank;
      strip = l: if isBlank l then "" else substring minIndent (stringLength l) l;
    in if trimmed == [] then "" else concatStringsSep "\n" (map strip trimmed) + "\n";

  # ---- the core hack ---------------------------------------------------------

  # Extract the first /* ... */ block at or after `line` in `file`.
  extractComment = file: line:
    let
      src = readFile file;
      off = lineOffset src line;
      rest = substring off (stringLength src - off) src;
      start = indexOf "/\\*" rest;
      afterStart = substring (start + 2) (stringLength rest) rest;
      end = indexOf "\\*/" afterStart;
    in
    if start == null || end == null then
      throw "rawtasks: no /* ... */ block found after ${toString file}:${toString line}"
    else
      dedent (substring 0 end afterStart);

  # @nix(name) interpolation, applied AFTER extraction
  substVars = vars: text:
    replaceStrings
      (map (k: "@nix(${k})") (attrNames vars))
      (map toString (attrValues vars))
      text;

in
rec {
  # tasks = rawTasks { build = /* ...bash... */ ""; };
  rawTasks = attrs:
    mapAttrs
      (name: _:
        let pos = unsafeGetAttrPos name attrs;
        in extractComment pos.file pos.line)
      attrs;

  # same, but with @nix(var) interpolation:
  # tasks = rawTasksWith { port = 3000; } { dev = /* ...bash... */ ""; };
  rawTasksWith = vars: attrs:
    mapAttrs (_: text: substVars vars text) (rawTasks attrs);

  # single-block form: run = raw ./file.nix line  (rarely needed directly)
  inherit extractComment dedent substVars;
}
