{
  description = "nixx × a hand-rolled pkgs.mkShell — you keep full control";

  # ── For the mkShell person ─────────────────────────────────────────────────
  # You like `pkgs.mkShell { packages; shellHook; }` and you want to keep it.
  # Two shell pains nixx removes WITHOUT taking over your shell:
  #   1. the `tasks` runner — merge it in with `tasks.extendShell yourShell`
  #      (inputsFrom = [yourShell]; packages += [runner]; + tab-completion).
  #   2. the shellHook itself is a Nix string, so a literal ${VAR} there needs
  #      the ''${ } tax. Author it as a nixx body instead and read out `.text`,
  #      which is taken from SOURCE — so ${VAR} stays raw.

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

        tasks = with n.runtimeScope; writers.mkTasks { name = "tasks"; } {
          build = n.task { description = "Build (raw bash)"; } (n.bash ''
            out="${OUT_DIR:-dist}"
            echo "building into $out for ${USER}"
          '');
          check = n.task { description = "A node check"; requirements = [ pkgs.nodejs ]; } (n.node ''
            const env = process.env.NODE_ENV || "dev";
            console.log(`checking in ${env} mode`);
          '');
        };

        # The shellHook body, authored with NO ''${ } tax. `.text` is the
        # source-read body — ${VAR} is shell's, resolved when the hook runs.
        welcome = with n.runtimeScope;
          (n.mkTasks { } {
            hook = n.bash ''
              echo "── ${USER}'s dev shell ───────────────"
              echo "   PWD=${PWD}"
              echo "   run 'tasks' to see what's available"
            '';
          }).tasks.hook.text;
      in
      {
        packages.default = tasks.runner;

        # YOUR mkShell, untouched — extendShell just folds the runner + its
        # tab-completion in via inputsFrom.
        devShells.default = tasks.extendShell (pkgs.mkShell {
          packages = [ pkgs.jq pkgs.ripgrep pkgs.nodejs ];
          shellHook = welcome;
        });
      });
}
