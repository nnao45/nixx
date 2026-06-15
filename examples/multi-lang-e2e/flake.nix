{
  description = "nixx multi-lang e2e — one app per runtime, each referencing real project deps";

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
        # undefined-variable check, so runtime-language ${...} (TS template
        # literals, Perl ${var}, etc.) can appear in source-read block bodies
        # without a ''${ escape — bodies are never forced, so the Nix thunks are
        # never evaluated.
      with nixx.lib.for pkgs;
      let
        # nodeModules shared by tsx-demo and node-demo.
        # Inline nixx-hello package created in the Nix store — no npm/network needed.
        # writeNodeApplication / writeTsxApplication set NODE_PATH via wrapProgram
        # so require("nixx-hello") resolves at runtime.
        # NOTE: string concatenation is used here (not template literals) because
        # this installPhase IS evaluated by Nix (not source-read).
        nodeModules = pkgs.stdenv.mkDerivation {
          name = "nixx-e2e-node-modules";
          dontUnpack = true;
          installPhase = ''
            mkdir -p $out/lib/node_modules/nixx-hello
            cat > $out/lib/node_modules/nixx-hello/index.js <<'EOF'
            "use strict";
            module.exports = {
              greet: function(name) { return "Hello from nixx-hello, " + name + "!"; },
              version: "1.0.0",
            };
            EOF
            cat > $out/lib/node_modules/nixx-hello/package.json <<'EOF'
            { "name": "nixx-hello", "version": "1.0.0", "main": "index.js" }
            EOF
          '';
        };

        appPkgs = mkApps { } {

          # ── 1. Python / uv ────────────────────────────────────────────────
          # Deps: ./py/pyproject.toml + uv.lock  (rich>=13).
          # Build: ruff-gated (offline). Runtime: `uv run --frozen` resolves from
          # the lockfile — needs network on first run if packages aren't cached.
          uv-demo = uv ''
            from rich import print
            from rich.table import Table
            t = Table(title="nixx e2e — uv")
            t.add_column("runtime")
            t.add_column("dep source")
            t.add_column("status")
            t.add_row("python/uv", "pyproject.toml + uv.lock (rich)", "[green]PASS[/]")
            print(t)
          ''
            { projectRoot = ./py; };

          # ── 2. TypeScript / bun (compile → standalone binary) ─────────────
          # Deps: ./bun_ts/package.json + bun.lock  (chalk ^5.3.0).
          # `bun build --compile` bakes chalk into a self-contained binary.
          # NOTE: `bun install` needs network at build time.
          #   macOS: nix run .#bun-demo  (works without extra flags)
          #   Linux: nix run .#bun-demo --option sandbox false
          bun-demo = bun ''
            import chalk from "chalk";
            const runtime = "typescript/bun";
            const src     = "package.json + bun.lock (chalk)";
            console.log(
              chalk.green(`✓ ${runtime}`) +
              `  dep: ${src}  status: ` + chalk.bold("PASS")
            );
          ''
            { projectRoot = ./bun_ts; compile = true; };

          # ── 3. TypeScript / tsx (Node + TS type-stripping) ────────────────
          # Deps: nixx-hello from the Nix-built nodeModules derivation.
          # NODE_PATH is set via wrapProgram; fully sandbox-safe.
          tsx-demo = ts ''
            interface Greeting { from: string; message: string; version: string }
            // eslint-disable-next-line @typescript-eslint/no-require-imports
            const nixxHello = require("nixx-hello") as {
              greet: (name: string) => string;
              version: string;
            };
            const g: Greeting = {
              from:    "nixx-hello",
              message: nixxHello.greet("TypeScript"),
              version: nixxHello.version,
            };
            console.log(`✓ typescript/tsx  dep: ${g.from}@${g.version}  status: PASS`);
            console.log(`                  ${g.message}`);
          ''
            { inherit nodeModules; };

          # ── 4. Node.js ────────────────────────────────────────────────────
          # Same nixx-hello nodeModules via NODE_PATH (CommonJS require).
          node-demo = node ''
            "use strict";
            const nixxHello = require("nixx-hello");
            const os        = require("os");
            console.log(
              "✓ node  dep: nixx-hello@" + nixxHello.version +
              "  platform: " + os.platform() + "  status: PASS"
            );
            console.log("        " + nixxHello.greet("Node.js"));
          ''
            { inherit nodeModules; };

          # ── 5. Deno ───────────────────────────────────────────────────────
          # Deps: inline jsr: import — no package.json, no lockfile.
          # Build: copies .ts (offline). Runtime: deno fetches jsr: on first run.
          deno-demo = deno ''
            import { bold, green } from "jsr:@std/fmt@1/colors";
            const dep = "jsr:@std/fmt@1/colors";
            console.log(
              green("✓ deno") +
              "  dep: " + dep + "  status: " + bold("PASS")
            );
          '';

          # ── 6. Perl ───────────────────────────────────────────────────────
          # JSON::PP ships with pkgs.perl (core module since Perl 5.14).
          # To add CPAN packages: perl '' ... '' { perlPackages = [...]; }
          perl-demo = perl ''
            use strict;
            use warnings;
            use JSON::PP;
            my $data = { runtime => "perl", dep => "JSON::PP (core)", status => "PASS" };
            my $json = JSON::PP->new->utf8->pretty->encode($data);
            $json =~ s/\n$//;
            print "✓ perl  dep: JSON::PP (core)  status: PASS\n";
            print "        $json\n";
          '';

          # ── 7. Ruby ───────────────────────────────────────────────────────
          # `json` ships with pkgs.ruby standard library — no extra gems needed.
          # To add gems: ruby '' ... '' { rubyGems = [...]; }
          ruby-demo = ruby ''
            require "json"
            data = { runtime: "ruby", dep: "json (stdlib)", status: "PASS" }
            puts "✓ ruby  dep: json (stdlib)  status: PASS"
            puts "        " + JSON.dump(data)
          '';

          # ── 8. Lua ────────────────────────────────────────────────────────
          # Built-in Lua (table, string, io) — no luarocks package needed.
          # To add packages: lua '' ... '' { luaPackages = [...]; }
          lua-demo = lua ''
            local result = {
              runtime = "lua",
              dep     = "table/string/io (built-in)",
              status  = "PASS",
            }
            io.write(string.format(
              "✓ lua   dep: %s  status: %s\n", result.dep, result.status
            ))
            local parts = {}
            for k, v in pairs(result) do
              parts[#parts + 1] = k .. '="' .. v .. '"'
            end
            table.sort(parts)
            io.write("        {" .. table.concat(parts, ", ") .. "}\n")
          '';
        };

        e2eAll = pkgs.writeShellApplication {
          name = "e2e-all";
          text = ''
            echo "╔══════════════════════════════════════════════════════════╗"
            echo "║          nixx multi-lang e2e                             ║"
            echo "╚══════════════════════════════════════════════════════════╝"
            echo ""
            echo "── 1. python / uv  (rich from pyproject.toml + uv.lock) ──"
            ${appPkgs.uv-demo}/bin/uv-demo
            echo ""
            echo "── 2. typescript / bun  (chalk compiled from package.json) ──"
            ${appPkgs.bun-demo}/bin/bun-demo
            echo ""
            echo "── 3. typescript / tsx  (nixx-hello via nodeModules) ──────"
            ${appPkgs.tsx-demo}/bin/tsx-demo
            echo ""
            echo "── 4. node.js  (nixx-hello via NODE_PATH) ─────────────────"
            ${appPkgs.node-demo}/bin/node-demo
            echo ""
            echo "── 5. deno  (jsr:@std/fmt inline import) ───────────────────"
            ${appPkgs.deno-demo}/bin/deno-demo
            echo ""
            echo "── 6. perl  (JSON::PP core module) ─────────────────────────"
            ${appPkgs.perl-demo}/bin/perl-demo
            echo ""
            echo "── 7. ruby  (json stdlib) ───────────────────────────────────"
            ${appPkgs.ruby-demo}/bin/ruby-demo
            echo ""
            echo "── 8. lua  (built-in table/string/io) ──────────────────────"
            ${appPkgs.lua-demo}/bin/lua-demo
            echo ""
            echo "╔══════════════════════════════════════════════════════════╗"
            echo "║  ALL RUNTIMES PASSED ★                                   ║"
            echo "╚══════════════════════════════════════════════════════════╝"
          '';
        };

        # mkCheck: build the app AND run it inside pkgs.runCommand so the output
        # is verified at `nix flake check` time (sandbox-safe runtimes only).
        # uv / bun / deno are excluded: they need network at build or first run.
        mkCheck = name: bin: pkgs.runCommand "lang-e2e-${name}" { } ''
          result=$(${bin})
          printf '%s\n' "$result"
          printf '%s\n' "$result" | grep -q "PASS" \
            || { echo "FAIL: ${name} output did not contain PASS"; exit 1; }
          touch "$out"
        '';

      in
      {
        packages = appPkgs // { default = e2eAll; };

        apps = builtins.mapAttrs
          (name: pkg: { type = "app"; program = "${pkg}/bin/${name}"; })
          appPkgs // {
          default = { type = "app"; program = "${e2eAll}/bin/e2e-all"; };
        };

        # Sandbox-safe checks — run by `nix flake check` and the lang-e2e CI job.
        # Each check builds the app derivation AND executes it, verifying "PASS"
        # appears in the output.  No network is required for these five.
        #
        # uv-demo:   build only (ruff-gated); runtime calls `uv run` → needs network
        # bun-demo:  excluded; `bun install` at build time needs network
        # deno-demo: build only (copies .ts); runtime fetches jsr: → needs network
        checks = {
          tsx = mkCheck "tsx" "${appPkgs.tsx-demo}/bin/tsx-demo";
          node = mkCheck "node" "${appPkgs.node-demo}/bin/node-demo";
          perl = mkCheck "perl" "${appPkgs.perl-demo}/bin/perl-demo";
          ruby = mkCheck "ruby" "${appPkgs.ruby-demo}/bin/ruby-demo";
          lua = mkCheck "lua" "${appPkgs.lua-demo}/bin/lua-demo";
          # build-only checks for network-dependent runtimes
          uv-build = appPkgs.uv-demo;
          deno-build = appPkgs.deno-demo;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.uv
            pkgs.bun
            pkgs.nodejs
            pkgs.deno
            pkgs.perl
            pkgs.ruby
            pkgs.lua
          ];
          shellHook = shellHook {
            hook = bash ''
              echo "nixx multi-lang e2e"
              echo ""
              echo "  nix run .#default       run all 8 runtimes end-to-end"
              echo "  nix run .#uv-demo       python + rich  (runtime: uv run)"
              echo "  nix run .#bun-demo      typescript + chalk  (compiled binary)"
              echo "  nix run .#tsx-demo      typescript + nixx-hello  (tsx + nodeModules)"
              echo "  nix run .#node-demo     node.js + nixx-hello  (NODE_PATH)"
              echo "  nix run .#deno-demo     deno + jsr:@std/fmt  (runtime: deno run)"
              echo "  nix run .#perl-demo     perl + JSON::PP  (core module)"
              echo "  nix run .#ruby-demo     ruby + json  (stdlib)"
              echo "  nix run .#lua-demo      lua + built-in table/string"
              echo ""
              echo "  NOTE: bun-demo needs network at build time (bun install)."
              echo "        Linux: nix run .#bun-demo --option sandbox false"
              echo "        uv-demo / deno-demo need network at first run."
            '';
          };
        };
      });
}
