{ pkgs, nixx, forPkgs, writersMkTasks }:

let
  mkE2e = name: runner:
    pkgs.writeShellApplication { inherit name; text = runner; };

  e2eDeps = mkE2e "e2e-deps"
    (nixx.mkTasks { name = "e2e-deps"; } {
      step1 = nixx.sh ''export LINEAR="ran"'';
      step2 = (nixx.sh ''
        test "''${LINEAR:-}" = "ran" \
          || { echo "FAIL: step1 did not run before step2"; exit 1; }
        export LINEAR="step2"
      '') { deps = [ "step1" ]; };
      step3 = (nixx.sh ''
        test "$LINEAR" = "step2" \
          || { echo "FAIL: step2 did not run before step3"; exit 1; }
        echo "PASS: linear chain"
      '') { deps = [ "step2" ]; };
      dia_a = nixx.sh ''
        export DIA_COUNT=''${DIA_COUNT:-0}
        DIA_COUNT=$((DIA_COUNT + 1))
        export DIA_COUNT
      '';
      dia_b = (nixx.sh ''export DIA_B=1'') { deps = [ "dia_a" ]; };
      dia_c = (nixx.sh ''export DIA_C=1'') { deps = [ "dia_a" ]; };
      dia_d = (nixx.sh ''
        test "$DIA_COUNT" -eq 1 \
          || { echo "FAIL: dia_a ran $DIA_COUNT times (expected 1)"; exit 1; }
        test "''${DIA_B:-}" = "1" || { echo "FAIL: dia_b missing"; exit 1; }
        test "''${DIA_C:-}" = "1" || { echo "FAIL: dia_c missing"; exit 1; }
        echo "PASS: diamond deps"
      '') { deps = [ "dia_b" "dia_c" ]; };
      all = (nixx.sh ''
        echo "=== e2e-deps: ALL PASSED ==="
      '') { deps = [ "step3" "dia_d" ]; };
    }).runner;

  e2eEnv = pkgs.writeShellApplication {
    name = "e2e-env";
    runtimeInputs = [ pkgs.jq ];
    text = (nixx.mkTasks { name = "e2e-env"; } {
      env_test = (nixx.sh ''
        test "$FOO" = "hello world" || { echo "FAIL: FOO=$FOO"; exit 1; }
        test "$BAR" = "it's a test"  || { echo "FAIL: BAR=$BAR"; exit 1; }
        echo "PASS: env variables"
      '') {
        env = { FOO = "hello world"; BAR = "it's a test"; };
      };
      path_test = nixx.sh ''
        command -v jq >/dev/null || { echo "FAIL: jq not in PATH"; exit 1; }
        echo '{"ok":true}' | jq -e .ok >/dev/null \
          || { echo "FAIL: jq not functional"; exit 1; }
        echo "PASS: global packages/PATH"
      '';
      cwd_test = (nixx.sh ''
        test "$(pwd)" = "/tmp" \
          || { echo "FAIL: cwd=$(pwd) expected=/tmp"; exit 1; }
        echo "PASS: cwd"
      '') { cwd = "/tmp"; };
      all = (nixx.sh ''
        echo "=== e2e-env: ALL PASSED ==="
      '') { deps = [ "env_test" "path_test" "cwd_test" ]; };
    }).runner;
  };

  e2eStrict = mkE2e "e2e-strict"
    (nixx.mkTasks { name = "e2e-strict"; } {
      loosen = nixx.sh ''set +u'';
      reasserted = (nixx.sh ''
        case "$-" in *u*) ;; *) echo "FAIL: -u leaked off from a prior task"; exit 1 ;; esac
        case "$-" in *e*) ;; *) echo "FAIL: -e leaked off from a prior task"; exit 1 ;; esac
        echo "PASS: shell options re-asserted per task (no leak)"
      '') { deps = [ "loosen" ]; };
      chdir = (nixx.sh ''test "$PWD" = "/"'') { cwd = "/"; };
      cwd_reset = (nixx.sh ''
        test "$PWD" != "/" || { echo "FAIL: dep's cd / leaked into this task"; exit 1; }
        echo "PASS: cwd reset to invocation dir (no leak)"
      '') { deps = [ "chdir" ]; };
      all = (nixx.sh ''
        echo "=== e2e-strict: ALL PASSED ==="
      '') { deps = [ "reasserted" "cwd_reset" ]; };
    }).runner;

  e2eCombo = mkE2e "e2e-combo"
    (nixx.mkTasks { name = "e2e-combo"; } {
      setter = nixx.sh ''
        export COMBO_VAR="from_parent"
        export COMBO_EXTRA="also_visible"
      '';
      getter = (nixx.sh ''
        test "$COMBO_VAR" = "from_parent" \
          || { echo "FAIL: COMBO_VAR=$COMBO_VAR"; exit 1; }
        test "$COMBO_EXTRA" = "also_visible" \
          || { echo "FAIL: COMBO_EXTRA=$COMBO_EXTRA"; exit 1; }
        echo "PASS: parent export propagates to child"
      '') { deps = [ "setter" ]; };
      all = (nixx.sh ''
        echo "=== e2e-combo: ALL PASSED ==="
      '') { deps = [ "getter" ]; };
    }).runner;

  e2eEdge = mkE2e "e2e-edge"
    (nixx.mkTasks
      {
        name = "e2e-edge";
        defaultDeps = [ "setup_a" "setup_b" ];
      }
      {
        empty = nixx.sh '''';
        special_chars = (nixx.sh ''
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
        setup_a = nixx.sh ''export SETUP_A=1'';
        setup_b = nixx.sh ''export SETUP_B=1'';
        verify_setups = nixx.sh ''
          test "''${SETUP_A:-}" = "1" || { echo "FAIL: setup_a didn't run"; exit 1; }
          test "''${SETUP_B:-}" = "1" || { echo "FAIL: setup_b didn't run"; exit 1; }
          echo "PASS: multi defaultDeps"
        '';
        all = (nixx.sh ''
          echo "=== e2e-edge: ALL PASSED ==="
        '') { deps = [ "empty" "special_chars" "verify_setups" ]; };
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
        check_override = (nixx.sh ''
          test "$OVERRIDE_ME" = "per_task_value" \
            || { echo "FAIL: OVERRIDE_ME=$OVERRIDE_ME"; exit 1; }
          echo "PASS: per-task env overrides global env"
        '') {
          env = { OVERRIDE_ME = "per_task_value"; };
        };
        check_merge = (nixx.sh ''
          test "$GLOBAL" = "from_mktasks" \
            || { echo "FAIL: GLOBAL=$GLOBAL"; exit 1; }
          test "$EXTRA" = "per_task_extra" \
            || { echo "FAIL: EXTRA=$EXTRA"; exit 1; }
          echo "PASS: global and per-task env both visible"
        '') {
          env = { EXTRA = "per_task_extra"; };
        };
        all = (nixx.sh ''
          echo "=== e2e-global-env: ALL PASSED ==="
        '') { deps = [ "check_global" "check_override" "check_merge" ]; };
      }).runner;

  e2eParallel = mkE2e "e2e-parallel"
    (nixx.mkTasks { name = "e2e-parallel"; } {
      task_a = nixx.sh ''
        echo "a-start"
        sleep 0.05
        echo "a-done" >> /tmp/nixx-parallel-$$
      '';
      task_b = nixx.sh ''
        echo "b-start"
        sleep 0.05
        echo "b-done" >> /tmp/nixx-parallel-$$
      '';
      dev = nixx.parallel [ "task_a" "task_b" ];
      verify = (nixx.sh ''
        lines=$(wc -l < /tmp/nixx-parallel-$$)
        rm -f /tmp/nixx-parallel-$$
        test "$lines" -eq 2 \
          || { echo "FAIL: expected 2 lines in output file, got $lines"; exit 1; }
        echo "PASS: both parallel tasks completed"
      '') { deps = [ "dev" ]; };
      with_dep = nixx.sh ''export PARALLEL_SETUP=1'';
      task_c = nixx.sh ''
        test "''${PARALLEL_SETUP:-}" = "1" \
          || { echo "FAIL: dep did not run before parallel spawn"; exit 1; }
        echo "PASS: dep runs before parallel spawn"
      '';
      dev_with_dep = (nixx.parallel [ "task_c" ]) { deps = [ "with_dep" ]; };
      all = (nixx.sh ''
        echo "=== e2e-parallel: ALL PASSED ==="
      '') { deps = [ "verify" "dev_with_dep" ]; };
    }).runner;

  e2eCircular = mkE2e "e2e-circular"
    (nixx.mkTasks { name = "e2e-circular"; } {
      circ_a = (nixx.sh ''export CIRC_A=1'') { deps = [ "circ_b" ]; };
      circ_b = (nixx.sh ''export CIRC_B=1'') { deps = [ "circ_a" ]; };
      verify = (nixx.sh ''
        test "''${CIRC_A:-}" = "1" || { echo "FAIL: circ_a body didn't run"; exit 1; }
        test "''${CIRC_B:-}" = "1" || { echo "FAIL: circ_b body didn't run"; exit 1; }
        echo "PASS: circular deps handled by guard"
      '') { deps = [ "circ_a" "circ_b" ]; };
      all = (nixx.sh ''
        echo "=== e2e-circular: ALL PASSED ==="
      '') { deps = [ "verify" ]; };
    }).runner;

  e2eArgs =
    let
      runner = pkgs.writeShellApplication {
        name = "e2e-args";
        runtimeInputs = [ pkgs.python3 pkgs.perl pkgs.ruby ];
        text = (nixx.mkTasks { name = "e2e-args"; } {
          greet = nixx.sh ''
            test "$1" = "hello" \
              || { echo "FAIL: bash expected arg1='hello', got '$1'"; exit 1; }
            test "$2" = "world" \
              || { echo "FAIL: bash expected arg2='world', got '$2'"; exit 1; }
            test "$#" -eq 2 \
              || { echo "FAIL: bash expected 2 args, got $#"; exit 1; }
            echo "PASS: bash: positional args ($*)"
          '';
          sum = nixx.sh ''
            total=0
            for n in "$@"; do
              total=$((total + n))
            done
            test "$total" -eq 6 \
              || { echo "FAIL: bash expected sum=6, got $total"; exit 1; }
            echo "PASS: bash: iterated $# args, sum=$total"
          '';
          py_argc = nixx.py ''
            import sys
            args = sys.argv[1:]
            assert args == ["alpha", "beta"], f"FAIL: python got {args}"
            print(f"PASS: python: {args}")
          '';
          perl_argc = nixx.perl ''
            my @args = @ARGV;
            die "FAIL: perl got '@args'\n" unless "@args" eq "a b c";
            print "PASS: perl: @args\n";
          '';
          ruby_argc = nixx.ruby ''
            got = ARGV
            exp = ["x", "y"]
            raise "FAIL: ruby got #{got}" unless got == exp
            puts "PASS: ruby: #{got.inspect}"
          '';
        }).runner;
      };
    in
    pkgs.runCommand "e2e-args" { } ''
      ${runner}/bin/e2e-args greet hello world
      ${runner}/bin/e2e-args sum 1 2 3
      ${runner}/bin/e2e-args py_argc alpha beta
      ${runner}/bin/e2e-args perl_argc a b c
      ${runner}/bin/e2e-args ruby_argc x y
      echo "=== e2e-args: ALL PASSED ==="
      touch "$out"
    '';

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
        all = (nixx.sh ''
          echo "=== e2e-packages: ALL PASSED ==="
        '') { deps = [ "uses_pkg" "not_listed" ]; };
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

  e2eProcessCompose =
    let
      nx = forPkgs pkgs;
      pc = with nx; processCompose
        {
          name = "e2e-process-compose";
          "no-server" = true;
          "use-uds" = true;
          port = 18080;
        }
        {
          web = bash ''
            echo "web"
          '';
        };
    in
    pkgs.runCommand "e2e-process-compose" { } ''
      grep -q -- '--no-server' ${pc.runner}/bin/e2e-process-compose \
        || { echo "FAIL: --no-server missing from runner"; exit 1; }
      grep -q -- '--use-uds' ${pc.runner}/bin/e2e-process-compose \
        || { echo "FAIL: --use-uds missing from runner"; exit 1; }
      grep -q -- '--port 18080' ${pc.runner}/bin/e2e-process-compose \
        || { echo "FAIL: --port missing from runner"; exit 1; }
      ${pc.runner}/bin/e2e-process-compose --dry-run
      echo "=== e2e-process-compose: ALL PASSED ==="
      touch "$out"
    '';

  e2eEnvCheck =
    let
      nx = forPkgs pkgs;
      # Global envCheck = true → every bash task is pre-flight checked.
      # `with nx` lets the common `${VAR}` / `${VAR:-x}` forms stay escape-free;
      # only Nix-unparseable forms (`:=` `:+` `:?` `?` `#` `!`, nested `$`) keep
      # the `''${...}` escape.
      #
      # Semantics under test (the redesign):
      #   - bare `$VAR` / `${VAR}`         → REQUIRED, must be set AND non-empty
      #   - `${VAR:?m}` / `${VAR?m}`       → REQUIRED ( :? also rejects empty )
      #   - `${VAR:-x}` `-` `:=` `:+`      → SKIP (author handles it; opt-out)
      #   - `${#VAR}` `${!VAR}` `${VAR#p}` → SKIP (AST collapses to bare → classify by text)
      #   - nested ref in a default        → SKIP (`${A:-$B}` ⇒ neither A nor B)
      #   - names bound in the block       → SKIP (assignment/export/for/read)
      #
      # Runtime-dangerous SKIP forms (unset var under `set -u`) are wrapped in
      # `if false; then … fi`: the expansion stays in the source for tree-sitter
      # to classify, but is never evaluated, so the body reaches BODY_RAN.
      tasks = with nx; mkTasks { name = "e2e-env-check"; envCheck = true; } {
        # ---- REQUIRED → pre-flight ABORT, body never runs ----
        req_simple = sh ''
          echo "BODY_RAN"
          echo "v=$NIXX_RS"
        '';
        req_braced = sh ''
          echo "BODY_RAN"
          echo "v=${NIXX_RB}"
        '';
        req_empty = (sh ''
          echo "BODY_RAN"
          echo "v=${NIXX_RE}"
        '') { env = { NIXX_RE = ""; }; };
        req_qcolon_unset = sh ''
          echo "BODY_RAN"
          echo "v=''${NIXX_QC:?need}"
        '';
        req_qcolon_empty = (sh ''
          echo "BODY_RAN"
          echo "v=''${NIXX_QCE:?need}"
        '') { env = { NIXX_QCE = ""; }; };
        req_qmark_unset = sh ''
          echo "BODY_RAN"
          echo "v=''${NIXX_QM?need}"
        '';
        req_multi = sh ''
          echo "BODY_RAN"
          echo "$NIXX_M1 ${NIXX_M2}"
        '';
        req_dedup = sh ''
          echo "BODY_RAN"
          echo "$NIXX_DD"
          echo "${NIXX_DD}"
        '';
        # bound NIXX_LOCAL is subtracted; only NIXX_NEEDED is required → abort
        combo_mixed = sh ''
          NIXX_LOCAL=ok
          echo "BODY_RAN"
          echo "$NIXX_LOCAL ${NIXX_NEEDED}"
        '';

        # ---- SKIP → no env-check abort, body runs (BODY_RAN) ----
        skip_default = sh ''
          echo "BODY_RAN"
          echo "v=${NIXX_DC:-fallback}"
        '';
        skip_dash = sh ''
          echo "BODY_RAN"
          echo "v=''${NIXX_DD2-fallback}"
        '';
        skip_assign = sh ''
          echo "BODY_RAN"
          echo "v=''${NIXX_AS:=fallback}"
        '';
        skip_alt = sh ''
          echo "BODY_RAN"
          echo "v=''${NIXX_AL:+set}"
        '';
        skip_length = sh ''
          echo "BODY_RAN"
          if false; then echo "''${#NIXX_LEN}"; fi
        '';
        skip_indirect = sh ''
          echo "BODY_RAN"
          if false; then echo "''${!NIXX_IND}"; fi
        '';
        skip_suffix = sh ''
          echo "BODY_RAN"
          if false; then echo "''${NIXX_SUF#pre}"; fi
        '';
        # `${VAR?m}` (no colon) on a set-but-empty var → allowed → body runs
        skip_qmark_empty = (sh ''
          echo "BODY_RAN"
          echo "v=''${NIXX_QEO?msg}"
        '') { env = { NIXX_QEO = ""; }; };
        skip_nested = sh ''
          echo "BODY_RAN"
          if false; then echo "''${NIXX_NA:-$NIXX_NESTED}"; fi
        '';
        skip_local = sh ''
          NIXX_LA=hi
          echo "BODY_RAN"
          echo "v=$NIXX_LA"
        '';
        skip_export = sh ''
          export NIXX_EA=hi
          echo "BODY_RAN"
          echo "v=$NIXX_EA"
        '';
        skip_for = sh ''
          echo "BODY_RAN"
          for NIXX_IT in a b c; do echo "v=$NIXX_IT"; done
        '';
        skip_read = sh ''
          echo "BODY_RAN"
          read -r NIXX_RV <<< "hi"
          echo "v=$NIXX_RV"
        '';

        # ---- PASS → set & non-empty: check passes, value shown, body runs ----
        pass_set = (sh ''
          echo "BODY_RAN"
          echo "v=$NIXX_PS"
        '') { env = { NIXX_PS = "hello nixx"; }; };
      };
      # Separate runner: per-task envCheck override + --env-check flag plumbing.
      flagTasks = with nx; mkTasks { name = "e2e-env-check-flag"; envCheck = true; } {
        # inherits global (true) → always checked
        always_task = sh ''
          echo "BODY_RAN"
          echo "v=${NIXX_FA}"
        '';
        # per-task false → only checked when --env-check is passed
        cli_task = (sh ''
          echo "CLI_BODY"
          echo "v=${NIXX_FC}"
        '') { envCheck = false; };
      };
      runnerBin = "${tasks.runner}/bin/e2e-env-check";
      flagBin = "${flagTasks.runner}/bin/e2e-env-check-flag";
    in
    pkgs.runCommand "e2e-env-check" { } ''
      set -euo pipefail

      chk_has() {
        local ctx="$1" needle="$2" hay="$3"
        if ! printf '%s' "$hay" | grep -qF "$needle"; then
          printf 'FAIL [%s]: expected to find: %s\n' "$ctx" "$needle" >&2
          printf '%s\n%s\n' '--- stderr/stdout ---' "$hay" >&2
          exit 1
        fi
        echo "PASS [$ctx]: found '$needle'"
      }

      chk_not() {
        local ctx="$1" needle="$2" hay="$3"
        if printf '%s' "$hay" | grep -qF "$needle"; then
          printf 'FAIL [%s]: should not contain: %s\n' "$ctx" "$needle" >&2
          printf '%s\n%s\n' '--- stderr/stdout ---' "$hay" >&2
          exit 1
        fi
        echo "PASS [$ctx]: absent '$needle'"
      }

      chk_count() {
        local ctx="$1" needle="$2" hay="$3" expected="$4" cnt
        cnt=$(printf '%s' "$hay" | grep -cF "$needle" || true)
        if [[ "$cnt" -ne "$expected" ]]; then
          printf 'FAIL [%s]: expected %s occurrences of %s, got %s\n' \
            "$ctx" "$expected" "$needle" "$cnt" >&2
          printf '%s\n%s\n' '--- stderr/stdout ---' "$hay" >&2
          exit 1
        fi
        echo "PASS [$ctx]: '$needle' appears exactly $expected time(s)"
      }

      R=${runnerBin}
      F=${flagBin}

      # determinism: the "unset" fixtures must truly be absent from the env
      unset NIXX_RS NIXX_RB NIXX_QC NIXX_QM NIXX_M1 NIXX_M2 NIXX_DD \
            NIXX_NEEDED NIXX_DC NIXX_DD2 NIXX_AS NIXX_AL NIXX_LEN NIXX_IND \
            NIXX_SUF NIXX_NA NIXX_NESTED NIXX_FA NIXX_FC 2>/dev/null || true

      errof() { "$1" "''${@:2}" 2>&1 >/dev/null || true; }
      outof() { "$1" "''${@:2}" 2>/dev/null || true; }

      # REQUIRED: pre-flight aborts, body never runs, every named var is reported
      abort_reports() {
        local t="$1"; shift
        local e o; e=$(errof "$R" "$t"); o=$(outof "$R" "$t")
        chk_has "$t:abort" "aborting" "$e"
        chk_not "$t:no-body" "BODY_RAN" "$o"
        local v; for v in "$@"; do chk_has "$t:reports-$v" "$v" "$e"; done
      }
      abort_reports req_simple       NIXX_RS
      abort_reports req_braced       NIXX_RB
      abort_reports req_empty        NIXX_RE
      abort_reports req_qcolon_unset NIXX_QC
      abort_reports req_qcolon_empty NIXX_QCE
      abort_reports req_qmark_unset  NIXX_QM
      abort_reports req_multi        NIXX_M1 NIXX_M2

      # dedup: a var referenced twice is reported exactly once
      e=$(errof "$R" req_dedup)
      chk_has   "dedup:abort" "aborting" "$e"
      chk_count "dedup:once"  "NIXX_DD"  "$e" 1

      # empty-set vars are labelled (empty), not UNSET
      e=$(errof "$R" req_empty);        chk_has "req_empty:label"  "(empty)" "$e"
      e=$(errof "$R" req_qcolon_empty); chk_has "req_qcolon:label" "(empty)" "$e"

      # combo: locally-bound NIXX_LOCAL is subtracted; only NIXX_NEEDED required
      e=$(errof "$R" combo_mixed); o=$(outof "$R" combo_mixed)
      chk_has "combo:abort"     "aborting"    "$e"
      chk_has "combo:needed"    "NIXX_NEEDED" "$e"
      chk_not "combo:not-local" "NIXX_LOCAL"  "$e"
      chk_not "combo:no-body"   "BODY_RAN"    "$o"

      # SKIP: env-check must NOT abort; body reaches BODY_RAN
      runs() {
        local t="$1"
        local e o; e=$(errof "$R" "$t"); o=$(outof "$R" "$t")
        chk_not "$t:no-abort" "aborting" "$e"
        chk_has "$t:body"     "BODY_RAN" "$o"
      }
      runs skip_default
      runs skip_dash
      runs skip_assign
      runs skip_alt
      runs skip_length
      runs skip_indirect
      runs skip_suffix
      runs skip_qmark_empty
      runs skip_nested
      runs skip_local
      runs skip_export
      runs skip_for
      runs skip_read

      # PASS: set & non-empty → no error, value shown, body runs
      e=$(errof "$R" pass_set); o=$(outof "$R" pass_set)
      chk_not "pass:no-error" "ERROR"       "$e"
      chk_has "pass:value"    "hello nixx"  "$e"
      chk_has "pass:body"     "BODY_RAN"    "$o"

      # --- per-task override + --env-check flag plumbing ---
      # always_task inherits global true → aborts on unset
      e=$(errof "$F" always_task); o=$(outof "$F" always_task)
      chk_has "flag-always:abort" "aborting" "$e"
      chk_not "flag-always:no-body" "BODY_RAN" "$o"
      # cli_task envCheck=false → no check without flag → body runs
      e=$(errof "$F" cli_task); o=$(outof "$F" cli_task)
      chk_not "flag-cli-off:no-check" "nixx-env" "$e"
      chk_has "flag-cli-off:body"     "CLI_BODY" "$o"
      # --env-check forces the check on cli_task → aborts
      e=$(errof "$F" --env-check cli_task); o=$(outof "$F" --env-check cli_task)
      chk_has "flag-cli-on:check" "nixx-env" "$e"
      chk_has "flag-cli-on:abort" "aborting" "$e"
      chk_not "flag-cli-on:no-body" "CLI_BODY" "$o"

      echo "=== e2e-env-check: ALL PASSED ==="
      touch "$out"
    '';

  e2eWrappers =
    let
      nx = forPkgs pkgs;
      app = with nx; writeShellApplication {
        name = "e2e-wrapper-app";
        text = {
          main = bash ''
            printf '%s\n' "${HOME}"
          '';
        };
      };
    in
    with nx; runCommand "e2e-wrappers" { nativeBuildInputs = [ app ]; } {
      build = bash ''
        e2e-wrapper-app >/dev/null
        printf '%s\n' "${HOME:-unset}" > "$out"
      '';
    };

  # F1 (extendShell keeps caller env/hook) + F5 (mkTasks inputsFrom) — eval-level.
  e2eShellWiring =
    let
      nx = forPkgs pkgs;
      base = pkgs.mkShell {
        NIXX_BASE_ENV = "frombase";
        shellHook = "echo NIXX_BASE_HOOK";
      };
      ifShell = pkgs.mkShell { shellHook = "echo NIXX_IF_HOOK"; };
      t = nx.mkTasks { name = "sw"; inputsFrom = [ ifShell ]; } { a = nx.sh "echo hi\n"; };
      ext = t.extendShell base;
      hasInfix = pkgs.lib.hasInfix;
    in
    assert (ext.NIXX_BASE_ENV or null) == "frombase"; # F1: bare env survives
    assert hasInfix "NIXX_BASE_HOOK" (ext.shellHook or ""); # F1: caller hook survives
    assert hasInfix "NIXX_IF_HOOK" (ext.shellHook or ""); # F5: inputsFrom hook folded in
    assert (t.devShell.drvPath != ""); # F5: devShell inputsFrom wiring evaluates
    pkgs.runCommand "e2e-shell-wiring" { } ''
      printf 'shell-wiring: PASSED\n'
      touch "$out"
    '';

  # F2 (vars/@nix in runCommand) + F3 (shellcheck gate, default-on with opt-out).
  e2eRunCommandVars =
    let
      nx = forPkgs pkgs;
      # gate is ON by default; a clean body that uses @sh:q() must build + run
      varsOut = nx.runCommand "e2e-rc-vars" { } {
        vars = { msg = "hello from nix"; };
        build = nx.bash ''printf '%s' @sh:q(msg) > "$out"'';
      };
      # opt-out: a body with a real lint finding (SC2086) builds only because the
      # gate is disabled — proving shellcheck=false works.
      optoutOut = nx.runCommand "e2e-rc-optout" { } {
        shellcheck = false;
        build = nx.bash ''
          words="a b c"
          # shellcheck would flag the unquoted $words (SC2086); gate is off
          printf '%s' $words > "$out"
        '';
      };
    in
    nx.runCommand "e2e-runcommand-vars" { inherit varsOut optoutOut; } {
      build = nx.bash ''
        v=$(cat "$varsOut")
        [[ "$v" == "hello from nix" ]] || { echo "FAIL vars: got '$v'"; exit 1; }
        [[ -s "$optoutOut" ]] || { echo "FAIL optout: empty output"; exit 1; }
        echo "runcommand-vars: PASSED"
        touch "$out"
      '';
    };

  # F4 (--env-list) — works even though this runner enables NO blocking env-check.
  e2eEnvList =
    let
      nx = forPkgs pkgs;
      elTasks = with nx; mkTasks { name = "el"; } {
        needs_it = sh ''
          echo "EL_BODY_RAN"
          echo "key=''${API_KEY:?required}"
          echo "opt=${OPT:-fallback}"
        '';
        local_ok = sh ''
          echo "EL_BODY_RAN"
          LOCAL_V=hi
          echo "v=$LOCAL_V"
        '';
      };
    in
    pkgs.runCommand "e2e-env-list" { } ''
      set -euo pipefail
      chk_has() {
        printf '%s' "$3" | grep -qF "$2" \
          || { printf 'FAIL [%s]: missing %s\n%s\n' "$1" "$2" "$3" >&2; exit 1; }
        echo "PASS [$1]"
      }
      chk_not() {
        printf '%s' "$3" | grep -qF "$2" \
          && { printf 'FAIL [%s]: unexpected %s\n%s\n' "$1" "$2" "$3" >&2; exit 1; }
        echo "PASS [$1]"
      }
      EL=${elTasks.runner}/bin/el
      unset API_KEY OPT 2>/dev/null || true

      # --env-list lists required vars, skips defaulted ones, never runs the body
      o=$("$EL" --env-list needs_it 2>&1) || { echo "FAIL: --env-list exited nonzero"; exit 1; }
      chk_has "envlist:required" "API_KEY"     "$o"
      chk_not "envlist:default"  "OPT"         "$o"
      chk_not "envlist:no-body"  "EL_BODY_RAN" "$o"

      # block-bound names are not listed; always available with envCheck OFF
      o=$("$EL" --env-list local_ok 2>&1) || { echo "FAIL: --env-list local_ok nonzero"; exit 1; }
      chk_not "envlist:not-bound" "LOCAL_V" "$o"
      chk_has "envlist:header"    "nixx-env [local_ok]" "$o"

      echo "=== e2e-env-list: ALL PASSED ==="
      touch "$out"
    '';

  # shellint — static lint over fixture .nix files (parse-wall fixtures live in
  # tests/shellint-fixtures and are NOT evaluated by the flake).
  e2eShellint =
    let
      nx = forPkgs pkgs;
      fx = ../tests/shellint-fixtures;
    in
    pkgs.runCommand "e2e-shellint" { nativeBuildInputs = [ nx.shellintBin ]; } ''
      set -u +e   # shellint exits nonzero on FATAL; we capture rc by hand
      chk_has() { printf '%s' "$3" | grep -qF "$2" || { printf 'FAIL [%s]: missing %s\n%s\n' "$1" "$2" "$3"; exit 1; }; echo "PASS [$1]"; }
      chk_not() { printf '%s' "$3" | grep -qF "$2" && { printf 'FAIL [%s]: unexpected %s\n%s\n' "$1" "$2" "$3"; exit 1; }; echo "PASS [$1]"; }

      # boundary: shell-only form ''${#ARR} breaks Nix → FATAL + nonzero exit
      o=$(nixx-shellint ${fx}/wall.nix 2>&1); rc=$?
      chk_has wall-fatal "[nix] FATAL" "$o"
      [[ $rc -ne 0 ]] || { echo "FAIL wall exit 0"; exit 1; }; echo "PASS wall-exit"

      # boundary: bare ''${HOME} with no enclosing `with` → FATAL
      o=$(nixx-shellint ${fx}/bare.nix 2>&1) || true
      chk_has bare-fatal 'bare ''${HOME} needs a' "$o"

      # clean: escaped / with-scoped / Nix-expr → no FATAL, exit 0
      o=$(nixx-shellint --no-shellcheck ${fx}/clean.nix 2>&1); rc=$?
      chk_not clean-no-fatal "FATAL" "$o"
      [[ $rc -eq 0 ]] || { echo "FAIL clean nonzero"; exit 1; }; echo "PASS clean-exit"

      # shellcheck pass: SC2086 → FATAL; --exclude removes it (exit 0)
      o=$(nixx-shellint --no-nix --no-envcheck ${fx}/sc.nix 2>&1) || true
      chk_has sc-fatal "SC2086" "$o"
      o=$(nixx-shellint --no-nix --no-envcheck --exclude=SC2086 ${fx}/sc.nix 2>&1); rc=$?
      chk_not sc-excluded "SC2086" "$o"
      [[ $rc -eq 0 ]] || { echo "FAIL sc-exclude nonzero"; exit 1; }; echo "PASS sc-exclude-exit"

      # markers: @nix()/@sh:q() are expanded before shellcheck → no parse-error
      # false positives, exit 0 (raw '@sh:q(url)' would trip SC1073/SC1036/…)
      o=$(nixx-shellint --no-nix --no-envcheck ${fx}/markers.nix 2>&1); rc=$?
      chk_not markers-no-sc "FATAL"  "$o"
      chk_not markers-no-1073 "SC1073" "$o"
      [[ $rc -eq 0 ]] || { echo "FAIL markers nonzero"; exit 1; }; echo "PASS markers-exit"

      # env pass: required (warn) listed, block-bound names not; warns are non-fatal
      o=$(nixx-shellint --no-nix --no-shellcheck ${fx}/env.nix 2>&1); rc=$?
      chk_has env-apikey 'requires external env $API_KEY' "$o"
      chk_has env-bucket 'requires external env $BUCKET' "$o"
      chk_not env-bound  "LOCAL_TMP" "$o"
      [[ $rc -eq 0 ]] || { echo "FAIL env warn nonzero"; exit 1; }; echo "PASS env-warn-exit"

      echo "=== e2e-shellint: ALL PASSED ==="
      touch "$out"
    '';

  # shellint --fix — bidirectional nix-boundary auto-fix. Fixtures are copied to a
  # writable dir (the store is read-only); needles use ANSI-C quoting so '' / ${ }
  # survive both the Nix '' string and bash.
  e2eShellintFix =
    let
      nx = forPkgs pkgs;
      fx = ../tests/shellint-fixtures/fix;
    in
    pkgs.runCommand "e2e-shellint-fix"
      { nativeBuildInputs = [ nx.shellintBin pkgs.coreutils pkgs.diffutils ]; } ''
      set -u +e
      W="$PWD/work"; mkdir -p "$W"; cp ${fx}/*.nix "$W"/; chmod +w "$W"/*.nix
      pass(){ echo "PASS [$1]"; }
      die(){ echo "FAIL [$1]: $2" >&2; exit 1; }
      ESC=$'\x27\x27'    # two single-quotes (the escape prefix)
      D=$'\x24'          # a dollar sign
      boundary(){ nixx-shellint --no-shellcheck --no-envcheck "$1" 2>/dev/null | grep -c FATAL; }

      ###################### ESCAPE direction ######################
      E="$W/escape.nix"
      [[ "$(boundary "$E")" -gt 0 ]] || die esc-pre "expected boundary fatals before fix"
      pass esc-pre
      nixx-shellint --fix "$E" >/dev/null 2>&1
      [[ "$(boundary "$E")" -eq 0 ]] || die esc-post "boundary not clean after --fix"
      pass esc-post
      for form in "$D{ARR[@]}" "$D{ARR[*]}" "$D{#ITEMS}" "$D{PATH#/usr}" "$D{FILE##*/}" \
                  "$D{NAME%.txt}" "$D{WORD^^}" "$D{WORD,,}" "$D{ARR[-1]}" "$D{HOME}"; do
        grep -qF "$ESC$form" "$E" || die "esc-form" "not escaped: $form"
      done
      pass esc-allforms
      grep -qF "$ESC$D{pkgs.hello}" "$E" && die esc-nixinterp "wrongly escaped \${pkgs.hello}"
      grep -qF "$D{pkgs.hello}" "$E" || die esc-nixinterp2 "lost \${pkgs.hello}"
      pass esc-nixinterp-untouched
      grep -qF "$ESC$ESC" "$E" && die esc-nodouble "double-escape present"
      pass esc-no-double-escape
      cp "$E" "$E.snap"; nixx-shellint --fix "$E" >/dev/null 2>&1
      diff "$E" "$E.snap" >/dev/null || die esc-idem "2nd --fix changed the file"
      pass esc-idempotent

      ###################### DE-ESCAPE direction ######################
      DE="$W/deescape.nix"
      nixx-shellint --fix "$DE" >/dev/null 2>&1
      grep -qF "$ESC$D{HOME}" "$DE" && die deesc-home "HOME still escaped"
      grep -qF "$D{HOME}" "$DE" || die deesc-home2 "HOME lost"
      grep -qF "$ESC$D{EDITOR:-vi}" "$DE" && die deesc-editor "EDITOR still escaped"
      grep -qF "$D{EDITOR:-vi}" "$DE" || die deesc-editor2 "EDITOR lost"
      grep -qF "$ESC$D"USER "$DE" && die deesc-user "\$USER still escaped"
      pass deesc-deescaped
      grep -qF "$ESC$D{#ARR[@]}" "$DE" || die deesc-keepwall "#ARR[@] wrongly de-escaped"
      grep -qF "$ESC$D{P##*/}" "$DE" || die deesc-keepbase "P##*/ wrongly de-escaped"
      grep -qF "$ESC$D{W^^}" "$DE" || die deesc-keepup "W^^ wrongly de-escaped"
      pass deesc-walls-kept
      grep -qF "$D{pkgs.hello}" "$DE" || die deesc-nix "lost \${pkgs.hello}"
      pass deesc-nixinterp-untouched
      [[ "$(boundary "$DE")" -eq 0 ]] || die deesc-parse "boundary not clean after de-escape"
      pass deesc-parses
      cp "$DE" "$DE.snap"; nixx-shellint --fix "$DE" >/dev/null 2>&1
      diff "$DE" "$DE.snap" >/dev/null || die deesc-idem "2nd --fix changed the file"
      pass deesc-idempotent

      ###################### no `with` → no de-escape ######################
      NW="$W/deescape-nowith.nix"; cp "$NW" "$NW.orig"
      nixx-shellint --fix "$NW" >/dev/null 2>&1
      diff "$NW" "$NW.orig" >/dev/null || die nowith "de-escaped without a \`with\` scope"
      pass nowith-noop

      ###################### --dry-run never writes ######################
      DR="$W/dryrun.nix"; cp ${fx}/escape.nix "$DR"; chmod +w "$DR"; cp "$DR" "$DR.orig"
      nixx-shellint --fix --dry-run "$DR" >/dev/null 2>&1
      diff "$DR" "$DR.orig" >/dev/null || die dryrun "dry-run modified the file"
      pass dryrun-no-write

      echo "=== e2e-shellint-fix: ALL PASSED ==="
      touch "$out"
    '';
  # mkTests (Pillar 3) — the hermetic shell-test runner + `nixx test --repro`.
  # We drive the FAST lane bin (built at eval time, referenced by store path) so
  # the sandbox never needs nested nix. The green suite's HERMETIC derivation is
  # an input: if it didn't build-and-pass, this e2e can't even start.
  e2eMkTests =
    let
      nx = forPkgs pkgs;
      # all-green → its sandbox build must succeed (proves the hermetic lane).
      green = with nx; mkTests { name = "e2e-mktests-green"; packages = [ pkgs.coreutils ]; } {
        setup = bash ''mkdir -p "$WORK/d"'';
        "work dir is writable" = bash ''
          echo hi > "$WORK/d/f"
          assert_file "$WORK/d/f"
          assert_file_contains "$WORK/d/f" hi
        '';
        "run captures status and output" = bash ''
          run printf 'hello'
          assert_success
          assert_output hello
        '';
        "assert_json structural compare" = bash ''
          run jq -n '{n:1}'
          assert_json '.n' '1'
        '';
        "sandbox mints HOME, real /home is invisible" = bash ''
          test ! -e /home || { echo "LEAK: /home visible in sandbox"; false; }
        '';
      };
      # mixed (one pass, one fail) → drives the fast lane for repro/--once.
      mixed = with nx; mkTests { name = "e2e-mktests-mixed"; packages = [ pkgs.coreutils ]; } {
        "green case" = bash ''
          run printf 'ok'
          assert_output ok
        '';
        "red case" = bash ''
          run printf 'actual'
          assert_output --partial 'EXPECTED'
        '';
      };
      # teardown that fails while the body passes ⇒ the test must still go red.
      tdFail = with nx; mkTests { name = "e2e-mktests-tdfail"; packages = [ pkgs.coreutils ]; } {
        teardown = bash ''false'';
        "body passes but teardown fails" = bash ''
          run printf 'ok'
          assert_success
        '';
      };
      # a failing setup_suite ⇒ no test runs and the lane goes red.
      ssFail = with nx; mkTests { name = "e2e-mktests-ssfail"; packages = [ pkgs.coreutils ]; } {
        setup_suite = bash ''false'';
        "should never run" = bash ''
          echo SHOULD_NOT_APPEAR
        '';
      };
      B = "${mixed.fast}/bin/e2e-mktests-mixed-test";
      TD = "${tdFail.fast}/bin/e2e-mktests-tdfail-test";
      SS = "${ssFail.fast}/bin/e2e-mktests-ssfail-test";
    in
    pkgs.runCommand "e2e-mktests" { inherit green; } ''
      set -uo pipefail
      pass() { echo "PASS [$1]"; }
      die() { echo "FAIL [$1]: $2" >&2; exit 1; }

      # 0. the green suite's hermetic build is an input ⇒ already passed in-sandbox
      test -e "$green" || die green-hermetic "green suite did not build"
      pass green-hermetic-passed

      # 1. fast lane full run: the red test fails ⇒ nonzero, names + summary shown
      rc=0; o="$(${B} 2>&1)" || rc=$?
      test "$rc" -ne 0 || die fast-red "expected nonzero when a test fails"
      printf '%s' "$o" | grep -q 'green case' || die fast-names "green case not listed"
      printf '%s' "$o" | grep -q '1 failed'   || die fast-summary "missing failed summary"
      pass fast-detects-failure

      # 2. NIXX_FILTER to the green test only ⇒ exit 0
      rc=0; NIXX_FILTER='green case' ${B} >/dev/null 2>&1 || rc=$?
      test "$rc" -eq 0 || die fast-filter "filtered green run should pass (got $rc)"
      pass fast-filter-green

      # 3. repro --once on the FAILING test, feed `t` ⇒ nonzero + live diagnostic
      rc=0
      o="$(printf 't\n' | NIXX_REPRO='red case' NIXX_REPRO_ONCE=1 ${B} 2>&1)" || rc=$?
      test "$rc" -ne 0 || die repro-red "t on a failing test should exit nonzero"
      printf '%s' "$o" | grep -q 'EXPECTED' || die repro-diag "assert diagnostic missing"
      pass repro-once-failing

      # 4. repro --once on the PASSING test, feed `t` ⇒ exit 0
      rc=0
      printf 't\n' | NIXX_REPRO='green case' NIXX_REPRO_ONCE=1 ${B} >/dev/null 2>&1 || rc=$?
      test "$rc" -eq 0 || die repro-green "t on a passing test should exit 0 (got $rc)"
      pass repro-once-passing

      # 5. repro --once custom probe: cwd is a writable $WORK, helpers are loaded
      rc=0
      o="$(printf 'echo "CWD=$PWD"; run printf hi; assert_output hi && echo PROBE_OK\n' \
              | NIXX_REPRO='green case' NIXX_REPRO_ONCE=1 ${B} 2>&1)" || rc=$?
      test "$rc" -eq 0 || die repro-probe "probe should pass (got $rc)"
      printf '%s' "$o" | grep -q 'PROBE_OK' || die repro-probe-ok "PROBE_OK missing"
      printf '%s' "$o" | grep -q 'CWD='     || die repro-probe-cwd "cwd not \$WORK"
      pass repro-once-probe

      # 6. repro --once on an unknown name ⇒ exit 3, lists what IS available
      rc=0
      o="$(printf 't\n' | NIXX_REPRO='nope-nope' NIXX_REPRO_ONCE=1 ${B} 2>&1)" || rc=$?
      test "$rc" -eq 3 || die repro-miss "unknown test should exit 3 (got $rc)"
      printf '%s' "$o" | grep -q 'available' || die repro-miss-list "available list missing"
      printf '%s' "$o" | grep -q 'green case' || die repro-miss-names "should name green case"
      pass repro-once-unknown

      # 7. a passing body with a FAILING teardown ⇒ the test is reported red
      rc=0; o="$(${TD} 2>&1)" || rc=$?
      test "$rc" -ne 0 || die teardown-fail "failing teardown should fail the test"
      printf '%s' "$o" | grep -q 'teardown failed' || die teardown-diag "teardown diagnostic missing"
      pass teardown-failure-counts

      # 8. a failing setup_suite ⇒ no body runs and the lane goes red
      rc=0; o="$(${SS} 2>&1)" || rc=$?
      test "$rc" -ne 0 || die setup-suite-fail "failing setup_suite should fail the lane"
      printf '%s' "$o" | grep -q 'setup_suite failed' || die setup-suite-msg "setup_suite message missing"
      if printf '%s' "$o" | grep -q 'SHOULD_NOT_APPEAR'; then die setup-suite-body "body ran despite setup_suite failure"; fi
      pass setup-suite-failure-aborts

      echo "=== e2e-mktests: ALL PASSED ==="
      touch "$out"
    '';

  # rawsh — the escape-free escape hatch. Parse-wall forms (${#x} ${arr[@]}
  # ${x^^} ${x%pat} ${arr[-1]} …) live in `#|` line-comments, so they need ZERO
  # '' escaping. Two things are proven: (1) the forms actually EXPAND in real
  # bash, and (2) an empty `a = rawsh;` can't steal the next attr's `#|` body.
  e2eRawsh =
    let
      nx = forPkgs pkgs;
      runner = (with nx; mkTasks { name = "e2e-rawsh"; } {
        walls = rawsh;
        #| arr=(alpha beta gamma)
        #| test "${#arr[@]}" -eq 3              || { echo "FAIL: length"; exit 1; }
        #| test "${arr[-1]}" = gamma            || { echo "FAIL: neg-index"; exit 1; }
        #| test "${arr[*]}" = "alpha beta gamma" || { echo "FAIL: splat"; exit 1; }
        #| f="Report.TXT"
        #| test "${f%.TXT}" = Report            || { echo "FAIL: suffix"; exit 1; }
        #| test "${f#Re}" = "port.TXT"          || { echo "FAIL: prefix"; exit 1; }
        #| test "${f,,}" = report.txt           || { echo "FAIL: lower"; exit 1; }
        #| test "${f^^}" = REPORT.TXT           || { echo "FAIL: upper"; exit 1; }
        #| echo "PASS: rawsh wall forms expand in bash"
      }).runner;
      # eval-level: empty `a` must extract "" (no theft of b's #| body)
      meta = (nixx.mkScripts { } {
        a = nixx.rawsh;
        b = nixx.rawsh;
        #| echo OWN_BODY
        # body must be found AFTER a multi-line `{ opts }`, not the attr line
        c = nixx.rawsh {
          description = "multi-line opts";
        };
        #| echo OPTS_BODY
        # two bindings sharing a line: `d` must NOT capture `e`'s body
        d = nixx.rawsh;
        e = nixx.rawsh;
        #| echo SAME_LINE
      }).meta;
      metaOf = n: builtins.head (builtins.filter (m: m.name == n) meta);
      textOf = n: (metaOf n).text;
      # the source line `meta.line` points at, for diagnostics
      srcLineOf = n:
        let m = metaOf n; in
        builtins.elemAt (pkgs.lib.splitString "\n" (builtins.readFile m.file)) (m.line - 1);
    in
    assert textOf "a" == "";
    assert pkgs.lib.hasInfix "OWN_BODY" (textOf "b");
    assert pkgs.lib.hasInfix "OPTS_BODY" (textOf "c");
    assert textOf "d" == "";
    assert pkgs.lib.hasInfix "SAME_LINE" (textOf "e");
    # diagnostics: meta.line points at the `#|` body, not the multi-line opts
    assert pkgs.lib.hasInfix "OPTS_BODY" (srcLineOf "c");
    pkgs.runCommand "e2e-rawsh" { } ''
      o=$(${runner}/bin/e2e-rawsh walls 2>&1) || { echo "$o"; echo "FAIL: nonzero"; exit 1; }
      printf '%s' "$o" | grep -q 'PASS: rawsh wall forms' || { echo "$o"; exit 1; }
      echo "PASS: empty rawsh steals nothing (eval-asserted)"
      echo "=== e2e-rawsh: ALL PASSED ==="
      touch "$out"
    '';
in
{
  checks = {
    e2e-deps = e2eDeps;
    e2e-env = e2eEnv;
    e2e-strict = e2eStrict;
    e2e-combo = e2eCombo;
    e2e-edge = e2eEdge;
    e2e-global-env = e2eGlobalEnv;
    e2e-parallel = e2eParallel;
    e2e-circular = e2eCircular;
    e2e-args = e2eArgs;
    e2e-packages = e2ePackages;
    e2e-process-compose = e2eProcessCompose;
    e2e-env-check = e2eEnvCheck;
    e2e-wrappers = e2eWrappers;
    e2e-shell-wiring = e2eShellWiring;
    e2e-runcommand-vars = e2eRunCommandVars;
    e2e-env-list = e2eEnvList;
    e2e-shellint = e2eShellint;
    e2e-shellint-fix = e2eShellintFix;
    e2e-mktests = e2eMkTests;
    e2e-rawsh = e2eRawsh;
  };
}
