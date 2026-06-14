{
  description = "nixx × devenv — keep devenv's languages/services, add raw-shell tasks";

  # ── For the devenv person ──────────────────────────────────────────────────
  # devenv owns languages, services, processes. What it does NOT remove is the
  # ${VAR} tax: `enterShell` and `scripts.<name>.exec` are Nix strings, so a
  # literal ${VAR} there still needs the ''${ } escape.
  #
  # nixx is complementary. `with nixx.for pkgs;` gives the raw-shell API in one
  # line; then drop the `tasks` runner into devenv's `packages`, and feed nixx
  # body `.text` into `enterShell` / `scripts.<name>.exec`. devenv keeps owning
  # the environment; nixx owns the scripting ergonomics.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    devenv.url = "github:cachix/devenv";
    nixx.url = "path:../..";
  };

  outputs = { nixpkgs, flake-utils, devenv, nixx, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nx = nixx.for pkgs;
      in
      with nx;
      let
        apps = mkApps { } {
          hello = bash ''
            echo "devenv app for ${USER}"
            echo "cwd=${PWD}"
          '';
        };

        # `tasks <name>` inside `devenv shell`.
        tasks = mkTasks { name = "tasks"; packages = [ pkgs.nodejs ]; } {
          fmt = task { description = "Format (raw bash)"; } (bash ''
            echo "formatting ${PWD} as ${USER}"
          '');
          gen = task { description = "A node generator"; } (node ''
            const name = process.env.APP_NAME || "app";
            console.log(`scaffolding ${name} v${process.env.npm_package_version || "0.0.0"}`);
          '');
        };

        # enterShell + a devenv script, authored with NO ''${ } tax.
        bodies = mkTasks { } {
          enter = bash ''
            echo "devenv + nixx ready — hi ${USER}"
            echo "node $(node --version 2>/dev/null || echo n/a)"
          '';
          doctor = bash ''
            echo "PATH has ${PATH}" | tr ':' '\n' | head -3
          '';
        };
      in
      {
        packages = apps // {
          default = tasks.runner;
        };

        devShells.default = devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            {
              # devenv stays in charge of the toolchain & services.
              languages.javascript.enable = true;
              packages = [ pkgs.jq tasks.runner ];

              # ${USER} below is raw shell — it came through nixx from source.
              enterShell = bodies.tasks.enter.text;

              # a devenv script whose body is likewise ${}-tax-free.
              scripts.doctor.exec = bodies.tasks.doctor.text;
            }
          ];
        };
      });
}
