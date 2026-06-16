# nixx — full API & reference

The [README](./README.md) covers the headline: the two pillars (escape-light
`${}` and `shellint`), the task runner, and one dev-shell idiom. This file is
everything else — the multi-language builders, `mkApps`, apps+tasks composition,
dependency wiring, the full option tables, the dev-shell wiring, `shellint` and
`envCheck` in full, interpolation markers, the linter source-mapping, and the
repo's own dev commands.

## Language constructors
A block carries its own language as `__lang`; pick the constructor that reads
naturally, and `mkApps` dispatches to the right builder.

| constructor | language | deps | lint/gate | `${}` tax (plain `''…''`)* |
|---|---|---|---|---|
| `nixx.sh` / `nixx.bash` | bash | `packages` opt | shellcheck | heavy |
| `nixx.py`   | python | (Nix) | ruff | **none** |
| `nixx.uv`   | python + uv inline deps | `requirements` opt | ruff | **none** |
| `nixx.ts` / `nixx.bun` | typescript via bun | auto (imports) | `bun build` (+compile) | light |
| `nixx.node` | node | Nix node_modules | `node --check` | heavy |
| `nixx.deno` | deno | `npm:`/`jsr:` inline | deno lint | light |
| `nixx.perl` | perl | `packages` opt | — | heavy |
| `nixx.ruby` `nixx.lua` | resp. | — | pluggable | none |

\* This column is the tax **only** when a body is *evaluated* (a standalone
`mkScript`). Bodies passed as attr values to `mkApps`, `mkTasks`, or `mkScripts`
are read from source, so they pay **zero** — see the README. Python/Ruby/Lua and
TS *type syntax* never use `${}` interpolation, so they never pay either way.

## The one rule (only when a body is evaluated)
`'' ''` is evaluated by Nix before nixx runs, so inside an **evaluated** body a
shell `${` must be written `''${` and a literal `''` must be written `'''`. This
is exactly the tax the source-read path removes for apps/tasks/scripts. It still
applies to a standalone `mkScript`, because that has no literal attrset position
to read from. For it, either escape, or pass Nix values with the `@nix(…)`
markers below.

Even on the source-read path, a `${…}` that isn't valid Nix (`${VAR:-}`,
`${ARR[@]}`, `${V^^}`, `${P##*/}`, `${!ref}`) still needs the `''${` escape —
Nix's lexer rejects it at *parse* time, before any source read. A plain
`${VAR}` / `$VAR` is raw; see the README's "what's raw, what's constrained".

## `mkApps` — build shippable store binaries
Reads each block's `__lang` and dispatches to the matching builder; the result
is an attrset of `/nix/store/.../bin/<name>` executables. Attr names become
binary names, and bodies are source-read.

**`packages` is a global option** on the first attrset — it adds packages to
PATH for every app in the set. Language-specific options (`requirements`,
`compile`, `projectRoot`, …) are attached per-block by calling the block as a
function: `bash ''body'' { opts }` (no separate `app` wrapper):

```nix
with inputs.nixx.lib.for pkgs;
mkApps { packages = [ pkgs.rsync ]; } {
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
- `packages` belongs only to the **global first attrset** of `mkApps` /
  `writers.mkTasks`. Passing it per-block or per-task throws an error.
- the very same `bash ''body'' { opts }` call attaches **task** options in
  `mkTasks` (`deps` / `env` / `cwd` / `description` / `group`) — one idiom, both
  entry points. For a singleton binary, write a one-attr `mkApps`.
- low-level builders in `writers.nix`: `writeBashApplication`,
  `writeUvApplication`, `writeBunApplication`, `writeNodeApplication`,
  `writeTsxApplication`, `writeDenoApplication`.

## Composing apps + tasks
`mkApps` binaries and `mkTasks` runners compose: put app derivations in the
runner's `vars`, then call them from a task with `@nix(name)`.

```nix
with inputs.nixx.lib.for pkgs;
let
  apps = mkApps { } {
    status = bash ''echo "${USER} in ${PWD}"'';
    report = uv ''
      from rich import print
      print("[green]ok[/]")
    '' { requirements = [ "rich" ]; };
  };
  tasks = mkTasks { name = "tasks"; vars = apps; } {
    check = bash ''
      status="@nix(status)"
      report="@nix(report)"
      "$status/bin/status"
      "$report/bin/report"
    '';
  };
