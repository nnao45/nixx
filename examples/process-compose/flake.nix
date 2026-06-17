{
  description = "nixx.processCompose — orchestrate processes (depends_on, readiness, graceful shutdown) in pure Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixx.url = "path:../..";
  };

  outputs = { nixpkgs, flake-utils, nixx, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      # one `with`: un-prefixes the constructors AND defers Nix's static
        # undefined-var check, so a bare ${VAR} in a source-read body is raw shell.
      with nixx.lib.for pkgs;
      let
        # processCompose wraps process-compose: each block body becomes a process
        # `command`, and per-block opts map to process-compose fields. process-
        # compose then supplies the orchestration: concurrent startup, depends_on
        # readiness gating, ordered graceful shutdown (Ctrl+C), restart policies,
        # and health probes — all declarative, no bash glue to write.
        #
        #   nix run .#dev            → start everything (logs stream to stdout)
        #   nix run .#dev -- web     → start just `web` (+ its deps)
        #   nix run .#dev-config     → print the generated process-compose JSON
        pc = processCompose
          {
            name = "dev";
            packages = [ pkgs.jq ]; # on PATH for every process
            vars = { port = 3000; }; # @nix() interpolation into commands
          }
          {
            # `web` becomes healthy ~2s after start (readiness probe). `api`
            # depends_on web, so it won't launch until web passes the probe.
            web = bash ''
              echo "[web] serving on @nix(port) (HOME=${HOME})"
              # a real server: `vite dev --port @nix(port)` etc.
              sleep 30
            ''
              {
                readiness = { exec = "true"; initial_delay_seconds = 2; };
                description = "frontend dev server";
              };

            api = bash ''
              echo "[api] web is healthy — booting backend"
              sleep 30
            ''
              {
                depends_on = [ "web" ];
                env = { NODE_ENV = "development"; };
                cwd = "./api";
                restart = "on_failure";
                description = "backend (restarts if it crashes)";
              };

            # a one-shot that runs once web is up (condition process_healthy), then
            # exits. Long-running servers + one-shots mix freely.
            seed = bash ''
              echo "[seed] seeding database..."
              sleep 1
              echo "[seed] done"
            ''
              { depends_on = [ "web" ]; namespace = "setup"; };
          };
      in
      {
        packages = {
          dev = pc.runner; # nix run .#dev
          default = pc.runner;
        };

        # `dev-config` prints the generated JSON — handy for debugging the mapping
        # or running the same stack outside Nix (`process-compose -f out.json up`).
        apps.dev-config = {
          type = "app";
          program = "${pkgs.writeShellScript "dev-config" ''
            echo ${pkgs.lib.escapeShellArg pc.configJson}
          ''}";
        };

        # nix develop → `dev` command available immediately.
        devShells.default = pc.extendShell (pkgs.mkShell { });
      });
}
