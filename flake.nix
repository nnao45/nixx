{
  description = "nixx — write raw, lintable, multi-language scripts inside pure Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      lib = import ./lib.nix;
      writersFor = pkgs: import ./writers.nix { inherit pkgs; nixx = lib; };
    in
    {
      # System-independent outputs consumed by flake users:
      #   inputs.nixx.lib.bun ''...''
      #   inputs.nixx.writers pkgs
      lib = lib;
      writers = writersFor;

      overlays.default = final: prev: {
        nixx = { lib = lib; writers = writersFor final; };
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

      in rec {
        # ---- example applications, one per language ----
        # Build:  nix build .#<name>
        # Run:    nix run   .#<name>
        packages = {

          # bash — deps via runtimeInputs, shellcheck-gated
          greet = runApplication {
            name = "greet";
            runtimeInputs = [ pkgs.hello ];
          } (nixx.sh ''
            hello -g "hi from nixx bash"
            for d in */; do echo "saw $d"; done
          '');

          # python + uv — deps from the project's pyproject.toml + uv.lock
          report = runApplication {
            name = "report";
            projectRoot = ./examples/py;
          } (nixx.uv ''
            from rich import print
            from rich.table import Table
            t = Table(title="nixx report")
            t.add_column("lang"); t.add_column("note")
            t.add_row("python-uv", "deps from project pyproject.toml")
            print(t)
          '');

          # inline PEP 723 deps — no project dir needed
          report-inline = runApplication {
            name = "report-inline";
            deps = [ "rich>=13" ];
          } (nixx.uv ''
            from rich import print
            print("[bold]inline deps[/] for throwaway scripts")
          '');

          # typescript via bun — compiled to a self-contained binary
          validate = runApplication {
            name = "validate";
            compile = true;
          } (nixx.ts ''
            interface User { name: string; age: number; }
            const users: User[] = [
              { name: "naoya", age: 30 },
              { name: "kid", age: 10 },
            ];
            for (const u of users) {
              const ok = u.age >= 18;
              console.log(`''${u.name}: ''${ok ? "ok" : "too young"}`);
            }
          '');

          # typescript via bun — deps from project package.json
          validate-project = runApplication {
            name = "validate-project";
            projectRoot = ./examples/ts;
            compile = true;
          } (nixx.ts ''
            import chalk from "chalk";
            interface User { name: string; age: number; }
            const users: User[] = [
              { name: "naoya", age: 30 },
              { name: "kid", age: 10 },
            ];
            for (const u of users) {
              const ok = u.age >= 18;
              const label = ok ? chalk.green("ok") : chalk.red("too young");
              console.log(`''${u.name}: ''${label}`);
            }
          '');

          # node — node --check syntax gate
          ping = runApplication {
            name = "ping";
          } (nixx.node ''
            const now = new Date().toISOString();
            console.log(`pong @ ''${now}`);
          '');

          # lib unit tests — nix run .#test
          test = libTests;

          default = packages.report;
        };

        # nix run .#<name>  (auto-wired from packages)
        apps = builtins.mapAttrs (name: pkg: {
          type = "app";
          program = "${pkg}/bin/${name}";
        }) (builtins.removeAttrs packages [ "default" ])
        // { default = apps.report; };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.uv pkgs.ruff pkgs.bun pkgs.nodejs
            pkgs.shellcheck pkgs.nixpkgs-fmt
          ];
          shellHook = ''
            echo "nixx dev shell — uv $(uv --version 2>/dev/null), bun $(bun --version 2>/dev/null)"
            echo "run tests: nix run .#test"
          '';
        };

        # nix flake check — all example apps + lib unit tests
        checks = packages // { lib-tests = libTests; };
      });
}
