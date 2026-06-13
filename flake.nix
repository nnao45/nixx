{
  description = "nixx — write raw, lintable, multi-language scripts inside pure Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    let
      lib = import ./lib.nix;
      writersFor = pkgs: import ./writers.nix { inherit pkgs; nixx = lib; };
      forPkgs = pkgs: lib // (writersFor pkgs) // { inherit pkgs; };
    in
    {
      # System-independent outputs consumed by flake users:
      #   inputs.nixx.lib.bun ''...''
      #   inputs.nixx.writers pkgs
      inherit lib;
      writers = writersFor;

      # `for pkgs` — the batteries-included namespace: lib + pkgs-bound writers
      # + `pkgs`, in ONE set meant to be brought in with `with`:
      #
      #   with inputs.nixx.for pkgs;
      #   (mkTasks { } { dev = bash '' echo ${HOME} ''; }).devShell
      #
      # The single `with` does double duty: it un-prefixes the constructors AND
      # defers Nix's static undefined-variable check (any `with` makes the scope
      # dynamic), so a bare ${VAR} survives with no separate `runtimeScope`. The
      # writers' `mkTasks` (derivation + devShell + .tasks) shadows lib's.
      for = forPkgs;

      overlays.default = final: prev: {
        nixx = { inherit lib; writers = writersFor final; for = forPkgs; };
      };
    }
    //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        nixx = lib;
        inherit (writersFor pkgs) runApplication;

        # Pure-Nix lib tests, evaluated at flake-eval time.
        # A failing assertion throws here and prevents the flake from building.
        # The resulting script is shellcheck-gated via nixx's own runApplication.
        libTests =
          let ok = import ./tests/lib-tests.nix;
          in runApplication { name = "test"; } (nixx.sh "echo ${nixx.shq ok}\n");

        # ---- e2e stress tests (inline, shared logic with examples/shell-hell-e2e) ----
        mkE2e = name: runner:
          pkgs.writeShellApplication { inherit name; text = runner; };

        e2eDeps = mkE2e "e2e-deps"
          (nixx.mkTasks { name = "e2e-deps"; } {
            step1 = nixx.sh ''export LINEAR="ran"'';
            step2 = nixx.task { deps = [ "step1" ]; } (nixx.sh ''
              test "''${LINEAR:-}" = "ran" \
                || { echo "FAIL: step1 did not run before step2"; exit 1; }
              export LINEAR="step2"
            '');
            step3 = nixx.task { deps = [ "step2" ]; } (nixx.sh ''
              test "$LINEAR" = "step2" \
                || { echo "FAIL: step2 did not run before step3"; exit 1; }
              echo "PASS: linear chain"
            '');
            dia_a = nixx.sh ''
              export DIA_COUNT=''${DIA_COUNT:-0}
              DIA_COUNT=$((DIA_COUNT + 1))
              export DIA_COUNT
            '';
            dia_b = nixx.task { deps = [ "dia_a" ]; } (nixx.sh ''export DIA_B=1'');
            dia_c = nixx.task { deps = [ "dia_a" ]; } (nixx.sh ''export DIA_C=1'');
            dia_d = nixx.task { deps = [ "dia_b" "dia_c" ]; } (nixx.sh ''
              test "$DIA_COUNT" -eq 1 \
                || { echo "FAIL: dia_a ran $DIA_COUNT times (expected 1)"; exit 1; }
              test "''${DIA_B:-}" = "1" || { echo "FAIL: dia_b missing"; exit 1; }
              test "''${DIA_C:-}" = "1" || { echo "FAIL: dia_c missing"; exit 1; }
              echo "PASS: diamond deps"
            '');
            all = nixx.task { deps = [ "step3" "dia_d" ]; } (nixx.sh ''
              echo "=== e2e-deps: ALL PASSED ==="
            '');
          }).runner;

        e2eEnv = mkE2e "e2e-env"
          (nixx.mkTasks { name = "e2e-env"; } {
            env_test = nixx.task
              {
                env = { FOO = "hello world"; BAR = "it's a test"; };
              }
              (nixx.sh ''
                test "$FOO" = "hello world" || { echo "FAIL: FOO=$FOO"; exit 1; }
                test "$BAR" = "it's a test"  || { echo "FAIL: BAR=$BAR"; exit 1; }
                echo "PASS: env variables"
              '');
            path_test = nixx.task { requirements = [ pkgs.jq ]; } (nixx.sh ''
              command -v jq >/dev/null || { echo "FAIL: jq not in PATH"; exit 1; }
              echo '{"ok":true}' | jq -e .ok >/dev/null \
                || { echo "FAIL: jq not functional"; exit 1; }
              echo "PASS: requirements/PATH"
            '');
            cwd_test = nixx.task { cwd = "/tmp"; } (nixx.sh ''
              test "$(pwd)" = "/tmp" \
                || { echo "FAIL: cwd=$(pwd) expected=/tmp"; exit 1; }
              echo "PASS: cwd"
            '');
            all = nixx.task { deps = [ "env_test" "path_test" "cwd_test" ]; } (nixx.sh ''
              echo "=== e2e-env: ALL PASSED ==="
            '');
          }).runner;

        e2eStrict = mkE2e "e2e-strict"
          (nixx.mkTasks { name = "e2e-strict"; } {
            disable = nixx.sh ''set +euo pipefail'';
            strict_on = nixx.task { strict = true; deps = [ "disable" ]; } (nixx.sh ''
              case "$-" in *u*) ;; *) echo "FAIL: -u not set with strict=true"; exit 1 ;; esac
              case "$-" in *e*) ;; *) echo "FAIL: -e not set with strict=true"; exit 1 ;; esac
              echo "PASS: strict=true restores -euo pipefail"
            '');
            strict_off = nixx.sh ''
              UNDEF=''${UNDEF:-ok}
              test "$UNDEF" = "ok" || { echo "FAIL: unexpected UNDEF=$UNDEF"; exit 1; }
              echo "PASS: strict=false allows undefined vars"
            '';
            all = nixx.task { deps = [ "strict_on" "strict_off" ]; } (nixx.sh ''
              echo "=== e2e-strict: ALL PASSED ==="
            '');
          }).runner;

        e2eCombo = mkE2e "e2e-combo"
          (nixx.mkTasks { name = "e2e-combo"; } {
            setter = nixx.sh ''
              export COMBO_VAR="from_parent"
              export COMBO_EXTRA="also_visible"
            '';
            getter = nixx.task { deps = [ "setter" ]; } (nixx.sh ''
              test "$COMBO_VAR" = "from_parent" \
                || { echo "FAIL: COMBO_VAR=$COMBO_VAR"; exit 1; }
              test "$COMBO_EXTRA" = "also_visible" \
                || { echo "FAIL: COMBO_EXTRA=$COMBO_EXTRA"; exit 1; }
              echo "PASS: parent export propagates to child"
            '');
            all = nixx.task { deps = [ "getter" ]; } (nixx.sh ''
              echo "=== e2e-combo: ALL PASSED ==="
            '');
          }).runner;

        e2eEdge = mkE2e "e2e-edge"
          (nixx.mkTasks
            {
              name = "e2e-edge";
              defaultDeps = [ "setup_a" "setup_b" ];
            }
            {
              empty = nixx.sh '''';
              special_chars = nixx.task
                {
                  env = {
                    WITH_SPACES = "hello world";
                    WITH_QUOTE = "it's a test";
                    WITH_BACKSLASH = "path/to\\file";
                    WITH_DOLLAR = "dollar dollar";
                  };
                }
                (nixx.sh ''
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
              setup_a = nixx.sh ''export SETUP_A=1'';
              setup_b = nixx.sh ''export SETUP_B=1'';
              verify_setups = nixx.sh ''
                test "''${SETUP_A:-}" = "1" || { echo "FAIL: setup_a didn't run"; exit 1; }
                test "''${SETUP_B:-}" = "1" || { echo "FAIL: setup_b didn't run"; exit 1; }
                echo "PASS: multi defaultDeps"
              '';
              all = nixx.task { deps = [ "empty" "special_chars" "verify_setups" ]; } (nixx.sh ''
                echo "=== e2e-edge: ALL PASSED ==="
              '');
            }).runner;

        e2eGlobalEnv = mkE2e "e2e-global-env"
          (nixx.mkTasks
            {
              name = "e2e-global-env";
              env = { GLOBAL = "from_mktasks"; OVERRIDE_ME = "global_value"; };
            }
            {
              check_global = nixx.sh ''
                test "$GLOBAL" = "from_mktasks" \
                  || { echo "FAIL: GLOBAL=$GLOBAL"; exit 1; }
                echo "PASS: global env visible in task"
              '';
              check_override = nixx.task
                {
                  env = { OVERRIDE_ME = "per_task_value"; };
                }
                (nixx.sh ''
                  test "$OVERRIDE_ME" = "per_task_value" \
                    || { echo "FAIL: OVERRIDE_ME=$OVERRIDE_ME"; exit 1; }
                  echo "PASS: per-task env overrides global env"
                '');
              check_merge = nixx.task
                {
                  env = { EXTRA = "per_task_extra"; };
                }
                (nixx.sh ''
                  test "$GLOBAL" = "from_mktasks" \
                    || { echo "FAIL: GLOBAL=$GLOBAL"; exit 1; }
                  test "$EXTRA" = "per_task_extra" \
                    || { echo "FAIL: EXTRA=$EXTRA"; exit 1; }
                  echo "PASS: global and per-task env both visible"
                '');
              all = nixx.task { deps = [ "check_global" "check_override" "check_merge" ]; } (nixx.sh ''
                echo "=== e2e-global-env: ALL PASSED ==="
              '');
            }).runner;

        e2eCircular = mkE2e "e2e-circular"
          (nixx.mkTasks { name = "e2e-circular"; } {
            circ_a = nixx.task { deps = [ "circ_b" ]; } (nixx.sh ''export CIRC_A=1'');
            circ_b = nixx.task { deps = [ "circ_a" ]; } (nixx.sh ''export CIRC_B=1'');
            verify = nixx.task { deps = [ "circ_a" "circ_b" ]; } (nixx.sh ''
              test "''${CIRC_A:-}" = "1" || { echo "FAIL: circ_a body didn't run"; exit 1; }
              test "''${CIRC_B:-}" = "1" || { echo "FAIL: circ_b body didn't run"; exit 1; }
              echo "PASS: circular deps handled by guard"
            '');
            all = nixx.task { deps = [ "verify" ]; } (nixx.sh ''
              echo "=== e2e-circular: ALL PASSED ==="
            '');
          }).runner;

      in
      rec {
        # ---- example applications, one per language ----
        # Build:  nix build .#<name>
        # Run:    nix run   .#<name>
        packages = {
          # lib unit tests — nix run .#test
          test = libTests;

          # Nix lint/format task runner (shellcheck-gated via writeShellApplication)
          # nix run .#nix-tasks -- fmt        auto-format all .nix files
          # nix run .#nix-tasks -- fmt-check  verify formatting (CI)
          # nix run .#nix-tasks -- lint       statix static analysis
          # nix run .#nix-tasks -- check      fmt-check + lint
          nix-tasks =
            let
              inherit ((nixx.mkTasks { name = "nix-tasks"; } {
                fmt = nixx.task { description = "Auto-format all .nix files"; } (nixx.sh ''
                  nixpkgs-fmt flake.nix lib.nix writers.nix tests/lib-tests.nix
                '');
                fmt-check = nixx.task { description = "Verify formatting (CI)"; } (nixx.sh ''
                  nixpkgs-fmt --check flake.nix lib.nix writers.nix tests/lib-tests.nix
                '');
                lint = nixx.task { description = "statix static analysis"; } (nixx.sh ''
                  statix check .
                '');
                lint-nixf = nixx.sh ''
                  echo "nixf-tidy --variable-lookup"
                  rc=0
                  # sema-primop-removed-prefix is noisy on inherit(builtins) patterns — skip it
                  for f in flake.nix lib.nix writers.nix tests/lib-tests.nix \
                           examples/simple01/flake.nix examples/shell-hell-e2e/flake.nix; do
                    diag=$(cat "$f" | nixf-tidy --variable-lookup \
                      | jq 'map(select(.sname != "sema-primop-removed-prefix"))')
                    if [ "$diag" != "[]" ]; then
                      echo "$f:"
                      echo "$diag" | jq -r '.[] | "  \(.sname): \(.message) [Ln \(.range.lCur.line)]"'
                      rc=1
                    fi
                  done
                  exit $rc
                '';
                check = nixx.task { description = "fmt-check + lint + lint-nixf"; deps = [ "fmt-check" "lint" "lint-nixf" ]; } (nixx.sh ''
                  echo "all nix checks passed"
                '');
              })) runner;
            in
            pkgs.writeShellApplication {
              name = "nix-tasks";
              runtimeInputs = [ pkgs.nixpkgs-fmt pkgs.statix pkgs.nixf pkgs.jq ];
              text = runner;
            };

          default = packages.test;
        };

        # nix run .#<name>  (auto-wired from packages)
        apps = builtins.mapAttrs
          (name: pkg: {
            type = "app";
            program = "${pkg}/bin/${name}";
          })
          (removeAttrs packages [ "default" ])
        // { default = apps.test; };

        # nix fmt — format all Nix files in the repo
        formatter = pkgs.nixpkgs-fmt;

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.uv
            pkgs.ruff
            pkgs.bun
            pkgs.nodejs
            pkgs.shellcheck
            pkgs.nixpkgs-fmt
            pkgs.statix
            pkgs.nixf
            pkgs.jq
          ];
          shellHook = ''
            echo "nixx dev shell — uv $(uv --version 2>/dev/null), bun $(bun --version 2>/dev/null)"
            echo "run tests:   nix run .#test"
            echo "format:      nix fmt"
            echo "lint/format: nix run .#nix-tasks -- check"
          '';
        };

        # nix flake check — lib tests + nix-tasks + shell-hell-e2e (shellcheck-gated)
        checks = packages // {
          lib-tests = libTests;
          inherit (packages) nix-tasks;
          e2e-deps = e2eDeps;
          e2e-env = e2eEnv;
          e2e-strict = e2eStrict;
          e2e-combo = e2eCombo;
          e2e-edge = e2eEdge;
          e2e-global-env = e2eGlobalEnv;
          e2e-circular = e2eCircular;
        };
      });
}
