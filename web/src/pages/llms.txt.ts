import type { APIRoute } from "astro";

const SITE = "https://nnao45.github.io/nixx";

const body = `# nixx

> Write real shell, JavaScript, Python, and TypeScript inside Nix — without escaping \${}.

nixx is a Nix library for writing raw shell/JS/Python/TypeScript inside Nix with no \${} escaping. Script bodies are read from source, never evaluated, so a \${VAR} in a body belongs to the language (shell, JS, ...), not Nix. No preprocessor, no codegen; files stay valid .nix so nil/nixd never error. Ships store binaries via mkApps and a just-style task runner via mkTasks.

## Docs
- [README](${SITE}/): the \${} mechanism, per-app options, dev-shell idioms, the task runner
- [API reference](${SITE}/api): mkApps, mkTasks options, dependency wiring, vars markers, linter source-mapping

## Plain text (full content for LLM context)
- [llms-full.txt](${SITE}/llms-full.txt): README + API reference concatenated

## Source
- [github.com/nnao45/nixx](https://github.com/nnao45/nixx)
`;

export const GET: APIRoute = () =>
  new Response(body, {
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
