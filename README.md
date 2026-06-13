# nixx — write raw, lintable, multi-language scripts inside pure Nix

No preprocessor. No codegen. Files stay valid `.nix`, so nil/nixd never error.
Script bodies live in Nix indented strings (`'' ''`) — which, unlike comments,
can contain `*/`, globs, heredocs, and any other bytes.

```nix
let
  nixx = inputs.nixx.lib;
  inherit (inputs.nixx.writers pkgs) runApplication;
in {
  # one entry point; the block knows its own language
  deploy = runApplication { name = "deploy"; runtimeInputs = [ pkgs.rsync ]; } (nixx.sh ''
    rsync -a ./dist/ "$HOST:/srv/"      # raw bash, */ and $VAR work
  '');

  report = runApplication { name = "report"; deps = [ "rich>=13" ]; } (nixx.uv ''
    from rich import print              # zero ${} tax in python
    print("[bold green]done[/]")        # rich auto-resolved by uv
  '');

  check = runApplication { name = "check"; compile = true; } (nixx.ts ''
    interface R { ok: boolean }         # TS types: no ${} tax
    const r: R = { ok: true };
    console.log(`status: ''${r.ok}`);    # only template literals need ''${}
  '');
}
```

## Language constructors
A block carries its own language as `__lang`; pick the constructor that reads
naturally, and `runApplication` dispatches to the right builder.

| constructor | language | deps | lint/gate | `${}` tax |
|---|---|---|---|---|
| `nixx.sh`   | bash | runtimeInputs | shellcheck | heavy |
| `nixx.py`   | python | (Nix) | ruff | **none** |
| `nixx.uv`   | python + uv inline deps | `deps = [...]` | ruff | **none** |
| `nixx.ts` / `nixx.bun` | typescript via bun | auto (imports) | `bun build` (+compile) | light* |
| `nixx.node` | node | Nix node_modules | `node --check` | heavy |
| `nixx.deno` | deno | `npm:`/`jsr:` inline | deno lint | light* |
| `nixx.ruby` `nixx.lua` | resp. | — | pluggable | none |

\* TS/JS type annotations use `{ }` not `${ }`, so only template literals pay.

## Dependencies: point at the project, don't redeclare them
Real projects already have a manifest (`pyproject.toml`+`uv.lock`,
`package.json`+lock). nixx **points at it** instead of restating deps, so
there's a single source of truth and no drift:

```nix
# preferred: deps come from the project's own manifest
runApplication { name = "report"; projectRoot = ./.; } (nixx.uv ''
  from rich import print          # rich resolved from ./pyproject.toml + uv.lock
  print("hello")
'')

# the project dir is imported into the store; the launcher runs
#   uv run --frozen --project <stored> main.py
# so resolution is deterministic from the lockfile.
```

`deps = [ "rich" ]` still exists as a **quick one-off** path (nixx writes a
PEP 723 header) — handy for throwaway scripts, but for a project use
`projectRoot`. Same for bun: `projectRoot = ./.;` uses the project's
`package.json` + lockfile.

