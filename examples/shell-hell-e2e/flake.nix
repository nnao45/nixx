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
                step2 = n.task { deps = [ "step1" ]; } (n.sh ''
                  test "''${LINEAR:-}" = "ran" \
                    || { echo "FAIL: step1 did not run before step2"; exit 1; }
                  export LINEAR="step2"
                '');
                step3 = n.task { deps = [ "step2" ]; } (n.sh ''
                  test "$LINEAR" = "step2" \
                    || { echo "FAIL: step2 did not run before step3"; exit 1; }
                  echo "PASS: linear chain"
                '');

                # A2: diamond  d→{b,c}→a  — a must execute exactly once (guard)
                dia_a = n.sh ''
                  export DIA_COUNT=''${DIA_COUNT:-0}
                  DIA_COUNT=$((DIA_COUNT + 1))
                  export DIA_COUNT
                '';
                dia_b = n.task { deps = [ "dia_a" ]; } (n.sh ''export DIA_B=1'');
                dia_c = n.task { deps = [ "dia_a" ]; } (n.sh ''export DIA_C=1'');
                dia_d = n.task { deps = [ "dia_b" "dia_c" ]; } (n.sh ''
                  test "$DIA_COUNT" -eq 1 \
                    || { echo "FAIL: dia_a ran $DIA_COUNT times (expected 1)"; exit 1; }
                  test "''${DIA_B:-}" = "1" || { echo "FAIL: dia_b missing"; exit 1; }
                  test "''${DIA_C:-}" = "1" || { echo "FAIL: dia_c missing"; exit 1; }
                  echo "PASS: diamond deps"
                '');

                all = n.task { deps = [ "step3" "dia_d" ]; } (n.sh ''
                  echo "=== e2e-deps: ALL PASSED ==="
                '');
              }).runner;

            # ── e2e-env: env vars, global packages (PATH), cwd ──────────────────
            e2eEnv = pkgs.writeShellApplication {
              name = "e2e-env";
              runtimeInputs = [ pkgs.jq ];
              text = (n.mkTasks { name = "e2e-env"; } {
                env_test = n.task
                  {
                    env = {
                      FOO = "hello world";
                      BAR = "it's a test";
                    };
                  }
                  (n.sh ''
                    test "$FOO" = "hello world" || { echo "FAIL: FOO=$FOO"; exit 1; }
                    test "$BAR" = "it's a test"  || { echo "FAIL: BAR=$BAR"; exit 1; }
                    echo "PASS: env variables"
                  '');

                path_test = n.sh ''
                  command -v jq >/dev/null || { echo "FAIL: jq not in PATH"; exit 1; }
                  echo '{"ok":true}' | jq -e .ok >/dev/null \
                    || { echo "FAIL: jq not functional"; exit 1; }
                  echo "PASS: global packages/PATH"
                '';

                cwd_test = n.task { cwd = "/tmp"; } (n.sh ''
                  test "$(pwd)" = "/tmp" \
                    || { echo "FAIL: cwd=$(pwd) expected=/tmp"; exit 1; }
                  echo "PASS: cwd"
                '');

                all = n.task { deps = [ "env_test" "path_test" "cwd_test" ]; } (n.sh ''
                  echo "=== e2e-env: ALL PASSED ==="
                '');
              }).runner;
            };

            # ── e2e-strict: cwd + shell options are re-asserted per task ─────────
            # One bash process, so env exports persist (see e2e-combo) — but cwd
            # and shell options must NOT leak across deps: a prior task's `cd` /
            # `set +u` is reset at the next task's entry.
            e2eStrict = mkE2e "e2e-strict"
              (n.mkTasks { name = "e2e-strict"; } {
                loosen = n.sh ''set +u'';

                reasserted = n.task { deps = [ "loosen" ]; } (n.sh ''
                  case "$-" in *u*) ;; *) echo "FAIL: -u leaked off from a prior task"; exit 1 ;; esac
                  case "$-" in *e*) ;; *) echo "FAIL: -e leaked off from a prior task"; exit 1 ;; esac
                  echo "PASS: shell options re-asserted per task (no leak)"
                '');

                chdir = n.task { cwd = "/"; } (n.sh ''test "$PWD" = "/"'');

                cwd_reset = n.task { deps = [ "chdir" ]; } (n.sh ''
                  test "$PWD" != "/" || { echo "FAIL: dep's cd / leaked into this task"; exit 1; }
                  echo "PASS: cwd reset to invocation dir (no leak)"
                '');

                all = n.task { deps = [ "reasserted" "cwd_reset" ]; } (n.sh ''
                  echo "=== e2e-strict: ALL PASSED ==="
                '');
              }).runner;

            # ── e2e-combo: parent export propagates to child (same bash process) ──
            e2eCombo = mkE2e "e2e-combo"
              (n.mkTasks { name = "e2e-combo"; } {
                setter = n.sh ''
                  export COMBO_VAR="from_parent"
                  export COMBO_EXTRA="also_visible"
                '';

                getter = n.task { deps = [ "setter" ]; } (n.sh ''
                  test "$COMBO_VAR" = "from_parent" \
                    || { echo "FAIL: COMBO_VAR=$COMBO_VAR"; exit 1; }
                  test "$COMBO_EXTRA" = "also_visible" \
                    || { echo "FAIL: COMBO_EXTRA=$COMBO_EXTRA"; exit 1; }
                  echo "PASS: parent export propagates to child"
                '');

                all = n.task { deps = [ "getter" ]; } (n.sh ''
                  echo "=== e2e-combo: ALL PASSED ==="
                '');
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
                  special_chars = n.task
                    {
                      env = {
                        WITH_SPACES = "hello world";
                        WITH_QUOTE = "it's a test";
                        WITH_BACKSLASH = "path/to\\file";
                        WITH_DOLLAR = "dollar dollar";
                      };
                    }
                    (n.sh ''
                      test "$WITH_SPACES" = "hello world" \
                        || { echo "FAIL: WITH_SPACES=$WITH_SPACES"; exit 1; }
                      test "$WITH_QUOTE" = "it's a test" \
                        || { echo "FAIL: WITH_QUOTE=$WITH_QUOTE"; exit 1; }
                      test "$WITH_BACKSLASH" = 'path/to\file' \
                        || { echo "FAIL: WITH_BACKSLASH=$WITH_BACKSLASH"; exit 1; }
                      test "$WITH_DOLLAR" = "dollar dollar" \
                        || { echo "FAIL: WITH_DOLLAR=$WITH_DOLLAR"; exit 1; }
                      echo "PASS: special chars in env"
                    '');

                  # E6: multi defaultDeps — setup_a and setup_b run before every task
                  setup_a = n.sh ''export SETUP_A=1'';
                  setup_b = n.sh ''export SETUP_B=1'';

                  verify_setups = n.sh ''
                    test "''${SETUP_A:-}" = "1" || { echo "FAIL: setup_a didn't run"; exit 1; }
                    test "''${SETUP_B:-}" = "1" || { echo "FAIL: setup_b didn't run"; exit 1; }
                    echo "PASS: multi defaultDeps"
                  '';

                  all = n.task { deps = [ "empty" "special_chars" "verify_setups" ]; } (n.sh ''
                    echo "=== e2e-edge: ALL PASSED ==="
                  '');
                }).runner;

            # ── e2e-circular: circular deps handled by run-once guard ─────────────
            e2eCircular = mkE2e "e2e-circular"
              (n.mkTasks { name = "e2e-circular"; } {
                circ_a = n.task { deps = [ "circ_b" ]; } (n.sh ''
                  export CIRC_A=1
                '');
                circ_b = n.task { deps = [ "circ_a" ]; } (n.sh ''
                  export CIRC_B=1
                '');

                verify = n.task { deps = [ "circ_a" "circ_b" ]; } (n.sh ''
                  # guard prevents infinite recursion: each task runs once
                  test "''${CIRC_A:-}" = "1" || { echo "FAIL: circ_a body didn't run"; exit 1; }
                  test "''${CIRC_B:-}" = "1" || { echo "FAIL: circ_b body didn't run"; exit 1; }
                  echo "PASS: circular deps handled by guard"
                '');

                all = n.task { deps = [ "verify" ]; } (n.sh ''
                  echo "=== e2e-circular: ALL PASSED ==="
                '');
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
                  all = n.task { deps = [ "uses_pkg" "not_listed" ]; } (n.sh ''
                    echo "=== e2e-packages: ALL PASSED ==="
                  '');
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

          in
          {
            e2e-deps = e2eDeps;
            e2e-env = e2eEnv;
            e2e-strict = e2eStrict;
            e2e-combo = e2eCombo;
            e2e-edge = e2eEdge;
            e2e-circular = e2eCircular;
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
            echo "  nix build .#e2e-packages      packages → runner PATH + devShell exposure"
          '';
        };
      });
}
