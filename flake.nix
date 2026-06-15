{
  description = "nixx — write raw, lintable, multi-language scripts inside pure Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    let
      pureLib = import ./lib.nix;
      writersFor = pkgs: import ./writers.nix { inherit pkgs; nixx = pureLib; };
      forPkgs = pkgs: lib // (writersFor pkgs) // { inherit pkgs; };
      lib = pureLib // {
        writers = writersFor;
        for = forPkgs;
      };
    in
    {
      # System-independent outputs consumed by flake users:
      #   inputs.nixx.lib.bun ''...''
      #   inputs.nixx.lib.writers pkgs
      #   inputs.nixx.lib.for pkgs
      inherit lib;

      # `for pkgs` — the batteries-included namespace: lib + pkgs-bound writers
      # + `pkgs`, in ONE set meant to be brought in with `with`:
      #
      #   with inputs.nixx.lib.for pkgs;
      #   (mkTasks { } { dev = bash '' echo ${HOME} ''; }).devShell
      #
      # The single `with` does double duty: it un-prefixes the constructors AND
      # defers Nix's static undefined-variable check (any `with` makes the scope
      # dynamic), so a bare ${VAR} survives — this is the one canonical entry
      # point. The writers' `mkTasks` (derivation + devShell + .tasks) shadows
      # lib's.

      overlays.default = final: prev: {
        nixx = { inherit lib; writers = writersFor final; for = forPkgs; };
      };
    }
    //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      import ./flake-tasks {
        inherit pkgs lib writersFor forPkgs;
        nixx = pureLib;
      });
}
