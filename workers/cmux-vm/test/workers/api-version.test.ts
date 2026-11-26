/**
 * Dated API versions (`Cmux-Api-Version`, src/api-version.ts): unpinned
 * requests are untouched, a pin resolves to the newest version on or before
 * it, a pinned client is translated both ways, and a bad pin is refused.
 */
import { afterEach, describe, expect, it } from "vitest";
import {
  API_VERSIONS,
  applyChange,
  BASE_DATE,
  resolvePin,
  validateTable,
  withApiVersion,
  type ApiVersionTable,
} from "../../src/api-version.ts";
import { makeHarness } from "../support/harness.ts";

/** One fixture version after the base: renames both ways, `labels` arrived, `legacy` left. */
const FIXTURE: ApiVersionTable = {
  baseDate: BASE_DATE,
  versions: [
    {
      date: "2027-01-01",
      note: "fixture: VM state renamed to status",
      changes: [
        { message: "response:GET /v1/vms/{vmId}", op: "rename", path: "/status", to: "state" },
        { message: "response:GET /v1/vms", op: "rename", path: "/vms/*/state", to: "status" },
        { message: "request:POST /v1/echo", op: "rename", path: "/vm/state", to: "status" },
        { message: "request:POST /v1/echo", op: "add", path: "/labels", value: {} },
        { message: "response:POST /v1/echo", op: "remove", path: "/legacy", value: "gone" },
      ],
    },
  ],
};

const record = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value)) : {};

const echo = withApiVersion(async (request) => {
  return Response.json({ ...record(await request.json()), echoed: true });
}, FIXTURE);

