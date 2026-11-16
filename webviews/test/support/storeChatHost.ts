// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat drawn from the page's row store (rows/chatSource.ts) in the pane's dev entry, for the shift
// tests of row 6d: a stand-in acpmux that advertises the hold (`attach-hold-v1`) and answers its
// attach, and a stand-in host for the five `chat.rows.*` operations that feeds windows, pages and ops
// to the document's receiver (`window.cmuxChatRows.receive`) as change strings (rows/wire.ts).
//
// The dev entry routes the page's `postNative` through the dev host's `cmuxPage` handler
// (dev-host/host.ts `installDevHost`), which installs its own only where none is: this one is put
// there first and passes every call but `chat.rows.*` on to it, as agent-pane-side-command.test.ts
// does. The dev host keeps the reading place (`chat.scrollAnchor`) in `cmuxDevHostKept`, which this
// seeds, so a second page opens at the place the first one left.
//
// Every painted frame is read for A0's shift: "a visible row's top moves more than 1 px between two
// painted frames with no input since the last one, and no visible row above it changed its own
// height in that frame."
import type { Page } from "playwright";
import type { ChatRow } from "../../src/agent-session/acpmux/rows/wire";

/// The daemon's capability for the hold (rows/chatSource.ts `HOLD_ATTACH_CAPABILITY`). Not imported:
/// chatSource.ts reaches the whole pane client (adapter.ts imports direct.ts).
export const HOLD_ATTACH = "attach-hold-v1";
const START_SECONDS = Date.UTC(2026, 10, 16, 9, 0, 0) / 1000;

/// A chat of `turns` finished turns as the daemon encodes its rows, ids 1..3*turns: each turn a
/// prompt (`user`), a reply of one to a dozen lines, some in paragraphs (`text`), and its end
/// (`notice` turn_result). `est` is the row's lines, the store's height unit.
export function storeChatRows(turns: number): ChatRow[] {
  const rows: ChatRow[] = [];
  for (let turn = 1; turn <= turns; turn++) {
    const prompt = rows.length + 1;
    rows.push({
      id: prompt,
      rev: 1,
      kind: "user",
      turn: prompt,
      at: START_SECONDS + prompt,
      open: false,
      body: { content: `Question ${turn}: what changed on this head?` },
      est: 2,
    });
    const sentences = 1 + ((turn * 37) % 11);
    const paragraphs = 1 + ((turn * 13) % 3);
    const text = Array.from({ length: paragraphs }, (_, paragraph) =>
      Array.from(
        { length: Math.max(1, Math.round(sentences / paragraphs)) },
        (_, n) => `Answer ${turn}.${paragraph + 1}.${n + 1}: the checks on the merged head ran again and passed.`,
      ).join(" "),
    ).join("\n\n");
    rows.push({
      id: prompt + 1,
      rev: 1,
      kind: "text",
      turn: prompt,
      at: START_SECONDS + prompt + 1,
      open: false,
      body: { text },
      est: Math.ceil(text.length / 90) + paragraphs,
    });
    rows.push({
      id: prompt + 2,
      rev: 1,
      kind: "notice",
      turn: prompt,
      at: START_SECONDS + prompt + 2,
      open: false,
      body: { notice: "turn_result", status: "completed" },
      est: 1,
    });
  }
  return rows;
}

/// The row ids of the replies (`text` rows): the second of each turn's three.
export const isReply = (id: number) => id % 3 === 2;

/// The chat's list row, as `_acpmux/watch` gives it.
export function storeChatSummary(chat: string, turns: number) {
  return {
    sessionId: chat,
    cwd: "/home/dev/project",
    title: "Store chat",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: turns,
    updatedAt: (START_SECONDS + 3 * turns) * 1000,
    lastSeq: 1,
  };
}

/// The stand-in acpmux: it names the hold among its capabilities, lists the one chat and answers
/// the hold attach with the session and no page (direct.ts `attachWatched`: a hold reads none).
/// `attaches` is every `_acpmux/attach`'s params, to prove the chat attached as the hold.
export function storeChatDaemon(summary: ReturnType<typeof storeChatSummary>) {
  const methods: string[] = [];
  const attaches: Record<string, unknown>[] = [];
  const answer = (method: string, params: Record<string, unknown>): unknown => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [], capabilities: [HOLD_ATTACH] } },
        };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        attaches.push(params);
        return params.hold === true
          ? { session: summary, lastSeq: summary.lastSeq }
          : { session: summary, events: [], hasMore: false, lastSeq: summary.lastSeq };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: summary.lastSeq };
      default:
        return null;
    }
  };
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        methods.push(message.method);
        if (message.id === undefined) return;
        const result = answer(message.method, message.params ?? {});
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
      },
    },
  });
  return {
    endpoint: `ws://127.0.0.1:${server.port}/`,
    methods,
    attaches,
    stop: () => server.stop(true),
  };
}

