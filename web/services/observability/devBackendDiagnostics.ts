import { z } from 'zod';
import { readBoundedJsonObject } from '../apns/routePolicy';

const eventSchema = z.strictObject({
  eventId: z.uuid(), tag: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/),
  revision: z.string().regex(/^(?:[0-9a-f]{7,64}|unknown)$/),
  startedAtMs: z.number().int().nonnegative(), durationMs: z.number().int().min(0).max(3_600_000),
  attempt: z.number().int().min(0).max(10_000),
  outcome: z.enum(['ready', 'unreachable', 'timeout', 'startup_failed', 'invalid_response']),
  errorNumber: z.number().int().min(-65_535).max(65_535).optional(),
  httpStatus: z.number().int().min(100).max(599).optional(),
});
const batchSchema = z.strictObject({version:z.literal(1),events:z.array(eventSchema).min(1).max(20)});
export type DevBackendEvent = z.infer<typeof eventSchema>;

export function makeDevBackendDiagnosticsHandler(dependencies: {
  allowed: (request: Request) => Promise<boolean>;
  deliver: (events: DevBackendEvent[]) => Promise<void>;
  now: () => number;
}) {
  return async (request: Request): Promise<Response> => {
    try {
      if (!await dependencies.allowed(request)) return response(429, {error:'rate_limited'});
      if (request.headers.get('content-type')?.split(';')[0].trim() !== 'application/json') return response(415, {error:'unsupported_content_type'});
      const encoding = request.headers.get('content-encoding');
      if (encoding && encoding !== 'identity') return response(415, {error:'unsupported_encoding'});
      const body = await readBoundedJsonObject(request, 16 * 1024);
      if (!body.ok) return response(body.error === 'request_too_large' ? 413 : 400, {error:'invalid_diagnostics'});
      const batch = batchSchema.safeParse(body.value);
      if (!batch.success) return response(400, {error:'invalid_diagnostics'});
      const now = dependencies.now();
      if (batch.data.events.some(event => event.startedAtMs < now - 86_400_000 || event.startedAtMs > now + 300_000)) return response(400, {error:'invalid_timestamp'});
      if (new Set(batch.data.events.map(event => event.eventId)).size !== batch.data.events.length) return response(400, {error:'duplicate_event'});
      await dependencies.deliver(batch.data.events);
      return response(202, {eventIds:batch.data.events.map(event => event.eventId)});
    } catch {
      return response(503, {error:'diagnostics_unavailable'});
    }
  };
}

/** Anonymous operational observations: no account identity, free text or client-selected destination. */
export async function deliverDevBackendDiagnostics(events: DevBackendEvent[], env = process.env, doFetch: typeof fetch = fetch) {
  const token = env.CMUX_DEV_BACKEND_DIAGNOSTICS_TOKEN?.trim();
  if (!token) throw new Error('dev_diagnostics_unconfigured');
  const rows = events.map(event => ({
    _time: new Date(event.startedAtMs).toISOString(), event_id:event.eventId,
    record_type:'dev_backend_app_outcome', source:'cmux-mac-dev',
    client_tag:event.tag, client_revision:event.revision,
    outcome:event.outcome, duration_ms:event.durationMs, attempt:event.attempt,
    error_number:event.errorNumber, http_status:event.httpStatus,
  }));
  const result = await doFetch('https://api.axiom.co/v1/datasets/cmux-dev-otel-traces/ingest', {
    method:'POST',redirect:'error',signal:AbortSignal.timeout(10_000),
    headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(rows),
  });
  if (!result.ok) throw new Error('dev_diagnostics_delivery_failed');
  const receipt = await result.json() as {ingested?:number;failed?:number};
  if (receipt.ingested !== rows.length || Number(receipt.failed ?? 0) !== 0) throw new Error('dev_diagnostics_partial_delivery');
}

function response(status: number, body: unknown): Response {
  return Response.json(body, {status,headers:{'cache-control':'no-store', ...(status === 429 || status === 503 ? {'retry-after':'60'} : {})}});
}
