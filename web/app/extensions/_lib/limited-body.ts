/**
 * Reads a remote response body with a hard byte limit, before it is buffered:
 * a declared Content-Length over the limit is refused without reading, and a
 * stream that grows past it is cancelled at the first chunk that crosses it.
 * Used for every remote fetch the extension pages make (registry JSON, the
 * icon and screenshot drawn into an Open Graph card).
 */

/** The body's bytes, or null when it is (or declares itself) larger than `maxBytes`. */
export async function readLimitedBody(response: Response, maxBytes: number): Promise<Uint8Array | null> {
  const declared = Number(response.headers.get("content-length") ?? "");
  if (Number.isFinite(declared) && declared > maxBytes) {
    await response.body?.cancel().catch(() => undefined);
    return null;
  }
  if (!response.body) return new Uint8Array(0);
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}
