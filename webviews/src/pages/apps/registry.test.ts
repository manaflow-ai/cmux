// The App Store's community registry flows against the `cmux.registry.*` page ops
// (custom-panes-DESIGN.md 6.4): Community listings and Get, Submit for Review, My Submissions and
// the reviewer's queue, with the expected `cloud.signed_out` and `cmux.page.cancelled` codes.
import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { MockAppsProvider, sampleApps, sampleLocalApp, sampleRegistry } from "./mockProvider";
import { AppsStore, validRejectReason } from "./store";
import { AppsOps, RegistryOps, type RegistryMe } from "./types";
import { decodeFile, manifestSummary } from "./wire";

const person: RegistryMe = { signedIn: true, user: "user_sample", reviewer: false, publishers: ["sample-studio"] };

function setup(me?: RegistryMe) {
  const data = { ...sampleApps(), registry: sampleRegistry(me) };
  data.installed["local/notes-pane"] = sampleLocalApp();
  const provider = new MockAppsProvider(data);
  const store = new AppsStore(provider);
  return { provider, store };
}

const ops = (provider: MockAppsProvider) => provider.calls.map((call) => call.op);

describe("Community listings and Get", () => {
  test("loads approved listings beside the catalog", async () => {
    const { store } = setup(person);
    await store.start();
    const registry = store.getSnapshot().registry;
    expect(registry.listingsStatus).toBe("ready");
    expect(registry.listings.map((listing) => listing.app)).toEqual([
      "sample-studio/workspace-board",
      "pixel-works/focus-timer",
    ]);
    store.stop();
  });

  test("reads every listings page so later apps remain searchable", async () => {
    const { provider, store } = setup(person);
    const call = provider.call.bind(provider);
    const listings = sampleRegistry(person).listings;
    provider.call = async <R>(op: string, rawParams: unknown): Promise<R> => {
      if (op !== RegistryOps.listings) return call<R>(op, rawParams);
      const params = rawParams as Record<string, unknown>;
      provider.calls.push({ op, params });
      return (
        params.cursor
          ? { listings: [listings[1]] }
          : { listings: [listings[0]], cursor: "sample-studio/workspace-board" }
      ) as R;
    };
    await store.start();
    expect(store.getSnapshot().registry.listings).toEqual(listings);
    expect(provider.calls.filter((entry) => entry.op === RegistryOps.listings).map((entry) => entry.params)).toEqual([
      {},
      { cursor: "sample-studio/workspace-board" },
    ]);
    store.setQuery("focus-timer");
    expect(store.getSnapshot().registry.listings.some((listing) => listing.app === "pixel-works/focus-timer")).toBe(
      true,
    );
    store.stop();
  });

  test("Get asks the host for the approved bundle, then installs through the native sheet", async () => {
    const { provider, store } = setup(person);
    await store.start();
    provider.calls.length = 0;

    await store.getListing("sample-studio/workspace-board", "0.2.0");

    const get = provider.calls.findIndex((call) => call.op === RegistryOps.get);
    const install = provider.calls.findIndex((call) => call.op === AppsOps.install);
    expect(get).toBeGreaterThanOrEqual(0);
    expect(install).toBeGreaterThan(get);
    expect(provider.calls[get]!.params).toEqual({ app: "sample-studio/workspace-board", version: "0.2.0" });
    expect(provider.calls[install]!.params).toMatchObject({ app: "sample-studio/workspace-board" });
    const snap = store.getSnapshot();
    expect(snap.catalog.find((app) => app.id === "sample-studio/workspace-board")?.installed).toBe(true);
    expect(snap.installed.some((app) => app.id === "sample-studio/workspace-board")).toBe(true);
    expect(snap.registry.busy).toBeUndefined();
    expect(snap.error).toBeUndefined();
    store.stop();
  });

  test("a failed Get shows the store error and installs nothing", async () => {
    const { provider, store } = setup(person);
    await store.start();
    provider.failNext(RegistryOps.get, pageError("cloud.bundle_mismatch", "The bundle does not match its hash."));

    await store.getListing("sample-studio/workspace-board", "0.2.0");

    expect(store.getSnapshot().error).toBe("The bundle does not match its hash.");
    expect(ops(provider)).not.toContain(AppsOps.install);
    store.stop();
  });

  test("a declined install sheet is silent and still rereads the catalog", async () => {
    const { provider, store } = setup(person);
    await store.start();
    provider.failNext(AppsOps.install, pageError("cmux.page.cancelled", "Declined"));
    provider.calls.length = 0;

    await store.getListing("sample-studio/workspace-board", "0.2.0");

    expect(store.getSnapshot().error).toBeUndefined();
    expect(ops(provider)).toContain(AppsOps.catalogList);
    expect(store.getSnapshot().catalog.some((app) => app.id === "sample-studio/workspace-board")).toBe(true);
    store.stop();
  });

  test("a host without the registry shows no Community and no error", async () => {
    const provider = new MockAppsProvider();
    const store = new AppsStore(provider);
    await store.start();
    const snap = store.getSnapshot();
    expect(snap.registry.listingsStatus).toBe("unavailable");
    expect(snap.registry.submissionsStatus).toBe("unavailable");
    expect(snap.error).toBeUndefined();
    store.stop();
  });
});