export type KeptPlace = { rowId: string; offset: number };

export type StoreHostOptions = {
  chat: string;
  rows: ChatRow[];
  /// The rows a window holds (acpmux-client chat.rs MAX_CHAT_ROWS) and a page gives.
  windowRows: number;
  pageRows: number;
  /// Each page before or after lands this late (a page of turns at once).
  pageDelayMs: number;
  /// The reading place the host kept for the chat (a restart), or none.
  kept: KeptPlace | null;
};

/// A `chat.rows.*` the page posted, with the painted frame it came after.
export type RowsPost = { method: string; params: Record<string, any>; frame: number };
/// One shift as A0 defines it.
export type Shift = { frame: number; rowId: string; moved: number; top: number };
export type ShiftTake = { frames: number; shifts: Shift[]; count: number; firstSeen: Record<string, number> };

/// The page side; runs in the page before its scripts, so it closes over nothing. Needs
/// installPaintedFrames first (`cmuxAfterPaint`).
function storeChatPage(options: StoreHostOptions) {
  const w = window as any;
  w.cmuxDevHostKept = { tails: {}, anchors: options.kept ? { [options.chat]: options.kept } : {} };
  const rows = options.rows;
  const last = rows.length;
  // Row ids are 1..N in order: a row's index is its id less one.
  const rowAt = (id: number) => rows[id - 1];

  // The shift watch: every painted frame's visible rows, compared with the frame before.
  type Box = { top: number; height: number };
  const watch = {
    frame: 0,
    inputs: 0,
    frames: 0,
    prev: null as null | { boxes: Map<string, Box>; inputs: number },
    shifts: [] as { frame: number; rowId: string; moved: number; top: number }[],
    count: 0,
    firstSeen: new Map<string, number>(),
  };
  // A person's input: what moves rows on purpose. The wheel driver below counts its own.
  for (const kind of ["wheel", "keydown", "pointerdown", "mousedown", "touchstart", "touchmove"])
    addEventListener(kind, () => (watch.inputs += 1), { capture: true, passive: true });
  const visibleBoxes = () => {
    const boxes = new Map<string, Box>();
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    // Rows the transcript holds hidden while it seeks its place are not on screen.
    if (!scroller || scroller.hasAttribute("data-seeking")) return boxes;
    const view = scroller.getBoundingClientRect();
    for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
      const box = row.getBoundingClientRect();
      if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
      boxes.set(row.dataset.rowId!, { top: box.top - view.top, height: box.height });
    }
    return boxes;
  };
  window.cmuxAfterPaint(() => {
    watch.frame += 1;
    watch.frames += 1;
    const boxes = visibleBoxes();
    for (const id of boxes.keys()) if (!watch.firstSeen.has(id)) watch.firstSeen.set(id, watch.frame);
    const prev = watch.prev;
    if (prev && prev.inputs === watch.inputs) {
      // The rows on screen in both frames, top first: a row is excused while one above it changed
      // its own height this frame.
      const shared = [...boxes].filter(([id]) => prev.boxes.has(id));
      shared.sort((a, b) => prev.boxes.get(a[0])!.top - prev.boxes.get(b[0])!.top);
      let aboveResized = false;
      for (const [id, box] of shared) {
        const before = prev.boxes.get(id)!;
        const moved = box.top - before.top;
        if (Math.abs(moved) > 1 && !aboveResized) {
          watch.count += 1;
          if (watch.shifts.length < 40) watch.shifts.push({ frame: watch.frame, rowId: id, moved, top: before.top });
        }
        if (Math.abs(box.height - before.height) > 1) aboveResized = true;
      }
    }
    watch.prev = { boxes, inputs: watch.inputs };
  });

  // The stand-in host's rows.
  const host = {
    sid: undefined as string | undefined,
    batch: 0,
    cursor: 0,
    seq: 0,
    edition: 1,
    pageDelayMs: options.pageDelayMs,
    pending: 0,
    posts: [] as { method: string; params: Record<string, unknown>; frame: number }[],
    errors: [] as string[],
  };
  const send = (changes: unknown[]) => {
    const receiver = w.cmuxChatRows as { receive(event: { batch: number; changes: string[] }): void } | undefined;
    if (!receiver) {
      host.errors.push("no window.cmuxChatRows when the host sent a batch");
      return;
    }
    receiver.receive({ batch: ++host.batch, changes: changes.map((change) => JSON.stringify(change)) });
  };
  const stretch = (from: number, to: number) => rows.slice(Math.max(1, from) - 1, Math.min(last, to));
  /// The window the core sends for an anchor: the newest rows, or rows around one.
  const windowFor = (anchor: unknown) => {
    const around = (anchor as { rowId?: unknown } | null)?.rowId;
    const at = typeof around === "number" && around >= 1 && around <= last ? around : undefined;
    const from = at === undefined ? last - options.windowRows + 1 : at - Math.floor(options.windowRows / 2);
    const held = stretch(Math.max(1, from), Math.max(1, from) + options.windowRows - 1);
    return {
      sid: host.sid,
      cursor: ++host.cursor,
      edition: host.edition,
      rows: held,
      hasBefore: held[0]!.id > 1,
      hasAfter: held[held.length - 1]!.id < last,
      seen: last,
    };
  };
  const pageFor = (params: Record<string, any>) => {
    // The page of turns: none held, so the rail draws no earlier prompts.
    if (params.turns)
      return { sid: params.sid, edition: host.edition, rows: [], hasBefore: false, hasAfter: false, turns: true };
    if (typeof params.before === "number") {
      const held = stretch(params.before - options.pageRows, params.before - 1);
      return {
        sid: params.sid,
        edition: host.edition,
        rows: held,
        hasBefore: (held[0]?.id ?? 1) > 1,
        hasAfter: params.before <= last,
      };
    }
    const held = stretch(params.after + 1, params.after + options.pageRows);
    return {
      sid: params.sid,
      edition: host.edition,
      rows: held,
      hasBefore: params.after >= 1,
      hasAfter: (held[held.length - 1]?.id ?? last) < last,
    };
  };
  const answer = (method: string, params: Record<string, any>): unknown => {
    host.posts.push({ method, params: JSON.parse(JSON.stringify(params)), frame: watch.frame });
    switch (method) {
      case "chat.rows.open": {
        host.sid = String(params.sid);
        const first = windowFor(params.anchor);
        // The core's first window comes as its own batch once the sub is open.
        setTimeout(() => send([{ kind: "chatWindow", replaces: true, window: first }]), 0);
        return { sid: params.sid };
      }
      case "chat.rows.page": {
        const page = pageFor(params);
        host.pending += 1;
        // fixed-wait: a page's latency, as from a busy daemon, is the condition under test.
        setTimeout(
          () => {
            host.pending -= 1;
            send([{ kind: "chatPage", page }]);
          },
          params.turns ? 0 : host.pageDelayMs,
        );
        return null;
      }
      default:
        // chat.rows.close, chat.rows.taken, chat.rows.blob: nothing to send.
        return null;
    }
  };

  // In front of the dev host's `cmuxPage` (installDevHost keeps a handler already there).
  const handlers: Record<string, unknown> = {};
  let devHost: { postMessage(message: unknown): Promise<unknown> } | undefined;
  Object.defineProperty(handlers, "cmuxPage", {
    configurable: true,
    enumerable: true,
    get: () =>
      devHost && {
        postMessage(message: { t?: string; id?: number; op?: string; params?: Record<string, unknown> }) {
          const prefix = "cmux.agent.";
          if (message?.t === "call" && typeof message.op === "string" && message.op.startsWith(`${prefix}chat.rows.`)) {
            try {
              return Promise.resolve({
                t: "ok",
                id: message.id,
                value: answer(message.op.slice(prefix.length), message.params ?? {}),
              });
            } catch (error) {
              host.errors.push(String(error));
              return Promise.resolve({ t: "err", id: message.id, code: "chat.rows.failed", message: String(error) });
            }
          }
          return devHost!.postMessage(message);
        },
      },
    set: (value: typeof devHost) => {
      devHost = value;
    },
  });
  w.webkit = { messageHandlers: handlers };

  w.__storeChat = {
    host,
    /// A window from the core: at the end, or around a row.
    sendWindow(anchor: unknown, replaces: boolean) {
      send([{ kind: "chatWindow", replaces, window: windowFor(anchor) }]);
    },
    /// A settled row changed after (a rev up): its newer text, a few lines taller.
    patch(id: number, more: string) {
      const row = rowAt(id)!;
      const body = row.body as { text?: string };
      const text = `${body.text ?? ""}\n\n${more}`;
      const next = { ...row, rev: row.rev + 1, body: { ...body, text }, est: row.est + 4 };
      rows[id - 1] = next;
      send([{ kind: "chatOp", sid: host.sid, replay: false, op: { op: "patch", seq: ++host.seq, row: next } }]);
    },
    /// The shifts since the last take, and when each row id was first seen on screen.
    take() {
      const taken = {
        frames: watch.frames,
        shifts: watch.shifts.splice(0),
        count: watch.count,
        firstSeen: Object.fromEntries(watch.firstSeen),
      };
      watch.frames = 0;
      watch.count = 0;
      return taken;
    },
    /// Wheels the transcript by `steps` px, one step a frame, through the reader's handlers (a
    /// synthetic event has no default, so the step's scroll is applied here). Resolves once the
    /// last step's frame painted.
    wheel(steps: number[]) {
      return new Promise<void>((resolve) => {
        let next = 0;
        window.cmuxAfterPaint(
          () => {
            if (next < steps.length) return true;
            resolve();
            return false;
          },
          () => {
            if (next >= steps.length) return;
            const asked = steps[next++]!;
            watch.inputs += 1;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const wheel = new WheelEvent("wheel", { deltaY: asked, deltaMode: 0, bubbles: true, cancelable: true });
            if (scroller.dispatchEvent(wheel)) scroller.scrollTop += asked;
          },
        );
      });
    },
    /// Until no page is out, no finite animation runs, and three painted frames show the same rows
    /// at the same places.
    async settle() {
      for (let tries = 0; tries < 200; tries++) {
        const finite = () =>
          document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await new Promise<void>((resolve) => {
          let lastKey = "";
          let still = 0;
          window.cmuxAfterPaint(() => {
            const key = [...visibleBoxes()].map(([id, box]) => `${id}:${Math.round(box.top)}`).join(",");
            still = key === lastKey ? still + 1 : 0;
            lastKey = key;
            if (still < 2) return true;
            resolve();
            return false;
          });
        });
        if (host.pending === 0 && finite().every((animation) => animation.playState !== "running")) return;
      }
      throw new Error("the transcript did not settle");
    },
    /// The rows on screen, top first, with their tops from the view's.
    visible() {
      return [...visibleBoxes()].sort((a, b) => a[1].top - b[1].top).map(([id, box]) => ({ id, ...box }));
    },
    /// Where the host keeps the chat's reading place (dev-host/host.ts `keptReply`).
    kept() {
      return (w.cmuxDevHostKept.anchors[options.chat] ?? null) as { rowId: string | null; offset: number } | null;
    },
  };
}

