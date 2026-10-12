// The one network read of models.dev: no Next fetch cache (the file is about
// 5 MB, above its 2 MB entry limit), a timeout, no redirects, and a body cap.

export const MODELS_DEV_URL = "https://models.dev/api.json";
/** models.dev's whole file is about 5 MB; refuse anything far above that. */
export const MAX_UPSTREAM_BYTES = 32 * 1024 * 1024;
export const UPSTREAM_TIMEOUT_MS = 20_000;

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

async function readLimitedBody(response: Response, maxBytes: number): Promise<string> {
  const declared = Number(response.headers.get("content-length") ?? "0");
  if (declared > maxBytes) throw new Error(`models.dev body is ${declared} bytes, above ${maxBytes}`);
  if (!response.body) throw new Error("models.dev returned no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error(`models.dev body is above ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** Fetches and parses the models.dev feed once. Throws on any failure. */
export async function fetchFeed(options: { fetch?: FetchLike; timeoutMs?: number } = {}): Promise<unknown> {
  const doFetch = options.fetch ?? fetch;
  const response = await doFetch(MODELS_DEV_URL, {
    cache: "no-store",
    headers: { Accept: "application/json", "User-Agent": "cmux-model-catalog/1 (+https://cmux.com)" },
    redirect: "error",
    signal: AbortSignal.timeout(options.timeoutMs ?? UPSTREAM_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`models.dev answered ${response.status}`);
  return JSON.parse(await readLimitedBody(response, MAX_UPSTREAM_BYTES));
}