describe("Submit for Review and My Submissions", () => {
  test("lists the person's submissions with status and the reviewer's reason", async () => {
    const { store } = setup(person);
    await store.start();
    const registry = store.getSnapshot().registry;
    expect(registry.submissionsStatus).toBe("ready");
    expect(registry.submissions.map((row) => row.status)).toEqual(["pending", "approved", "rejected"]);
    expect(registry.submissions.find((row) => row.status === "rejected")?.reason).toContain("terminal:execute");
    store.stop();
  });

  test("submit sends app, publisher and notes, closes the form and rereads the submissions", async () => {
    const { provider, store } = setup(person);
    await store.start();
    store.toggleSubmit("local/notes-pane");

    await store.submit("local/notes-pane", " sample-studio ", " First version ");

    const call = provider.calls.find((entry) => entry.op === RegistryOps.submit);
    expect(call?.params).toEqual({ app: "local/notes-pane", publisher: "sample-studio", notes: "First version" });
    const registry = store.getSnapshot().registry;
    expect(registry.submitFor).toBeUndefined();
    expect(registry.submissions[0]).toMatchObject({ app: "sample-studio/notes-pane", status: "pending" });
    store.stop();
  });

  test("submit leaves notes out when empty", async () => {
    const { provider, store } = setup(person);
    await store.start();
    await store.submit("local/notes-pane", "sample-studio", "   ");
    expect(provider.calls.find((entry) => entry.op === RegistryOps.submit)?.params).toEqual({
      app: "local/notes-pane",
      publisher: "sample-studio",
    });
    store.stop();
  });

  test("a declined confirmation sheet is a no-op: no error, the form stays open", async () => {
    const { provider, store } = setup(person);
    await store.start();
    store.toggleSubmit("local/notes-pane");
    provider.failNext(RegistryOps.submit, pageError("cmux.page.cancelled", "Declined"));

    await store.submit("local/notes-pane", "sample-studio", "");

    const snap = store.getSnapshot();
    expect(snap.error).toBeUndefined();
    expect(snap.registry.submitFor).toBe("local/notes-pane");
    expect(snap.registry.busy).toBeUndefined();
    expect(snap.registry.submissions).toHaveLength(3);
    store.stop();
  });

  test("a refused submission shows the Cloud's message", async () => {
    const { provider, store } = setup(person);
    await store.start();
    provider.failNext(
      RegistryOps.submit,
      pageError("cloud.publisher_taken", "That publisher belongs to someone else."),
    );
    await store.submit("local/notes-pane", "taken", "");
    expect(store.getSnapshot().error).toBe("That publisher belongs to someone else.");
    store.stop();
  });

  test("signed out: me says so, submissions are not read", async () => {
    const { provider, store } = setup({ signedIn: false });
    await store.start();
    const registry = store.getSnapshot().registry;
    expect(registry.me?.signedIn).toBe(false);
    expect(registry.submissionsStatus).toBe("signed-out");
    expect(ops(provider)).not.toContain(RegistryOps.submissions);
    expect(store.getSnapshot().error).toBeUndefined();
    store.stop();
  });

  test("a me call that fails signed out reads as signed out", async () => {
    const { provider, store } = setup(person);
    provider.failNext(RegistryOps.me, pageError("cloud.signed_out", "Sign in to cmux Cloud."));
    await store.start();
    expect(store.getSnapshot().registry.me).toEqual({ signedIn: false });
    expect(store.getSnapshot().registry.submissionsStatus).toBe("signed-out");
    store.stop();
  });
});

