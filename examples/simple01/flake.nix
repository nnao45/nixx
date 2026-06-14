{
  description = "nixx dev-env examples — multi-language workflows managed via nixx";

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
        writers = nixx.writers pkgs;
        inherit (writers) mkApps;
      in
      with n.runtimeScope;
      let
        apps = mkApps { packages = [ pkgs.uv pkgs.bun pkgs.nodejs ]; } {
          # ── bash: show dev-environment tool versions ──────────────────────
          # nix run .#status
          status = n.sh ''
            echo "=== dev environment ==="
            printf "  home    %s\n" "${HOME}"
            printf "  python  %s\n" "$(python3 --version 2>/dev/null || echo n/a)"
            printf "  uv      %s\n" "$(uv --version      2>/dev/null || echo n/a)"
            printf "  bun     %s\n" "$(bun --version     2>/dev/null || echo n/a)"
            printf "  node    %s\n" "$(node --version    2>/dev/null || echo n/a)"
          '';

          # ── python/uv: project health report (deps from ./py) ─────────────
          # nix run .#report
          report = n.uv ''
            from rich import print
            from rich.table import Table
            t = Table(title="python project")
            t.add_column("check")
            t.add_column("result")
            t.add_row("deps",   "[green]ok[/]")
            t.add_row("python", "[green]ok[/]")
            print(t)
          '' { projectRoot = ./py; };

          # ── typescript/bun: project validation (deps from ./ts) ───────────
          # nix run .#validate
          validate = n.bun ''
            import chalk from "chalk";
            const checks: [string, boolean][] = [
              ["python env",  true],
              ["ts env",      true],
              ["nix flake",   true],
            ];
            for (const [label, ok] of checks) {
              console.log((ok ? chalk.green("✓") : chalk.red("✗")) + "  " + label);
            }
          '' { projectRoot = ./ts; compile = true; };
        };
        inherit (apps) status report validate;

        # ── mkTasks: unified task runner ───────────────────────────────────
        # nix run .#tasks -- <task>   OR   tasks <task>  (inside nix develop)
        #   (no args)       → list available tasks
        #   tasks status    → show tool versions
        #   tasks report    → python health report
        #   tasks validate  → ts project validation
        #   tasks check     → report then validate (just-style deps)
        # task bodies are read from SOURCE (so a shell ${VAR} would be raw), so
        # to splice in a Nix derivation path use the explicit @nix() marker.
        mkT = writers.mkTasks
          {
            name = "tasks";
            vars = { inherit status report validate; };
          }
          {
            status = n.sh ''
              status="@nix(status)"
              "$status/bin/status"
            '';
            report = n.sh ''
              report="@nix(report)"
              "$report/bin/report"
            '';
            validate = n.sh ''
              validate="@nix(validate)"
              "$validate/bin/validate"
            '';
            check = n.task { deps = [ "report" "validate" ]; } (n.sh ''
              echo "all checks passed"
            '');
          };
      in
      {
        packages = {
          inherit status report validate;
          tasks = mkT.runner;
          default = mkT.runner;
        };

        # nix develop → `tasks` command available immediately, alongside the
        # language toolchain packages from the extended base shell.
        devShells.default = mkT.extendShell (pkgs.mkShell {
          packages = [ pkgs.uv pkgs.ruff pkgs.bun pkgs.nodejs pkgs.nixpkgs-fmt ];
        });
      });
}
