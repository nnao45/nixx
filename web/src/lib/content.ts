import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  createMarkdownProcessor,
  type MarkdownProcessor,
  type MarkdownHeading,
} from "@astrojs/markdown-remark";

// Single source of truth: read the REAL docs from the repo root, never copies.
// web/src/lib/ → ../../../ = repo root (where README.md / API.md live).
const repoRoot = new URL("../../../", import.meta.url);

export type DocName = "README" | "API";
export type { MarkdownHeading as Heading };

export interface RenderedDoc {
  html: string;
  headings: MarkdownHeading[];
}

function rawDoc(file: DocName): string {
  return readFileSync(fileURLToPath(new URL(`${file}.md`, repoRoot)), "utf8");
}

/** Drop a leading `# title` line — the landing hero replaces it. */
function stripFirstH1(md: string): string {
  return md.replace(/^#[^\n]*\n+/, "");
}

/** Extract h2/h3 (depth, slug, text) from rendered HTML for the ToC.
 *  The bare processor renders heading `id`s but doesn't return a headings list
 *  (that's Astro's content-layer job), so parse the ids it already emitted. */
function extractHeadings(html: string): MarkdownHeading[] {
  const out: MarkdownHeading[] = [];
  const re = /<h([23])\s+id="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/g;
  for (const m of html.matchAll(re)) {
    const text = m[3].replace(/<[^>]+>/g, "").trim();
    if (text) out.push({ depth: Number(m[1]), slug: m[2], text });
  }
  return out;
}

// Shiki loads grammars async; create the processor once and reuse it.
let processorPromise: Promise<MarkdownProcessor> | null = null;
function getProcessor(): Promise<MarkdownProcessor> {
  if (!processorPromise) {
    processorPromise = createMarkdownProcessor({
      gfm: true,
      syntaxHighlight: "shiki",
      shikiConfig: { theme: "github-dark-default", wrap: false },
    });
  }
  return processorPromise;
}

export async function renderDoc(
  file: DocName,
  opts: { stripFirstH1?: boolean } = {},
): Promise<RenderedDoc> {
  let md = rawDoc(file);
  if (opts.stripFirstH1) md = stripFirstH1(md);

  const processor = await getProcessor();
  const { code } = await processor.render(md);

  return {
    html: code,
    headings: extractHeadings(code),
  };
}

/** Raw markdown text — for the LLM-friendly llms-full.txt dump. */
export function docText(file: DocName): string {
  return rawDoc(file);
}
