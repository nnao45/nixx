{
  description = "nixx × a hand-rolled pkgs.mkShell — you keep full control";

  # ── For the mkShell person ─────────────────────────────────────────────────
  # You like `pkgs.mkShell { packages; shellHook; }` and you want to keep it.
  # `with nixx.lib.for pkgs;` gives you the raw-shell API in one line; then:
  #   • merge the `tasks` runner in with `tasks.extendShell yourShell`
  #     (inputsFrom = [yourShell]; packages += [runner]; + tab-completion), and
  #   • author the shellHook itself as a nixx body — so even the hook is free of
  #     the ''${ } tax that a bare Nix-string shellHook pays.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixx.url = "path:../..";
  };

  outputs = { nixpkgs, flake-utils, nixx, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      with nixx.lib.for nixpkgs.legacyPackages.${system};
      let
        apps = mkApps { packages = [ pkgs.jq ]; } {
          envcheck = bash ''
            jq --version
            echo "shell user=${USER}"
          '';
        };

        tasks = mkTasks { name = "tasks"; packages = [ pkgs.nodejs ]; } {
          build = (bash ''
            out="${OUT_DIR:-dist}"
            echo "building into $out for ${USER}"
          '') { description = "Build (raw bash)"; };
          check = (node ''
            const env = process.env.NODE_ENV || "dev";
            console.log(`checking in ${env} mode`);
          '') { description = "A node check"; };
        };

        # The shellHook body, authored with NO ''${ } tax. ${VAR} is shell's,
        # resolved when the hook runs.
        welcome = shellHook {
          hook = bash ''
            echo "── ${USER}'s dev shell ───────────────"
            echo "   PWD=${PWD}"
            echo "   run 'tasks' to see what's available"
          '';
        };
      in
      {
        packages = apps // {
          default = tasks.runner;
        };

        # YOUR mkShell, untouched — extendShell just folds the runner + its
        # tab-completion in via inputsFrom.
        devShells.default = tasks.extendShell (pkgs.mkShell {
          packages = [ pkgs.jq pkgs.ripgrep pkgs.nodejs ];
          shellHook = welcome;
        });
      });
}
