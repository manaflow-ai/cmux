import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

const originalFetch = globalThis.fetch;
const fetchMock = mock(async () => new Response("ok", { status: 200 }));

globalThis.fetch = fetchMock as unknown as typeof fetch;

const { POST } = await import("../app/api/analytics/browser-events/route");

afterAll(() => {
  globalThis.fetch = originalFetch;
});

beforeEach(() => {
  fetchMock.mockClear();
  fetchMock.mockResolvedValue(new Response("ok", { status: 200 }));
});

function request(body: unknown): Request {
  return new Request("https://cmux.test/api/analytics/browser-events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("browser analytics route", () => {
  test("forwards allowlisted browser events to PostHog from the server", async () => {
    const response = await POST(request({
      event: "cmuxterm_download_clicked",
      distinctId: "visitor-1",
      properties: {
        location: "hero",
        platform: "mac",
        nested: { kept: true },
      },
      timestamp: "2026-07-07T12:00:00.000Z",
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const calls = (fetchMock as unknown as {
      mock: { calls: Array<[string | URL | Request, RequestInit?]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("https://r.cmux.com/batch/");
    const body = JSON.parse((calls[0]?.[1]?.body as string) ?? "{}");
    expect(body).toMatchObject({
      api_key: "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP",
      batch: [
        {
          event: "cmuxterm_download_clicked",
          distinct_id: "visitor-1",
          properties: {
            location: "hero",
            platform: "mac",
            nested: { kept: true },
          },
          timestamp: "2026-07-07T12:00:00.000Z",
        },
      ],
    });
  });

  test("preserves waitlist enrollment properties", async () => {
    const response = await POST(request({
      event: "cmuxterm_waitlist_signup",
      distinctId: "ada@example.com",
      properties: {
        email: "ada@example.com",
        platforms: ["linux", "windows"],
        $set: {
          email: "ada@example.com",
          "$feature_enrollment/cmux-linux-early-access": true,
        },
        $set_once: { waitlist_email: "ada@example.com" },
      },
    }));

    expect(response.status).toBe(200);
    const calls = (fetchMock as unknown as {
      mock: { calls: Array<[string | URL | Request, RequestInit?]> };
    }).mock.calls;
    const body = JSON.parse((calls[0]?.[1]?.body as string) ?? "{}");
    expect(body.batch[0].properties).toEqual({
      email: "ada@example.com",
      platforms: ["linux", "windows"],
      $set: {
        email: "ada@example.com",
        "$feature_enrollment/cmux-linux-early-access": true,
      },
      $set_once: { waitlist_email: "ada@example.com" },
    });
  });

  test("rejects arbitrary event names before forwarding", async () => {
    const response = await POST(request({
      event: "anything_goes",
      distinctId: "visitor-1",
      properties: { location: "hero" },
    }));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "unknown_event" });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
