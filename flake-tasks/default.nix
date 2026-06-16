{ pkgs, lib, nixx, writersFor, forPkgs }:

let
  writers = writersFor pkgs;
  inherit (writers) mkApps;
  writersMkTasks = writers.mkTasks;

  libTests = import ./lib-tests.nix { inherit mkApps nixx; };
  nixTasks = import ./nix-tasks.nix { inherit pkgs nixx; };
  e2e = import ./e2e.nix { inherit pkgs nixx forPkgs writersMkTasks; };

  # dogfood: the nix-boundary pass (the differentiator) must be clean across the
  # whole valid repo. shellcheck/envcheck are turned off here — most bash in the
  # repo is test fixtures that intentionally aren't lint-clean; those passes are
  # exercised on controlled fixtures by the e2e checks instead.
  shellintCheck = writers.shellint {
    src = ../.;
    exclude = [ "*/result/*" "*/shellint-fixtures/*" ];
    passes = { shellcheck = false; envcheck = false; };
  };
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
  // {
    default = apps.test;
    shellint = {
      type = "app";
      program = "${writers.shellintBin}/bin/nixx-shellint";
      meta.description = "nixx shellint — static lint for nixx shell blocks";
    };
  };

  formatter = pkgs.nixpkgs-fmt;

  devShells.default = import ./dev-shell.nix { inherit pkgs lib; };

  checks = packages // e2e.checks // {
    lib-tests = libTests;
    inherit (packages) nix-tasks;
    shellint = shellintCheck;
  };
}
