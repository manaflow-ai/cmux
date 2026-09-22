import { describe, expect, test } from "bun:test";
import { freestyleRequestFetch, type FreestyleRequestTiming } from "../services/vms/drivers/freestyleRequestTiming";

describe("Freestyle enrollment request timings", () => {
  test("distinguishes the initial request from background completion without logging access material", async () => {
    const events: FreestyleRequestTiming[] = [];
    const forwarded: Array<{ input: RequestInfo | URL; init?: RequestInit }> = [];
    const responses = [new Response("accepted", { status: 202 }), new Response("complete", { status: 200 })];
    let clock = 0;
    const traced = freestyleRequestFetch({
      timeoutMs: 60_000, now: () => { clock += 125; return clock; }, record: event => events.push(event),
      fetch: (async (input, init) => { forwarded.push({ input, init }); return responses.shift()!; }) as typeof fetch,
    });
    const body = JSON.stringify({ clientPublicKey: "private-test-payload" });
    const headers = { Authorization: "Bearer private-test-credential" };
    expect(await (await traced("https://api.example.test/v5/tunnels?secret=private-test-query", {
      method: "POST", body, headers,
    })).text()).toBe("accepted");
    expect(await (await traced("https://api.example.test/v5/background-requests/private-test-request")).text()).toBe("complete");

    expect(events.map(event => [event.stage, event.phase, event.status])).toEqual([
      ["begin", "tunnel_create", undefined], ["response", "tunnel_create", 202],
      ["begin", "background_result", undefined], ["response", "background_result", 200],
    ]);
    expect(events[1]?.elapsedMs).toBe(125);
    expect(events[3]?.elapsedMs).toBe(125);
    expect(events[0]?.clientId).toBe(events[2]?.clientId);
    expect(events[0]?.requestId).not.toBe(events[2]?.requestId);
    expect(JSON.stringify(events)).not.toContain("private-test");
    expect(forwarded[0]?.init?.body).toBe(body);
    expect(forwarded[0]?.init?.headers).toBe(headers);
    expect(forwarded[0]?.init?.signal).toBeInstanceOf(AbortSignal);
  });

  test("records a timeout without exposing its message or changing the error", async () => {
    const events: FreestyleRequestTiming[] = [];
    const failure = new DOMException("private-test-error", "TimeoutError");
    const traced = freestyleRequestFetch({ timeoutMs: 100, record: event => events.push(event),
      fetch: (async () => { throw failure; }) as typeof fetch });
    await expect(traced("https://example.test/v5/tunnels/private-test-slug")).rejects.toBe(failure);
    expect(events.map(event => event.stage)).toEqual(["begin", "error"]);
    expect(events[1]?.errorKind).toBe("timeout");
    expect(events[1]?.phase).toBe("tunnel_read");
    expect(JSON.stringify(events)).not.toContain("private-test");
  });

  test("a failing diagnostic sink never breaks the provider request", async () => {
    const response = new Response("unchanged");
    const traced = freestyleRequestFetch({ timeoutMs: 100, record: () => { throw new Error("logging failed"); },
      fetch: (async () => response) as typeof fetch });
    expect(await traced(new Request("https://example.test/v5/tunnels/peer/vpcs/network", { method: "POST" }))).toBe(response);
  });
});
