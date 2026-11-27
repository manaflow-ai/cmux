// The App Store page against the host's real event rules, and the deploy facts a listing and an
// Installed row show. The relay host below follows DaemonPageRelay (CmuxNextApp/Pages): a page
// stream `cmux.<ns>.<event>` is the daemon event `<ns>-<event>`, and the daemon delivers only the
// events its page's entry in cmux-tui/spec/page-router.json names; any other stream is
// `unknown_op`, and the page then reads once with no live updates.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import router from "../../../../cmux-tui/spec/page-router.json";
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import type { Strings } from "../shared/i18n";
import { AppDetailView } from "./AppDetailView";
import generated from "./generated/strings.json";
import { InstalledView } from "./InstalledView";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore, type AppsSnapshot } from "./store";
import type { InstalledApp } from "./types";
import { fromDetail, fromInstalled, type WireDetail } from "./wire";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};

/** The host relay: calls answer from the in-memory owner, streams follow the daemon's page list. */
class RelayHost implements PageClient {
  private readonly listeners = new Map<number, { event: string; deliver: (data: unknown, seq: number) => void }>();
  private next = 0;
  constructor(readonly owner: MockAppsProvider) {}

  call<R>(op: string, params: unknown): Promise<R> {
    return this.owner.call<R>(op, params);
  }

  handle(op: string, handler: PageHandler): () => void {
    return this.owner.handle(op, handler);
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    // The host's own streams (connection state) are not daemon events.
    if (stream.startsWith("cmux.page.")) return () => {};
    const event = stream.replace(/^cmux\./, "").replaceAll(".", "-");
    const heard: string[] = (router.pages as Record<string, { events: string[] }>).apps?.events ?? [];
    if (!stream.startsWith("cmux.") || !heard.includes(event)) throw pageError("cmux.protocol.unknown_op", stream);
    const id = ++this.next;
    this.listeners.set(id, { event, deliver: onEvent as (data: unknown, seq: number) => void });
    return () => void this.listeners.delete(id);
  }

  /** The daemon sends `event` on the page's relay connection. */
  daemon(event: string, payload: Record<string, unknown>): void {
    for (const listener of this.listeners.values()) if (listener.event === event) listener.deliver(payload, 1);
  }
}

/** Resolves when the store's snapshot satisfies `done` (each change is checked; no timer). */
function until(store: AppsStore, done: (snap: AppsSnapshot) => boolean): Promise<() => void> {
  return new Promise((resolve) => {
    const unsubscribe = store.subscribe(() => {
      if (done(store.getSnapshot())) resolve(unsubscribe);
    });
    if (done(store.getSnapshot())) resolve(unsubscribe);
  });
}

test("the open Installed tab shows an app the person installed from the CLI", async () => {
  const owner = new MockAppsProvider();
  const host = new RelayHost(owner);
  const store = new AppsStore(host, "#/installed");
  const ids = (snap: AppsSnapshot) => snap.installed.map((app) => app.id);
  const stopFirst = await until(store, (snap) => snap.catalogStatus === "ready" && !snap.loading);
  expect(ids(store.getSnapshot())).not.toContain("acme.caffeinate");

  // `cmux apps install acme.caffeinate`: the owner commits, then the daemon sends apps-changed.
  const row: InstalledApp = {
    id: "acme.caffeinate",
    name: "Caffeinate",
    version: "1.0.0",
    enabled: true,
    hidden: false,
    sandboxed: true,
    source: "user",
    tier: "unverified",
  };
  owner.installed[row.id] = row;
  host.daemon("apps-changed", { revision: 99, app: row.id });

  const stop = await until(store, (snap) => ids(snap).includes("acme.caffeinate"));
  expect(ids(store.getSnapshot())).toContain("acme.caffeinate");
  stop();
  stopFirst();
});

const helloDeploy: WireDetail = {
  app: "manaflow-ai/hello-deploy",
  name: "Hello Deploy",
  summary: "Install = deploy + pin.",
  publisher: "manaflow-ai",
  tier: "unverified",
  version: "1.0.0",
  icon: { symbol: "server.rack" },
  categories: ["developer-tools"],
  hide_only: false,
  install: null,
  scopes: [],
  deploy: { targets: ["self-hosted", "cloud-vm"], tenancy: ["user"] },
};

test("a deployed app's listing says where it runs", () => {
  const detail = fromDetail(helloDeploy);
  expect(detail.deploy?.targets).toEqual(["self-hosted", "cloud-vm"]);
  const snap = { selection: detail.id, detail, detailStatus: "ready", grants: {} } as unknown as AppsSnapshot;
  const html = renderToStaticMarkup(<AppDetailView snap={snap} store={{} as AppsStore} strings={strings} />);
  expect(html).toContain(en["store.detail.runsOn"]!);
  expect(html).toContain(en["store.deploy.target.selfHosted"]!);
  expect(html).toContain(en["store.deploy.target.cloudVM"]!);
});

test("a listing with no deploy block has no Runs on section", () => {
  const { deploy: _, ...plain } = helloDeploy;
  const detail = fromDetail(plain);
  const snap = { selection: detail.id, detail, detailStatus: "ready", grants: {} } as unknown as AppsSnapshot;
  const html = renderToStaticMarkup(<AppDetailView snap={snap} store={{} as AppsStore} strings={strings} />);
  expect(html).not.toContain(en["store.detail.runsOn"] ?? "store.detail.runsOn");
});

test("an Installed row shows its deployed instance and where it runs", () => {
  const row = fromInstalled({
    app: "manaflow-ai/hello-deploy",
    name: "Hello Deploy",
    tier: "unverified",
    hide_only: false,
    state: {
      installed: true,
      enabled: true,
      hidden: false,
      sandboxed: true,
      source: "user",
      version: "1.0.0",
      update: null,
    },
    grants: [],
    instance: { id: "inst_1", target: "self-hosted:ops@build-01", state: "running", url: "http://100.64.0.9:49153" },
  });
  expect(row.instance?.state).toBe("running");
  const snap = { installed: [row], grants: {}, logs: {}, updates: [] } as unknown as AppsSnapshot;
  const html = renderToStaticMarkup(<InstalledView snap={snap} store={{} as AppsStore} strings={strings} />);
  expect(html).toContain(strings.format("store.instance.running", "self-hosted:ops@build-01"));
});
