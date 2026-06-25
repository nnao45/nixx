{ pkgs, nixx }:

# Nix lint/format task runner (shellcheck-gated via writeShellApplication)
# nix run .#nix-tasks -- fmt        auto-format all .nix files
# nix run .#nix-tasks -- fmt-check  verify formatting (CI)
# nix run .#nix-tasks -- lint       statix static analysis
# nix run .#nix-tasks -- check      fmt-check + lint
let
  inherit ((nixx.mkTasks { name = "nix-tasks"; } {
    fmt = (nixx.sh ''
      nixpkgs-fmt flake.nix lib.nix writers.nix tests/lib-tests.nix \
        flake-tasks/default.nix flake-tasks/dev-shell.nix \
        flake-tasks/e2e.nix flake-tasks/lib-tests.nix \
        flake-tasks/nix-tasks.nix \
        examples/multi-lang-e2e/flake.nix
    '') { description = "Auto-format all .nix files"; };
    fmt-check = (nixx.sh ''
      nixpkgs-fmt --check flake.nix lib.nix writers.nix tests/lib-tests.nix \
        flake-tasks/default.nix flake-tasks/dev-shell.nix \
        flake-tasks/e2e.nix flake-tasks/lib-tests.nix \
        flake-tasks/nix-tasks.nix \
        examples/multi-lang-e2e/flake.nix
    '') { description = "Verify formatting (CI)"; };
    lint = (nixx.sh ''
      statix check .
    '') { description = "statix static analysis"; };
    lint-nixf = nixx.sh ''
      echo "nixf-tidy --variable-lookup"
      rc=0
      # sema-primop-removed-prefix is noisy on inherit(builtins) patterns — skip it
      for f in flake.nix lib.nix writers.nix tests/lib-tests.nix \
               flake-tasks/default.nix flake-tasks/dev-shell.nix \
               flake-tasks/e2e.nix flake-tasks/lib-tests.nix \
               flake-tasks/nix-tasks.nix \
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
    sh-lint = (nixx.sh ''
      shellcheck shellint.sh
    '') { description = "shellcheck shellint.sh (the one non-inlinable engine)"; };
    check = (nixx.sh ''
      echo "all nix checks passed"
    '') { description = "fmt-check + lint + lint-nixf + sh-lint"; deps = [ "fmt-check" "lint" "lint-nixf" "sh-lint" ]; };
  })) runner;
in
pkgs.writeShellApplication {
  name = "nix-tasks";
  runtimeInputs = [ pkgs.nixpkgs-fmt pkgs.statix pkgs.nixf pkgs.jq pkgs.shellcheck ];
  text = runner;
}
