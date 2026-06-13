# Pure unit tests for lib.nix — no pkgs, no builders, no IO.
# Evaluated by nixx's own flake check; a failing assertion throws immediately.
let
  lib = import ../lib.nix;
  inherit (builtins)
    concatStringsSep filter length split isString isList isAttrs
    replaceStrings head;

  splitLines = s: filter isString (split "\n" s);

  # Literal (non-regex) substring check: safe for (, ), [, {, +, * etc.
  contains = needle: text: replaceStrings [ needle ] [ "" ] text != text;

  # First non-empty line of a multi-line string.
  firstLine = text: head (filter (l: l != "") (splitLines text));

  # ================================================================
  tests = [

    # ----------------------------------------------------------------
    # shq — POSIX single-quote escaping
    # ----------------------------------------------------------------
    {
      name = "shq: plain string";
      got = lib.shq "hello";
      expected = "'hello'";
    }

    {
      name = "shq: string with a single quote";
      got = lib.shq "it's";
      expected = "'it'\\''s'";
    }

    {
      name = "shq: multiple single quotes";
      got = lib.shq "a'b'c";
      expected = "'a'\\''b'\\''c'";
    }

    {
      name = "shq: empty string";
      got = lib.shq "";
      expected = "''";
    }

    {
      name = "shq: only a single quote";
      got = lib.shq "'";
      expected = "''\\'''";
    }

    {
      name = "shq: string with spaces";
      got = lib.shq "hello world";
      expected = "'hello world'";
    }

    {
      name = "shq: dollar sign is safe inside single quotes";
      got = lib.shq "\${VAR}";
      expected = "'\${VAR}'";
    }

    {
      name = "shq: integer coerced via toString";
      got = lib.shq 42;
      expected = "'42'";
    }

    {
      name = "shq: path-like string";
      got = lib.shq "/usr/local/bin";
      expected = "'/usr/local/bin'";
    }

    {
      name = "shq: backslash is safe inside single quotes";
      got = lib.shq "a\\b";
      expected = "'a\\b'";
    }

    # ----------------------------------------------------------------
    # dedent — strip common leading whitespace + surrounding blank lines
    # ----------------------------------------------------------------
    {
      name = "dedent: basic indented body";
      got = lib.dedent "  echo hello\n  echo world\n";
      expected = "echo hello\necho world\n";
    }

    {
      name = "dedent: deeper indentation";
      got = lib.dedent "    line1\n    line2\n";
      expected = "line1\nline2\n";
    }

    {
      name = "dedent: mixed indentation — only common part stripped";
      got = lib.dedent "  a\n    b\n  c\n";
      expected = "a\n  b\nc\n";
    }

    {
      name = "dedent: leading blank lines stripped";
      got = lib.dedent "\n\n  echo hi\n";
      expected = "echo hi\n";
    }

    {
      name = "dedent: trailing blank lines stripped";
      got = lib.dedent "  echo hi\n\n\n";
      expected = "echo hi\n";
    }

    {
      name = "dedent: empty body";
      got = lib.dedent "";
      expected = "";
    }

    {
      name = "dedent: blank-only body";
      got = lib.dedent "   \n   \n";
      expected = "";
    }

    {
      name = "dedent: zero indentation preserved as-is";
      got = lib.dedent "no-indent\n";
      expected = "no-indent\n";
    }

    {
      name = "dedent: blank line in middle preserved as empty string";
      got = lib.dedent "  a\n\n  b\n";
      expected = "a\n\nb\n";
    }

    {
      name = "dedent: tab counts as one column";
      got = lib.dedent "\techo a\n\techo b\n";
      expected = "echo a\necho b\n";
    }

    {
      name = "dedent: single non-blank line";
      got = lib.dedent "    only\n";
      expected = "only\n";
    }

    # ----------------------------------------------------------------
    # langProfiles
    # ----------------------------------------------------------------
    {
      name = "langProfiles bash: shebang";
      got = lib.langProfiles.bash.shebang;
      expected = "#!/usr/bin/env bash";
    }

    {
      name = "langProfiles python: shebang";
      got = lib.langProfiles.python.shebang;
      expected = "#!/usr/bin/env python3";
    }

    {
      name = "langProfiles python-uv: shebang uses -S";
      got = lib.langProfiles."python-uv".shebang;
      expected = "#!/usr/bin/env -S uv run --script";
    }

    {
      name = "langProfiles deno: shebang uses -S";
      got = lib.langProfiles.deno.shebang;
      expected = "#!/usr/bin/env -S deno run -A";
    }

    {
      name = "langProfiles typescript: shebang";
      got = lib.langProfiles.typescript.shebang;
      expected = "#!/usr/bin/env tsx";
    }

    {
      name = "langProfiles bun: shebang";
      got = lib.langProfiles.bun.shebang;
      expected = "#!/usr/bin/env bun";
    }

    {
      name = "langProfiles node: shebang";
      got = lib.langProfiles.node.shebang;
      expected = "#!/usr/bin/env node";
    }

    {
      name = "langProfiles ruby: shebang";
      got = lib.langProfiles.ruby.shebang;
      expected = "#!/usr/bin/env ruby";
    }

    {
      name = "langProfiles lua: shebang";
      got = lib.langProfiles.lua.shebang;
      expected = "#!/usr/bin/env lua";
    }

    {
      name = "langProfiles bash: strict=true";
      got = lib.langProfiles.bash.strict;
      expected = true;
    }

    {
      name = "langProfiles python: strict=false";
      got = lib.langProfiles.python.strict;
      expected = false;
    }

    {
      name = "langProfiles python-uv: pathStyle=uv";
      got = lib.langProfiles."python-uv".pathStyle;
      expected = "uv";
    }

    {
      name = "langProfiles bash: pathStyle=bash";
      got = lib.langProfiles.bash.pathStyle;
      expected = "bash";
    }

    {
      name = "langProfiles ruby: pathStyle=none";
      got = lib.langProfiles.ruby.pathStyle;
      expected = "none";
    }

    {
      name = "langProfiles deno: pathStyle=none";
      got = lib.langProfiles.deno.pathStyle;
      expected = "none";
    }

    # ----------------------------------------------------------------
    # mkBlock / language constructors
    # ----------------------------------------------------------------
    {
      name = "sh: __lang=bash";
      got = (lib.sh "echo hi\n").__lang;
      expected = "bash";
    }

    {
      name = "sh: __sh=true";
      got = (lib.sh "echo hi\n").__sh;
      expected = true;
    }

    {
      name = "sh: body is dedented";
      got = (lib.sh "  echo hi\n  echo bye\n").text;
      expected = "echo hi\necho bye\n";
    }

    {
      name = "sh: rawBody preserved verbatim";
      got = (lib.sh "  echo raw\n").rawBody;
      expected = "  echo raw\n";
    }

    {
      name = "sh: indent column count recorded";
      got = (lib.sh "  echo x\n").indent;
      expected = 2;
    }

    {
      name = "py: __lang=python";
      got = (lib.py "print('hi')\n").__lang;
      expected = "python";
    }

    {
      name = "uv: __lang=python-uv";
      got = (lib.uv "print('hi')\n").__lang;
      expected = "python-uv";
    }

    {
      name = "bun: __lang=bun";
      got = (lib.bun "console.log('hi')\n").__lang;
      expected = "bun";
    }

    {
      name = "ts: __lang=typescript";
      got = (lib.ts "console.log('hi')\n").__lang;
      expected = "typescript";
    }

    {
      name = "node: __lang=node";
      got = (lib.node "console.log('hi')\n").__lang;
      expected = "node";
    }

    {
      name = "deno: __lang=deno";
      got = (lib.deno "console.log('hi')\n").__lang;
      expected = "deno";
    }

    {
      name = "ruby: __lang=ruby";
      got = (lib.ruby "puts 'hi'\n").__lang;
      expected = "ruby";
    }

    {
      name = "lua: __lang=lua";
      got = (lib.lua "print('hi')\n").__lang;
      expected = "lua";
    }

    {
      name = "mkBlock: requirements defaults to []";
      got = (lib.sh "echo\n").requirements;
      expected = [ ];
    }

    {
      name = "mkBlock: env defaults to {}";
      got = (lib.sh "echo\n").env;
      expected = { };
    }

    {
      name = "mkBlock: cwd defaults to null";
      got = (lib.sh "echo\n").cwd;
      expected = null;
    }

    # ----------------------------------------------------------------
    # mkScript — shebang selection
    # ----------------------------------------------------------------
    {
      name = "mkScript bash: default shebang #!/usr/bin/env bash";
      got = firstLine (lib.mkScript { } (lib.sh "echo hi\n"));
      expected = "#!/usr/bin/env bash";
    }

    {
      name = "mkScript py: default shebang #!/usr/bin/env python3";
      got = firstLine (lib.mkScript { } (lib.py "print('hi')\n"));
      expected = "#!/usr/bin/env python3";
    }

    {
      name = "mkScript uv: default shebang -S uv run --script";
      got = firstLine (lib.mkScript { } (lib.uv "print('hi')\n"));
      expected = "#!/usr/bin/env -S uv run --script";
    }

    {
      name = "mkScript deno: default shebang -S deno run -A";
      got = firstLine (lib.mkScript { } (lib.deno "console.log('hi')\n"));
      expected = "#!/usr/bin/env -S deno run -A";
    }

    {
      name = "mkScript bun: default shebang #!/usr/bin/env bun";
      got = firstLine (lib.mkScript { } (lib.bun "console.log('hi')\n"));
      expected = "#!/usr/bin/env bun";
    }

    {
      name = "mkScript ts: default shebang #!/usr/bin/env tsx";
      got = firstLine (lib.mkScript { } (lib.ts "console.log('hi')\n"));
      expected = "#!/usr/bin/env tsx";
    }

    {
      name = "mkScript node: default shebang #!/usr/bin/env node";
      got = firstLine (lib.mkScript { } (lib.node "console.log('hi')\n"));
      expected = "#!/usr/bin/env node";
    }

    {
      name = "mkScript ruby: default shebang #!/usr/bin/env ruby";
      got = firstLine (lib.mkScript { } (lib.ruby "puts 'hi'\n"));
      expected = "#!/usr/bin/env ruby";
    }

    {
      name = "mkScript lua: default shebang #!/usr/bin/env lua";
      got = firstLine (lib.mkScript { } (lib.lua "print('hi')\n"));
      expected = "#!/usr/bin/env lua";
    }

    {
      name = "mkScript: #!/bin/sh in body is preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/bin/sh\necho hi\n"));
      expected = "#!/bin/sh";
    }

    {
      name = "mkScript: #!/bin/bash in body is preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/bin/bash\necho hi\n"));
      expected = "#!/bin/bash";
    }

    {
      name = "mkScript: #!/usr/bin/env -S bash --norc in body is preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/usr/bin/env -S bash --norc\necho hi\n"));
      expected = "#!/usr/bin/env -S bash --norc";
    }

    {
      name = "mkScript: #!/usr/bin/env nix-shell in body is preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/usr/bin/env nix-shell\n#!nix-shell -p bash\necho hi\n"));
      expected = "#!/usr/bin/env nix-shell";
    }

    {
      name = "mkScript: explicit shebang= arg overrides profile default";
      got = firstLine (lib.mkScript { shebang = "#!/usr/bin/env bash5"; }
        (lib.sh "echo hi\n"));
      expected = "#!/usr/bin/env bash5";
    }

    {
      name = "mkScript: explicit lang= arg selects a different profile shebang";
      got = firstLine (lib.mkScript { lang = "python"; }
        (lib.sh "print('hi')\n"));
      expected = "#!/usr/bin/env python3";
    }

    # ----------------------------------------------------------------
    # mkScript — strict mode
    # ----------------------------------------------------------------
    {
      name = "mkScript bash: set -euo pipefail present by default";
      got = contains "set -euo pipefail" (lib.mkScript { } (lib.sh "echo hi\n"));
      expected = true;
    }

    {
      name = "mkScript bash: strict=false suppresses set -euo pipefail";
      got = contains "set -euo pipefail" (lib.mkScript { strict = false; } (lib.sh "echo hi\n"));
      expected = false;
    }

    {
      name = "mkScript python: no set -euo pipefail";
      got = contains "set -euo pipefail" (lib.mkScript { } (lib.py "print('hi')\n"));
      expected = false;
    }

    {
      name = "mkScript deno: no set -euo pipefail";
      got = contains "set -euo pipefail" (lib.mkScript { } (lib.deno "console.log('hi')\n"));
      expected = false;
    }

    {
      name = "mkScript bun: no set -euo pipefail";
      got = contains "set -euo pipefail" (lib.mkScript { } (lib.bun "console.log('hi')\n"));
      expected = false;
    }

    {
      name = "mkScript node: no set -euo pipefail";
      got = contains "set -euo pipefail" (lib.mkScript { } (lib.node "console.log('hi')\n"));
      expected = false;
    }

    # ----------------------------------------------------------------
    # mkScript — complex shell syntax passes through intact
    # ----------------------------------------------------------------
    {
      name = "mkScript: basic body content present";
      got = contains "echo hello" (lib.mkScript { } (lib.sh "echo hello\n"));
      expected = true;
    }

    {
      name = "mkScript: glob */ passes through";
      got = contains "for d in */" (lib.mkScript { } (lib.sh "for d in */; do echo \"$d\"; done\n"));
      expected = true;
    }

    {
      name = "mkScript: pipeline | passes through";
      got = contains "ls | grep foo" (lib.mkScript { } (lib.sh "ls | grep foo\n"));
      expected = true;
    }

    {
      name = "mkScript: subshell (cmd) passes through";
      got = contains "(cd /tmp && ls)" (lib.mkScript { } (lib.sh "(cd /tmp && ls)\n"));
      expected = true;
    }

    {
      name = "mkScript: arithmetic (( expr )) passes through";
      got = contains "(( x + 1 ))" (lib.mkScript { } (lib.sh "(( x + 1 ))\n"));
      expected = true;
    }

    {
      name = "mkScript: process substitution <(cmd) passes through";
      got = contains "diff <(sort a) <(sort b)" (lib.mkScript { } (lib.sh "diff <(sort a) <(sort b)\n"));
      expected = true;
    }

    {
      name = "mkScript: array literal arr=(a b c) passes through";
      got = contains "arr=(a b c)" (lib.mkScript { } (lib.sh "arr=(a b c)\n"));
      expected = true;
    }

    {
      name = "mkScript: sed with * delimiter passes through";
      got = contains "sed 's*foo*bar*'" (lib.mkScript { } (lib.sh "sed 's*foo*bar*'\n"));
      expected = true;
    }

    {
      name = "mkScript: heredoc <<'EOF' passes through";
      got = contains "cat <<'EOF'" (lib.mkScript { } (lib.sh "cat <<'EOF'\nhello\nEOF\n"));
      expected = true;
    }

    {
      name = "mkScript: case statement passes through";
      got = contains "case \"$x\" in" (lib.mkScript { } (lib.sh "case \"$x\" in\n  a) echo a;;\nesac\n"));
      expected = true;
    }

    {
      name = "mkScript: function definition passes through";
      got = contains "my_func() {" (lib.mkScript { } (lib.sh "my_func() {\n  echo hi\n}\n"));
      expected = true;
    }

    {
      name = "mkScript: [[ double bracket ]] passes through";
      got = contains "[[ -f foo ]] && echo yes" (lib.mkScript { } (lib.sh "[[ -f foo ]] && echo yes\n"));
      expected = true;
    }

    {
      name = "mkScript: brace expansion {a,b,c} passes through";
      got = contains "echo {a,b,c}" (lib.mkScript { } (lib.sh "echo {a,b,c}\n"));
      expected = true;
    }

    {
      name = "mkScript: tilde ~ passes through";
      got = contains "cd ~/work" (lib.mkScript { } (lib.sh "cd ~/work\n"));
      expected = true;
    }

    {
      name = "mkScript: multiline if-then-fi passes through";
      got = contains "if [[ $x -gt 0 ]]; then" (lib.mkScript { } (lib.sh "if [[ \$x -gt 0 ]]; then\n  echo pos\nfi\n"));
      expected = true;
    }

    {
      name = "mkScript: bang negation ! passes through";
      got = contains "! grep" (lib.mkScript { } (lib.sh "! grep foo bar\n"));
      expected = true;
    }

    {
      name = "mkScript: here-string <<< passes through";
      got = contains "grep foo <<<\"$bar\"" (lib.mkScript { } (lib.sh "grep foo <<<\"$bar\"\n"));
      expected = true;
    }

    {
      name = "mkScript: while read loop passes through";
      got = contains "while IFS= read -r line" (lib.mkScript { } (lib.sh "while IFS= read -r line; do echo \"$line\"; done\n"));
      expected = true;
    }

    {
      name = "mkScript: mapfile/readarray passes through";
      got = contains "mapfile -t lines" (lib.mkScript { } (lib.sh "mapfile -t lines < file.txt\n"));
      expected = true;
    }

    {
      name = "mkScript: printf with format string passes through";
      got = contains "printf '%s\\n'" (lib.mkScript { } (lib.sh "printf '%s\\n' \"$x\"\n"));
      expected = true;
    }

    # ----------------------------------------------------------------
    # substVars integration (via mkScript vars=)
    # ----------------------------------------------------------------
    {
      name = "substVars @nix(x): integer raw value";
      got = contains "echo 42" (lib.mkScript { vars = { port = 42; }; } (lib.sh "echo @nix(port)\n"));
      expected = true;
    }

    {
      name = "substVars @sh:q(x): value shell-quoted";
      got = contains "echo 'hello world'" (lib.mkScript { vars = { msg = "hello world"; }; } (lib.sh "echo @sh:q(msg)\n"));
      expected = true;
    }

    {
      name = "substVars @sh:q(x): single quotes in value escaped";
      got = contains "echo 'it'\\''s'" (lib.mkScript { vars = { msg = "it's"; }; } (lib.sh "echo @sh:q(msg)\n"));
      expected = true;
    }

    {
      name = "substVars @nix:q(x) is identical to @sh:q(x)";
      got = (lib.mkScript { vars = { x = "hello"; }; } (lib.sh "echo @nix:q(x)\n"))
        == (lib.mkScript { vars = { x = "hello"; }; } (lib.sh "echo @sh:q(x)\n"));
      expected = true;
    }

    {
      name = "substVars: multiple vars replaced";
      got =
        let out = lib.mkScript { vars = { a = 3000; b = 8080; }; } (lib.sh "echo @nix(a) @nix(b)\n");
        in contains "3000" out && contains "8080" out;
      expected = true;
    }

    {
      name = "substVars: unknown marker left unchanged when no vars given";
      got = contains "@nix(port)" (lib.mkScript { } (lib.sh "echo @nix(port)\n"));
      expected = true;
    }

    {
      name = "substVars @py:q(x): python double-quoted string";
      got = contains "print(\"hello\")" (lib.mkScript { vars = { msg = "hello"; }; } (lib.py "print(@py:q(msg))\n"));
      expected = true;
    }

    {
      name = "substVars @js:q(x): js double-quoted string";
      got = contains "console.log(\"hello\")" (lib.mkScript { vars = { msg = "hello"; }; } (lib.bun "console.log(@js:q(msg))\n"));
      expected = true;
    }

    # ----------------------------------------------------------------
    # mkTasks — runner generation
    # ----------------------------------------------------------------
    {
      name = "mkTasks runner: first line is #!/usr/bin/env bash";
      got = firstLine (lib.mkTasks { } { build = lib.sh "make\n"; }).runner;
      expected = "#!/usr/bin/env bash";
    }

    {
      name = "mkTasks runner: set -euo pipefail present";
      got = contains "set -euo pipefail" (lib.mkTasks { } { build = lib.sh "make\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: task function emitted";
      got = contains "task_build() {" (lib.mkTasks { } { build = lib.sh "make\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: dispatcher _nixx_run emitted";
      got = contains "_nixx_run() {" (lib.mkTasks { } { build = lib.sh "make\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: run-once guard _NIXX_DONE present";
      got = contains "_NIXX_DONE" (lib.mkTasks { } { build = lib.sh "make\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: case dispatch for task";
      got = contains "build) shift; task_build" (lib.mkTasks { } { build = lib.sh "make\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: body content included";
      got = contains "make" (lib.mkTasks { } { build = lib.sh "make\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: two tasks both emitted";
      got =
        let r = (lib.mkTasks { } { build = lib.sh "make\n"; test = lib.sh "cargo test\n"; }).runner;
        in contains "task_build() {" r && contains "task_test() {" r;
      expected = true;
    }

    {
      name = "mkTasks runner: task content after stripped shebang is preserved";
      got = contains "echo hi"
        (lib.mkTasks { } { build = lib.sh "#!/usr/bin/env bash\necho hi\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: python body uses python3 heredoc";
      got = contains "python3 <<'" (lib.mkTasks { } { run = lib.py "print('hi')\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: node body uses node --input-type=module heredoc";
      got = contains "node --input-type=module <<'" (lib.mkTasks { } { run = lib.node "console.log('hi')\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: bun body uses bun run - heredoc";
      got = contains "bun run - <<'" (lib.mkTasks { } { run = lib.bun "console.log('hi')\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: ts body uses tsx heredoc";
      got = contains "tsx <<'" (lib.mkTasks { } { run = lib.ts "console.log('hi')\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: deno body uses deno run -A - heredoc";
      got = contains "deno run -A - <<'" (lib.mkTasks { } { run = lib.deno "console.log('hi')\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: ruby body uses ruby heredoc";
      got = contains "ruby <<'" (lib.mkTasks { } { run = lib.ruby "puts 'hi'\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: lua body uses lua - heredoc";
      got = contains "lua - <<'" (lib.mkTasks { } { run = lib.lua "print('hi')\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: vars substituted in task body";
      got = contains "echo 9000"
        (lib.mkTasks { vars = { port = 9000; }; } { run = lib.sh "echo @nix(port)\n"; }).runner;
      expected = true;
    }

    {
      name = "mkTasks: .tasks is an attrset";
      got = isAttrs (lib.mkTasks { } { build = lib.sh "make\n"; }).tasks;
      expected = true;
    }

    {
      name = "mkTasks: .meta is a list";
      got = isList (lib.mkTasks { } { build = lib.sh "make\n"; }).meta;
      expected = true;
    }

    {
      name = "mkTasks: task text accessible via .tasks.name.text";
      got = (lib.mkTasks { } { build = lib.sh "make\n"; }).tasks.build.text;
      expected = "make\n";
    }

    # ----------------------------------------------------------------
    # mkTasks — task descriptions (just-style --list)
    # ----------------------------------------------------------------
    {
      name = "task: description from opts stored on block";
      got = (lib.task { description = "Build it"; } (lib.sh "make\n")).description;
      expected = "Build it";
    }

    {
      name = "task: description defaults to null";
      got = (lib.task { } (lib.sh "make\n")).description;
      expected = null;
    }

    {
      name = "mkTasks: description accessible via .tasks.name.description";
      got = (lib.mkTasks { } {
        build = lib.task { description = "Build it"; } (lib.sh "make\n");
      }).tasks.build.description;
      expected = "Build it";
    }

    {
      name = "mkTasks: description surfaced in .meta";
      got =
        let
          meta = (lib.mkTasks { } {
            deploy = lib.task { description = "Deploy production"; } (lib.sh "aws s3 sync\n");
          }).meta;
        in
        (head meta).description;
      expected = "Deploy production";
    }

    {
      name = "mkTasks runner: --list shows the description text";
      got = contains "Deploy production"
        (lib.mkTasks { } {
          deploy = lib.task { description = "Deploy production"; } (lib.sh "aws s3 sync\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: --list still lists a task with no description";
      got = contains "printf '  %s\\n' 'build'"
        (lib.mkTasks { } {
          build = lib.sh "make\n";
        }).runner;
      expected = true;
    }

    # ----------------------------------------------------------------
    # Task groups (--list grouped display)
    # ----------------------------------------------------------------

    {
      name = "task: group from opts stored on block";
      got = (lib.task { group = "release"; } (lib.sh "deploy\n")).group;
      expected = "release";
    }

    {
      name = "task: group defaults to null";
      got = (lib.task { } (lib.sh "make\n")).group;
      expected = null;
    }

    {
      name = "mkTasks: group accessible via .tasks.name.group";
      got = (lib.mkTasks { } {
        deploy = lib.task { group = "release"; } (lib.sh "aws s3 sync\n");
      }).tasks.deploy.group;
      expected = "release";
    }

    {
      name = "mkTasks: group surfaced in .meta";
      got =
        let
          meta = (lib.mkTasks { } {
            deploy = lib.task { group = "release"; } (lib.sh "aws s3 sync\n");
          }).meta;
        in
        (head meta).group;
      expected = "release";
    }

    {
      name = "mkTasks runner: grouped --list emits group header";
      got = contains "printf '%s\\n' 'release:'"
        (lib.mkTasks { } {
          deploy = lib.task { description = "Deploy production"; group = "release"; } (lib.sh "aws s3 sync\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: grouped --list emits task under group";
      got = contains "Deploy production"
        (lib.mkTasks { } {
          deploy = lib.task { description = "Deploy production"; group = "release"; } (lib.sh "aws s3 sync\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: grouped --list omits 'available tasks:' header";
      got = contains "available tasks:"
        (lib.mkTasks { } {
          deploy = lib.task { group = "release"; } (lib.sh "aws s3 sync\n");
        }).runner;
      expected = false;
    }

    {
      name = "mkTasks runner: grouped --list emits blank-line separator between groups";
      got = contains "printf '\\n'"
        (lib.mkTasks { } {
          deploy = lib.task { group = "release"; } (lib.sh "aws s3 sync\n");
          build = lib.task { group = "dev"; } (lib.sh "make\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: multiple groups both emit their headers";
      got =
        let
          r = (lib.mkTasks { } {
            deploy = lib.task { group = "release"; } (lib.sh "aws s3 sync\n");
            build = lib.task { group = "dev"; } (lib.sh "make\n");
          }).runner;
        in
        contains "printf '%s\\n' 'release:'" r && contains "printf '%s\\n' 'dev:'" r;
      expected = true;
    }

    {
      name = "mkTasks runner: ungrouped tasks when no groups uses flat 'available tasks:'";
      got = contains "available tasks:"
        (lib.mkTasks { } {
          build = lib.sh "make\n";
        }).runner;
      expected = true;
    }

    # ----------------------------------------------------------------
    # Task env — per-task and global environment variables
    # ----------------------------------------------------------------
    {
      name = "task: env from opts stored on block";
      got = (lib.task { env = { FOO = "bar"; }; } (lib.sh "echo\n")).env;
      expected = { FOO = "bar"; };
    }

    {
      name = "task: env defaults to {}";
      got = (lib.task { } (lib.sh "echo\n")).env;
      expected = { };
    }

    {
      name = "mkTasks runner: env var exported in task function";
      got = contains "export FOO='bar'"
        (lib.mkTasks { } {
          run = lib.task { env = { FOO = "bar"; }; } (lib.sh "echo hi\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: multiple env vars all exported";
      got =
        let
          r = (lib.mkTasks { } {
            run = lib.task { env = { FOO = "hello"; BAR = "world"; }; } (lib.sh "echo hi\n");
          }).runner;
        in
        contains "export FOO=" r && contains "export BAR=" r;
      expected = true;
    }

    {
      name = "mkTasks runner: env value with spaces is shell-quoted";
      got = contains "export GREETING='hello world'"
        (lib.mkTasks { } {
          run = lib.task { env = { GREETING = "hello world"; }; } (lib.sh "echo hi\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: env value with single quote is POSIX-escaped";
      got = contains "export MSG='it'\\''s fine'"
        (lib.mkTasks { } {
          run = lib.task { env = { MSG = "it's fine"; }; } (lib.sh "echo hi\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks runner: no env export when task has no env";
      got = contains "export"
        (lib.mkTasks { } {
          run = lib.sh "echo hi\n";
        }).runner;
      expected = false;
    }

    {
      name = "mkTasks global env: applied to task with no per-task env";
      got = contains "export GLOBAL='1'"
        (lib.mkTasks { env = { GLOBAL = "1"; }; } {
          run = lib.sh "echo hi\n";
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks global env: applied to all tasks";
      got =
        let
          r = (lib.mkTasks { env = { SHARED = "yes"; }; } {
            task1 = lib.sh "echo one\n";
            task2 = lib.sh "echo two\n";
          }).runner;
          count = length (filter (l: l == "  export SHARED='yes'") (splitLines r));
        in
        count == 2;
      expected = true;
    }

    {
      name = "mkTasks global env: per-task env overrides global for same key";
      got = contains "export FOO='local'"
        (lib.mkTasks { env = { FOO = "global"; }; } {
          run = lib.task { env = { FOO = "local"; }; } (lib.sh "echo hi\n");
        }).runner;
      expected = true;
    }

    {
      name = "mkTasks global env: global value absent when overridden by per-task";
      got = contains "export FOO='global'"
        (lib.mkTasks { env = { FOO = "global"; }; } {
          run = lib.task { env = { FOO = "local"; }; } (lib.sh "echo hi\n");
        }).runner;
      expected = false;
    }

    {
      name = "mkTasks global env: per-task extra keys merged with global";
      got =
        let
          r = (lib.mkTasks { env = { GLOBAL = "g"; }; } {
            run = lib.task { env = { LOCAL = "l"; }; } (lib.sh "echo hi\n");
          }).runner;
        in
        contains "export GLOBAL=" r && contains "export LOCAL=" r;
      expected = true;
    }

    # ----------------------------------------------------------------
    # Complex shebang scenarios
    # ----------------------------------------------------------------
    {
      name = "shebang: env -S with multiple flags preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/usr/bin/env -S bash -x --norc\necho hi\n"));
      expected = "#!/usr/bin/env -S bash -x --norc";
    }

    {
      name = "shebang: absolute /bin/bash preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/bin/bash\nset -e\necho hi\n"));
      expected = "#!/bin/bash";
    }

    {
      name = "shebang: absolute /bin/sh preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/bin/sh\nset -e\necho hi\n"));
      expected = "#!/bin/sh";
    }

    {
      name = "shebang: uv run with version constraint preserved";
      got = firstLine (lib.mkScript { } (lib.py "#!/usr/bin/env -S uv run --python 3.12 --script\nprint('hi')\n"));
      expected = "#!/usr/bin/env -S uv run --python 3.12 --script";
    }

    {
      name = "shebang: nix-shell polyglot shebang preserved";
      got = firstLine (lib.mkScript { } (lib.sh "#!/usr/bin/env nix-shell\n#!nix-shell -i bash -p hello\necho hi\n"));
      expected = "#!/usr/bin/env nix-shell";
    }

    # ----------------------------------------------------------------
    # source-read bodies — the ${VAR} antiquotation tax, defeated.
    # Under `with lib.runtimeScope;` a literal `bash ''...''` (or node/perl/...)
    # passed to mkTasks/mkScripts is read from SOURCE, so a ${VAR} in the
    # ${}-family survives verbatim with NO '' prefix. The body is never forced,
    # so undefined-in-Nix names like HOME never error.
    # ----------------------------------------------------------------
    {
      name = "source-read: block __sh is true";
      got = (lib.bash "placeholder").__sh;
      expected = true;
    }

    {
      name = "source-read: bash __lang is bash";
      got = (lib.bash "placeholder").__lang;
      expected = "bash";
    }

    {
      name = "source-read: description carried via task wrapper";
      got = (lib.task { description = "Deploy"; } (lib.bash "x")).description;
      expected = "Deploy";
    }

    {
      name = "source-read: deps carried via task wrapper";
      got = (lib.task { deps = [ "setup" ]; } (lib.bash "x")).deps;
      expected = [ "setup" ];
    }

    # The headline: shell ${VAR} recovered VERBATIM, zero prefix. HOME/PORT are
    # undefined in Nix — a body that got EVALUATED would throw here.
    {
      name = "source-read: shell \${HOME} verbatim, zero prefix";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          dev = lib.bash ''
            echo ${HOME}
          '';
        }).tasks.dev.text;
      expected = "echo \${HOME}\n";
    }

    {
      name = "source-read: multiple shell vars in one body";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          dev = lib.bash ''
            echo ${HOME}
            npm run -- --port ${PORT}
          '';
        }).tasks.dev.text;
      expected = "echo \${HOME}\nnpm run -- --port \${PORT}\n";
    }

    {
      name = "source-read: \$VAR (no braces) also raw";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          dev = lib.bash ''
            ls $PWD
          '';
        }).tasks.dev.text;
      expected = "ls $PWD\n";
    }

    # node/ts/bun/deno: the SAME mechanism rescues JS template-literal ${x}.
    {
      name = "source-read: node template literal `\${x}` survives";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          hi = lib.node ''
            console.log(`hi ${name}`)
          '';
        }).tasks.hi.text;
      expected = "console.log(`hi \${name}`)\n";
    }

    # perl: $VAR / ${VAR} survive too; runner pipes it to the perl interpreter.
    {
      name = "source-read: perl \${VAR} verbatim";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          p = lib.perl ''
            print ${MSG};
          '';
        }).tasks.p.text;
      expected = "print \${MSG};\n";
    }

    {
      name = "perl: task body piped to perl heredoc in runner";
      got = with lib.runtimeScope;
        contains "perl <<'NIXX_EOT"
          (lib.mkTasks { name = "t"; } {
            p = lib.perl ''
              print ${MSG};
            '';
          }).runner;
      expected = true;
    }

    # THE GUARD: a programmatic body (no literal '') has no source to read, so
    # it falls back to ordinary evaluation — it must NOT steal a neighbour's ''.
    {
      name = "guard: programmatic body falls back to evaluation (no corruption)";
      got =
        let cmd = "make build\n"; in
        (lib.mkTasks { } {
          a = lib.sh cmd;
          b = lib.sh ''
            echo NEIGHBOUR
          '';
        }).tasks.a.text;
      expected = "make build\n";
    }

    {
      name = "guard: opts brace `;` does not terminate the binding early";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          t = lib.task { env = { A = "1"; }; } (lib.bash ''
            echo ${HOME}
          '');
        }).tasks.t.text;
      expected = "echo \${HOME}\n";
    }

    {
      name = "source-read: @nix() vars still substituted";
      got = with lib.runtimeScope;
        (lib.mkTasks { vars = { port = 9000; }; } {
          svc = lib.bash ''
            echo ${HOST}
            echo @nix(port)
          '';
        }).tasks.svc.text;
      expected = "echo \${HOST}\necho 9000\n";
    }

    {
      name = "source-read: runner contains the source-read shell var";
      got =
        let
          r = with lib.runtimeScope;
            (lib.mkTasks { } {
              run = lib.bash ''
                echo ${HOME}
              '';
            }).runner;
        in
        contains ''echo ''\${HOME}'' r;
      expected = true;
    }

    {
      name = "source-read: task-wrapped body also read from source";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          wrapped = lib.task { description = "wrapped"; } (lib.bash ''
            echo ${HOME}
          '');
        }).tasks.wrapped.text;
      expected = "echo \${HOME}\n";
    }

    {
      name = "source-read: mkScripts preserves source-read shell var";
      got =
        let
          s = with lib.runtimeScope;
            (lib.mkScripts { } {
              deploy = lib.bash ''
                echo ${HOME}
              '';
            }).scripts.deploy;
        in
        contains ''echo ''\${HOME}'' s;
      expected = true;
    }

    {
      name = "source-read: replays Nix ''' -> '' escape";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          t = lib.bash ''
            echo a'''b
          '';
        }).tasks.t.text;
      expected = "echo a''b\n";
    }

    {
      name = "source-read: multiline body extracted and dedented";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          multi = lib.bash ''
            echo ${HOME}
            ls $PWD
          '';
        }).tasks.multi.text;
      expected = "echo \${HOME}\nls $PWD\n";
    }

    # Bash parameter expansion coverage. The common forms parse as Nix
    # antiquotation bodies and so work with ZERO prefix. The array/length forms
    # are NOT valid Nix inside ${...}, so they hit the parse wall before any
    # source read can happen — they still need the '' prefix (which the scanner
    # then replays back to a literal $). This is the one residual tax.
    {
      name = "source-read: \${VAR:-default} works with zero prefix";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          t = lib.bash ''
            echo ${VAR:-default}
          '';
        }).tasks.t.text;
      expected = "echo \${VAR:-default}\n";
    }

    {
      name = "source-read: \${VAR/old/new} works with zero prefix";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          t = lib.bash ''
            echo ${VAR/old/new}
          '';
        }).tasks.t.text;
      expected = "echo \${VAR/old/new}\n";
    }

    {
      name = "source-read: parse-wall \${ARR[@]} needs '' (scanner replays \$)";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          t = lib.bash ''
            for x in ''${ARR[@]}; do echo "$x"; done
          '';
        }).tasks.t.text;
      expected = "for x in \${ARR[@]}; do echo \"\$x\"; done\n";
    }

    {
      name = "source-read: parse-wall \${#VAR} needs '' (scanner replays \$)";
      got = with lib.runtimeScope;
        (lib.mkTasks { } {
          t = lib.bash ''
            echo ''${#VAR}
          '';
        }).tasks.t.text;
      expected = "echo \${#VAR}\n";
    }

  ];

  run = t: if t.got == t.expected then null else t;
  failures = filter (x: x != null) (map run tests);
  total = length tests;
  nfail = length failures;
  failReport = concatStringsSep "\n\n" (map
    (f:
      "FAIL  ${f.name}\n  got:      ${builtins.toJSON f.got}\n  expected: ${builtins.toJSON f.expected}"
    )
    failures);

in
if failures == [ ]
then "ALL ${toString total} TESTS PASSED"
else throw "\n\n${failReport}\n\n${toString nfail}/${toString total} FAILED"
