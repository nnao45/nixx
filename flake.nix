{
  description = "nixx — write raw, lintable, multi-language scripts inside pure Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # ---- the library itself (pure, pkgs-independent) ----
      lib = import ./lib.nix;

      # exposed so consumers can `nixx.lib.mkScript`, `nixx.lib.bun`, etc.
      # and build their own apps via `nixx.writers pkgs`.
      writersFor = pkgs: import ./writers.nix { inherit pkgs; nixx = lib; };
    in
    {
      # Consumable outputs that don't depend on a system:
      #   inputs.nixx.lib.bun ''...''
      #   inputs.nixx.writers pkgs
      lib = lib;
      writers = writersFor;

      # A reusable overlay isn't needed, but expose the writers factory.
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
      in
      rec {
        # ---- example applications, one per language ----
        # Build any of these with:  nix build .#<name>
        # Run with:                 nix run   .#<name>
        packages = {

          # bash — deps via runtimeInputs, shellcheck-gated by writeShellApplication
          greet = runApplication {
            name = "greet";
            runtimeInputs = [ pkgs.hello ];
          } (nixx.sh ''
            hello -g "hi from nixx bash"
            for d in */; do echo "saw $d"; done   # */ works in string-mode
          '');

          # python + uv — deps from the PROJECT's pyproject.toml + uv.lock.
          # The manifest is the single source of truth; nixx declares nothing.
          # (Drop-in: point projectRoot at a dir with pyproject.toml + uv.lock.)
          report = runApplication {
            name = "report";
            projectRoot = ./examples/py;   # owns pyproject.toml + uv.lock
          } (nixx.uv ''
            from rich import print
            from rich.table import Table
            t = Table(title="nixx report")
            t.add_column("lang"); t.add_column("note")
            t.add_row("python-uv", "deps from project pyproject.toml")
            print(t)
          '');

          # quick one-off variant: inline deps via PEP 723 (no project needed)
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

          # node — deps supplied by Nix (here: none), node --check gate
          ping = runApplication {
            name = "ping";
          } (nixx.node ''
            const now = new Date().toISOString();
            console.log(`pong @ ''${now}`);
          '');

          default = packages.report;
        };

        # `nix run .#<name>` wiring
        apps = builtins.mapAttrs (name: pkg: {
          type = "app";
          program = "${pkg}/bin/${name}";
        }) (builtins.removeAttrs packages [ "default" ])
        // { default = apps.report; };

        # ---- dev shell: tools for editing & linting nixx scripts ----
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.uv pkgs.ruff pkgs.bun pkgs.nodejs
            pkgs.shellcheck pkgs.nixpkgs-fmt
          ];
          shellHook = ''
            echo "nixx dev shell — uv $(uv --version 2>/dev/null), bun $(bun --version 2>/dev/null)"
            echo "build an example:  nix build .#report  (or greet/validate/ping)"
          '';
        };

        # ---- checks: `nix flake check` lints every example via nixx-check ----
        # Each app already gates itself at build time; this is an extra pass.
        checks = packages;
      });
}
