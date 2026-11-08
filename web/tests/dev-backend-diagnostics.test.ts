import { describe, expect, test } from 'bun:test';
import { makeDevBackendDiagnosticsHandler } from '../services/observability/devBackendDiagnostics';
const now = 1_800_000_000_000;
const event = { eventId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', tag: 'pr-123-check', revision: 'a'.repeat(40), startedAtMs: now, durationMs: 25, attempt: 0, outcome: 'unreachable', errorNumber: -1004 };
const request = (value: unknown) => new Request('https://cmux.test/api/observability/dev-backend', {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(value)});
describe('dev app diagnostics', () => {
  test('accepts a signed-out fixed-schema event only after delivery', async () => {
    let delivered = false;
    const handler = makeDevBackendDiagnosticsHandler({allowed:async()=>true,deliver:async events=>{expect(events[0]).toEqual(event);delivered=true;},now:()=>now});
    const response = await handler(request({version:1,events:[event]}));
    expect(response.status).toBe(202);expect(delivered).toBe(true);
    expect(await response.json()).toEqual({eventIds:[event.eventId]});
  });
  test('does not acknowledge an unavailable collector', async () => {
    const handler = makeDevBackendDiagnosticsHandler({allowed:async()=>true,deliver:async()=>{throw Error('unavailable');},now:()=>now});
    expect((await handler(request({version:1,events:[event]}))).status).toBe(503);
  });
  test('rejects arbitrary data, malformed tags and expired events before delivery', async () => {
    let delivered = false;
    const handler = makeDevBackendDiagnosticsHandler({allowed:async()=>true,deliver:async()=>{delivered=true;},now:()=>now});
    for (const invalid of [{...event,message:'private'}, {...event,tag:'../private'}, {...event,startedAtMs:0}, {...event,outcome:'anything'}]) {
      expect((await handler(request({version:1,events:[invalid]}))).status).toBe(400);
    }
    expect(delivered).toBe(false);
  });
  test('rate limits before parsing or delivery', async () => {
    const handler = makeDevBackendDiagnosticsHandler({allowed:async()=>false,deliver:async()=>{throw Error('must not deliver');},now:()=>now});
    expect((await handler(request({version:1,events:[event]}))).status).toBe(429);
  });
});
