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
- low-level builders in `writers.nix`: `writeBashApplication`,
  `writeUvApplication`, `writeBunApplication`, `writeNodeApplication`

### Interpolation (`vars`)
- `@nix(name)` → raw value   ·   `@nix:q(name)` → shell-quoted (bash)
- a **path** (`./util.py`, `./libdir`) is auto-imported to the store
  (reproducible; exec bit preserved)

## flake usage
This repo's `flake.nix` ships one example per language:

```
nix build .#greet      # bash   (writeShellApplication + runtimeInputs)
nix build .#report     # python (uv inline deps, ruff gate)
nix build .#validate   # ts     (bun --compile, self-contained binary)
nix build .#ping       # node
nix run   .#report     # run any of them
nix develop            # shell with uv/ruff/bun/node/shellcheck
nix flake check        # build (and thereby gate) every example
```

Consume it elsewhere:
```nix
inputs.nixx.url = "github:you/nixx";
# then: inputs.nixx.lib.uv ''...''  and  (inputs.nixx.writers pkgs).runApplication
```

## Tooling
- **Lint with source mapping**: `./nixx-check file.nix [attr]` runs the right
  linter per block (`bash`→shellcheck, `python`→ruff) and maps each diagnostic
  back to the ORIGINAL `.nix` `line:col` (via `unsafeGetAttrPos` + source read
  + common-indent column correction). Exact for nested indentation.
- **LSP**: zero errors (valid Nix).  **Highlight**: `injections.scm` (nvim).

## Status — proven end-to-end in a real Nix
1. ✅ shellcheck / ruff / bun build gates (bad code fails the build)
2. ✅ dependency injection: bash runtimeInputs, uv PEP 723, bun auto-import, node_modules
3. ✅ `@nix(./path)` local-file store import (files + dirs, exec bit kept)
4. ✅ linter diagnostics remapped to exact `.nix` line:col
5. ✅ multi-language via constructors (bash/python/uv/bun/ts/node)
6. ✅ `bun --compile` → self-contained store binary
7. ✅ `runApplication` single dispatcher + `flake.nix` with one app per language
