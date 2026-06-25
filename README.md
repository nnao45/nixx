# nixx — raw shell in Nix: escape-light *and* statically checked.

[![release](https://img.shields.io/github/v/release/nnao45/nixx?logo=github&label=release&color=5277C3)](https://github.com/nnao45/nixx/releases/latest)
[![nix flake check](https://github.com/nnao45/nixx/actions/workflows/nix-version-compat.yml/badge.svg)](https://github.com/nnao45/nixx/actions/workflows/nix-version-compat.yml)
[![Nix ≥ 2.18](https://img.shields.io/badge/nix-%E2%89%A52.18-5277C3?logo=nixos)](https://nixos.org/download/)

nixx stands on **two pillars that need each other**:

1. **Escape-light.** One `with`, and a `${VAR}` in a script body is the
   **shell's**, not Nix's — read from source, never escaped. No preprocessor, no
   codegen; files stay valid `.nix`, so nil/nixd never error.
2. **Statically checked.** That raw embedded shell would otherwise be opaque to
   your tools. `shellint` reads it back — running shellcheck on the body **and**
   guarding the one boundary the escape-light path leaves behind: the few `${…}`
   forms that *do* still need an `''` escape, and bare `${VAR}` that needs a
   `with`. Skip the escaping; let shellint point at whatever you missed.

```nix
{
  packages = with inputs.nixx.lib.for pkgs; mkApps { packages = [ pkgs.rsync ]; } {
    deploy = bash ''
      echo "deploying from ${HOME}"          # ${} is shell's — no ''${ } escape
      rsync -a ./dist/ "$HOST:/srv/"
    '';
  };
}
```
```sh
nix run .#deploy            # ships a /nix/store/.../bin/deploy
nix run nixx#shellint -- .  # lint the embedded shell: boundary + shellcheck + env
```

Swap `mkApps` for `mkTasks` when you want a tab-completed `tasks build` /
`tasks check` workflow.

**Add to your flake:**
```nix
inputs.nixx.url = "github:nnao45/nixx";
# then, in a per-system output with `pkgs` in scope:
#   { packages = with inputs.nixx.lib.for pkgs; mkApps { } { hello = bash ''echo hi''; }; }
```

> Also speaks python (uv), typescript (bun/tsx), node, deno, perl, ruby, lua —
> bundles dev workflows with `mkTasks`, and runs those same bodies as **hermetic
> sandbox tests** with `mkTests` (below). Full reference, dependency wiring, and
> every option table in **[API.md](./API.md)**.

## Pillar 1 — `${}` belongs to the language
Every body passed as an attr value to `mkApps`, `mkTasks`, or `mkScripts` is read
**from source** instead of evaluated, so a `${VAR}` in the `${}` family — shell
`${HOME}`, a JS template `` `${x}` ``, a perl `${name}` — survives verbatim with
**no `''` prefix**. The one line of ceremony is the `with`
(`inputs.nixx.lib.for pkgs` — the canonical entry point): any `with` makes the
scope dynamic, deferring Nix's static undefined-variable check to a runtime that
never arrives (the body is never forced). To splice in an actual **Nix** value,
use the `@nix(x)` / `@sh:q(x)` markers — native Nix `${…}` does not run in a
source-read body, by design: `${}` belongs to the language.

The common shell forms work with zero prefix. A few aren't valid Nix inside
`${…}`, so Nix rejects them at *parse* time and they still need the `''`:

| form | zero prefix? | example |
|---|---|---|
| `${VAR}`, `$VAR`, `$@`, `$?` | ✅ | `echo ${HOME}` |
| `${VAR:-d}` `${VAR:-}` `${VAR:=d}` `${VAR:?e}` `${VAR:+x}` | ✅ | `echo ${EDITOR:-vi}` |
| `${VAR:off:len}` (substring) | ✅ | `echo ${name:0:3}` |
| `${!ref}` (indirect) `${ARR[0]}` (numeric index) | ✅ | `echo ${!chosen}` |
| `${VAR/old/new}` (operands identifier-only) | ✅ | `echo ${PATH//bin/BIN}` |
| `${ARR[@]}` `${#VAR}` `${VAR%x}` `${VAR#x}` `${VAR^^}` `${VAR,,}` `${ARR[-1]}` | ❌ use `''` | `for x in ''${ARR[@]}; do …` |
| `${VAR/o/n}` whose operand carries `, ; # %` etc. | ❌ use `''` | `''${csv/,/;}` |

The escape-light path is **partial by design** — and that's exactly the gap
Pillar 2 closes: **forget an `''` on a ❌ row, or write a bare `${VAR}` with no
`with`, and `shellint` points at the precise `file:line`** instead of leaving you
a cryptic Nix parse error. (Mechanism — lazy thunks, `unsafeGetAttrPos`, the
parse-wall rule — in [API.md](./API.md).)

> **Trade-off.** Any `with` defers undefined-variable checking, so a typo in
> *never-evaluated* code under its scope won't be caught statically — which is
> the other reason `shellint` exists. Keep the `with` on the flake output that
> builds your tasks; evaluated code still errors clearly at runtime.

## Pillar 2 — `shellint`: check the embedded shell
`shellint` is a **source-driven** linter (no eval): it parses your `.nix` files
with tree-sitter-nix, finds every `bash ''…''` block, and runs three passes that
a generic Nix linter can't — because only nixx knows the string is shell:

- **nix-boundary** (fatal) — the warden of Pillar 1's gap. A shell-only
  expansion that breaks Nix (`${#x}`, `${x[@]}`, `${x^^}` …) needs `''${…}`; a
  bare `${VAR}` with no enclosing `with` will fail Nix eval. Escaped `''${…}`,
  `with`-scoped `${VAR}`, and real Nix interpolations (`${pkgs.hello}`) are left
  alone. tree-sitter-nix pinpoints the breakage even through parse cascades.
- **shellcheck** (fatal) — the bash body is shellcheck'd (`$out`/`$src`-style
  build-env refs excluded; add codes with `excludeShellChecks`).
- **env** (warn) — lists the external env each block requires (block-bound names
  subtracted).

```sh
nix run nixx#shellint -- ./           # lint a tree (or files)
nix run nixx#shellint -- --fix ./     # auto-fix the boundary: add/remove '' as needed
nix run nixx#shellint -- --fix --dry-run ./   # preview the fixes as a diff
```

`--fix` is the bidirectional normalizer for the boundary: it **escapes** a
shell-only `${…}` that needs it (`${#x}` → `''${#x}`) and **de-escapes** an `''${VAR}`
that doesn't (back to `${VAR}`, only under a `with`). Each fixed file is re-parsed
afterward and reverted if it isn't clean — so a fix can never leave you worse off.
```nix
# gate it in your own flake
checks.shellint = (inputs.nixx.lib.for pkgs).shellint {
  src = ./.;
  exclude = [ "*/vendor/*" ];
  passes = { envcheck = false; };     # toggle individual passes
};
```

Full pass semantics, config, and the runtime sibling `envCheck` (a `mkTasks`
option that blocks a task when a required env var is unset) are in
**[API.md](./API.md)**.

## Per-block options
Call a block like a function with an attrset of options. This **one idiom**
covers both `mkApps` (language opts like `compile`) and `mkTasks` (task opts like
`deps` / `env` / `cwd`) — there is no separate `app` / `task` wrapper:

```nix
with inputs.nixx.lib.for pkgs;
mkApps { packages = [ pkgs.curl pkgs.jq ]; } {   # ← packages is global (whole set)
  fetch  = bash ''curl -s https://api.example.com | jq .'';   # ← no opts needed
  report = uv ''
    from rich import print
    print("[green]ok[/]")
  '' { requirements = [ "rich>=13" ]; };          # ← per-block
  check  = bun ''
    const r: { ok: boolean } = { ok: true };
    console.log(`status: ${r.ok}`);
  '' { compile = true; };                         # ← per-block
}
```

One rule: **`packages` is global** (first attrset of `mkApps` / `mkTasks`); the
language options are **per-block**. Passing `packages` per-block throws, on purpose.

| option | level | what it does |
|---|---|---|
| `packages` | **global** | `/bin` on PATH for **every** app/task |
| `inputsFrom` | **global** (`mkTasks`) | other derivations' setup hooks + build inputs in the dev shell (tools that need a stdenv hook, not just a binary) |
| `requirements` | per-block (uv) | PEP 723 inline deps |
| `compile` | per-block (bun) | `bun --compile` → standalone binary |
| `projectRoot` | per-block (uv/bun) | deps from `./pyproject.toml` / `package.json` |
| `envCheck` | **global** or per-block (bash) | block a task when a *required* env var is unset/empty; `--env-list <task>` just prints what it needs. Full semantics → [API.md](./API.md) |

The same call form attaches task options in `mkTasks`
(`bash ''…'' { deps = [ … ]; env = { … }; cwd = ./d; }`). Full option matrix,
`mkScript(s)`, and `vars` markers are in **[API.md](./API.md)**.

## Task runner
`mkTasks` is a `just`-style runner: one `tasks <name>` is a **single bash
process**, so an `export` (or `defaultDeps`/`env`) in an early task persists into
every later one. **Only env crosses task boundaries** — cwd and shell options
reset at each task's entry (every bash task is `set -euo pipefail`; a dep's `cd`
or `set +u` can't leak), so tasks stay predictable. Supports `deps`, `group`,
per-task `cwd` / `env`.

```
$ tasks --list
  build    Build the project
  test     Run the test suite

release:
  deploy   Deploy production

$ tasks build      # or: nix run .#tasks -- build
```

**One trap:** if a task calls a tool, put it in `mkTasks { packages }`, never only
in `mkShell` — a `mkShell`-only package is absent from `nix run .#tasks`. Full
`env`/`deps` semantics and the `writers.mkTasks` return value (`runner` /
`devShell` / `extendShell`) in **[API.md](./API.md)**.

## Hermetic tests — `mkTests`
`mkTests` runs each test in the **Nix build sandbox**: no `$HOME`, no network, and
PATH limited to the suite's declared `packages`. A green run isn't "passed on my
machine" — it's "passed with *only* what was declared, offline, against a freshly
minted `$HOME`." A hidden `curl`, a stray `~/.aws/credentials` read, or an
undeclared `jq` can't sneak a pass: the sandbox withholds them and the test fails
the instant it reaches for one. That guarantee is what a host-resident runner like
bats can't give you.

Bodies are the usual source-read `bash ''…''` (escape-light, shellcheck'd), with a
**bats-compatible** vocabulary so existing muscle memory transfers — over a
per-test writable `$WORK` the harness mints and tears down:

```nix
with inputs.nixx.lib.for pkgs;
{
  # one mkTests call = one suite = one named check
  checks.${system}.tools = mkTests { name = "tools"; packages = [ pkgs.jq ]; } {
    setup = bash ''mkdir -p "$WORK/out"'';            # lifecycle hook, not a test

    "jq extracts fields" = bash ''
      run jq -n '{ port: 8080 }'                      # run captures $status/$output
      assert_success
      assert_json '.port' '8080'
    '';

    "writes into the per-test $WORK" = bash ''
      printf 'ok' > "$WORK/out/marker"
      assert_file "$WORK/out/marker"
      assert_file_contains "$WORK/out/marker" ok
    '';
  };
}
```

`run` captures `$status` / `$output` / `$stderr` (bats style); `assert_success`,
`assert_failure`, `assert_output [--partial|--regexp]`, `refute_output`, and
`assert_equal` are joined by nixx extras `assert_file`, `assert_dir`,
`assert_file_contains`, and `assert_json`. `setup` / `teardown` / `setup_suite` /
`teardown_suite` are lifecycle hooks. The code under test is reached by name if
it's a nixx app, or via `src = ./.;` (mounted read-only as `$FIXTURES`).

**Two lanes from one definition:**

| lane | how | when |
|---|---|---|
| **hermetic** | the returned derivation → `checks.<system>`; `nix flake check` builds it in the sandbox | CI, pre-commit — the source of truth |
| **fast** | `.fast` — a devShell-lane runnable, no sandbox, instant | the carve-carve TDD loop |

**`nixx test`** discovers `*_test.nix` and drives both lanes:

```sh
nixx test                     # fast lane: every *_test.nix under .
nixx test -f deploy           # only tests whose name contains "deploy"
nixx test --hermetic          # run each suite in the sandbox
nix flake check               # the hermetic suites, as checks
```

When a hermetic test goes red, **`--repro`** drops you into that test's *exact*
environment — same `$WORK`, same PATH, `setup` already run, every `run`/`assert_*`
helper loaded — as an interactive shell; type `t` to re-run the body and watch the
assertion fail live:

```sh
nixx test path/to/x_test.nix --repro "jq extracts fields"
#   cwd is $WORK (writable) · helpers loaded · `t` runs the body · Ctrl-D leaves
```

`--once` reads stdin one-shot instead of opening a prompt, so the repro path is
scriptable and CI-able.

> **Eating its own shell.** The assert runtime and `nixx test` CLI are written as
> source-read `bash ''…''` inside nixx itself — no external `.sh`. Runnable suites
> live in `tests/*_test.nix`; the full option/assert reference is in
> **[API.md](./API.md)**.

## Process groups with process-compose
Use `processCompose` when the workflow is several long-running processes instead
of a dependency-ordered task list. It turns nixx bash blocks into a
`process-compose` config with readiness gates, `depends_on`, restart policy, and
graceful shutdown:

```nix
with inputs.nixx.lib.for pkgs;
let
  pc = processCompose {
    name = "dev";
    vars = { port = 3000; };
    "no-server" = true;
  } {
    web = bash ''
      echo "web on @nix(port), home=${HOME}"
      sleep 30
    '' { readiness = { exec = "true"; initial_delay_seconds = 2; }; };

    api = bash ''
      echo "api after web"
      sleep 30
    '' { depends_on = [ "web" ]; restart = "on_failure"; };
  };
in {
  packages.default = pc.runner;       # nix run .#default
}
```

Per-process options use the same `bash ''...'' { ... }` call form as tasks:
`cwd`, `env`, `depends_on`, `readiness`, `restart`, `description`, `namespace`,
and `shutdown`. `pc.config`, `pc.configJson`, and `pc.configFile` expose the
generated process-compose config for inspection or reuse. Runner options also
expose process-compose global flags like `"no-server"`, `"use-uds"`, and `port`.
Full mapping and return values are in **[API.md](./API.md)**; the runnable
example is `examples/process-compose`.

## Dev shells — pick your idiom
Same `with inputs.nixx.lib.for pkgs;`, same zero-`${}`-tax bodies; only the wiring
differs. The zero-config path lands the runner on PATH, tab-completed:

```nix
with inputs.nixx.lib.for pkgs;
let
  apps  = mkApps  { }                 { whereami = bash ''echo ${PWD} as ${USER}''; };
  tasks = mkTasks { name = "tasks"; } { info     = bash ''echo ${PWD} as ${USER}''; };
in {
  packages = apps // { default = tasks.runner; tasks = tasks.runner; };
  devShells.default = tasks.devShell;
}
```

`tasks.extendShell` folds the runner into your own `pkgs.mkShell` (preserving its
env + shellHook); `shellHook` / `runCommand` wrappers give the same `${}`-tax-free
bodies to plain Nix APIs; and devenv is supported by feeding a body's `.text` into
`enterShell`. Runnable flakes for all three live in `examples/`; the wiring is
documented in **[API.md](./API.md)**.

## More
- **Docs site**: [nnao45.github.io/nixx](https://nnao45.github.io/nixx) — browsable reference with examples.
- **LLM-friendly plain-text**: [nnao45.github.io/nixx/llms.txt](https://nnao45.github.io/nixx/llms.txt)
- **Multi-language & shippable binaries**, `mkScript(s)`, `vars` markers
  (`@nix`, `@sh:q`), full language/option tables, `shellint` & `envCheck`
  reference, `processCompose`, and the linter source-mapping:
  **[API.md](./API.md)**.
