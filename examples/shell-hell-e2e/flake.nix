{
  description = "nixx shell-hell-e2e — stress-test mkTasks with complex shell scenarios";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixx.url = "path:../..";
  };

  outputs = { nixpkgs, flake-utils, nixx, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        n = nixx.lib;
        # pkgs-bound mkTasks (carries the global `packages` option + devShell).
        w = nixx.writers pkgs;
        mkE2e = name: runner:
          pkgs.writeShellApplication { inherit name; text = runner; };
      in
      {
        packages =
          let

            # ── e2e-deps: dependency chains, diamond, guard ──────────────────────
            e2eDeps = mkE2e "e2e-deps"
              (n.mkTasks { name = "e2e-deps"; } {
                # A1: linear chain  step1 → step2 → step3
                step1 = n.sh ''export LINEAR="ran"'';
                step2 = (n.sh ''
                  test "''${LINEAR:-}" = "ran" \
                    || { echo "FAIL: step1 did not run before step2"; exit 1; }
                  export LINEAR="step2"
                '') { deps = [ "step1" ]; };
                step3 = (n.sh ''
                  test "$LINEAR" = "step2" \
                    || { echo "FAIL: step2 did not run before step3"; exit 1; }
                  echo "PASS: linear chain"
                '') { deps = [ "step2" ]; };

                # A2: diamond  d→{b,c}→a  — a must execute exactly once (guard)
                dia_a = n.sh ''
                  export DIA_COUNT=''${DIA_COUNT:-0}
                  DIA_COUNT=$((DIA_COUNT + 1))
                  export DIA_COUNT
                '';
                dia_b = (n.sh ''export DIA_B=1'') { deps = [ "dia_a" ]; };
                dia_c = (n.sh ''export DIA_C=1'') { deps = [ "dia_a" ]; };
                dia_d = (n.sh ''
                  test "$DIA_COUNT" -eq 1 \
                    || { echo "FAIL: dia_a ran $DIA_COUNT times (expected 1)"; exit 1; }
                  test "''${DIA_B:-}" = "1" || { echo "FAIL: dia_b missing"; exit 1; }
                  test "''${DIA_C:-}" = "1" || { echo "FAIL: dia_c missing"; exit 1; }
                  echo "PASS: diamond deps"
                '') { deps = [ "dia_b" "dia_c" ]; };

                all = (n.sh ''
                  echo "=== e2e-deps: ALL PASSED ==="
                '') { deps = [ "step3" "dia_d" ]; };
              }).runner;

            # ── e2e-env: env vars, global packages (PATH), cwd ──────────────────
            e2eEnv = pkgs.writeShellApplication {
              name = "e2e-env";
              runtimeInputs = [ pkgs.jq ];
              text = (n.mkTasks { name = "e2e-env"; } {
                env_test = (n.sh ''
                    test "$FOO" = "hello world" || { echo "FAIL: FOO=$FOO"; exit 1; }
                    test "$BAR" = "it's a test"  || { echo "FAIL: BAR=$BAR"; exit 1; }
                    echo "PASS: env variables"
                  '') {
                    env = {
                      FOO = "hello world";
                      BAR = "it's a test";
                    };
                  };

                path_test = n.sh ''
                  command -v jq >/dev/null || { echo "FAIL: jq not in PATH"; exit 1; }
                  echo '{"ok":true}' | jq -e .ok >/dev/null \
                    || { echo "FAIL: jq not functional"; exit 1; }
                  echo "PASS: global packages/PATH"
                '';

                cwd_test = (n.sh ''
                  test "$(pwd)" = "/tmp" \
                    || { echo "FAIL: cwd=$(pwd) expected=/tmp"; exit 1; }
                  echo "PASS: cwd"
                '') { cwd = "/tmp"; };

                all = (n.sh ''
                  echo "=== e2e-env: ALL PASSED ==="
                '') { deps = [ "env_test" "path_test" "cwd_test" ]; };
              }).runner;
            };

            # ── e2e-strict: cwd + shell options are re-asserted per task ─────────
            # One bash process, so env exports persist (see e2e-combo) — but cwd
            # and shell options must NOT leak across deps: a prior task's `cd` /
            # `set +u` is reset at the next task's entry.
            e2eStrict = mkE2e "e2e-strict"
              (n.mkTasks { name = "e2e-strict"; } {
                loosen = n.sh ''set +u'';

                reasserted = (n.sh ''
                  case "$-" in *u*) ;; *) echo "FAIL: -u leaked off from a prior task"; exit 1 ;; esac
                  case "$-" in *e*) ;; *) echo "FAIL: -e leaked off from a prior task"; exit 1 ;; esac
                  echo "PASS: shell options re-asserted per task (no leak)"
                '') { deps = [ "loosen" ]; };

                chdir = (n.sh ''test "$PWD" = "/"'') { cwd = "/"; };

                cwd_reset = (n.sh ''
                  test "$PWD" != "/" || { echo "FAIL: dep's cd / leaked into this task"; exit 1; }
                  echo "PASS: cwd reset to invocation dir (no leak)"
                '') { deps = [ "chdir" ]; };

                all = (n.sh ''
                  echo "=== e2e-strict: ALL PASSED ==="
                '') { deps = [ "reasserted" "cwd_reset" ]; };
              }).runner;

            # ── e2e-combo: parent export propagates to child (same bash process) ──
            e2eCombo = mkE2e "e2e-combo"
              (n.mkTasks { name = "e2e-combo"; } {
                setter = n.sh ''
                  export COMBO_VAR="from_parent"
                  export COMBO_EXTRA="also_visible"
                '';

                getter = (n.sh ''
                  test "$COMBO_VAR" = "from_parent" \
                    || { echo "FAIL: COMBO_VAR=$COMBO_VAR"; exit 1; }
                  test "$COMBO_EXTRA" = "also_visible" \
                    || { echo "FAIL: COMBO_EXTRA=$COMBO_EXTRA"; exit 1; }
                  echo "PASS: parent export propagates to child"
                '') { deps = [ "setter" ]; };

                all = (n.sh ''
                  echo "=== e2e-combo: ALL PASSED ==="
                '') { deps = [ "getter" ]; };
              }).runner;

            # ── e2e-edge: empty tasks, special chars, multi defaultDeps ───────────
            e2eEdge = mkE2e "e2e-edge"
              (n.mkTasks
                {
                  name = "e2e-edge";
                  defaultDeps = [ "setup_a" "setup_b" ];
                }
                {
                  # E2: empty task body
                  empty = n.sh ''''; # intentionally empty

                  # E5: special characters in env values
                  special_chars = (n.sh ''
                      test "$WITH_SPACES" = "hello world" \
                        || { echo "FAIL: WITH_SPACES=$WITH_SPACES"; exit 1; }
                      test "$WITH_QUOTE" = "it's a test" \
                        || { echo "FAIL: WITH_QUOTE=$WITH_QUOTE"; exit 1; }
                      test "$WITH_BACKSLASH" = 'path/to\file' \
                        || { echo "FAIL: WITH_BACKSLASH=$WITH_BACKSLASH"; exit 1; }
                      test "$WITH_DOLLAR" = "dollar dollar" \
                        || { echo "FAIL: WITH_DOLLAR=$WITH_DOLLAR"; exit 1; }
                      echo "PASS: special chars in env"
                    '') {
                      env = {
                        WITH_SPACES = "hello world";
                        WITH_QUOTE = "it's a test";
                        WITH_BACKSLASH = "path/to\\file";
                        WITH_DOLLAR = "dollar dollar";
                      };
                    };

                  # E6: multi defaultDeps — setup_a and setup_b run before every task
                  setup_a = n.sh ''export SETUP_A=1'';
                  setup_b = n.sh ''export SETUP_B=1'';

                  verify_setups = n.sh ''
                    test "''${SETUP_A:-}" = "1" || { echo "FAIL: setup_a didn't run"; exit 1; }
                    test "''${SETUP_B:-}" = "1" || { echo "FAIL: setup_b didn't run"; exit 1; }
                    echo "PASS: multi defaultDeps"
                  '';

                  all = (n.sh ''
                    echo "=== e2e-edge: ALL PASSED ==="
                  '') { deps = [ "empty" "special_chars" "verify_setups" ]; };
                }).runner;

            # ── e2e-circular: circular deps handled by run-once guard ─────────────
            e2eCircular = mkE2e "e2e-circular"
              (n.mkTasks { name = "e2e-circular"; } {
                circ_a = (n.sh ''
                  export CIRC_A=1
                '') { deps = [ "circ_b" ]; };
                circ_b = (n.sh ''
                  export CIRC_B=1
                '') { deps = [ "circ_a" ]; };

                verify = (n.sh ''
                  # guard prevents infinite recursion: each task runs once
                  test "''${CIRC_A:-}" = "1" || { echo "FAIL: circ_a body didn't run"; exit 1; }
                  test "''${CIRC_B:-}" = "1" || { echo "FAIL: circ_b body didn't run"; exit 1; }
                  echo "PASS: circular deps handled by guard"
                '') { deps = [ "circ_a" "circ_b" ]; };

                all = (n.sh ''
                  echo "=== e2e-circular: ALL PASSED ==="
                '') { deps = [ "verify" ]; };
              }).runner;

            # ── e2e-packages: command-dependency resolution via `packages` ────────
            # Actually RUNS the runner: `jq` resolves from the runner's own wrapped
            # runtimeInputs (no ambient jq), and an unlisted command (`rg`) stays
            # unresolved. Also eval-asserts that devShell + extendShell re-expose
            # `packages` on the prompt PATH (not only inside the wrapped runner).
            e2ePackages =
              let
                tasks = w.mkTasks { name = "e2e-packages"; packages = [ pkgs.jq ]; } {
                  uses_pkg = n.sh ''
                    command -v jq >/dev/null \
                      || { echo "FAIL: jq not resolved from packages"; exit 1; }
                    echo '{"ok":true}' | jq -e .ok >/dev/null \
                      || { echo "FAIL: jq present but not functional"; exit 1; }
                    echo "PASS: packages command resolved in runner (nix run path)"
                  '';
                  not_listed = n.sh ''
                    if command -v rg >/dev/null; then
                      echo "FAIL: ripgrep resolved but was never listed"; exit 1
                    fi
                    echo "PASS: a command absent from packages stays unresolved"
                  '';
                  all = (n.sh ''
                    echo "=== e2e-packages: ALL PASSED ==="
                  '') { deps = [ "uses_pkg" "not_listed" ]; };
                };
                shellNames = shell: map (d: d.name or "?")
                  ((shell.buildInputs or [ ])
                    ++ (shell.nativeBuildInputs or [ ])
                    ++ (shell.propagatedBuildInputs or [ ]));
                exposes = shell:
                  builtins.all (p: builtins.elem (p.name or "?") (shellNames shell)) [ pkgs.jq ];
              in
              assert exposes tasks.devShell || throw "devShell does not expose packages";
              assert exposes (tasks.extendShell (pkgs.mkShell { })) || throw "extendShell does not expose packages";
              pkgs.runCommand "e2e-packages" { } ''
                if command -v jq >/dev/null 2>&1; then
                  echo "PRECONDITION FAIL: jq on build PATH; test vacuous"; exit 1
                fi
                ${tasks.runner}/bin/e2e-packages all
                echo "PASS: devShell + extendShell expose packages (eval-asserted)"
                touch "$out"
              '';

            # ── e2e-expansion: the bash ${...} parameter-expansion zoo ───────────
            # IMPORTANT NUANCE: a bare ${VAR} survives source-read raw, but a
            # COMPLEX bash expansion (${VAR:-x}, ${a[@]}, ${v^^}, ${p##*/}, ${!r})
            # is NOT valid Nix, so Nix's lexer can't even parse the '' string —
            # these MUST keep the ''${ escape (nixx replays ''$ -> $ from source).
            # So: plain $VAR / ${VAR} = raw; everything fancier = ''${…}.
            e2eExpansion = mkE2e "e2e-expansion"
              (n.mkTasks { name = "e2e-expansion"; } {
                # default / alternate / assign — ''${VAR:-x} ''${VAR:+x} ''${VAR:=x}
                defaults = n.sh ''
                  unset MAYBE || true
                  test "''${MAYBE:-fallback}" = "fallback" || { echo "FAIL :-"; exit 1; }
                  test "''${MAYBE:+set}" = "" || { echo "FAIL :+ (unset)"; exit 1; }
                  VAL="x"
                  test "''${VAL:+present}" = "present" || { echo "FAIL :+ (set)"; exit 1; }
                  : "''${MAYBE:=assigned}"
                  test "$MAYBE" = "assigned" || { echo "FAIL :="; exit 1; }
                  echo "PASS: default / alternate / assign"
                '';

                # length & substring — ''${#VAR} ''${VAR:o:l} ''${VAR: -n}
                slicing = n.sh ''
                  s="hello world"
                  test "''${#s}" -eq 11       || { echo "FAIL length";          exit 1; }
                  test "''${s:0:5}" = "hello" || { echo "FAIL substr";          exit 1; }
                  test "''${s:6}" = "world"   || { echo "FAIL substr offset";   exit 1; }
                  test "''${s: -5}" = "world" || { echo "FAIL negative offset"; exit 1; }
                  echo "PASS: length & substring"
                '';

                # prefix/suffix trim — ''${VAR#p} ''${VAR##p} ''${VAR%s} ''${VAR%%s}
                trimming = n.sh ''
                  path="/usr/local/bin/nixx"
                  test "''${path##*/}" = "nixx"          || { echo "FAIL ##";          exit 1; }
                  test "''${path%/*}" = "/usr/local/bin" || { echo "FAIL %";           exit 1; }
                  file="archive.tar.gz"
                  test "''${file%.*}" = "archive.tar"    || { echo "FAIL % shortest";  exit 1; }
                  test "''${file%%.*}" = "archive"       || { echo "FAIL %% longest";  exit 1; }
                  test "''${file#*.}" = "tar.gz"         || { echo "FAIL # shortest";  exit 1; }
                  echo "PASS: prefix/suffix trimming"
                '';

                # pattern substitution — ''${VAR/p/r} ''${VAR//p/r} ''${VAR/#p/r} ''${VAR/%p/r}
                substitution = n.sh ''
                  csv="a,b,c,d"
                  test "''${csv/,/;}" = "a;b,c,d"  || { echo "FAIL / first";         exit 1; }
                  test "''${csv//,/;}" = "a;b;c;d" || { echo "FAIL // all";          exit 1; }
                  test "''${csv/#a/X}" = "X,b,c,d" || { echo "FAIL /# front-anchor"; exit 1; }
                  test "''${csv/%d/Z}" = "a,b,c,Z" || { echo "FAIL /% end-anchor";   exit 1; }
                  echo "PASS: pattern substitution"
                '';

                # case modification (bash 4+) — ''${VAR^^} ''${VAR,,} ''${VAR^}
                casing = n.sh ''
                  word="Hello"
                  test "''${word^^}" = "HELLO" || { echo "FAIL ^^";      exit 1; }
                  test "''${word,,}" = "hello" || { echo "FAIL ,,";      exit 1; }
                  low="abc"
                  test "''${low^}" = "Abc"     || { echo "FAIL ^ first"; exit 1; }
                  echo "PASS: case modification"
                '';

                # arrays & indirect expansion — ''${a[@]} ''${#a[@]} ''${!a[*]} ''${!ref}
                arrays = n.sh ''
                  arr=(alpha beta gamma)
                  test "''${#arr[@]}" -eq 3               || { echo "FAIL array length";   exit 1; }
                  test "''${arr[1]}" = "beta"             || { echo "FAIL array index";    exit 1; }
                  test "''${arr[*]}" = "alpha beta gamma" || { echo "FAIL array join";     exit 1; }
                  test "''${arr[-1]}" = "gamma"           || { echo "FAIL negative index"; exit 1; }
                  test "''${!arr[*]}" = "0 1 2"           || { echo "FAIL index list";     exit 1; }
                  # indirect expansion: ''${!ref} = value of the variable NAMED by $ref
                  # shellcheck disable=SC2034
                  greeting="bonjour"
                  ref="greeting"
                  test "''${!ref}" = "bonjour"            || { echo "FAIL indirect";       exit 1; }
                  echo "PASS: arrays & indirect expansion"
                '';

                # nested expansions + arithmetic + command substitution
                nested = n.sh ''
                  name="config.yaml"
                  ext="''${name##*.}"
                  base="''${name%.*}"
                  test "$ext" = "yaml"                        || { echo "FAIL nested ext"; exit 1; }
                  test "''${base}.''${ext^^}" = "config.YAML" || { echo "FAIL compose";    exit 1; }
                  count=5
                  acc=""
                  for ((i = 1; i <= count; i++)); do acc="''${acc}''${i} "; done
                  test "$acc" = "1 2 3 4 5 "                  || { echo "FAIL loop: $acc"; exit 1; }
                  test "$(printf '%s' "''${name^^}")" = "CONFIG.YAML" \
                    || { echo "FAIL cmd subst"; exit 1; }
                  echo "PASS: nested expansions & command substitution"
                '';

                all = (n.sh ''
                  echo "=== e2e-expansion: ALL PASSED ==="
                '') { deps = [ "defaults" "slicing" "trimming" "substitution" "casing" "arrays" "nested" ]; };
              }).runner;

          in
          {
            e2e-deps = e2eDeps;
            e2e-env = e2eEnv;
            e2e-strict = e2eStrict;
            e2e-combo = e2eCombo;
            e2e-edge = e2eEdge;
            e2e-circular = e2eCircular;
            e2e-expansion = e2eExpansion;
            e2e-packages = e2ePackages;

            default = pkgs.writeShellApplication {
              name = "e2e-all";
              text = ''
                echo "╔══════════════════════════════════════════╗"
                echo "║       nixx shell-hell-e2e suite          ║"
                echo "╚══════════════════════════════════════════╝"
                echo ""
                ${e2eDeps}/bin/e2e-deps all
                echo ""
                ${e2eEnv}/bin/e2e-env all
                echo ""
                ${e2eStrict}/bin/e2e-strict all
                echo ""
                ${e2eCombo}/bin/e2e-combo all
                echo ""
                ${e2eEdge}/bin/e2e-edge all
                echo ""
                ${e2eCircular}/bin/e2e-circular all
                echo ""
                ${e2eExpansion}/bin/e2e-expansion all
                echo ""
                echo "e2e-packages: built & asserted at ${e2ePackages}"
                echo ""
                echo "╔══════════════════════════════════════════╗"
                echo "║      ALL E2E TESTS PASSED ★              ║"
                echo "╚══════════════════════════════════════════╝"
              '';
            };
          };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.shellcheck pkgs.nixpkgs-fmt ];
          shellHook = ''
            echo "nixx shell-hell-e2e"
            echo "  nix run .#default          run all e2e tests"
            echo "  nix run .#e2e-deps -- all  deps / diamond / guard"
            echo "  nix run .#e2e-env -- all   env / PATH / cwd"
            echo "  nix run .#e2e-strict -- all  cwd/options no-leak"
            echo "  nix run .#e2e-combo -- all   parent→child export"
            echo "  nix run .#e2e-edge -- all    empty / special chars / defaultDeps"
            echo "  nix run .#e2e-circular -- all  circular deps"
            echo "  nix run .#e2e-expansion -- all  bash ''${...} parameter-expansion zoo"
            echo "  nix build .#e2e-packages      packages → runner PATH + devShell exposure"
          '';
        };
      });
}
