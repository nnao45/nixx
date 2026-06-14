import type { APIRoute } from "astro";
import { docText } from "../lib/content";

// README + API, verbatim — the whole docs as one plain-text blob for LLMs.
const body = `${docText("README")}\n\n---\n\n${docText("API")}\n`;

export const GET: APIRoute = () =>
  new Response(body, {
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
