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
      inherit lib;
      writers = writersFor;

      overlays.default = final: prev: {
        nixx = { inherit lib; writers = writersFor final; };
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
              runner = (nixx.mkTasks { name = "nix-tasks"; } {
                fmt = nixx.sh ''
                  nixpkgs-fmt flake.nix lib.nix writers.nix tests/lib-tests.nix
                '';
                fmt-check = nixx.sh ''
                  nixpkgs-fmt --check flake.nix lib.nix writers.nix tests/lib-tests.nix
                '';
                lint = nixx.sh ''
                  statix check .
                '';
                check = nixx.task { deps = [ "fmt-check" "lint" ]; } (nixx.sh ''
                  echo "all nix checks passed"
                '');
              }).runner;
            in
            pkgs.writeShellApplication {
              name = "nix-tasks";
              runtimeInputs = [ pkgs.nixpkgs-fmt pkgs.statix ];
              text = runner;
            };

          default = packages.report;
        };

        # nix run .#<name>  (auto-wired from packages)
        apps = builtins.mapAttrs
          (name: pkg: {
            type = "app";
            program = "${pkg}/bin/${name}";
          })
          (builtins.removeAttrs packages [ "default" ])
        // { default = apps.report; };

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
          ];
          shellHook = ''
            echo "nixx dev shell — uv $(uv --version 2>/dev/null), bun $(bun --version 2>/dev/null)"
            echo "run tests:   nix run .#test"
            echo "format:      nix fmt"
            echo "lint/format: nix run .#nix-tasks -- check"
          '';
        };

        # nix flake check — example apps + lib tests + nix-tasks (shellcheck-gated)
        checks = packages // {
          lib-tests = libTests;
          nix-tasks = packages.nix-tasks;
        };
      });
}