## The one rule (bash / node / template literals only)
`'' ''` is evaluated by Nix before nixx runs, so `${` must be written `''${`
and a literal `''` must be written `'''`. Python/Ruby/Lua and TS *type syntax*
never hit this; only `${}` interpolation does. (Even this README's flake hits
it — that's the problem nixx exists to tame.)

## API
- **constructors**: `nixx.sh` `nixx.py` `nixx.uv` `nixx.bun` `nixx.ts`
  `nixx.node` `nixx.deno` `nixx.ruby` `nixx.lua` — each `''...''` → tagged block
- **`nixx.runApplication { name, ... } block`** — THE entry point; builds a
  store-path executable, dispatching on the block's language
- `nixx.mkScript { lang?, vars?, deps?, ... } block` — just the script string
- `nixx.mkScripts` / `nixx.mkTasks` — many scripts / a bash task runner

### Task runner (`nixx.mkTasks`)
A `just`-style runner where one `nix run .#tasks -- <name>` invocation is a
single bash process, so env exports made early persist into every later task.

```nix
(nixx.mkTasks { name = "tasks"; defaultDeps = [ "nixenv" ]; } {
  # runs before EVERY task → no more --extra-experimental-features … each time
  nixenv = nixx.sh ''export NIX_CONFIG="experimental-features = nix-command flakes"'';
  build  = nixx.task { description = "Build the project"; } (nixx.sh ''nix build'');
  test   = nixx.task { description = "Run the test suite"; } (nixx.sh ''nix run .#test'');
  deploy = nixx.task { description = "Deploy production"; } (nixx.sh ''aws s3 sync ...'');
  check  = nixx.task { deps = [ "build" ]; } (nixx.sh ''  # deps = prerequisite tasks
    echo ok
  '');
}).runner
```

List the tasks (no arg, `-l`, `--list`, or `help`) — descriptions line up `just`-style:

```
$ nix run .#tasks -- --list
available tasks:
  build    Build the project
  check
  deploy   Deploy production
  nixenv
  test     Run the test suite
```

- **`description`** (on `nixx.task`) — a one-line summary shown by `--list`.
  Tasks without one are still listed by name. Also exposed programmatically on
  `(mkTasks ...).tasks.<name>.description` and each `(mkTasks ...).meta` entry.
- **`deps`** (on `nixx.task`) — prerequisite *tasks*, run once each before the body
  (renamed from `needs`).
- **`requirements`** (on `nixx.task`) — *packages* whose `/bin` join `PATH`
  (renamed from the old `deps`).
- **`defaultDeps`** (on `mkTasks`) — tasks prepended to every task's `deps`;
  the default-dep tasks themselves are exempt (no self-loop).
- low-level builders in `writers.nix`: `writeBashApplication`,
  `writeUvApplication`, `writeBunApplication`, `writeNodeApplication`

### Interpolation (`vars`)
- `@nix(name)` → raw value   ·   `@nix:q(name)` → shell-quoted (bash)
- a **path** (`./util.py`, `./libdir`) is auto-imported to the store
  (reproducible; exec bit preserved)

## flake usage
This repo's root `flake.nix` is the library itself plus its own checks:

```
nix run   .#test                  # pure-Nix lib unit tests (tests/lib-tests.nix)
nix run   .#nix-tasks -- --list   # list this repo's lint/format tasks
nix run   .#nix-tasks -- check    # fmt-check + statix + nixf (a mkTasks runner)
nix develop                       # uv ruff bun node shellcheck nixpkgs-fmt statix nixf jq
nix flake check                   # lib tests + nix-tasks + e2e task runners (all gated)
```

A runnable example **per language** lives in `examples/simple01` (it consumes
nixx as a flake input):

```
cd examples/simple01
nix run .#status      # bash   (runApplication + runtimeInputs)
nix run .#report      # python (uv, deps from ./py via projectRoot)
nix run .#validate    # ts     (bun --compile, deps from ./ts)
nix run .#tasks -- check   # mkTasks runner: report + validate (just-style deps)
```

Consume it elsewhere:
```nix
inputs.nixx.url = "github:you/nixx";
# then: inputs.nixx.lib.uv ''...''  and  (inputs.nixx.writers pkgs).runApplication
```

## Tooling
- **Source-mapping for linters**: `mkTasks` / `mkScripts` return a `meta` list
  (per block: `name`, `file`, `line`, `indent` — plus `lang` for `mkScripts`)
  built from `unsafeGetAttrPos` + source read + common-indent column
  correction. A linter wrapper can feed each block to the right tool
  (`bash`→shellcheck, `python`→ruff) and remap every diagnostic back to the
  ORIGINAL `.nix` `line:col` — exact even under nested indentation.
- **LSP**: zero errors — files stay valid Nix, so nil/nixd never choke on the
  script bodies.

## Status — proven end-to-end in a real Nix
1. ✅ shellcheck / ruff / bun build gates (bad code fails the build)
2. ✅ dependency injection: bash runtimeInputs, uv PEP 723, bun auto-import, node_modules
3. ✅ `@nix(./path)` local-file store import (files + dirs, exec bit kept)
4. ✅ linter diagnostics remapped to exact `.nix` line:col
5. ✅ multi-language via constructors (bash/python/uv/bun/ts/node)
6. ✅ `bun --compile` → self-contained store binary
7. ✅ `runApplication` single dispatcher + one runnable app per language in
   `examples/simple01` (root `flake.nix` ships the lib, its unit tests, and
   `mkTasks`-based lint/e2e runners)
