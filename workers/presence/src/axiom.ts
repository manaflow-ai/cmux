/** Small, dependency-free Axiom logger for Worker and Durable Object events.
 *
 * Events are deliberately structured and bounded. We never send bearer
 * tokens, request bodies, endpoint ids, or exception stacks to Axiom. The
 * Worker log stream remains enabled as a local fallback when Axiom is not
 * configured.
 */
export interface AxiomEnv {
  AXIOM_TOKEN?: string;
  AXIOM_DATASET?: string;
}

export type AxiomEvent = Readonly<Record<string, string | number | boolean | null>>;

function clean(value: string | number | boolean | null): string | number | boolean | null {
  if (typeof value !== "string") return value;
  return value.length <= 256 ? value : `${value.slice(0, 253)}...`;
}

export async function emitAxiomEvent(
  env: AxiomEnv,
  event: AxiomEvent,
  send: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<void> {
  const token = env.AXIOM_TOKEN?.trim();
  const dataset = env.AXIOM_DATASET?.trim();
  if (!token || !dataset) return;
  const body = JSON.stringify({
    _time: new Date().toISOString(),
    service: "cmux-presence",
    ...Object.fromEntries(Object.entries(event).map(([key, value]) => [key, clean(value)])),
  });
  try {
    await send(`https://api.axiom.co/v1/datasets/${encodeURIComponent(dataset)}/ingest`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: `[${body}]`,
    });
  } catch {
    // Observability must never change request or Durable Object behavior.
  }
}

export function traceId(request: Request): string {
  const supplied = request.headers.get("x-cmux-trace-id")?.trim();
  return supplied && /^[A-Za-z0-9._-]{8,128}$/.test(supplied) ? supplied : crypto.randomUUID();
}