in { packages = apps // { default = tasks.runner; tasks = tasks.runner; }; }
```

## Dependencies: point at the project, don't redeclare them
Real projects already have a manifest (`pyproject.toml`+`uv.lock`,
`package.json`+lock). nixx **points at it** instead of restating deps, so
there's a single source of truth and no drift:

```nix
# preferred: deps come from the project's own manifest
with inputs.nixx.lib.for pkgs;
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
- `nixx.mkScript { lang?, vars?, shebang?, strict?, packages?, requirements?, pythonReq? } block`
  → just the script string (with shebang). A standalone block is *evaluated*, so
  a bare `${VAR}` needs `''${VAR}` (or build it through `mkScripts`, which
  source-reads).
- `nixx.mkScripts { lang?, vars? } { name = block; … }` → `{ scripts, meta }`;
  bodies are source-read (zero `${}` tax). `meta` feeds the linter remap.
- `nixx.shellHook { hook = bash ''…''; }` → just the source-read bash body
  string, for Nix APIs like `pkgs.mkShell.shellHook` that already want bash
  text and do not need a runner.

The pkgs-bound namespace (`with inputs.nixx.lib.for pkgs;`) also includes thin
wrappers for common bash-string APIs:

```nix
pkgs.mkShell {
  shellHook = shellHook {
    hook = bash ''
      echo ${HOME}
    '';
  };
}

runCommand "x" {} {
  build = bash ''
    echo ${HOME}
    mkdir -p $out
  '';
}

writeShellApplication {
  name = "hello";
  text = {
    main = bash ''
      echo ${HOME}
    '';
  };
}
```

## Dev shells — full wiring
Same `with inputs.nixx.lib.for pkgs;` and zero-`${}`-tax bodies; only the wiring
differs. The README shows the zero-config `tasks.devShell`; the other two idioms:

**`pkgs.mkShell` + `extendShell`** — you keep full control; `extendShell` folds the
runner into *your* shell. It **overrides** the shell you pass, so its bare env vars
and `shellHook` survive (it does not merely pull build inputs):
```nix
with inputs.nixx.lib.for pkgs;
let
  apps  = mkApps { packages = [ pkgs.jq ]; } { envcheck = bash ''jq --version''; };
  # nodejs is in mkTasks.packages because a TASK calls it — resolves via
  # `nix run .#tasks` AND at the prompt (single source of truth).
  tasks = mkTasks { name = "tasks"; packages = [ pkgs.nodejs ]; } {
    build = bash ''echo ${OUT_DIR:-dist}'';
  };
in {
  packages = apps // { default = tasks.runner; };
  devShells.default = tasks.extendShell (pkgs.mkShell {
    packages  = [ pkgs.jq pkgs.ripgrep ];   # prompt-only — no task calls these
    FOO       = "bar";                       # ← preserved (extendShell keeps it)
    shellHook = shellHook { hook = bash ''echo "hi ${USER}"''; };  # ← preserved
  });
}
```

**devenv** — devenv owns the environment, nixx owns the scripting; feed a body's
`.text` into `enterShell` / `scripts.<n>.exec` (Nix strings that would otherwise
pay the `${}` tax):
```nix
with inputs.nixx.lib.for pkgs;
let
  apps   = mkApps  { }                 { hello = bash ''echo "ready, ${USER}"''; };
  tasks  = mkTasks { name = "tasks"; } { fmt   = bash ''echo ${PWD}''; };
  bodies = mkTasks { }                 { enter = bash ''echo "ready, ${USER}"''; };
in {
  packages = apps // { default = tasks.runner; };
  devShells.default = devenv.lib.mkShell {  # + inherit inputs pkgs; — see examples/devenv
    modules = [{
      packages   = [ tasks.runner ];
      enterShell = bodies.tasks.enter.text;   # ${USER} stays raw
    }];
  };
}
```

**`shellHook` / `runCommand` wrappers** accept a reserved `vars` attr for
`@nix()` / `@sh:q()` interpolation. `runCommand` bodies are **shellcheck-gated by
default** (the lint runs as a build dependency, so a finding fails the build);
`$out`/`$src`-style build-env refs are excluded automatically — opt out per call
with `shellcheck = false`, or allow specific codes with
`excludeShellChecks = [ "SC2086" ]`:
```nix
with inputs.nixx.lib.for pkgs;
runCommand "x" {} {
  vars  = { url = "https://example.com"; };
  build = bash ''
    echo ${HOME}
    curl @sh:q(url)        # @sh:q() = shell-quoted Nix value; ${HOME} = raw shell
    mkdir -p $out
  '';
}
```

## Task runner — full reference
The README shows the concise version. `writers.mkTasks` (pkgs-bound) returns a
ready-to-use derivation plus devShell helpers:

```nix
with inputs.nixx.lib.for pkgs;
let
  tasks = mkTasks {
    name        = "tasks";
    defaultDeps = [ "nixenv" ];
    env         = { CI = "true"; };          # exported in every task
    packages    = [ pkgs.awscli2 ];          # global — on PATH for every task
  } {
    # runs before EVERY task → no more --extra-experimental-features … each time
    nixenv = sh ''export NIX_CONFIG="experimental-features = nix-command flakes"'';
    build  = sh ''nix build''      { description = "Build the project"; };
    test   = sh ''nix run .#test'' { description = "Run the test suite"; };
    deploy = sh ''aws s3 sync ...'' {
      description = "Deploy production";
      group       = "release";
      env         = { DEPLOY_ENV = "prod"; };  # merged with global; per-task wins on conflict
      cwd         = ./infra;
    };
    check  = sh ''
      echo ok
    '' { deps = [ "build" ]; };
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
  Global `packages` packages from opts are added to PATH for every task.
- **`devShell`** — `pkgs.mkShell { packages = [runner] ++ <opts.packages>; }` with a
  `shellHook` that registers bash tab-completion for all task names. The global
  `packages` are added alongside the runner so they're on the **prompt** PATH too
  (the runner's own `runtimeInputs` are wrapped and otherwise invisible there).
- **`extendShell`** — `shell: pkgs.mkShell { inputsFrom = [shell]; packages = [runner] ++ <opts.packages>; }`.
  Merges the runner (its completion hook, and the global `packages`) into an existing shell.
- **`tasks`** / **`meta`** — same as the pure `nixx.mkTasks` result.

The pure `nixx.mkTasks` (no pkgs) is still available if you only need the runner
script text or a body's `.text`:

```nix
(inputs.nixx.lib.mkTasks { name = "tasks"; } { … }).runner          # → bash script string
(inputs.nixx.lib.mkTasks { } { hook = inputs.nixx.lib.bash ''…''; }).tasks.hook.text  # → one body, source-read
```

#### `writers.mkTasks` options

| option | default | description |
|---|---|---|
| `name` | `"tasks"` | name embedded in runner comments |
| `packages` | `[]` | packages whose `/bin` join `PATH` for **every** task in the runner — baked into the runner's `runtimeInputs` (so `nix run .#tasks` and `tasks` in a shell resolve them identically) **and** re-exposed on the `devShell`/`extendShell` prompt. Put anything a task body calls here, never only in `pkgs.mkShell` — see README "what goes where" |
| `vars` | `{}` | Nix values interpolated via `@nix(…)` / `@sh:q(…)` markers |
| `env` | `{}` | attrset exported as shell env vars in **every** task; per-task `env` overrides on conflict |
| `defaultDeps` | `[]` | task names prepended to every task's deps; the default-dep tasks themselves are exempt |

#### per-task options (attached as `sh ''body'' { … }`)

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

**Positional args** (`tasks <name> a b c`) are forwarded to all task bodies.
Bash bodies receive them as `$@` / `$1`, `$2`, … (the normal positional
parameters, via `shift; task_<name> "$@"`). Non-bash bodies that read from
stdin via a `-` flag also receive the same args through the interpreter's
argv (`sys.argv[1:]` in Python, `@ARGV` in Perl, `ARGV` in Ruby, `Deno.args`
in Deno, `process.argv` in Bun). Node (`--input-type=module`) and TypeScript
(`tsx`) do not currently receive positional args; pass data to those via `env`.

## `envCheck` — runtime env-check (the `mkTasks` sibling of `shellint`)
`envCheck` is a `mkTasks` option that, **before a task body runs**, parses it with
tree-sitter and **aborts** if a *required* env var is unset or empty. It is the
runtime counterpart to `shellint`'s static `env` pass: `shellint` reports what a
block needs; `envCheck` enforces it at run time, where the actual environment is
known.

```nix
with inputs.nixx.lib.for pkgs;
mkTasks { name = "tasks"; envCheck = true; } {   # global default for every bash task
  build  = bash ''cp -r ./src "${OUT_DIR}/build"'';         # inherits global (always)
  deploy = bash ''aws s3 sync ./dist "s3://${BUCKET}"''
           { envCheck = false; };                           # only with --env-check
}
# tasks build              → always checks; aborts if OUT_DIR unset/empty
# tasks deploy             → checks only when --env-check is passed
# tasks --env-check deploy → checks and aborts if BUCKET unset/empty
# tasks --env-list deploy  → just prints the env deploy needs (set/unset/empty), runs nothing
```

`envCheck` is `false` by default (check only when the runner gets `--env-check`),
or `true` to always check; a per-block value overrides the global default.
`--env-list <task>` is the non-blocking companion — it prints exactly the env a
task needs (with each var's live status) and exits without running deps or the
body. It is **always available** (even with no task enabling `envCheck`), so
`tree-sitter` ships in every runner.

**What counts as "required"** — a free-variable analysis, not a grep. A var is
required only if the block references it *bare* and never binds it itself:

| in the body | treated as | why |
|---|---|---|
| `$VAR` / `${VAR}` | **required** (set & non-empty) | a bare reference is an external dependency |
| `${VAR:?msg}` / `${VAR?msg}` | **required** ( `:?` also rejects empty ) | the author declared it mandatory |
| `${VAR:-x}` `${VAR:=x}` `${VAR:+x}` `${VAR-x}` | skipped | a default handles the missing case — also the **opt-out**: `${VAR:-}` allows empty |
| `${#VAR}` `${!VAR}` `${VAR#p}` `${VAR%p}` … | skipped | length / indirection / transforms, not a plain dependency |
| `${A:-$B}` (nested) | neither A nor B | `B` is only the fallback value |
| `VAR=…`, `export VAR`, `for VAR in …`, `read VAR` | skipped | the block assigns it, so it isn't external |

Because bare references to external env are intentional under `envCheck`, enabling
it also tells `shellcheck` to stop flagging them (`SC2154` / `SC2153`) for that
runner.

## Interpolation (`vars`)
To splice an actual **Nix** value into a (source-read) body, use a marker —
native Nix `${…}` does not run there. There are exactly two:

- `@nix(name)` → raw value (for paths / derivations / numbers)
- `@sh:q(name)` → bash shell-quoted string literal (for arbitrary strings)
- a **path** value (`./util.py`, `./libdir`) is auto-imported to the store
  (reproducible; exec bit preserved)

To pass a value into a **non-bash** body, use `env` instead of a marker.

```nix
with inputs.nixx.lib.for pkgs;
mkTasks { vars = { port = 3000; tool = ./bin/tool; }; } {
  serve = bash ''
    @nix(tool) --listen ${HOST:-0.0.0.0}:@nix(port)   # ${HOST} raw shell; @nix() = Nix value
  '';
}
```

## `shellint` — full reference
`shellint` is **source-driven**: it reads `.nix` files with tree-sitter-nix (no
eval — so a parse error in one file doesn't stop it), locates every nixx block
(`bash`/`sh`/… constructor applied to an `''…''` body), and runs three
block-scoped passes. Plain Nix `''…''` strings that aren't nixx blocks are
ignored.

| pass | severity | what it does |
|---|---|---|
| **nix-boundary** | fatal | shell-only expansions that break Nix (`${#x}` `${x[@]}` `${x^^}` `${x%p}` …) must be `''${…}`; a bare `${VAR}` with no enclosing `with` will fail Nix eval. Escaped `''${…}`, `with`-scoped `${VAR}`, and real Nix interpolations (`${pkgs.hello}`) are skipped. tree-sitter-nix ERROR nodes localise the breakage even through parse cascades |
| **shellcheck** | fatal | the bash body (wrapped in a function, so `local`/`return` are valid) is shellcheck'd. `$out`/`$src`-style build-env refs (`SC2154` / `SC2153`) are excluded by default; more via `excludeShellChecks` |
| **env** | warn | lists the external env each block requires (block-bound names subtracted), reusing the `envCheck` classifier; never fatal |

Findings print as `file:line:col [pass] severity message`; a fatal makes the run
exit nonzero (and the `check` derivation fail).

```sh
nix run nixx#shellint -- ./                       # lint a tree (default: cwd)
nix run nixx#shellint -- --no-shellcheck a.nix b.nix
nix run nixx#shellint -- --exclude=SC2086 src/    # add a shellcheck exclusion
nix run nixx#shellint -- --fix ./                 # auto-fix the nix-boundary
nix run nixx#shellint -- --fix --dry-run ./       # preview fixes as a diff
```

### `--fix` — bidirectional boundary normalizer
`--fix` rewrites only the **nix-boundary** finding, both ways:
- **escape** a shell-only expansion that breaks Nix → `${#x}` `${x[@]}` `${x^^}`
  `${x%p}` `${x#p}` become `''${…}`; a bare `${VAR}` with no `with` becomes `''${VAR}`.
- **de-escape** an over-escaped `''${VAR}` / `''${VAR:-d}` / `''$VAR` back to the bare
  form — but **only inside a `with`** (otherwise the bare form would fail Nix eval),
  and only for forms that are valid zero-prefix (parse-wall escapes are left alone).

It edits files in place (`--dry-run` prints a diff instead). Each file is
**re-parsed after editing and reverted if any tree-sitter ERROR remains**, so a
mis-fix can never corrupt a file — worst case it's reported as "could not auto-fix
safely (reverted)". `--fix` lives on the `nix run` app only; the `shellint` flake
check stays read-only. The fix is idempotent (a second run is a no-op). Even a
`#`-cascade (where the `#` comments out the closing `''` and the Nix parse derails)
is fixed via a raw-text scan, since the bytes — `}` and `''` included — are intact.
```nix
# as a flake check (gates `nix flake check`)
checks.shellint = (inputs.nixx.lib.for pkgs).shellint {
  src                = ./.;
  exclude            = [ "*/vendor/*" ];        # find(1) path globs to skip
  passes             = { nix = true; shellcheck = true; envcheck = false; };
  excludeShellChecks = [ "SC2086" ];
};
```

The engine ships in every `mkTasks` runner too (that's why `tree-sitter` is always
a runtime input), and is exposed standalone as the `nixx#shellint` app. See
`envCheck` above for the runtime sibling.

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
nix run .#status      # bash   (mkApps + packages)
nix run .#report      # python (uv, deps from ./py via projectRoot)
nix run .#validate    # ts     (bun --compile, deps from ./ts)
nix run .#tasks -- check   # mkTasks runner: report + validate (just-style deps)
```

## Status — proven end-to-end in a real Nix
1. ✅ shellcheck / ruff / bun build gates (bad code fails the build)
2. ✅ dependency injection: bash packages, uv PEP 723, bun auto-import, node_modules
3. ✅ `@nix(./path)` local-file store import (files + dirs, exec bit kept)
4. ✅ linter diagnostics remapped to exact `.nix` line:col
5. ✅ multi-language via constructors (bash/python/uv/bun/ts/node/deno/perl)
6. ✅ `bun --compile` → self-contained store binary
7. ✅ `mkApps` dispatcher + one runnable app per language in
   `examples/simple01`
8. ✅ source-read `${}`-tax-free task/script bodies (175+ unit tests)
9. ✅ `shellint` — source-driven static lint (nix-boundary + shellcheck + env)
   over real `.nix`, with `envCheck`/`--env-list` as the runtime sibling
