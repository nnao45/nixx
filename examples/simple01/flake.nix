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
        inherit (writers) runApplication;
      in
      {
        packages = rec {

          # ── bash: show dev-environment tool versions ──────────────────────
          # nix run .#status
          status = runApplication {
            name = "status";
            runtimeInputs = [ pkgs.uv pkgs.bun pkgs.nodejs ];
          } (n.sh ''
            echo "=== dev environment ==="
            printf "  python  %s\n" "$(python3 --version 2>/dev/null || echo n/a)"
            printf "  uv      %s\n" "$(uv --version      2>/dev/null || echo n/a)"
            printf "  bun     %s\n" "$(bun --version     2>/dev/null || echo n/a)"
            printf "  node    %s\n" "$(node --version    2>/dev/null || echo n/a)"
          '');

          # ── python/uv: project health report (deps from ./py) ─────────────
          # nix run .#report
          report = runApplication {
            name = "report";
            projectRoot = ./py;
          } (n.uv ''
            from rich import print
            from rich.table import Table
            t = Table(title="python project")
            t.add_column("check")
            t.add_column("result")
            t.add_row("deps",   "[green]ok[/]")
            t.add_row("python", "[green]ok[/]")
            print(t)
          '');

          # ── typescript/bun: project validation (deps from ./ts) ───────────
          # nix run .#validate
          validate = runApplication {
            name = "validate";
            projectRoot = ./ts;
            compile = true;
          } (n.ts ''
            import chalk from "chalk";
            const checks: [string, boolean][] = [
              ["python env",  true],
              ["ts env",      true],
              ["nix flake",   true],
            ];
            for (const [label, ok] of checks) {
              console.log((ok ? chalk.green("✓") : chalk.red("✗")) + "  " + label);
            }
          '');

          # ── mkTasks: unified task runner ───────────────────────────────────
          # nix run .#tasks -- <task>
          #   (no args)       → list available tasks
          #   tasks status    → show tool versions
          #   tasks report    → python health report
          #   tasks validate  → ts project validation
          #   tasks check     → report then validate (just-style deps)
          tasks =
            let
              inherit ((n.mkTasks { name = "tasks"; } {
                status   = n.sh ''${status}/bin/status'';
                report   = n.sh ''${report}/bin/report'';
                validate = n.sh ''${validate}/bin/validate'';
                check    = n.task { deps = [ "report" "validate" ]; } (n.sh ''
                  echo "all checks passed"
                '');
              })) runner;
            in
            pkgs.writeShellApplication { name = "tasks"; text = runner; };

          default = tasks;
        };

        # nix develop
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.uv pkgs.ruff pkgs.bun pkgs.nodejs pkgs.nixpkgs-fmt ];
          shellHook = ''
            echo "nixx examples dev shell"
            echo "  nix run .#tasks -- status    show tool versions"
            echo "  nix run .#tasks -- report    python health report"
            echo "  nix run .#tasks -- validate  ts project validation"
            echo "  nix run .#tasks -- check     report + validate"
          '';
        };
      });
}
