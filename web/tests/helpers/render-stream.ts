import type { ReactNode } from "react";
import { renderToReadableStream } from "react-dom/server";

/** Read the initial page through its closing main tag, independent of transport chunk sizes. */
export async function readInitialMain(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let html = "";
  while (!html.includes("</main>")) {
    const { value, done } = await reader.read();
    if (done) throw new Error("Pricing stream ended before the initial main content completed");
    html += decoder.decode(value, { stream: true });
  }
  return html.slice(0, html.indexOf("</main>") + "</main>".length);
}

/** Render a tree with async server components to its settled HTML. */
export async function renderSettled(node: ReactNode): Promise<string> {
  const stream = await renderToReadableStream(node);
  await stream.allReady;
  return new Response(stream).text();
}
