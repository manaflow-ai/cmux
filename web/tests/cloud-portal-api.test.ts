import { afterEach, describe, expect, mock, test } from "bun:test";

import {
  CloudPortalApiError,
  createCloudMachine,
  deleteCloudMachine,
  listCloudMachines,
  shortMachineId,
} from "../app/[locale]/dashboard/cloud/cloud-api";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("cloud portal API client", () => {
  test("lists active machines with browser cookie authentication", async () => {
    const fetchMock = mock(async () => Response.json({
      vms: [
        { id: "running", provider: "freestyle", status: "running", image: "base", imageVersion: "1", createdAt: "2026-07-22T00:00:00Z" },
        { id: "gone", provider: "freestyle", status: "destroyed", image: "base", imageVersion: "1", createdAt: "2026-07-21T00:00:00Z" },
      ],
    }));
    globalThis.fetch = fetchMock as typeof fetch;

    const machines = await listCloudMachines();

    expect(machines.map((machine) => machine.id)).toEqual(["running"]);
    expect(fetchMock).toHaveBeenCalledWith("/api/vm", expect.objectContaining({
      credentials: "same-origin",
    }));
  });

  test("creates a default machine with a unique idempotency key", async () => {
    const fetchMock = mock(async (...args: unknown[]) => {
      const [, init] = args as [RequestInfo | URL, RequestInit?];
      expect(init?.method).toBe("POST");
      expect(init?.body).toBe("{}");
      expect(new Headers(init?.headers).get("idempotency-key")).toBeTruthy();
      return Response.json({ id: "vm-1", provider: "freestyle", status: "running", image: "base", imageVersion: "1", createdAt: "2026-07-22T00:00:00Z" });
    });
    globalThis.fetch = fetchMock as typeof fetch;

    expect((await createCloudMachine()).id).toBe("vm-1");
  });

  test("encodes machine ids before destructive requests", async () => {
    const fetchMock = mock(async (...args: unknown[]) => {
      const [input, init] = args as [RequestInfo | URL, RequestInit?];
      expect(input).toBe("/api/vm/vm%2Funsafe");
      expect(init?.method).toBe("DELETE");
      return Response.json({ ok: true });
    });
    globalThis.fetch = fetchMock as typeof fetch;

    await deleteCloudMachine("vm/unsafe");
  });

  test("returns a typed error without trusting malformed API payloads", async () => {
    globalThis.fetch = mock(async () => new Response("bad gateway", { status: 502 })) as typeof fetch;

    await expect(listCloudMachines()).rejects.toEqual(new CloudPortalApiError(502, "HTTP 502"));
  });

  test("shortens long machine ids without hiding short ids", () => {
    expect(shortMachineId("short-id")).toBe("short-id");
    expect(shortMachineId("1234567890abcdefghij")).toBe("12345678…ghij");
  });
});
