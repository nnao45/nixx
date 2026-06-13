{
  description = "nixx × devenv — keep devenv's languages/services, add raw-shell tasks";

  # ── For the devenv person ──────────────────────────────────────────────────
  # devenv already gives you languages, services, processes. What it does NOT
  # remove is the ${VAR} tax: `enterShell` and `scripts.<name>.exec` are Nix
  # strings, so a literal ${VAR} in them still needs the ''${ } escape.
  #
  # nixx is complementary, not a replacement. Author shell/JS bodies under
  # `with n.runtimeScope;` (read from source → ${VAR} stays raw), then:
  #   • drop the `tasks` runner into devenv's `packages`, and
  #   • feed nixx body `.text` into `enterShell` / `scripts.<name>.exec`.
  # devenv keeps owning the environment; nixx owns the scripting ergonomics.

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
        n = nixx.lib;
        writers = nixx.writers pkgs;

        # A nixx task runner — `tasks <name>` inside `devenv shell`.
        tasks = with n.runtimeScope; writers.mkTasks { name = "tasks"; } {
          fmt = n.task { description = "Format (raw bash)"; } (n.bash ''
            echo "formatting ${PWD} as ${USER}"
          '');
          gen = n.task { description = "A node generator"; requirements = [ pkgs.nodejs ]; } (n.node ''
            const name = process.env.APP_NAME || "app";
            console.log(`scaffolding ${name} v${process.env.npm_package_version || "0.0.0"}`);
          '');
        };

        # enterShell + a devenv script, authored with NO ''${ } tax.
        bodies = with n.runtimeScope;
          n.mkTasks { } {
            enter = n.bash ''
              echo "devenv + nixx ready — hi ${USER}"
              echo "node $(node --version 2>/dev/null || echo n/a)"
            '';
            doctor = n.bash ''
              echo "PATH has ${PATH}" | tr ':' '\n' | head -3
            '';
          };
      in
      {
        packages.default = tasks.runner;

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
