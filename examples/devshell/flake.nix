{
  description = "nixx × a plain flake devShell — zero-config `tasks` in `nix develop`";

  # ── For the plain-flake person ─────────────────────────────────────────────
  # You already have `devShells.default`. You just want a `just`-style task
  # command in the shell, with task bodies written as RAW shell/JS — no ''${ }.
  #
  # The whole wiring is ONE line: `with nixx.lib.for pkgs;`. That single `with`
  #   • un-prefixes the API (bash / node / perl / mkApps / mkTasks / pkgs), and
  #   • defers Nix's undefined-variable check, so a bare ${VAR} in a body is the
  #     language's, resolved at runtime — no escaping, no '' tax.
  #
  # Per-task options ride on the block itself: bash ''…'' { description = …; }.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixx.url = "path:../..";
  };

  outputs = { nixpkgs, flake-utils, nixx, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      with nixx.lib.for nixpkgs.legacyPackages.${system};
      let
        apps = mkApps { } {
          whereami = bash ''
            echo "app cwd=${PWD}"
            echo "app user=${USER}"
          '';
        };

        tasks = mkTasks { name = "tasks"; packages = [ pkgs.nodejs pkgs.perl ]; } {
          # bash — ${HOME} / ${PWD} are RAW, no '' prefix.
          info = (bash ''
            echo "user=${USER}  home=${HOME}"
            echo "cwd=${PWD}  editor=${EDITOR:-vi}"
          '') { description = "Show where we are"; };

          # node — a JS template literal `${PORT}` survives verbatim too.
          serve = (node ''
            const PORT = process.env.PORT || 3000;
            const scheme = "ht" + "tp:";
            console.log(`serving on ${scheme}//localhost:${PORT}`);
          '') { description = "Print the dev URL"; };

          # perl — same trick: ${name} is perl's, not Nix's.
          hello = (perl ''
            my $name = $ENV{USER} || "stranger";
            print "perl waves at ${name}\n";
          '') { description = "A perl hello"; };
        };
      in
      {
        # `nix run .#tasks -- info`  works from anywhere.
        packages = apps // {
          default = tasks.runner;
          tasks = tasks.runner;
        };

        # `nix develop` → the `tasks` command is on PATH, tab-completed.
        #   $ tasks            # list
        #   $ tasks info
        devShells.default = tasks.devShell;
      });
}
