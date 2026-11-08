import { addCoderouterBreadcrumb } from "./observability";

const RETRYABLE_STATUS = new Set([408, 425, 500, 502, 503, 504]);

/** Retry one safe, replayable provider read. Mutating requests must not use this. */
export async function fetchProviderRead(
  request: () => Promise<Response>,
): Promise<Response> {
  let first: Response;
  try {
    first = await request();
  } catch {
    addCoderouterBreadcrumb("retry", "Retrying provider read after transport failure", {
      attempt: 2,
    }, "warning");
    return await request();
  }
  if (!RETRYABLE_STATUS.has(first.status)) return first;
  addCoderouterBreadcrumb("retry", "Retrying safe provider read", {
    status: first.status,
    attempt: 2,
  }, "warning");
  return await request();
}
