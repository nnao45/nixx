# nixx — full API & reference

The [README](./README.md) covers the headline: raw shell (and the rest of the
`${}` family) inside pure Nix via `with nixx.for pkgs;`, the three dev-shell
idioms, and the task runner. This file is everything else — the multi-language
builders, `mkApps`, dependency wiring, option tables, interpolation
markers, the linter source-mapping, and the repo's own dev commands.

## Language constructors
A block carries its own language as `__lang`; pick the constructor that reads
naturally, and `mkApps` dispatches to the right builder.

| constructor | language | deps | lint/gate | `${}` tax (plain `''…''`)* |
|---|---|---|---|---|
| `nixx.sh` / `nixx.bash` | bash | `runtimeInputs` opt | shellcheck | heavy |
| `nixx.py`   | python | (Nix) | ruff | **none** |
| `nixx.uv`   | python + uv inline deps | `requirements` opt | ruff | **none** |
| `nixx.ts` / `nixx.bun` | typescript via bun | auto (imports) | `bun build` (+compile) | light |
| `nixx.node` | node | Nix node_modules | `node --check` | heavy |
| `nixx.deno` | deno | `npm:`/`jsr:` inline | deno lint | light |
| `nixx.perl` | perl | `runtimeInputs` opt | — | heavy |
| `nixx.ruby` `nixx.lua` | resp. | — | pluggable | none |

\* This column is the tax **only** when a body is *evaluated* (a standalone
`mkScript`, or legacy `mkApp`/`runApplication` direct-block form). Bodies passed
as attr values to `mkApps`, `mkTasks`, or `mkScripts` are read from source, so
they pay **zero** — see the README. Python/Ruby/Lua and TS *type syntax* never
use `${}` interpolation, so they never pay either way.

## The one rule (only when a body is evaluated)
`'' ''` is evaluated by Nix before nixx runs, so inside an **evaluated** body a
shell `${` must be written `''${` and a literal `''` must be written `'''`. This
is exactly the tax the source-read path removes for apps/tasks/scripts. It still
applies to standalone `mkScript` and legacy direct-block `mkApp` /
`runApplication`, because those have no literal attrset position to read from.
For those, either escape, or pass Nix values with the `@nix(…)` markers below.

## `mkApps` — build shippable store binaries
Reads each block's `__lang` and dispatches to the matching builder; the result
is an attrset of `/nix/store/.../bin/<name>` executables. Attr names become
binary names, and bodies are source-read.

**`runtimeInputs` is a global option** on the first attrset — it adds packages to
PATH for every app in the set. Language-specific options (`requirements`,
`compile`, `projectRoot`, …) are attached per-block by calling the block as a
function: `bash ''body'' { opts }` (no separate `app` wrapper):

```nix
with inputs.nixx.for pkgs;
mkApps { runtimeInputs = [ pkgs.rsync ]; } {
  deploy = bash ''
    echo "deploying from ${PWD}"
    rsync -a ./dist/ "$HOST:/srv/"
  '';

  report = uv ''
    from rich import print
    print("[bold green]done[/]")
  '' { requirements = [ "rich>=13" ]; };

  check = bun ''
    interface R { ok: boolean }
    const r: R = { ok: true };
    console.log(`status: ${r.ok}`);
  '' { compile = true; };
}
```

- `bun --compile` → a self-contained store binary.
- `bash ''...'' { opts }` — opts trail the body; Nix left-to-right application
  means `bash ''body'' { opts }` = `(bash ''body'') { opts }`, calling the
  block's `__functor`. The body thunk is **never forced** during this — only
  `materializeRaw` reads it (from source), so `${HOME}` in the body is safe.
- `runtimeInputs` belongs only to the **global first attrset** of `mkApps` /
  `writers.mkTasks`. Passing it per-block or per-task throws an error.
- `app { ... } block` still works as a backwards-compatible composition helper.
  `mkApp` remains as a singleton helper; `runApplication` is a deprecated alias.
- low-level builders in `writers.nix`: `writeBashApplication`,
  `writeUvApplication`, `writeBunApplication`, `writeNodeApplication`,
  `writeTsxApplication`, `writeDenoApplication`.

