# nixx — Write real shell, JavaScript, Python, and TypeScript inside Nix — without escaping ${}.

[![release](https://img.shields.io/github/v/release/nnao45/nixx?logo=github&label=release&color=5277C3)](https://github.com/nnao45/nixx/releases/latest)
[![nix flake check](https://github.com/nnao45/nixx/actions/workflows/nix-version-compat.yml/badge.svg)](https://github.com/nnao45/nixx/actions/workflows/nix-version-compat.yml)
[![Nix ≥ 2.18](https://img.shields.io/badge/nix-%E2%89%A52.18-5277C3?logo=nixos)](https://nixos.org/download/)

One `with`, and a `${VAR}` in a script body is the **shell's**, not Nix's —
read from source, never escaped. No preprocessor, no codegen; files stay valid
`.nix`, so nil/nixd never error.

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

`nix run .#deploy` ships a `/nix/store/.../bin/deploy`. Swap `mkApps` for
`mkTasks` when you want a tab-completed `tasks build` / `tasks check` workflow.

**Add to your flake:**
```nix
inputs.nixx.url = "github:nnao45/nixx";
# then, in a per-system output with `pkgs` in scope:
#   { packages = with inputs.nixx.lib.for pkgs; mkApps { } { hello = bash ''echo hi''; }; }
```

> Also speaks python (uv), typescript (bun/tsx), node, deno, perl, ruby, lua —
> and bundles dev workflows with `mkTasks`. Full reference, dependency wiring,
> and option tables in **[API.md](./API.md)**.

## `${}` — what's raw, what's constrained
Every body passed as an attr value to `mkApps`, `mkTasks`, or `mkScripts` is
read **from source** instead of evaluated, so a `${VAR}` in the `${}` family —
shell `${HOME}`, a JS template `` `${x}` ``, a perl `${name}` — survives
verbatim with **no `''` prefix**. The one line of ceremony is the `with`
(`inputs.nixx.lib.for pkgs` — the one canonical entry point): any
`with` makes the scope dynamic, which defers Nix's static undefined-variable
check to a runtime that never arrives (the body is never forced). To splice in
an actual **Nix** value, use the `@nix(x)` / `@sh:q(x)` markers — native Nix
`${…}` does not run in a source-read body, by design: `${}` belongs to the
language.

The common shell forms work with zero prefix; a few aren't valid Nix inside
`${…}`, so Nix rejects them at *parse* time (before any source read) and they
still need the `''` — which the scanner replays back to a literal `$`:

| form | zero prefix? | example |
|---|---|---|
| `${VAR}`, `$VAR`, `$@`, `$?` | ✅ | `echo ${HOME}` |
| `${VAR:-d}` `${VAR:-}` `${VAR:=d}` `${VAR:?e}` `${VAR:+x}` | ✅ | `echo ${EDITOR:-vi}` |
| `${VAR:off:len}` (substring) | ✅ | `echo ${name:0:3}` |
| `${!ref}` (indirect) `${ARR[0]}` (numeric index) | ✅ | `echo ${!chosen}` |
| `${VAR/old/new}` `${VAR//o/n}` (operands are identifier-only) | ✅ | `echo ${PATH//bin/BIN}` |
| `${ARR[@]}` `${ARR[*]}` `${#VAR}` `${VAR%x}` `${VAR#x}` `${VAR^^}` `${VAR,,}` `${ARR[-1]}` | ❌ use `''` | `for x in ''${ARR[@]}; do …` |
| `${VAR/o/n}` whose old/new carries `, ; # %` etc. | ❌ use `''` | `''${csv/,/;}` |

Rule of thumb: anything lexically valid as a Nix expression inside `${…}`
(the `:` / `:off:len` / `!` / `[n]` / identifier-only `/` families) survives
**raw**; a token Nix can't lex (`@ * # % ^`, a negative index, or a symbol in
a substitution operand) hits the *parse* wall first and needs `''`. 

Still strictly better than a plain evaluated `''…''`, which needs `''` on
*everything*. (Mechanism — lazy thunks, `unsafeGetAttrPos`, the literal-vs-
programmatic guard — in [API.md](./API.md).)

**Trade-off.** Any `with` defers undefined-variable checking, so a typo in
*never-evaluated* code under its scope won't be caught statically. Keep the
`with` on the flake output that builds your tasks; evaluated code still errors
clearly at runtime.

## Per-block options
Call a block like a function with an attrset of options. This **one idiom**
covers both `mkApps` (language opts like `compile`) and `mkTasks` (task opts
like `deps` / `env` / `cwd`) — there is no separate `app` / `task` wrapper:

```nix
with inputs.nixx.lib.for pkgs;
mkApps { packages = [ pkgs.curl pkgs.jq ]; } {   # ← packages is global (whole set)
  fetch = bash ''
    curl -s https://api.example.com | jq .
  '';                                            # ← no opts needed

  report = uv ''
    from rich import print
    print("[green]ok[/]")
  '' { requirements = [ "rich>=13" ]; };          # ← per-block

  check = bun ''
    const r: { ok: boolean } = { ok: true };
    console.log(`status: ${r.ok}`);
  '' { compile = true; };                         # ← per-block
}
```

One rule: **`packages` is global** (first attrset of `mkApps` / `mkTasks`); the
language options are **per-block**. Passing `packages` per-block or per-task
throws, on purpose.

| option | level | what it does |
|---|---|---|
| `packages` | **global** — `mkApps { }` / `mkTasks { }` first attrset | `/bin` on PATH for **every** app/task |
| `requirements` | per-block (uv) | PEP 723 inline deps |
| `compile` | per-block (bun) | `bun --compile` → standalone binary |
| `projectRoot` | per-block (uv/bun) | deps from `./pyproject.toml` / `package.json` |
| `envCheck` | **global** (`mkTasks { }`) **or** per-block (bash tasks) | before running, parse the task body with tree-sitter and report unset / empty env vars; if any ERROR is found, **abort** the task. `false` (default) = check only with `--env-check`, `true` = always check |

`envCheck` can be set globally as the default for every bash task, then overridden
per-block. `--env-check` passed to the runner runs the check on **all** bash blocks,
regardless of per-task settings:

```nix
with inputs.nixx.lib.for pkgs;
mkTasks { name = "tasks"; envCheck = true; } {   # ← always check every bash task

  build = bash ''
    cp -r ./src "${OUT_DIR}/build"
  '';                                             # ← inherits global (always)

  deploy = bash ''
    aws s3 sync ./dist "s3://${BUCKET}"
  '' { envCheck = false; };                       # ← only with --env-check
}
# tasks build              → always checks; aborts if OUT_DIR unset/empty
# tasks deploy             → checks only when --env-check is passed
# tasks --env-check deploy → checks and aborts if BUCKET unset/empty
```

The check is **blocking** — if any referenced variable is unset or empty, the task
aborts with an error before the body runs. `tree-sitter` is added to `runtimeInputs`
automatically whenever any task opts in to `envCheck = true`.

The same call form attaches task options in `mkTasks`
(`bash ''…'' { deps = [ … ]; env = { … }; cwd = ./d; }`). Everything else (full
option matrix, `mkScript(s)`, `vars` markers) is in **[API.md](./API.md)**.

## Apps and shells
`mkApps` builds store binaries; `mkTasks` builds a just-style runner. They
compose — app derivations go in the runner's `vars`, tasks call them with
`@nix(name)`. Wired example in **[API.md](./API.md)**.

## devShell / devenv / mkShell — pick your idiom
Same `with inputs.nixx.lib.for pkgs;`, same zero-`${}`-tax bodies; only the wiring
differs. Runnable flakes in `examples/`.

**`devShells.default`** (`examples/devshell`) — zero-config; the runner lands on
PATH, tab-completed:
```nix
with inputs.nixx.lib.for pkgs;
let
  apps  = mkApps { } { whereami = bash ''echo ${PWD} as ${USER}''; };
  tasks = mkTasks { name = "tasks"; } { info = bash ''echo ${PWD} as ${USER}''; };
in {
  packages = apps // { default = tasks.runner; tasks = tasks.runner; };
  devShells.default = tasks.devShell;
}
```

**`pkgs.mkShell`** (`examples/mkshell`) — you keep full control; `extendShell`
folds the runner into *your* shell:
```nix
with inputs.nixx.lib.for pkgs;
let
  apps  = mkApps { packages = [ pkgs.jq ]; } { envcheck = bash ''jq --version''; };
  # nodejs is in mkTasks.packages because a TASK calls it — resolves via
  # `nix run .#tasks` AND at the prompt (single source of truth; see API.md).
  tasks = mkTasks { name = "tasks"; packages = [ pkgs.nodejs ]; } {
    build = bash ''echo ${OUT_DIR:-dist}'';
  };
in {
  packages = apps // { default = tasks.runner; };
  devShells.default = tasks.extendShell (pkgs.mkShell {
    packages = [ pkgs.jq pkgs.ripgrep ];   # prompt-only — no task calls these
    # even the hook is ${}-tax-free:
    shellHook = shellHook {
      hook = bash ''
        echo "hi ${USER}"
      '';
    };
  });
}
```

For Nix APIs that want a raw bash string directly, use the thin wrappers:

```nix
with inputs.nixx.lib.for pkgs;

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
```

**devenv** (`examples/devenv`) — devenv owns the environment, nixx owns the
scripting; feed body `.text` into `enterShell` / `scripts.<n>.exec` (Nix strings
that would otherwise pay the `${}` tax):
```nix
with inputs.nixx.lib.for pkgs;
let
  apps   = mkApps { } { hello = bash ''echo "ready, ${USER}"''; };
  tasks  = mkTasks { name = "tasks"; } { fmt = bash ''echo ${PWD}''; };
  bodies = mkTasks { } { enter = bash ''echo "ready, ${USER}"''; };
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

`packages` is global on `mkTasks` — same rule as `mkApps` (see
[Per-block options](#per-block-options)). **One trap:** if a task calls a tool, put
it in `mkTasks { packages }`, never only in `mkShell` — a `mkShell`-only package
is absent from `nix run .#tasks`, so the task works under `nix develop` but
breaks as a shipped binary. Full options and `env`/`deps` semantics in
**[API.md](./API.md)**.

## More
- **Docs site**: [nnao45.github.io/nixx](https://nnao45.github.io/nixx) — browsable reference with examples.
- **LLM-friendly plain-text**: [nnao45.github.io/nixx/llms.txt](https://nnao45.github.io/nixx/llms.txt)
- **Multi-language & shippable binaries**, `mkScript(s)`, `vars` markers
  (`@nix`, `@sh:q`), the full language/option tables: **[API.md](./API.md)**.
- **Linter source-mapping** — blocks carry their source position, so shellcheck
  / ruff diagnostics remap back to the exact `.nix` `line:col`, even under nested
  indentation. Details in [API.md](./API.md).
