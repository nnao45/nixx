# nixx/writers.nix — pkgs-dependent builders that turn nixx blocks into
# store-path executables. Import with your nixpkgs `pkgs`:
#
#   let
#     nixx = import ./lib.nix;
#     writers = import ./writers.nix { inherit pkgs nixx; };
#   in writers.writeUvApplication { ... }
#
# Kept separate from lib.nix so lib.nix stays pure (no nixpkgs dependency).
{ pkgs, nixx }:
let
  inherit (pkgs) lib stdenv;
in
rec {
  # mkTasks — pkgs-bound wrapper around nixx.mkTasks.  Returns a derivation for
  # the runner plus helpers for wiring it into a devShell, so users can write:
  #
  #   let tasks = (inputs.nixx.writers pkgs).mkTasks { name = "tasks"; packages = [ pkgs.curl ]; } { ... };
  #   in {
  #     packages.tasks    = tasks.runner;         # nix run .#tasks -- build
  #     devShells.default = tasks.devShell;       # nix develop → `tasks` in PATH
  #   }
  #
  # Or merge the runner into an existing shell (task names are tab-completed):
  #
  #   devShells.default = tasks.extendShell (pkgs.mkShell { packages = [ nodejs ]; });
  #
  # `runner` is a pkgs.writeShellApplication derivation (shellcheck-gated).
  # Global `packages` from opts are added to PATH for every task in the
  # runner.  The binary is named after `opts.name` (defaults to "tasks").
  mkTasks = opts: taskDefs:
    let
      name = opts.name or "tasks";
      pkgList = opts.packages or [ ];
      result = nixx.mkTasks (lib.removeAttrs opts [ "packages" ]) taskDefs;
      runner = pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = pkgList;
        text = result.runner;
      };
      taskNames = lib.concatStringsSep " " (map (m: m.name) result.meta);
      completionHook = ''
        if [[ -n "''${BASH_VERSION-}" ]]; then
          _${name}_completions() {
            COMPREPLY=($(compgen -W "${taskNames}" -- "''${COMP_WORDS[COMP_CWORD]}"))
          }
          complete -F _${name}_completions ${name}
        fi
      '';
      # `runner`'s own runtimeInputs are wrapped — visible only INSIDE the runner
      # process, never on the interactive shell prompt. So a task that calls `jq`
      # works via `nix run .#tasks`, but typing `jq` at the `nix develop` prompt
      # would not. We re-expose `pkgList` on the shell's PATH so the mental model
      # collapses to a single source of truth: `mkTasks { packages }` covers tasks
      # AND the prompt; `mkShell { packages }` is only for prompt-only extras that
      # no task calls. (See README "what goes where".)
      devShell = pkgs.mkShell {
        packages = [ runner ] ++ pkgList;
        shellHook = completionHook;
      };
      extendShell = shell: pkgs.mkShell {
        inputsFrom = [ shell ];
        packages = [ runner ] ++ pkgList;
        shellHook = completionHook;
      };
    in
    {
      inherit runner devShell extendShell;
      inherit (result) tasks meta;
    };

  # mkApps — build shippable store binaries from a source-read attrset.
  # Attr names become binary names, and each block's __lang dispatches to the
  # matching low-level write*Application builder. Because bodies live as attr
  # values, nixx can source-read them and preserve shell/JS `${...}`:
  #
  #   mkApps { } {
  #     inspect = nixx.sh ''echo ${HOME}'';
  #     report  = nixx.uv  ''from rich import print ...'' { requirements = [ "rich" ]; };
  #     fetch   = nixx.sh  ''curl ${URL}'';
  #   }
  #
  # Per-app options are attached by calling the block: bash ''body'' { opts }.
  # nixx.app { } (block) still works as a backwards-compatible helper.
  # Global options in the first attrset apply to every app. Options that a
  # language builder doesn't accept are dropped first so it won't error.
  mkApps = opts: apps:
    let
      common = [ "name" "vars" "packages" ];
      pickFrom = src: names: lib.filterAttrs (n: _: lib.elem n names) src;
      dispatch = appOpts: block:
        let lang = block.__lang or "bash";
        in
        if lang == "bash" then
          writeBashApplication ((pickFrom appOpts (common ++ [ "strict" ])) // { inherit block; })
        else if lang == "python-uv" then
          writeUvApplication ((pickFrom appOpts (common ++ [ "projectRoot" "frozen" "requirements" "pythonReq" "lintIgnore" ])) // { inherit block; })
        else if lang == "bun" then
          writeBunApplication ((pickFrom appOpts (common ++ [ "projectRoot" "compile" ])) // { inherit block; })
        else if lang == "node" then
          writeNodeApplication ((pickFrom appOpts (common ++ [ "projectRoot" "nodeModules" "syntaxCheck" ])) // { inherit block; })
        else if lang == "typescript" then
          writeTsxApplication ((pickFrom appOpts (common ++ [ "nodeModules" ])) // { inherit block; })
        else if lang == "deno" then
          writeDenoApplication ((pickFrom appOpts common) // { inherit block; })
        else if lang == "perl" then
          writePerlApplication ((pickFrom appOpts (common ++ [ "perlPackages" ])) // { inherit block; })
        else if lang == "ruby" then
          writeRubyApplication ((pickFrom appOpts (common ++ [ "rubyGems" ])) // { inherit block; })
        else if lang == "lua" then
          writeLuaApplication ((pickFrom appOpts (common ++ [ "luaPackages" ])) // { inherit block; })
        else
          throw ("nixx.mkApps: no builder for lang '" + lang + "' "
            + "(have: bash, python-uv, bun, node, typescript, deno, perl, ruby, lua)");
      result = nixx.mkTasks { vars = opts.vars or { }; } apps;
      globalOpts = lib.removeAttrs opts [ "name" "vars" ];
    in
    lib.mapAttrs
      (name: block:
        let appOpts = globalOpts // (block.__appOptions or { }) // { inherit name; };
        in dispatch appOpts block)
      result.tasks;

  # mkApp — singleton helper plus legacy direct-block compatibility.
  #
  # Preferred, source-read form:
  #   (mkApp { } { inspect = nixx.sh ''echo ${HOME}''; })
  #
  # Legacy direct-block form is still accepted, but it is evaluated by Nix
  # before nixx sees it, so shell/JS `${...}` needs normal Nix escaping there:
  #   mkApp { name = "inspect"; } (nixx.sh ''echo ''${HOME}'')
  mkApp = opts: value:
    if value.__sh or false then
      let
        legacyName = opts.name or (throw "nixx.mkApp: direct-block form requires `name`");
        apps = mkApps (lib.removeAttrs opts [ "name" ]) {
          ${legacyName} = value;
        };
      in
      apps.${legacyName}
    else
      let
        names = lib.attrNames value;
        attrName =
          if names == [ ] then
            throw "nixx.mkApp: expected a singleton attrset, got an empty attrset"
          else if lib.length names != 1 then
            throw "nixx.mkApp: expected a singleton attrset; use mkApps for multiple binaries"
          else
            lib.head names;
        apps = mkApps opts value;
      in
      apps.${attrName};

  # runApplication — deprecated alias of mkApp (the "run" was a misnomer: it
  # builds a runnable, it doesn't run anything). Kept for back-compat.
  runApplication = mkApp;

  # writeUvApplication — Python via uv, built to /nix/store/<hash>/bin/<name>.
  #
  # Dependency source (pick ONE; projectRoot is preferred for real projects):
  #   * projectRoot = ./.      -> uv reads the project's own pyproject.toml +
  #                               uv.lock. The manifest is the single source of
  #                               truth; nixx declares nothing. The project dir
  #                               is imported into the store, and `uv run
  #                               --frozen` resolves deterministically from the
  #                               lockfile (offline-friendly once cached).
  #   * requirements = [ "rich" ] -> quick one-off: nixx writes a PEP 723 header.
  #                               Good for throwaway scripts, not for projects.
  #
  # ruff gates the build; uv & ruff are Nix-pinned via `pkgs`.
  writeUvApplication =
    { name
    , block                  # nixx.uv ''...''
    , projectRoot ? null     # dir containing pyproject.toml (+ uv.lock)
    , requirements ? [ ]     # fallback: inline PEP 723 deps
    , pythonReq ? ">=3.11"
    , vars ? { }
    , lintIgnore ? [ ]
    , packages ? [ ]
    , frozen ? true          # use uv.lock as-is (reproducible); false = resolve
    }:
    let
      useProject = projectRoot != null;
      # in project mode the body needs no PEP 723 header (manifest owns deps)
      script = nixx.mkScript
        {
          lang = "python-uv";
          requirements = if useProject then [ ] else requirements;
          inherit pythonReq vars;
          # in project mode we run via `uv run`, so a uv shebang is redundant;
          # keep a plain python marker the wrapper strips.
          shebang = if useProject then "# (project script)" else null;
        }
        block;
      storedProject =
        if useProject
        then builtins.path { path = projectRoot; name = "${name}-project"; }
        else null;
      pathPrefix = lib.makeBinPath ([ pkgs.uv ] ++ packages);
      frozenFlag = lib.optionalString frozen "--frozen";
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.ruff pkgs.makeWrapper ];
      buildPhase = ''
        runHook preBuild
        cp "$scriptPath" prog
        # BUILD GATE: ruff statically checks the body (deterministic, offline).
        ruff check --no-cache \
          ${lib.optionalString (lintIgnore != []) "--ignore ${lib.concatStringsSep "," lintIgnore}"} \
          prog
        runHook postBuild
      '';
      installPhase =
        if useProject then ''
          runHook preInstall
          mkdir -p "$out/bin" "$out/share/${name}"
          # strip the marker line; keep the python body
          tail -n +2 prog > "$out/share/${name}/main.py"
          # a launcher that runs the body against the stored project manifest
          cat > "$out/bin/${name}" <<LAUNCH
          #!${pkgs.runtimeShell}
          exec ${pkgs.uv}/bin/uv run ${frozenFlag} \
            --project ${storedProject} \
            "$out/share/${name}/main.py" "\$@"
          LAUNCH
          chmod +x "$out/bin/${name}"
          wrapProgram "$out/bin/${name}" --prefix PATH : ${pathPrefix}
          runHook postInstall
        '' else ''
          runHook preInstall
          mkdir -p "$out/bin"
          cp prog "$out/bin/${name}"
          chmod +x "$out/bin/${name}"
          wrapProgram "$out/bin/${name}" --prefix PATH : ${pathPrefix}
          runHook postInstall
        '';
      meta.mainProgram = name;
    };

  # writeBashApplication — thin alias over nixpkgs' writeShellApplication that
  # accepts a nixx.sh block instead of a raw text string.
  writeBashApplication =
    { name, packages ? [ ], vars ? { }, block, strict ? true }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = packages;
      text = nixx.mkScript
        {
          lang = "bash"; inherit vars strict;
          shebang = ""; # writeShellApplication adds its own shebang+strict
        }
        block;
    };

  # writeNodeApplication — a Node script built to a store path.
  # Unlike Python/uv, Node has no clean runtime-inline dep mechanism, so deps
  # are supplied by Nix: pass `nodeModules` (e.g. from buildNpmPackage or
  # pkgs.nodePackages) and they're put on NODE_PATH via a wrapper.
  #   writeNodeApplication {
  #     name = "tool";
  #     nodeModules = (pkgs.buildNpmPackage { ... });  # provides /lib/node_modules
  #     block = nixx.sh ''  const _ = require("lodash"); ...  '';
  #   }
  writeNodeApplication =
    { name
    , block
    , vars ? { }
    , nodeModules ? null
    , packages ? [ ]
    , syntaxCheck ? true
    }:
    let
      script = nixx.mkScript { lang = "node"; inherit vars; } block;
      nodePath = lib.optionalString (nodeModules != null)
        "${nodeModules}/lib/node_modules";
      binPath = lib.makeBinPath ([ pkgs.nodejs ] ++ packages);
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.nodejs pkgs.makeWrapper ];
      buildPhase = ''
        runHook preBuild
        cp "$scriptPath" prog
        ${lib.optionalString syntaxCheck ''
          # BUILD GATE: node --check catches syntax errors (offline, zero-config)
          node --check prog
        ''}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share/${name}"
        tail -n +2 prog > "$out/share/${name}/main.js"
        cat > "$out/bin/${name}" <<LAUNCH
        #!${pkgs.runtimeShell}
        exec ${pkgs.nodejs}/bin/node "$out/share/${name}/main.js" "\$@"
        LAUNCH
        chmod +x "$out/bin/${name}"
        wrapProgram "$out/bin/${name}" \
          --prefix PATH : ${binPath} \
          ${lib.optionalString (nodeModules != null) "--set NODE_PATH ${nodePath}"}
        runHook postInstall
      '';
      meta.mainProgram = name;
    };

  # writeBunApplication — TypeScript/JS built to a store path via bun.
  # Two modes:
  #   compile = true  (default): `bun build --compile` bakes deps into ONE
  #     self-contained binary at build time → fully reproducible, offline,
  #     no runtime resolution. This is the strongest story of any nixx lang.
  #   compile = false: emits the .ts with a `#!/usr/bin/env bun` shebang and
  #     relies on bun's runtime auto-install (fast, but resolves at run time).
  # `tscheck = true` runs `bun build` (which type-checks) as a BUILD GATE.
  writeBunApplication =
    { name
    , block
    , vars ? { }
    , compile ? true
    , packages ? [ ]
    , projectRoot ? null    # dir with package.json (+ bun.lockb); deps from there
    }:
    let
      useProject = projectRoot != null;
      script = nixx.mkScript
        {
          lang = "bun";
          shebang = if compile then "// (compiled)" else "#!/usr/bin/env bun";
          inherit vars;
        }
        block;
      storedProject =
        if useProject
        then builtins.path { path = projectRoot; name = "${name}-project"; }
        else null;
      binPath = lib.makeBinPath ([ pkgs.bun ] ++ packages);
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.bun pkgs.makeWrapper ];
      buildPhase =
        if compile then ''
          runHook preBuild
          tail -n +2 "$scriptPath" > prog.ts
          export HOME=$TMPDIR
          ${lib.optionalString useProject ''
            # bring the project's manifest + lock so bundling resolves deps
            cp ${storedProject}/package.json . 2>/dev/null || true
            # bun.lock (text, v1.1+) or bun.lockb (binary, legacy)
            cp ${storedProject}/bun.lock . 2>/dev/null || \
              cp ${storedProject}/bun.lockb . 2>/dev/null || true
            bun install --frozen-lockfile 2>/dev/null || bun install
          ''}
          # compile to a standalone binary (deps baked in, reproducible)
          bun build --compile prog.ts --outfile "$name"
          runHook postBuild
        '' else ''
          runHook preBuild
          cp "$scriptPath" prog.ts
          export HOME=$TMPDIR
          bun build prog.ts --outfile /dev/null
          runHook postBuild
        '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin"
        ${if compile then ''
          cp "$name" "$out/bin/${name}"
          chmod +x "$out/bin/${name}"
        '' else ''
          cp prog.ts "$out/bin/${name}"
          chmod +x "$out/bin/${name}"
          wrapProgram "$out/bin/${name}" --prefix PATH : ${binPath} \
            ${lib.optionalString useProject "--set NODE_PATH ${storedProject}/node_modules"}
        ''}
        runHook postInstall
      '';
      meta.mainProgram = name;
    };

  # writeTsxApplication — TypeScript via tsx (Node + TS stripping), built to a
  # store-path executable. Deps supplied by Nix via `nodeModules`; tsx runs the
  # .ts file directly with no compile step (closest analog to writeNodeApplication).
  #   writeTsxApplication {
  #     name = "tool";
  #     nodeModules = (pkgs.buildNpmPackage { ... });
  #     block = nixx.ts ''  const x: number = 1; console.log(x);  '';
  #   }
  writeTsxApplication =
    { name
    , block
    , vars ? { }
    , nodeModules ? null
    , packages ? [ ]
    }:
    let
      script = nixx.mkScript { lang = "typescript"; inherit vars; } block;
      nodePath = lib.optionalString (nodeModules != null)
        "${nodeModules}/lib/node_modules";
      binPath = lib.makeBinPath ([ pkgs.tsx ] ++ packages);
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.tsx pkgs.makeWrapper ];
      buildPhase = ''
        runHook preBuild
        cp "$scriptPath" prog.ts
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share/${name}"
        # strip the shebang line; tsx receives a named .ts file so it type-strips correctly
        tail -n +2 prog.ts > "$out/share/${name}/main.ts"
        cat > "$out/bin/${name}" <<LAUNCH
        #!${pkgs.runtimeShell}
        exec ${pkgs.tsx}/bin/tsx "$out/share/${name}/main.ts" "\$@"
        LAUNCH
        chmod +x "$out/bin/${name}"
        wrapProgram "$out/bin/${name}" \
          --prefix PATH : ${binPath} \
          ${lib.optionalString (nodeModules != null) "--set NODE_PATH ${nodePath}"}
        runHook postInstall
      '';
      meta.mainProgram = name;
    };

  # writePerlApplication — Perl script built to a store-path executable.
  # Perl module deps are supplied via `perlPackages` (a list of derivations);
  # nixx calls `pkgs.perl.withPackages` so each module's lib is on PERL5LIB.
  # Core Perl modules (JSON::PP, Data::Dumper, …) need no extra packages.
  #   writePerlApplication {
  #     name = "tool";
  #     perlPackages = [ pkgs.perlPackages.JSON ];
  #     block = nixx.perl ''
  #       use JSON; print JSON->new->encode({ ok => 1 }) . "\n";
  #     '';
  #   }
  writePerlApplication =
    { name
    , block
    , vars ? { }
    , packages ? [ ]
    , perlPackages ? [ ]
    }:
    let
      script = nixx.mkScript { lang = "perl"; inherit vars; } block;
      perlInterp = if perlPackages == [ ] then pkgs.perl
                   else pkgs.perl.withPackages (_: perlPackages);
      binPath = lib.makeBinPath ([ perlInterp ] ++ packages);
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      buildPhase = ''
        runHook preBuild
        cp "$scriptPath" prog
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share/${name}"
        tail -n +2 prog > "$out/share/${name}/main.pl"
        cat > "$out/bin/${name}" <<LAUNCH
        #!${pkgs.runtimeShell}
        exec ${perlInterp}/bin/perl "$out/share/${name}/main.pl" "\$@"
        LAUNCH
        chmod +x "$out/bin/${name}"
        wrapProgram "$out/bin/${name}" --prefix PATH : ${binPath}
        runHook postInstall
      '';
      meta.mainProgram = name;
    };

  # writeRubyApplication — Ruby script built to a store-path executable.
  # Gem deps are supplied via `rubyGems` (a list of gem derivations);
  # nixx calls `pkgs.ruby.withPackages` so each gem is available at runtime.
  # Ruby's standard library (json, csv, …) needs no extra gems.
  #   writeRubyApplication {
  #     name = "tool";
  #     rubyGems = [ pkgs.rubyPackages.faraday ];
  #     block = nixx.ruby ''
  #       require "json"; puts JSON.dump({ ok: true })
  #     '';
  #   }
  writeRubyApplication =
    { name
    , block
    , vars ? { }
    , packages ? [ ]
    , rubyGems ? [ ]
    }:
    let
      script = nixx.mkScript { lang = "ruby"; inherit vars; } block;
      rubyInterp = if rubyGems == [ ] then pkgs.ruby
                   else pkgs.ruby.withPackages (_: rubyGems);
      binPath = lib.makeBinPath ([ rubyInterp ] ++ packages);
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      buildPhase = ''
        runHook preBuild
        cp "$scriptPath" prog
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share/${name}"
        tail -n +2 prog > "$out/share/${name}/main.rb"
        cat > "$out/bin/${name}" <<LAUNCH
        #!${pkgs.runtimeShell}
        exec ${rubyInterp}/bin/ruby "$out/share/${name}/main.rb" "\$@"
        LAUNCH
        chmod +x "$out/bin/${name}"
        wrapProgram "$out/bin/${name}" --prefix PATH : ${binPath}
        runHook postInstall
      '';
      meta.mainProgram = name;
    };

  # writeLuaApplication — Lua script built to a store-path executable.
  # Lua module deps are supplied via `luaPackages` (a list of derivations);
  # nixx calls `pkgs.lua.withPackages` so LUA_PATH/LUA_CPATH are set.
  # Built-in Lua (table, string, io, math, …) needs no extra packages.
  #   writeLuaApplication {
  #     name = "tool";
  #     luaPackages = [ pkgs.luaPackages.dkjson ];
  #     block = nixx.lua ''
  #       local json = require "dkjson"
  #       print(json.encode({ ok = true }))
  #     '';
  #   }
  writeLuaApplication =
    { name
    , block
    , vars ? { }
    , packages ? [ ]
    , luaPackages ? [ ]
    }:
    let
      script = nixx.mkScript { lang = "lua"; inherit vars; } block;
      luaInterp = if luaPackages == [ ] then pkgs.lua
                  else pkgs.lua.withPackages (_: luaPackages);
      binPath = lib.makeBinPath ([ luaInterp ] ++ packages);
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      buildPhase = ''
        runHook preBuild
        cp "$scriptPath" prog
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share/${name}"
        tail -n +2 prog > "$out/share/${name}/main.lua"
        cat > "$out/bin/${name}" <<LAUNCH
        #!${pkgs.runtimeShell}
        exec ${luaInterp}/bin/lua "$out/share/${name}/main.lua" "\$@"
        LAUNCH
        chmod +x "$out/bin/${name}"
        wrapProgram "$out/bin/${name}" --prefix PATH : ${binPath}
        runHook postInstall
      '';
      meta.mainProgram = name;
    };

  # writeDenoApplication — TypeScript/JS via deno, built to a store-path
  # executable. Supports inline deps via npm:/jsr: import specifiers.
  #   writeDenoApplication {
  #     name = "tool";
  #     block = nixx.deno ''
  #       import { bold } from "jsr:@std/fmt/colors";
  #       console.log(bold("hello"));
  #     '';
  #   }
  writeDenoApplication =
    { name
    , block
    , vars ? { }
    , packages ? [ ]
    }:
    let
      script = nixx.mkScript { lang = "deno"; inherit vars; } block;
      binPath = lib.makeBinPath ([ pkgs.deno ] ++ packages);
    in
    stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      passAsFile = [ "script" ];
      inherit script;
      nativeBuildInputs = [ pkgs.deno pkgs.makeWrapper ];
      buildPhase = ''
        runHook preBuild
        cp "$scriptPath" prog.ts
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin" "$out/share/${name}"
        # strip the shebang line; deno receives a named .ts file so it parses as TypeScript
        tail -n +2 prog.ts > "$out/share/${name}/main.ts"
        cat > "$out/bin/${name}" <<LAUNCH
        #!${pkgs.runtimeShell}
        exec ${pkgs.deno}/bin/deno run -A "$out/share/${name}/main.ts" "\$@"
        LAUNCH
        chmod +x "$out/bin/${name}"
        wrapProgram "$out/bin/${name}" --prefix PATH : ${binPath}
        runHook postInstall
      '';
      meta.mainProgram = name;
    };
}