/// Installs the stand-in host and the shift watch on `page`, before it loads.
export async function installStoreChatHost(page: Page, options: StoreHostOptions): Promise<void> {
  await page.addInitScript(storeChatPage, options);
}

type StoreChatWindow = {
  __storeChat: {
    host: { posts: RowsPost[]; errors: string[]; pending: number };
    sendWindow(anchor: unknown, replaces: boolean): void;
    patch(id: number, more: string): void;
    take(): ShiftTake;
    wheel(steps: number[]): Promise<void>;
    settle(): Promise<void>;
    visible(): { id: string; top: number; height: number }[];
    kept(): { rowId: string | null; offset: number } | null;
  };
};

/// The page's side, from the test.
export function storeChat(page: Page) {
  return {
    posts: () => page.evaluate(() => (window as unknown as StoreChatWindow).__storeChat.host.posts),
    errors: () => page.evaluate(() => (window as unknown as StoreChatWindow).__storeChat.host.errors),
    take: () => page.evaluate(() => (window as unknown as StoreChatWindow).__storeChat.take()),
    settle: () => page.evaluate(() => (window as unknown as StoreChatWindow).__storeChat.settle()),
    visible: () => page.evaluate(() => (window as unknown as StoreChatWindow).__storeChat.visible()),
    kept: () => page.evaluate(() => (window as unknown as StoreChatWindow).__storeChat.kept()),
    wheel: (steps: number[]) =>
      page.evaluate((steps) => (window as unknown as StoreChatWindow).__storeChat.wheel(steps), steps),
    sendWindow: (anchor: unknown, replaces: boolean) =>
      page.evaluate(
        ({ anchor, replaces }) => (window as unknown as StoreChatWindow).__storeChat.sendWindow(anchor, replaces),
        { anchor, replaces },
      ),
    patch: (id: number, more: string) =>
      page.evaluate(({ id, more }) => (window as unknown as StoreChatWindow).__storeChat.patch(id, more), { id, more }),
  };
}

/// The page asks for rows (`chat.rows.page`) other than the page of turns.
export const rowPages = (posts: readonly RowsPost[]) =>
  posts.filter((post) => post.method === "chat.rows.page" && !post.params.turns);
