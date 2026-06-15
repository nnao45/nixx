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
      task_c = (nixx.sh ''
        test "''${PARALLEL_SETUP:-}" = "1" \
          || { echo "FAIL: dep did not run before parallel spawn"; exit 1; }
        echo "PASS: dep runs before parallel spawn"
      '');
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

  e2eEnvCheck =
    let
      always = writersMkTasks
        {
          name = "e2e-env-check-always";
          envCheck = true;
        }
        {
          unset = nixx.sh ''
            echo "body ran"
            echo "val=''${NIXX_CHK_UNSET:-<unset>}"
          '';
          empty = (nixx.sh ''
            echo "body ran"
            echo "val=''${NIXX_CHK_EMPTY:-<empty>}"
          '') { env = { NIXX_CHK_EMPTY = ""; }; };
          set = (nixx.sh ''
            echo "body ran"
            echo "val=$NIXX_CHK_SET"
          '') { env = { NIXX_CHK_SET = "hello nixx"; }; };
          dedup = nixx.sh ''
            echo "a=''${NIXX_CHK_DEDUP:-x}"
            echo "b=''${NIXX_CHK_DEDUP:-y}"
          '';
        };
      flag = writersMkTasks
        {
          name = "e2e-env-check-flag";
          envCheck = "flag";
        }
        {
          target = nixx.sh ''
            echo "flag task body ran"
            echo "val=''${NIXX_FLAG_VAR:-<unset>}"
          '';
        };
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

      always=${always.runner}/bin/e2e-env-check-always
      flag_r=${flag.runner}/bin/e2e-env-check-flag
      cerr() { local e; e=$("$@" 2>&1 >/dev/null); printf '%s' "$e"; }

      e=$(cerr "$always" unset)
      chk_has "unset-name" "NIXX_CHK_UNSET" "$e"
      chk_has "unset-label" "UNSET" "$e"

      stdout=$("$always" unset 2>/dev/null)
      chk_has "nonblocking-and-trap-clean" "body ran" "$stdout"

      e=$(cerr "$always" empty)
      chk_has "empty-name" "NIXX_CHK_EMPTY" "$e"
      chk_has "empty-label" "(empty)" "$e"

      e=$(cerr "$always" set)
      chk_has "set-name" "NIXX_CHK_SET" "$e"
      chk_has "set-value" "= hello nixx" "$e"
      chk_not "set-no-warn" "WARN" "$e"

      e=$(cerr "$always" dedup)
      chk_count "dedup" "NIXX_CHK_DEDUP" "$e" 1

      e=$(cerr "$flag_r" target)
      chk_not "flag-off" "nixx-env" "$e"

      e=$(cerr "$flag_r" --env-check target)
      chk_has "flag-on" "nixx-env" "$e"
      chk_has "flag-var" "NIXX_FLAG_VAR" "$e"

      stdout=$("$flag_r" --env-check target 2>/dev/null)
      chk_has "flag-body" "flag task body ran" "$stdout"

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
    e2e-env-check = e2eEnvCheck;
    e2e-wrappers = e2eWrappers;
  };
}
