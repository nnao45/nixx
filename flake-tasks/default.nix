{ pkgs, lib, nixx, writersFor, forPkgs }:

let
  writers = writersFor pkgs;
  inherit (writers) mkApps nixxTest;
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

  # shellint.sh is the one engine that CAN'T be an inline `bash ''…''` block: it
  # manipulates `''` and `${…}` as data (it's the linter), so source-read's
  # scanBody would mangle it. It stays a real .sh file — gate it on shellcheck
  # here so it's still managed by `nix flake check`. (The test runtime + CLI ARE
  # inlined into writers.nix and get the embedded-block coverage instead.)
  engineShellcheck = pkgs.runCommandLocal "engine-shellcheck"
    { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
    shellcheck ${../shellint.sh}
    echo "engine-shellcheck: PASSED"
    touch "$out"
  '';
in
rec {
  packages = {
    test = nixxTest; # `nixx test` — the *_test.nix discovery CLI
    lib-tests = libTests; # nixx's own pure-Nix unit tests
    nix-tasks = nixTasks;
    default = packages.lib-tests;
  };

  # `program` must point at the real binary; `test`/`lib-tests` carry a binary
  # name that differs from their attr (nixx-test / test), so they're spelled out
  # rather than derived by the `${pkg}/bin/${name}` shorthand.
  apps = builtins.mapAttrs
    (name: pkg: {
      type = "app";
      program = "${pkg}/bin/${name}";
      meta.description = "nixx ${name}";
    })
    { inherit (packages) nix-tasks; }
  // {
    default = apps.lib-tests;
    test = {
      type = "app";
      program = "${nixxTest}/bin/nixx-test";
      meta.description = "nixx test — discover & run *_test.nix suites";
    };
    lib-tests = {
      type = "app";
      program = "${libTests}/bin/test";
      meta.description = "nixx lib unit tests";
    };
    shellint = {
      type = "app";
      program = "${writers.shellintBin}/bin/nixx-shellint";
      meta.description = "nixx shellint — static lint for nixx shell blocks";
    };
  };

  formatter = pkgs.nixpkgs-fmt;

  devShells.default = import ./dev-shell.nix { inherit pkgs lib; };

  checks = packages // e2e.checks // {
    shellint = shellintCheck;
    engine-shellcheck = engineShellcheck;
  };
}