## Dependencies: point at the project, don't redeclare them
Real projects already have a manifest (`pyproject.toml`+`uv.lock`,
`package.json`+lock). nixx **points at it** instead of restating deps, so
there's a single source of truth and no drift:

```nix
# preferred: deps come from the project's own manifest
with inputs.nixx.for pkgs;
mkApps { } {
  report = uv ''
    from rich import print          # rich resolved from ./pyproject.toml + uv.lock
    print("hello")
  '' { projectRoot = ./.; };
}

# the project dir is imported into the store; the launcher runs
#   uv run --frozen --project <stored> main.py
# so resolution is deterministic from the lockfile.
```

`requirements = [ "rich" ]` still exists as a **quick one-off** path (nixx writes a
PEP 723 header) — handy for throwaway scripts, but for a project use
`projectRoot`. Same for bun: `projectRoot = ./.;` uses the project's
`package.json` + lockfile.

## `mkScript` / `mkScripts`
- `nixx.mkScript { lang?, vars?, shebang?, strict?, runtimeInputs?, requirements?, pythonReq? } block`
  → just the script string (with shebang). A standalone block is *evaluated*, so
  a bare `${VAR}` needs `''${VAR}` (or build it through `mkScripts`, which
  source-reads).
- `nixx.mkScripts { lang?, vars? } { name = block; … }` → `{ scripts, meta }`;
  bodies are source-read (zero `${}` tax). `meta` feeds the linter remap.

## Task runner — full reference
The README shows the concise version. `writers.mkTasks` (pkgs-bound) returns a
ready-to-use derivation plus devShell helpers:

```nix
let
  nixx    = inputs.nixx.lib;
  writers = inputs.nixx.writers pkgs;
  tasks   = writers.mkTasks {
    name        = "tasks";
    defaultDeps = [ "nixenv" ];
    env         = { CI = "true"; };          # exported in every task
  } {
    # runs before EVERY task → no more --extra-experimental-features … each time
    nixenv = nixx.sh ''export NIX_CONFIG="experimental-features = nix-command flakes"'';
    build  = nixx.task { description = "Build the project"; } (nixx.sh ''nix build'');
    test   = nixx.task { description = "Run the test suite"; } (nixx.sh ''nix run .#test'');
    deploy = nixx.task {
      description  = "Deploy production";
      group        = "release";
      env          = { DEPLOY_ENV = "prod"; };  # merged with global; per-task wins on conflict
      runtimeInputs = [ pkgs.awscli2 ];
      cwd          = ./infra;
    } (nixx.sh ''aws s3 sync ...'');
    check  = nixx.task { deps = [ "build" ]; } (nixx.sh ''
      echo ok
    '');
  };
in {
  packages.tasks    = tasks.runner;        # nix run .#tasks -- build
  devShells.default = tasks.devShell;      # nix develop → `tasks build` (tab-completed)
  # or merge the runner into an existing shell:
  # devShells.default = tasks.extendShell (pkgs.mkShell { packages = [ pkgs.nodejs ]; });
}
```

`writers.mkTasks` returns:
- **`runner`** — a `pkgs.writeShellApplication` derivation (shellcheck-gated).
  Global `runtimeInputs` packages from opts are added to PATH for every task.
- **`devShell`** — `pkgs.mkShell { packages = [runner]; }` with a `shellHook` that
  registers bash tab-completion for all task names.
- **`extendShell`** — `shell: pkgs.mkShell { inputsFrom = [shell]; packages = [runner]; }`.
  Merges the runner (and its completion hook) into an existing shell.
- **`tasks`** / **`meta`** — same as the pure `nixx.mkTasks` result.

The pure `nixx.mkTasks` (no pkgs) is still available if you only need the runner
script text or a body's `.text`:

```nix
(nixx.mkTasks { name = "tasks"; } { … }).runner          # → bash script string
(nixx.mkTasks { } { hook = nixx.bash ''…''; }).tasks.hook.text  # → one body, source-read
```

#### `writers.mkTasks` options

| option | default | description |
|---|---|---|
| `name` | `"tasks"` | name embedded in runner comments |
| `runtimeInputs` | `[]` | packages whose `/bin` join `PATH` for **every** task in the runner |
| `vars` | `{}` | Nix values interpolated via `@nix(…)` / `@sh:q(…)` markers |
| `env` | `{}` | attrset exported as shell env vars in **every** task; per-task `env` overrides on conflict |
| `defaultDeps` | `[]` | task names prepended to every task's deps; the default-dep tasks themselves are exempt |

