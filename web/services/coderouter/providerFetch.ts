const RETRYABLE_STATUS = new Set([408, 425, 500, 502, 503, 504]);

/** Retry one safe, replayable provider read. Mutating requests must not use this. */
export async function fetchProviderRead(
  request: () => Promise<Response>,
): Promise<Response> {
  try {
    const first = await request();
    return RETRYABLE_STATUS.has(first.status) ? await request() : first;
  } catch {
    return await request();
  }
}
