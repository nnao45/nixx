{
  description = "nixx × a hand-rolled pkgs.mkShell — you keep full control";

  # ── For the mkShell person ─────────────────────────────────────────────────
  # You like `pkgs.mkShell { packages; shellHook; }` and you want to keep it.
  # `with nixx.for pkgs;` gives you the raw-shell API in one line; then:
  #   • merge the `tasks` runner in with `tasks.extendShell yourShell`
  #     (inputsFrom = [yourShell]; packages += [runner]; + tab-completion), and
  #   • author the shellHook itself as a nixx body and read `.text` — so even the
  #     hook is free of the ''${ } tax that a bare Nix-string shellHook pays.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixx.url = "path:../..";
  };

  outputs = { nixpkgs, flake-utils, nixx, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      with nixx.for nixpkgs.legacyPackages.${system};
      let
        apps = mkApps { } {
          envcheck = bash ''
            jq --version
            echo "shell user=${USER}"
          '' { runtimeInputs = [ pkgs.jq ]; };
        };

        tasks = mkTasks { name = "tasks"; } {
          build = task { description = "Build (raw bash)"; } (bash ''
            out="${OUT_DIR:-dist}"
            echo "building into $out for ${USER}"
          '');
          check = task { description = "A node check"; requirements = [ pkgs.nodejs ]; } (node ''
            const env = process.env.NODE_ENV || "dev";
            console.log(`checking in ${env} mode`);
          '');
        };

        # The shellHook body, authored with NO ''${ } tax. `.text` is the
        # source-read body — ${VAR} is shell's, resolved when the hook runs.
        welcome = (mkTasks { } {
          hook = bash ''
            echo "── ${USER}'s dev shell ───────────────"
            echo "   PWD=${PWD}"
            echo "   run 'tasks' to see what's available"
          '';
        }).tasks.hook.text;
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
