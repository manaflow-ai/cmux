// l10n-allow-file: test fixture machine names, not shipped UI.
//
// Session Info's machine row names the machine the chat's agent runs on, through every hop between
// this Mac and it (Leo, 2026-11-07, on a huge-blue chat whose Session Info said "cosmic-gray · Local":
// "hmm is the session info not accurately describing machine provenance?" and "yeah this is def a bit
// of a miss"). The chat is opened through a fake acpmux that answers as the real one does: a peer's
// chat is listed with `peer`, and its attach reply names the peer at its top level only, its
// `session` being the peer daemon's own detail (acpmux server/peer_forward.rs, mesh_read_tests.rs).
//
//   - a chat on peer huge-blue, opened on cosmic-gray, names huge-blue, never Local;
//   - a chat on this Mac names this Mac, Local;
//   - a chat two hops away (the app's wire to another machine's acpmux, the chat on that machine's
//     peer) names the far machine; one on the wire's own machine names that machine, never this Mac.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { EnvironmentSection } from "../src/agent-session/acpmux/session-info/EnvironmentSection";
import { translate } from "../src/agent-session/acpmux/i18n";
import { environmentSection } from "../src/agent-session/acpmux/session-info/native/environment";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { settleReact } from "./support/domTeardown";

const SESSION = "menubar-chats-menu";
const THIS_MAC = "cosmic-gray";
const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeAll(() => {
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
});

afterAll(async () => {
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

type Message = { id?: number; method: string; params?: Record<string, unknown> };

/// The acpmux the page talks to (`origin`), listing one chat: on its peer `peer`, or its own when
/// none. `machine` is the hostname of the daemon that runs the chat (acpmux views.rs `machine`).
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;

  constructor(
    readonly origin: "local" | "remote",
    readonly peer: string | undefined,
    readonly machine: string,
  ) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  /// The chat's row as the page's acpmux lists it: a peer's row names the peer (hub/peers.rs).
  row() {
    return {
      sessionId: SESSION,
      name: this.peer ? `${this.peer}/${SESSION}` : SESSION,
      cwd: "/home/dev/cmux",
      title: "Menubar chats menu",
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: 1,
      createdAt: 1,
      ...(this.peer ? { peer: this.peer } : {}),
    };
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id !== undefined) queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  private reply(id: number | undefined, result: unknown) {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id, result }) });
  }

  private answer(message: Message): void {
    if (message.method === "initialize")
      return this.reply(message.id, {
        protocolVersion: 1,
        _meta: { acpmux: { origin: this.origin, extensions: [], operations: [] } },
      });
    if (message.method === "_acpmux/watch" || message.method === "_acpmux/sessions")
      return this.reply(message.id, { sessions: [this.row()] });
    if (message.method === "_acpmux/attach") {
      // The owning daemon's detail: no `peer`, its own name as `machine` (views.rs session_detail).
      const { peer: _peer, name: _name, ...own } = this.row();
      return this.reply(message.id, {
        session: { ...own, name: SESSION, machine: this.machine },
        events: [],
        hasMore: false,
        lastSeq: 0,
        ...(this.peer ? { peer: this.peer } : {}),
      });
    }
    this.reply(message.id, {});
  }
}

const flush = async () => {
  for (let pass = 0; pass < 12; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

let live: AcpmuxDirectClient[] = [];
let root: Root | undefined;
afterEach(async () => {
  for (const client of live) client.close();
  live = [];
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetKeptTailsForTests();
});

/// Opens the chat through `daemon` and draws Session Info's machine row as the App does: this Mac's
/// name from the handshake, the peers' kinds and the page's route from the snapshot.
async function machineRow(
  daemon: Daemon,
): Promise<{ snapshot: AcpmuxSnapshot; row: (string | undefined)[]; native: (string | undefined)[] }> {
  resetKeptTailsForTests();
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://acpmux.invalid/",
      token: "t",
      sessionId: SESSION,
    },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  live.push(client);
  await flush();
  const snapshot = drawn.at(-1)!;
  const container = dom.window.document.getElementById("root")!;
  root ??= createRoot(container);
  await act(async () =>
    root!.render(
      <EnvironmentSection
        summary={snapshot.summary}
        machineName={THIS_MAC}
        peerKinds={{ "huge-blue": "ssh", "far-box": "ssh" }}
        place={snapshot.origin ? { origin: snapshot.origin } : {}}
      />,
    ),
  );
  const li = container.querySelector<HTMLElement>("li[data-machine]")!;
  // The native panel's machine row (NativeSessionInfo.tsx) draws from the same helper.
  const native = environmentSection(
    {
      summary: snapshot.summary,
      machineName: THIS_MAC,
      peerKinds: { "huge-blue": "ssh", "far-box": "ssh" },
      place: snapshot.origin ? { origin: snapshot.origin } : {},
    },
    new NativeInfoActions(),
    translate,
  )?.rows.find((row) => row.id === "machine");
  return {
    snapshot,
    native: [native?.title, native?.trailing],
    row: [
      li.dataset.machine,
      li.querySelector(".acpmux-session-info-row__name")?.textContent ?? undefined,
      li.querySelector("[data-machine-kind]")?.textContent ?? undefined,
    ],
  };
}

test("a chat on peer huge-blue, opened on this Mac, names huge-blue, not this Mac or Local", async () => {
  const { snapshot, row, native } = await machineRow(new Daemon("local", "huge-blue", "huge-blue"));
  expect(snapshot.summary?.sessionId).toBe(SESSION);
  // The attach's detail keeps the peer its reply named: every reader of the summary sees it.
  expect(snapshot.summary?.peer).toBe("huge-blue");
  expect(row).toEqual(["ssh", "huge-blue", translate("composer.envSSH")]);
  expect(native).toEqual(["huge-blue", translate("composer.envSSH")]);
});

test("a chat on this Mac names this Mac, Local", async () => {
  const { snapshot, row, native } = await machineRow(new Daemon("local", undefined, THIS_MAC));
  expect(snapshot.summary?.peer).toBeUndefined();
  expect(row).toEqual(["local", THIS_MAC, translate("composer.envLocal")]);
  expect(native).toEqual([THIS_MAC, translate("composer.envLocal")]);
});

test("a chat two hops away names the far machine; one on the remote route's own machine names it", async () => {
  // This Mac -> huge-blue's acpmux (the app's wire, origin remote) -> its peer far-box, where it runs.
  const far = await machineRow(new Daemon("remote", "far-box", "far-box"));
  expect(far.row).toEqual(["ssh", "far-box", translate("composer.envSSH")]);
  expect(far.native).toEqual(["far-box", translate("composer.envSSH")]);
  // This Mac -> huge-blue's acpmux, the chat huge-blue's own: huge-blue, never this Mac.
  const remote = await machineRow(new Daemon("remote", undefined, "huge-blue"));
  expect(remote.row).toEqual(["ssh", "huge-blue", translate("composer.envSSH")]);
  expect(remote.native).toEqual(["huge-blue", translate("composer.envSSH")]);
});