#### `nixx.task` options

| option | default | description |
|---|---|---|
| `description` | `null` | one-line summary shown by `--list`; also on `.tasks.<name>.description` and `.meta` |
| `group` | `null` | groups tasks under a header in `--list` output |
| `deps` | `[]` | prerequisite task names run (once each) before this body |
| `env` | `{}` | attrset of shell env vars exported before the body; merged with global `mkTasks env`, this wins on conflict |
| `cwd` | `null` | working directory; the runner `cd`s here after first resetting to the invocation dir (a dep's `cwd` never leaks in) |

There is intentionally **no per-task `strict`**: the runner is one bash process,
so it re-asserts `set -euo pipefail` at every bash task's entry. Every task is
strict, and a prior task's `set +u` can't leak in. If a specific body needs to
tolerate an unset var, do it locally (`${VAR:-}` or a scoped `set +u; …; set -u`).

**Positional args** (`tasks <name> a b c`) reach **bash** task bodies as `$@`
(via `shift; task_<name> "$@"`). Non-bash bodies run as scripts through a
heredoc and do **not** receive `$@`; pass data to them via `env` instead.

## Interpolation (`vars`)
To splice an actual **Nix** value into a (source-read) body, use a marker —
native Nix `${…}` does not run there.

- `@nix(name)` → raw value   ·   `@nix:q(name)` / `@sh:q(name)` → shell-quoted (bash)
- `@py:q(name)` / `@js:q(name)` → python / js string literal
- a **path** value (`./util.py`, `./libdir`) is auto-imported to the store
  (reproducible; exec bit preserved)

```nix
with nixx.runtimeScope;
nixx.mkTasks { vars = { port = 3000; tool = ./bin/tool; }; } {
  serve = nixx.bash ''
    @nix(tool) --listen ${HOST:-0.0.0.0}:@nix(port)   # ${HOST} raw shell; @nix() = Nix value
  '';
}
```

## Tooling: linter source-mapping
`mkTasks` / `mkScripts` return a `meta` list (per block: `name`, `file`, `line`,
`indent` — plus `lang` for `mkScripts`) built from `unsafeGetAttrPos` + source
read + common-indent column correction. A linter wrapper can feed each block to
the right tool (`bash`→shellcheck, `python`→ruff) and remap every diagnostic back
to the ORIGINAL `.nix` `line:col` — exact even under nested indentation.

Files stay valid Nix, so nil/nixd never choke on the script bodies (zero LSP
errors).

## This repo's own dev commands
The root `flake.nix` is the library itself plus its own checks:

```
nix run   .#test                  # pure-Nix lib unit tests (tests/lib-tests.nix)
nix run   .#nix-tasks -- --list   # list this repo's lint/format tasks
nix run   .#nix-tasks -- check    # fmt-check + statix + nixf (a mkTasks runner)
nix develop                       # uv ruff bun node shellcheck nixpkgs-fmt statix nixf jq
nix flake check                   # lib tests + nix-tasks + e2e task runners (all gated)
```

A runnable example **per language** lives in `examples/simple01`:

```
cd examples/simple01
nix run .#status      # bash   (mkApps + runtimeInputs)
nix run .#report      # python (uv, deps from ./py via projectRoot)
nix run .#validate    # ts     (bun --compile, deps from ./ts)
nix run .#tasks -- check   # mkTasks runner: report + validate (just-style deps)
```

## Status — proven end-to-end in a real Nix
1. ✅ shellcheck / ruff / bun build gates (bad code fails the build)
2. ✅ dependency injection: bash runtimeInputs, uv PEP 723, bun auto-import, node_modules
3. ✅ `@nix(./path)` local-file store import (files + dirs, exec bit kept)
4. ✅ linter diagnostics remapped to exact `.nix` line:col
5. ✅ multi-language via constructors (bash/python/uv/bun/ts/node/deno/perl)
6. ✅ `bun --compile` → self-contained store binary
7. ✅ `mkApps` dispatcher + one runnable app per language in
   `examples/simple01`
8. ✅ source-read `${}`-tax-free task/script bodies (175+ unit tests)
