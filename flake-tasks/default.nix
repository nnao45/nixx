{ pkgs, lib, nixx, writersFor, forPkgs }:

let
  writers = writersFor pkgs;
  inherit (writers) mkApps;
  writersMkTasks = writers.mkTasks;

  libTests = import ./lib-tests.nix { inherit mkApps nixx; };
  nixTasks = import ./nix-tasks.nix { inherit pkgs nixx; };
  e2e = import ./e2e.nix { inherit pkgs nixx forPkgs writersMkTasks; };
in
rec {
  packages = {
    test = libTests;
    nix-tasks = nixTasks;
    default = packages.test;
  };

  apps = builtins.mapAttrs
    (name: pkg: {
      type = "app";
      program = "${pkg}/bin/${name}";
      meta.description = "nixx ${name}";
    })
    (removeAttrs packages [ "default" ])
  // { default = apps.test; };

  formatter = pkgs.nixpkgs-fmt;

  devShells.default = import ./dev-shell.nix { inherit pkgs lib; };

  checks = packages // e2e.checks // {
    lib-tests = libTests;
    inherit (packages) nix-tasks;
  };
}