const post = (headers: Record<string, string>, body: unknown) =>
  new Request("https://vm.test/v1/echo", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

describe("resolvePin", () => {
  it("leaves an unpinned request unpinned", () => {
    expect(resolvePin(null, FIXTURE)).toEqual({ kind: "unpinned" });
  });

  it("serves the newest version dated on or before the pin", () => {
    const base = resolvePin("2026-11-24", FIXTURE);
    expect(base.kind === "pinned" && base.date).toBe("2026-11-24");
    expect(base.kind === "pinned" && base.pending.length).toBe(1);
    const between = resolvePin("2026-12-31", FIXTURE);
    expect(between.kind === "pinned" && between.date).toBe("2026-11-24");
    const exact = resolvePin("2027-01-01", FIXTURE);
    expect(exact.kind === "pinned" && exact.date).toBe("2027-01-01");
    expect(exact.kind === "pinned" && exact.pending.length).toBe(0);
    const future = resolvePin(" 2030-06-01 ", FIXTURE);
    expect(future.kind === "pinned" && future.date).toBe("2027-01-01");
  });

  it("refuses a malformed pin and one older than the base, naming the update", async () => {
    for (const bad of ["2026-11-23", "yesterday", "2026-02-30", "2026-11-24T00:00:00Z", ""]) {
      const pin = resolvePin(bad, FIXTURE);
      expect(pin.kind).toBe("refused");
      if (pin.kind !== "refused") continue;
      expect(pin.response.status).toBe(400);
      expect(await pin.response.json()).toMatchObject({
        _tag: "UnsupportedApiVersion",
        message: expect.stringContaining("update the client"),
        minApiVersion: "2026-11-24",
        apiVersion: "2027-01-01",
      });
    }
  });
});

describe("the compat table", () => {
  it("is valid as shipped, and refuses an undated or out-of-order version", () => {
    expect(() => validateTable(API_VERSIONS)).not.toThrow();
    expect(() => validateTable(FIXTURE)).not.toThrow();
    expect(() => validateTable({ baseDate: BASE_DATE, versions: [{ date: "2026-11-24", note: "", changes: [] }] })).toThrow("not after");
    expect(() => validateTable({ baseDate: "nope", versions: [] })).toThrow("YYYY-MM-DD");
  });

  it("applies rename, add and remove both ways, through arrays", () => {
    const body = { vms: [{ state: "running" }, { state: "stopped" }] };
    applyChange(body, { message: "response:GET /v1/vms", op: "rename", path: "/vms/*/state", to: "status" }, true);
    expect(body).toEqual({ vms: [{ status: "running" }, { status: "stopped" }] });
    applyChange(body, { message: "response:GET /v1/vms", op: "rename", path: "/vms/*/state", to: "status" }, false);
    expect(body).toEqual({ vms: [{ state: "running" }, { state: "stopped" }] });
    const added: Record<string, unknown> = {};
    applyChange(added, { message: "request:POST /v1/vms", op: "add", path: "/labels", value: { a: "b" } }, true);
    expect(added).toEqual({ labels: { a: "b" } });
    applyChange(added, { message: "request:POST /v1/vms", op: "add", path: "/labels", value: {} }, false);
    expect(added).toEqual({});
  });
});

describe("withApiVersion", () => {
  it("passes an unpinned request and its response through untouched", async () => {
    const response = await echo(post({}, { vm: { state: "running" } }));
    expect(response.headers.get("cmux-api-version")).toBeNull();
    expect(await response.json()).toEqual({ vm: { state: "running" }, echoed: true });
  });

  it("translates a pinned client's request up and the response down", async () => {
    const response = await echo(post({ "cmux-api-version": "2026-11-24" }, { vm: { state: "running" }, legacy: "x" }));
    expect(response.headers.get("cmux-api-version")).toBe("2026-11-24");
    // Up: state became status, labels filled in. Down: legacy filled back in for the old shape.
    expect(await response.json()).toEqual({ vm: { status: "running" }, labels: {}, legacy: "x", echoed: true });
  });

  it("serves a current pin unchanged, naming its version", async () => {
    const response = await echo(post({ "cmux-api-version": "2027-03-01" }, { vm: { state: "running" } }));
    expect(response.headers.get("cmux-api-version")).toBe("2027-01-01");
    expect(await response.json()).toEqual({ vm: { state: "running" }, echoed: true });
  });

  it("refuses an old pin before the handler runs", async () => {
    let ran = false;
    const handler = withApiVersion(async () => {
      ran = true;
      return new Response(null, { status: 204 });
    }, FIXTURE);
    const response = await handler(post({ "cmux-api-version": "2025-01-01" }, {}));
    expect(response.status).toBe(400);
    expect(ran).toBe(false);
  });
});

describe("the Worker", () => {
  let dispose: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await dispose?.();
    dispose = undefined;
  });

  it("serves GET /v1/vms/{vmId} in the pinned shape, and unpinned as before", async () => {
    const h = await makeHarness({ apiVersions: FIXTURE });
    dispose = h.dispose;
    const { vmId } = h.addVm("team_alpha");
    const key = await h.addKey("team_alpha", ["vm:read"]);
    const auth = { authorization: `Bearer ${key}` };

    const current = await h.request(`/v1/vms/${vmId}`, auth);
    expect(current.status).toBe(200);
    expect(current.headers.get("cmux-api-version")).toBeNull();
    const now = record(await current.json());
    expect(now).toHaveProperty("state");

    const pinned = await h.request(`/v1/vms/${vmId}`, { ...auth, "cmux-api-version": "2026-11-24" });
    expect(pinned.status).toBe(200);
    expect(pinned.headers.get("cmux-api-version")).toBe("2026-11-24");
    const { state, ...rest } = now;
    expect(await pinned.json()).toEqual({ ...rest, status: state });

    const refused = await h.request(`/v1/vms/${vmId}`, { ...auth, "cmux-api-version": "2026-01-01" });
    expect(refused.status).toBe(400);
  });

  it("answers the shipped table's base pin with the shape unpinned clients get", async () => {
    const h = await makeHarness();
    dispose = h.dispose;
    const { vmId } = h.addVm("team_alpha");
    const key = await h.addKey("team_alpha", ["vm:read"]);
    const auth = { authorization: `Bearer ${key}` };
    const unpinned = await (await h.request(`/v1/vms/${vmId}`, auth)).json();
    const pinned = await h.request(`/v1/vms/${vmId}`, { ...auth, "cmux-api-version": BASE_DATE });
    expect(pinned.headers.get("cmux-api-version")).toBe(BASE_DATE);
    expect(await pinned.json()).toEqual(unpinned);
  });
});
