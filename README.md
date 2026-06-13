# nixx — Write real shell, JavaScript, Python, and TypeScript inside Nix — without escaping ${}.

One `with`, and a `${VAR}` in a script body is the **shell's**, not Nix's —
read from source, never escaped. No preprocessor, no codegen; files stay valid
`.nix`, so nil/nixd never error.

```nix
{
  packages = with nixx.for pkgs; mkApps { } {
    deploy = bash { runtimeInputs = [ pkgs.rsync ]; } ''
      echo "deploying from ${HOME}"       # ${} is shell's — no ''${ } escape
      rsync -a ./dist/ "$HOST:/srv/"
    '';
    report = uv { deps = [ "rich" ]; } ''
      from rich import print
      print("[bold green]done[/]")
    '';
    validate = bun { compile = true; } ''
      const ok: boolean = true;
      console.log(`status: ${ok}`);       # TS template literal, verbatim
    '';
  };
}
```

`nix run .#deploy`, and you have a shippable `/nix/store/.../bin/deploy`.
Use `mkTasks` when you want a tab-completed `tasks build` / `tasks check`
workflow.

**Add to your flake:**
```nix
inputs.nixx.url = "github:nnao45/nixx";
# in a per-system output, with `pkgs` in scope:
#   { packages = with inputs.nixx.for pkgs; mkApps { } { hello = bash ''…''; }; }
```

> Also speaks python (uv), typescript (bun/tsx), node, deno, perl, ruby, lua —
> and bundles dev workflows with `mkTasks`. Full reference,
> dependency wiring, and option tables in **[API.md](./API.md)**.

## `${}` — what's raw, what's constrained
Every body passed as an attr value to `mkApps`, `mkTasks`, or `mkScripts` is
read **from source** instead of evaluated, so a `${VAR}` in the `${}` family —
shell `${HOME}`, a JS template `` `${x}` ``, a perl `${name}` — survives
verbatim with **no `''` prefix**. The one line of ceremony is the `with`
(`nixx.for pkgs`, or just `nixx.runtimeScope` for the deferral alone): any
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
| `${VAR:-default}` `${VAR:=d}` `${VAR:?e}` | ✅ | `echo ${EDITOR:-vi}` |
| `${VAR/old/new}` | ✅ | `echo ${PATH//bin/BIN}` |
| `${ARR[@]}` `${ARR[*]}` `${#VAR}` `${VAR%x}` `${VAR#x}` | ❌ use `''` | `for x in ''${ARR[@]}; do …` |

Still strictly better than a plain evaluated `''…''`, which needs `''` on
*everything*. (Mechanism — lazy thunks, `unsafeGetAttrPos`, the literal-vs-
programmatic guard — in [API.md](./API.md).)

**Trade-off.** Any `with` defers undefined-variable checking, so a typo in
*never-evaluated* code under its scope won't be caught statically. Keep the
`with` on the flake output that builds your tasks; evaluated code still errors
clearly at runtime.

## Per-app options — inline, no wrapper
Pass options directly to the block constructor as a first attrset.
No `app { } (...)` wrapper needed:

```nix
with nixx.for pkgs;
mkApps { } {
  # bash — add tools to PATH
  fetch  = bash { runtimeInputs = [ pkgs.curl pkgs.jq ]; } ''
    curl -s https://api.example.com | jq .
  '';

  # python/uv — inline deps (PEP 723) or point at a project manifest
  report = uv { deps = [ "rich>=13" ]; } ''
    from rich import print
    print("[green]ok[/]")
  '';

  # bun — compile to a self-contained binary
  check  = bun { compile = true; } ''
    const r: { ok: boolean } = { ok: true };
    console.log(`status: ${r.ok}`);
  '';

  # point at the project's own pyproject.toml + uv.lock
  serve  = uv { projectRoot = ./.; } ''
    import myapp; myapp.start()
  '';
}
```

`app { ... } block` still works as a backwards-compatible composition helper.

## Apps and shells
`mkApps` builds store binaries. `mkTasks` builds a just-style runner for local
workflows. They compose: put app derivations in `vars`, then call them from
tasks with `@nix(name)`.

