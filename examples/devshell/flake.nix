{
  description = "nixx × a plain flake devShell — zero-config `tasks` in `nix develop`";

  # ── For the plain-flake person ─────────────────────────────────────────────
  # You already have `devShells.default`. You don't want devenv, you don't want
  # to hand-roll a mkShell. You just want a `just`-style task command in the
  # shell, and you want to write the task bodies as RAW shell/JS — no ''${ } tax.
  #
  # nixx gives you exactly that: author bodies under `with n.runtimeScope;`
  # (so ${VAR} is the language's, read from source — no '' prefix), then drop the
  # ready-made `tasks.devShell` in as your devShell. That's the whole wiring.

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

        # The one line of ceremony. Under it, every ${VAR} in a body below is
        # left for the body's own interpreter at runtime — never resolved by Nix.
        tasks = with n.runtimeScope; writers.mkTasks { name = "tasks"; } {
          # bash — ${HOME} / ${PWD} are RAW, no '' prefix.
          info = n.task { description = "Show where we are"; } (n.bash ''
            echo "user=${USER}  home=${HOME}"
            echo "cwd=${PWD}  editor=${EDITOR:-vi}"
          '');

          # node — a JS template literal `${PORT}` survives verbatim too.
          serve = n.task { description = "Print the dev URL"; requirements = [ pkgs.nodejs ]; } (n.node ''
            const PORT = process.env.PORT || 3000;
            console.log(`serving on http://localhost:${PORT}`);
          '');

          # perl — same trick: ${name} is perl's, not Nix's.
          hello = n.task { description = "A perl hello"; requirements = [ pkgs.perl ]; } (n.perl ''
            my $name = $ENV{USER} || "stranger";
            print "perl waves at ${name}\n";
          '');
        };
      in
      {
        # `nix run .#tasks -- info`  works from anywhere.
        packages.default = tasks.runner;
        packages.tasks = tasks.runner;

        # `nix develop` → the `tasks` command is on PATH, tab-completed.
        #   $ tasks            # list
        #   $ tasks info
        devShells.default = tasks.devShell;
      });
}
