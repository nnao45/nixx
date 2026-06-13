{
  description = "nixx × a plain flake devShell — zero-config `tasks` in `nix develop`";

  # ── For the plain-flake person ─────────────────────────────────────────────
  # You already have `devShells.default`. You just want a `just`-style task
  # command in the shell, with task bodies written as RAW shell/JS — no ''${ }.
  #
  # The whole wiring is ONE line: `with nixx.for pkgs;`. That single `with`
  #   • un-prefixes the API (bash / node / perl / mkTasks / task / pkgs), and
  #   • defers Nix's undefined-variable check, so a bare ${VAR} in a body is the
  #     language's, resolved at runtime — no separate `runtimeScope`, no '' tax.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixx.url = "path:../..";
  };

  outputs = { nixpkgs, flake-utils, nixx, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      with nixx.for nixpkgs.legacyPackages.${system};
      let
        tasks = mkTasks { name = "tasks"; } {
          # bash — ${HOME} / ${PWD} are RAW, no '' prefix.
          info = task { description = "Show where we are"; } (bash ''
            echo "user=${USER}  home=${HOME}"
            echo "cwd=${PWD}  editor=${EDITOR:-vi}"
          '');

          # node — a JS template literal `${PORT}` survives verbatim too.
          serve = task { description = "Print the dev URL"; requirements = [ pkgs.nodejs ]; } (node ''
            const PORT = process.env.PORT || 3000;
            console.log(`serving on http://localhost:${PORT}`);
          '');

          # perl — same trick: ${name} is perl's, not Nix's.
          hello = task { description = "A perl hello"; requirements = [ pkgs.perl ]; } (perl ''
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