```nix
with nixx.for pkgs;
let
  apps = mkApps { } {
    status = bash ''echo "${USER} in ${PWD}"'';
    report = uv { deps = [ "rich" ]; } ''
      from rich import print
      print("[green]ok[/]")
    '';
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

## devShell / devenv / mkShell — pick your idiom
Same `with nixx.for pkgs;`, same zero-`${}`-tax bodies; only the wiring differs.
Runnable flakes in `examples/`. These examples expose a small `mkApps` binary
under `packages` and put the `tasks` runner in the shell.

**Plain flake `devShells.default`** (`examples/devshell`) — zero-config:
```nix
with nixx.for pkgs;
let
  apps = mkApps { } { whereami = bash ''echo ${PWD} as ${USER}''; };
  tasks = mkTasks { name = "tasks"; } {
    info = bash ''echo ${PWD} as ${USER}'';
  };
in {
  packages = apps // { default = tasks.runner; tasks = tasks.runner; };
  devShells.default = tasks.devShell;          # `tasks` on PATH, tab-completed
}
```

**Hand-rolled `pkgs.mkShell`** (`examples/mkshell`) — you keep full control;
`extendShell` folds the runner + completion into *your* shell:
```nix
with nixx.for pkgs;
let
  apps  = mkApps { } {
    envcheck = bash { runtimeInputs = [ pkgs.jq ]; } ''jq --version'';
  };
  tasks = mkTasks { name = "tasks"; } { build = bash ''echo ${OUT_DIR:-dist}''; };
in {
  packages = apps // { default = tasks.runner; };
  devShells.default = tasks.extendShell (pkgs.mkShell {
    packages  = [ pkgs.jq pkgs.ripgrep ];
    # even the hook is ${}-tax-free — it's a nixx body's .text:
    shellHook = (mkTasks { } { h = bash ''echo "hi ${USER}"''; }).tasks.h.text;
  });
}
```

**devenv** (`examples/devenv`) — complementary, not a replacement: devenv owns
the environment, nixx owns the scripting. Drop the runner in `packages`, feed
body `.text` into `enterShell` / `scripts.<n>.exec` (both are Nix strings that
otherwise pay the `${}` tax):
```nix
with nixx.for pkgs;
let
  apps   = mkApps { } { hello = bash ''echo "ready, ${USER}"''; };
  tasks  = mkTasks { name = "tasks"; } { fmt = bash ''echo ${PWD}''; };
  bodies = mkTasks { } { enter = bash ''echo "ready, ${USER}"''; };
in {
  packages = apps // { default = tasks.runner; };
  devShells.default = devenv.lib.mkShell {  # + inherit inputs pkgs; — see examples/devenv
    modules = [{
      packages   = [ tasks.runner ];
      enterShell = bodies.tasks.enter.text; # a Nix string, yet ${USER} stays raw
    }];
  };
}
```

## Task runner
`mkTasks` is a `just`-style runner: one `tasks <name>` invocation is a **single
bash process**, so an `export` in an early task (or `defaultDeps`/`env`) persists
into every later task. **Only env crosses task boundaries** — cwd and shell
options are normalized at each task's entry (every bash task is `set -euo
pipefail`; a dep's `cd` or `set +u` can't leak in), so tasks stay predictable.
Tasks support `deps` (just-style prerequisites), `group`, per-task
`requirements` / `cwd` / `env`.

```
$ tasks --list
  build    Build the project
  test     Run the test suite

release:
  deploy   Deploy production

$ tasks build
```

`nix run .#tasks -- build` works too. Options, `env`/`deps` semantics, and the
pure (no-pkgs) `nixx.mkTasks` → [API.md](./API.md).

## More
- **Multi-language & shippable binaries** — `mkApps`, inline opts (`bash { runtimeInputs = […] } ''…''`),
  `projectRoot` dependency wiring, `mkScript(s)`, `vars` markers, language table:
  **[API.md](./API.md)**.
- **Linter source-mapping** — blocks carry their source position, so
  shellcheck / ruff diagnostics remap back to the exact `.nix` `line:col`, even
  under nested indentation (details in [API.md](./API.md)).
