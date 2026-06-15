{
  description = "nixx — website (Astro). Dev/build tasks managed by nixx itself.";

  inputs = {
    # Consume the local nixx the same way an external user would — via the flake
    # API (`inputs.nixx.lib.for pkgs`). path:../ → always the current working tree,
    # no published-version lag. If root lib.nix changes, re-run `nix flake lock`.
    nixx.url = "path:../";
    nixpkgs.follows = "nixx/nixpkgs";
    flake-utils.follows = "nixx/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, nixx }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      with nixx.lib.for pkgs;
      let
        # node+npm come from the global `packages` option → they resolve
        # identically via `nix run .#tasks` and on the `nix develop` prompt
        # (single source of truth — see the nixx README "what goes where").
        tasks = mkTasks {
          name = "web-tasks";
          packages = [ pkgs.nodejs ];
        } {
          install = (sh ''npm install'') { description = "npm install"; };
          dev = (sh ''npm run dev'') {
            description = "Astro dev server (http://localhost:4321/nixx/)";
          };
          build = (sh ''npm run build'') {
            description = "Build the static site to ./dist";
            deps = [ "install" ];
          };
          preview = (sh ''npm run preview'') {
            description = "Preview the built site";
            deps = [ "build" ];
          };
          clean = sh ''rm -rf dist .astro'';
        };
      in
      {
        # from web/:  nix run .#tasks -- build   |   nix run .#tasks -- dev
        packages.tasks = tasks.runner;
        packages.default = tasks.runner;

        # nix develop → `tasks build` (tab-completed), node+npm already on PATH
        devShells.default = tasks.devShell;
      });
}