describe("Review", () => {
  test("a person who is not a reviewer never reads the queue", async () => {
    const { provider, store } = setup(person);
    await store.start();
    expect(ops(provider)).not.toContain(RegistryOps.reviewQueue);
    expect(store.getSnapshot().registry.queue).toEqual([]);
    store.stop();
  });

  test("a reviewer reads the queue and opens a file as text or as a binary size", async () => {
    const { provider, store } = setup();
    await store.start();
    expect(store.getSnapshot().registry.queue.map((item) => item.id)).toEqual(["sub_9"]);
    store.selectReview("sub_9");

    await store.openReviewFile("sub_9", "web/clock.js");
    let file = store.getSnapshot().registry.reviewFile;
    expect(provider.calls.find((call) => call.op === RegistryOps.reviewFile)?.params).toEqual({
      id: "sub_9",
      path: "web/clock.js",
    });
    expect(file?.status).toBe("ready");
    expect(file?.file).toMatchObject({ kind: "text" });
    expect(file?.file?.kind === "text" && file.file.text).toContain("setInterval");

    await store.openReviewFile("sub_9", "web/icon.png");
    file = store.getSnapshot().registry.reviewFile;
    expect(file?.file).toEqual({ kind: "binary", size: 6 });
    store.stop();
  });

  test("reject needs a reason of 8 to 500 characters before it calls the Cloud", async () => {
    const { provider, store } = setup();
    await store.start();
    store.selectReview("sub_9");

    expect(await store.decide("sub_9", "reject", "  short ")).toBe(false);

    expect(ops(provider)).not.toContain(RegistryOps.reviewDecide);
    expect(store.getSnapshot().registry.reviewFormError).toBe("store.registry.reasonLength");
    expect(validRejectReason("x".repeat(501))).toBe(false);
    expect(validRejectReason("x".repeat(500))).toBe(true);
    expect(validRejectReason("eight ch")).toBe(true);
    store.stop();
  });

  test("reject with a reason decides and rereads the queue", async () => {
    const { provider, store } = setup();
    await store.start();
    store.selectReview("sub_9");

    expect(await store.decide("sub_9", "reject", "Reads files it does not need.")).toBe(true);

    expect(provider.calls.find((call) => call.op === RegistryOps.reviewDecide)?.params).toEqual({
      id: "sub_9",
      decision: "reject",
      reason: "Reads files it does not need.",
      app: "pixel-works/clock-pane",
      version: "0.3.0",
    });
    expect(store.getSnapshot().registry.queue).toEqual([]);
    expect(store.getSnapshot().registry.reviewSelection).toBeUndefined();
    store.stop();
  });

  test("approve calls decide; a declined approve sheet keeps the selection and shows no error", async () => {
    const { provider, store } = setup();
    await store.start();
    store.selectReview("sub_9");
    provider.failNext(RegistryOps.reviewDecide, pageError("cmux.page.cancelled", "Declined"));

    expect(await store.decide("sub_9", "approve", "")).toBe(false);
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().registry.reviewSelection).toBe("sub_9");

    expect(await store.decide("sub_9", "approve", "")).toBe(true);
    const decided = provider.calls.filter((call) => call.op === RegistryOps.reviewDecide);
    expect(decided.at(-1)?.params).toEqual({
      id: "sub_9",
      decision: "approve",
      reason: "",
      app: "pixel-works/clock-pane",
      version: "0.3.0",
    });
    expect(store.getSnapshot().registry.queue).toEqual([]);
    store.stop();
  });
});

describe("registry wire helpers", () => {
  test("manifestSummary reads name, version, required and optional scopes", () => {
    expect(
      manifestSummary({
        name: "Board",
        version: "1.0.0",
        icon: { symbol: "square.grid.2x2" },
        scopes: { "workspace:read": "List workspaces." },
        optionalScopes: { "terminal:execute": "Send a command." },
      }),
    ).toEqual({
      name: "Board",
      version: "1.0.0",
      description: undefined,
      symbol: "square.grid.2x2",
      scopes: [
        { scope: "workspace:read", reason: "List workspaces.", optional: false },
        { scope: "terminal:execute", reason: "Send a command.", optional: true },
      ],
    });
    expect(manifestSummary("not a manifest").scopes).toEqual([]);
  });

  test("decodeFile keeps UTF-8 text and calls invalid UTF-8 or NUL bytes binary", () => {
    expect(decodeFile(btoa("héllo".replace("é", "Ã©")))).toEqual({ kind: "text", text: "héllo", size: 6 });
    expect(decodeFile(btoa("ÿþ"))).toEqual({ kind: "binary", size: 2 });
    expect(decodeFile(btoa("a\u0000b"))).toEqual({ kind: "binary", size: 3 });
    expect(decodeFile("%%%")).toEqual({ kind: "binary", size: 0 });
  });
});
