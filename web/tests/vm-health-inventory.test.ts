import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";

import { freestyleHealthInventory } from "../services/vms/drivers/freestyleHealthInventory";

type Route = (path: string, init: RequestInit) => Promise<Response> | Response;

/** A Freestyle client double whose raw fetch answers by path and records every request. */
function client(route: Route, lists: { vms?: (offset: number) => unknown; rules?: (offset: number) => unknown } = {}) {
  const requests: string[] = [];
  const instance = {
    fetch: async (path: string, init: RequestInit) => {
      requests.push(`${init.method ?? "GET"} ${path}`);
      return route(path, init);
    },
    vms: { list: async ({ offset }: { offset: number }) => lists.vms?.(offset) },
    tls: { rules: { list: async ({ offset }: { offset: number }) => lists.rules?.(offset) } },
  } as unknown as Freestyle;
  return { requests, inventory: freestyleHealthInventory(() => instance) };
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const stateIs = (state: string) => (path: string) => path === "/v5/vms/vm-1" ? json(200, { id: "vm-1", state }) : json(500, {});

describe("probeControl", () => {
  test("a VM paused since the listing is never sent a file system call", async () => {
    const { requests, inventory } = client(stateIs("paused"));
    const probe = await inventory.probeControl("vm-1", { timeoutMs: 1_000 });
    expect(probe.outcome).toBe("not_running");
    expect(requests).toEqual(["GET /v5/vms/vm-1"]);
  });

  test("a running VM gets one GET state read and one GET fs/stat, nothing else", async () => {
    const { requests, inventory } = client((path) => path.includes("/fs/stat") ? json(200, { isDirectory: true }) : json(200, { state: "running" }));
    expect((await inventory.probeControl("vm-1", { timeoutMs: 1_000 })).outcome).toBe("ok");
    expect(requests).toEqual(["GET /v5/vms/vm-1", "GET /v5/vms/vm-1/fs/stat?path=%2F"]);
  });

  test("the guest request receives a fresh timeout after the provider state read", async () => {
    const signals: (AbortSignal | null | undefined)[] = [];
    const { inventory } = client((path, init) => {
      signals.push(init.signal);
      return path.includes("/fs/stat") ? json(200, {}) : json(200, { state: "running" });
    });
    expect((await inventory.probeControl("vm-1", { timeoutMs: 1_000 })).outcome).toBe("ok");
    expect(signals).toHaveLength(2);
    expect(signals[0]).toBeInstanceOf(AbortSignal);
    expect(signals[1]).toBeInstanceOf(AbortSignal);
    expect(signals[0]).not.toBe(signals[1]);
  });

  test("only explicit guest failures are hung on fs/stat error responses", async () => {
    const cases = [
      [409, "CONFLICT", "vm runtime stale runtime instance responsive=false", "hung"],
      [409, "VM_NON_RESPONSIVE", "", "hung"],
      [502, "VM_NON_RESPONSIVE", "", "hung"],
      [409, "CONFLICT", "no manager has enough capacity", "error"],
      [409, "CONFLICT", "stale runtime instance", "error"],
      [503, "UNAVAILABLE", "upstream", "error"],
      [504, "", "", "error"],
      [401, "VM_NON_RESPONSIVE", "", "error"],
      [429, "CONFLICT", "", "error"],
      [404, "", "", "gone"],
    ] as const;
    for (const [status, code, message, outcome] of cases) {
      const { inventory } = client((path) => path.includes("/fs/stat")
        ? json(status, { code, message })
        : json(200, { state: "running" }));
      const probe = await inventory.probeControl("vm-1", { timeoutMs: 1_000 });
      expect(`${status} ${code}: ${probe.outcome}`).toBe(`${status} ${code}: ${outcome}`);
    }
  });

  test("an unreadable state read is a probe error, never a paused VM", async () => {
    for (const body of ["not json", JSON.stringify({ id: "vm-1" })]) {
      const { requests, inventory } = client(() => new Response(body, { status: 200 }));
      const probe = await inventory.probeControl("vm-1", { timeoutMs: 1_000 });
      expect(probe.outcome).toBe("error");
      expect(requests).toEqual(["GET /v5/vms/vm-1"]);
    }
  });

  test("a control-plane outage on the state read is a probe error, not a hung VM", async () => {
    const { requests, inventory } = client(() => json(503, { code: "UNAVAILABLE", message: "upstream" }));
    const probe = await inventory.probeControl("vm-1", { timeoutMs: 1_000 });
    expect(probe.outcome).toBe("error");
    expect(requests).toHaveLength(1);
  });

  test("an fs/stat that never answers is hung at the timeout", async () => {
    const { inventory } = client((path, init) => path.includes("/fs/stat")
      ? new Promise<Response>((_, reject) => init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError"))))
      : json(200, { state: "running" }));
    const probe = await inventory.probeControl("vm-1", { timeoutMs: 150 });
    expect(probe.outcome).toBe("hung");
  });
});

describe("account listings", () => {
  const vm = (id: string) => ({ id, state: "running", metadata: {}, resources: {}, vpcs: [], createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z" });
  const rule = (id: string) => ({ id, dependencies: [], source: {}, destination: {} });
  const ids = (prefix: string, from: number, count: number) => Array.from({ length: count }, (_, index) => `${prefix}${from + index}`);

  test("VM paging dedupes a repeated VM and reports a shortfall as incomplete", async () => {
    // 150 VMs; one was deleted mid-walk, so vm-100 shifted onto page one and was never seen.
    const pages: Record<number, unknown> = {
      0: { vms: ids("vm-", 0, 100).map(vm), totalCount: 150 },
      100: { vms: [...ids("vm-", 99, 1), ...ids("vm-", 101, 49)].map(vm), totalCount: 150 },
    };
    const { inventory } = client(() => json(500, {}), { vms: (offset) => pages[offset] });
    const result = await inventory.listAccountVms({ deadlineAtMs: Date.now() + 10_000 });
    expect(result.vms).toHaveLength(149);
    expect(result.complete).toBe(false);
  });

  test("VM pages are fetched in bounded batches after the count-bearing first page", async () => {
    let active = 0;
    let peak = 0;
    const { inventory } = client(() => json(500, {}), {
      vms: async (offset) => {
        active += 1;
        peak = Math.max(peak, active);
        await new Promise((resolve) => setTimeout(resolve, 10));
        active -= 1;
        const count = offset === 0 ? 100 : Math.min(100, 401 - offset);
        return { vms: ids("vm-", offset, Math.max(0, count)).map(vm), totalCount: 401 };
      },
    });
    const result = await inventory.listAccountVms({ deadlineAtMs: Date.now() + 10_000 });
    expect(result.vms).toHaveLength(401);
    expect(result.complete).toBe(true);
    expect(peak).toBe(4);
  });

  test("TLS paging dedupes a rule repeated by a mid-walk create", async () => {
    const pages: Record<number, unknown> = {
      0: { rules: ids("r", 0, 100).map(rule), totalCount: 120 },
      100: { rules: ids("r", 99, 20).map(rule), totalCount: 120 },
    };
    const { inventory } = client(() => json(500, {}), { rules: (offset) => pages[offset] });
    const result = await inventory.listAccountTlsRules({ deadlineAtMs: Date.now() + 10_000 });
    expect(result.rules).toHaveLength(119);
    expect(result.totalCount).toBe(120);
    expect(result.complete).toBe(false);
  });

  test("a TLS listing that fetched no page fails instead of reporting zero rules", async () => {
    const { inventory } = client(() => json(500, {}), { rules: () => ({ rules: [], totalCount: 0 }) });
    await expect(inventory.listAccountTlsRules({ deadlineAtMs: Date.now() - 1 })).rejects.toThrow("first page");
  });
});
