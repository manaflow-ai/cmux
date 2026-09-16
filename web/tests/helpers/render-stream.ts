import type { ReactNode } from "react";
import { renderToReadableStream } from "react-dom/server";

/** Render a tree with async server components to its settled HTML. */
export async function renderSettled(node: ReactNode): Promise<string> {
  const stream = await renderToReadableStream(node);
  await stream.allReady;
  return new Response(stream).text();
}
