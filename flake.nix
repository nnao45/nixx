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
        inherit (writersFor pkgs) mkApps;
        # The pkgs-bound mkTasks (derivation + devShell), distinct from the pure
        # `nixx.mkTasks`. Only this one carries the global `packages` option.
        writersMkTasks = (writersFor pkgs).mkTasks;

        # Pure-Nix lib tests, evaluated at flake-eval time.
        # A failing assertion throws here and prevents the flake from building.
        # The resulting script is shellcheck-gated via nixx's own mkApps.
        libTests =
          let ok = import ./tests/lib-tests.nix;
          in (mkApps { } { test = nixx.sh "echo ${nixx.shq ok}\n"; }).test;

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

        e2eEnv = pkgs.writeShellApplication {
          name = "e2e-env";
          runtimeInputs = [ pkgs.jq ];
          text = (nixx.mkTasks { name = "e2e-env"; } {
            env_test = nixx.task
              {
                env = { FOO = "hello world"; BAR = "it's a test"; };
              }
              (nixx.sh ''
                test "$FOO" = "hello world" || { echo "FAIL: FOO=$FOO"; exit 1; }
                test "$BAR" = "it's a test"  || { echo "FAIL: BAR=$BAR"; exit 1; }
                echo "PASS: env variables"
              '');
            path_test = nixx.sh ''
              command -v jq >/dev/null || { echo "FAIL: jq not in PATH"; exit 1; }
              echo '{"ok":true}' | jq -e .ok >/dev/null \
                || { echo "FAIL: jq not functional"; exit 1; }
              echo "PASS: global packages/PATH"
            '';
            cwd_test = nixx.task { cwd = "/tmp"; } (nixx.sh ''
              test "$(pwd)" = "/tmp" \
                || { echo "FAIL: cwd=$(pwd) expected=/tmp"; exit 1; }
              echo "PASS: cwd"
            '');
            all = nixx.task { deps = [ "env_test" "path_test" "cwd_test" ]; } (nixx.sh ''
              echo "=== e2e-env: ALL PASSED ==="
            '');
          }).runner;
        };

        # Volatile state is normalized per task: the runner is ONE bash process
        # (so env exports persist — see e2e-combo), but cwd and shell options are
        # re-asserted at each task's entry, so a prior task's `cd` / `set +u`
        # must NOT leak into a dependent task.
        e2eStrict = mkE2e "e2e-strict"
          (nixx.mkTasks { name = "e2e-strict"; } {
            loosen = nixx.sh ''set +u'';
            reasserted = nixx.task { deps = [ "loosen" ]; } (nixx.sh ''
              case "$-" in *u*) ;; *) echo "FAIL: -u leaked off from a prior task"; exit 1 ;; esac
              case "$-" in *e*) ;; *) echo "FAIL: -e leaked off from a prior task"; exit 1 ;; esac
              echo "PASS: shell options re-asserted per task (no leak)"
            '');
            chdir = nixx.task { cwd = "/"; } (nixx.sh ''test "$PWD" = "/"'');
            cwd_reset = nixx.task { deps = [ "chdir" ]; } (nixx.sh ''
              test "$PWD" != "/" || { echo "FAIL: dep's cd / leaked into this task"; exit 1; }
              echo "PASS: cwd reset to invocation dir (no leak)"
            '');
            all = nixx.task { deps = [ "reasserted" "cwd_reset" ]; } (nixx.sh ''
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

        # ── e2e-packages: command-dependency resolution via the `packages` option ──
        # Unlike the others, this check ACTUALLY RUNS the runner (in runCommand)
        # and asserts two contracts of `writers.mkTasks { packages = [...] }`:
        #
        #   (1) nix-run path — the runner resolves `jq` from its OWN wrapped
        #       runtimeInputs, with NO ambient jq on the build PATH. That proves
        #       the resolution comes from the `packages` option, not the env.
        #       A command never listed (`rg`) must stay unresolved.
        #   (2) prompt path — devShell AND extendShell put `packages` on the shell
        #       PATH too (not only inside the wrapped runner). Asserted at eval
        #       time by name-superset; mkShell may carry a non-default output, so
        #       object identity is unreliable. `nix print-dev-env` was used to
        #       confirm jq's bin output really lands on PATH.
        e2ePackages =
          let
            tasks = writersMkTasks { name = "e2e-packages"; packages = [ pkgs.jq ]; } {
              uses_pkg = nixx.sh ''
                command -v jq >/dev/null \
                  || { echo "FAIL: jq not resolved from packages (runner runtimeInputs)"; exit 1; }
                echo '{"ok":true}' | jq -e .ok >/dev/null \
                  || { echo "FAIL: jq present but not functional"; exit 1; }
                echo "PASS: packages command resolved in runner (nix run path)"
              '';
              not_listed = nixx.sh ''
                if command -v rg >/dev/null; then
                  echo "FAIL: ripgrep resolved but was never listed in packages"; exit 1
                fi
                echo "PASS: a command absent from packages stays unresolved"
              '';
              all = nixx.task { deps = [ "uses_pkg" "not_listed" ]; } (nixx.sh ''
                echo "=== e2e-packages: ALL PASSED ==="
              '');
            };
            shellNames = shell: map (d: d.name or "?")
              ((shell.buildInputs or [ ])
              ++ (shell.nativeBuildInputs or [ ])
              ++ (shell.propagatedBuildInputs or [ ]));
            exposes = shell:
              builtins.all (p: builtins.elem (p.name or "?") (shellNames shell)) [ pkgs.jq ];
            devOk = exposes tasks.devShell;
            extendOk = exposes (tasks.extendShell (pkgs.mkShell { }));
          in
          assert devOk || throw "e2e-packages: devShell does not expose `packages` on the prompt PATH";
          assert extendOk || throw "e2e-packages: extendShell does not expose `packages` on the prompt PATH";
          pkgs.runCommand "e2e-packages" { } ''
            if command -v jq >/dev/null 2>&1; then
              echo "PRECONDITION FAIL: jq is on the build PATH — the nix-run test would be vacuous"; exit 1
            fi
            ${tasks.runner}/bin/e2e-packages all
            echo "PASS: devShell + extendShell expose packages on prompt PATH (eval-asserted)"
            echo "=== e2e-packages: ALL PASSED ==="
            touch "$out"
          '';

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
                  nixpkgs-fmt flake.nix lib.nix writers.nix tests/lib-tests.nix \
                    examples/multi-lang-e2e/flake.nix
                '');
                fmt-check = nixx.task { description = "Verify formatting (CI)"; } (nixx.sh ''
                  nixpkgs-fmt --check flake.nix lib.nix writers.nix tests/lib-tests.nix \
                    examples/multi-lang-e2e/flake.nix
                '');
                lint = nixx.task { description = "statix static analysis"; } (nixx.sh ''
                  statix check .
                '');
                lint-nixf = nixx.sh ''
                  echo "nixf-tidy --variable-lookup"
                  rc=0
                  # sema-primop-removed-prefix is noisy on inherit(builtins) patterns — skip it
                  for f in flake.nix lib.nix writers.nix tests/lib-tests.nix \
                           examples/simple01/flake.nix examples/shell-hell-e2e/flake.nix \
                           examples/multi-lang-e2e/flake.nix; do
                    diag=$(cat "$f" | nixf-tidy --variable-lookup \
                      | jq 'map(select(
                          .sname != "sema-primop-removed-prefix"
                          and .sname != "sema-extra-with"
                          and .sname != "deprecated-url-literal"
                        ))')
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
          e2e-packages = e2ePackages;
        };
      });
}
