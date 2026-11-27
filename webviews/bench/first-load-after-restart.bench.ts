// l10n-allow-file: bench fixture prompts and replies, and benchmark output, not shipped UI.
// A chat's first load after a restart, frame by frame (Leo, 2026-11-09, after "restart to update" on the
// nightly: "the chat loading kinda flickered in and out and layout shifted... our first loads aren't
// perfected yet? at least after restart?"). A first load is a state transition: its first painted frame
// should be its final state, it never blanks a pane that had content, and nothing in it moves.
//
// After an update the app restarts acpmux, and the chat's page boots while acpmux is not up yet. The page
// draws the chat's saved copy in its first frame (chatSnapshot/boot.ts, served as `__snapshot/chat.js`),
// and the host's kept tail (`chat.tail.get`) may draw rows under it while the socket connects (direct.ts
// `drawTailWhileConnecting`). Then the first handshake fails quietly (hostRetry.ts `hostIsReconnecting`)
// and the page retries about every 2 s until acpmux answers. This bench replays that with the production
// pane (a vite build of the pane's dev entry, as chat-open.bench.ts builds it) served as the app serves
// it: one linked `pane.css` (id cmux-pane-styles) with every sheet and the copy's `pane-copy.css` beside it,
// and the copy's two scripts before the module.
//
// Each round, per mode:
//   warm      a fresh context opens the TURNS-turn chat with acpmux up, waits until the newest answer
//             painted and the page was quiet SETTLE_QUIET_MS, and writes the copy (chatSnapshot/capture.ts).
//   relaunch  a new (cold) context opens the same chat, served that copy and the chat's kept tail by the
//             host, with acpmux unavailable for ACPMUX_DOWN_MS from navigation:
//               down       the socket is refused (HTTP 503, no upgrade), as while acpmux restarts;
//               slow-init  the socket opens but `initialize` answers only then, as a slow daemon does;
//               native-ready       native ready waits, with the saved HTML copy;
//               native-ready-tail  native ready waits, no HTML copy, retained event tail only;
//               refused            native ready refuses with a coded error (the line with Retry above the
//                                  composer, HostError.tsx) until then, with the copy;
//               refused-no-copy    the same with no copy (one written at another size or theme, or by
//                                  another build): the live page draws the kept tail under that line.
//             Every painted frame until ACPMUX_DOWN_MS + 4000 ms is read after it painted
//             (test/support/paintedFrames.ts) from the layer on top: the copy's shadow root while it
//             shows, else the live page.
// Two more modes time a hidden chat whose page was released (HiddenChatPages' idle release; Leo 2026-11-14: "if
// something isn't drawn/is completely proven idle then dont bother taking memory") and opens again, with acpmux up:
//               reopen          the page is built in the warm renderer (one renderer per site, another chat page open
//                               in it, as the app's other chats are), served the copy its hide wrote and the kept tail;
//               reopen-no-copy  the same with no copy and no tail: a page built from nothing.
//               reopen-spare    the prewarmed spare page (a connected New Tab page in the warm renderer) takes the
//                               chat (AgentPaneView.adoptSession's `acpmux-session-adopt`, carrying the kept tail and
//                               the place); timed from that event, not from the spare's own load.
//             Not in MODE=all: MODE=reopen (or reopen-no-copy, reopen-spare) runs one; MODE=reopen-both runs reopen
//             and reopen-no-copy, MODE=reopen-all all three; the rounds' p50 and p95 are printed too.
//             refused and refused-no-copy are not in MODE=all either: MODE=refused, refused-no-copy or nightly.
// What a NIGHTLY restart has that the default rounds do not (Leo, 2026-11-16, cosmic-gray: "the chat appeared
// in 3 seconds and then it said something went wrong with a retry button just above the composer ... and then
// it layout shifted as it drew and tried to settle"), each a knob:
//   CONTENT=rich       replies with code blocks, tables whose cells wrap and long paragraphs (the height
//                      index estimates them: model.ts), not one line each;
//   HEIGHT_DELTA=N     the relaunch's window is N px shorter than the one the copy was written at (within
//                      shared.ts SNAPSHOT_HEIGHT_SLACK, so the copy still draws): a tab row or toolbar that
//                      came back at another height;
//   PAGES=N            N-1 other restored chat pages load beside the recorded one, at once.
// MODE=nightly runs down, refused and refused-no-copy (RUNNING, CONTENT, HEIGHT_DELTA, PAGES as given).
// Per round (bench/firstLoadFrames.ts): blank frames after the first content, shift frames (the composer
// or the bottom-most row in view moved, or that row was replaced), when the final state first painted,
// when content first painted; and the layout-shift entries' sum.
//   [MODE=all|nightly|down|slow-init|native-ready|native-ready-tail|refused|refused-no-copy] [RUNNING=1]
//     [CONTENT=rich] [HEIGHT_DELTA=28] [PAGES=6] [CPU=4] [ENGINE=webkit] [ROUNDS=3] [TURNS=120] [ACPMUX_DOWN_MS=3000] [GATE=1] [TRACE=1] [SOURCES=1] \
//     bun bench/first-load-after-restart.bench.ts
// GATE=1 fails if content takes over 2 s, blanks, shifts, or never becomes live. TRACE=1 prints each
// mode's worst round frame by frame. SOURCES=1 prints each round's layout-shift entries with the boxes
// that moved (from and to: x, y, width, height). One `FIRST_LOAD_JSON {...}` line carries every number.
// Restart to settled (Leo, 2026-11-22: "you guys need to be able to simulate the update/restart and the connection
// speed and what is actually displayed"): LINK=local|rtt50|rtt200|throttled (bench/link-profiles.json) puts the
// bridge's socket on a simulated link (bench/linkModel.ts: the connect costs a round trip, each frame waits for its
// pipe and half a round trip); the copy and the kept tail are the app's own and do not cross it. Each mode then
// prints `RESTART_SETTLED_JSON {...}` (bench/restartSettled.ts): first content, settled (the live chat showing the
// newest answer with nothing in view moving after), shifts after first content and how far they moved, and the
// bytes the daemon sent. scripts/measure/restart-settled-linux.sh runs it per link beside the terminal's reattach.
// FIXTURE=replay REPLAY=FILE serves a recorded (sanitized) chat instead, a coordinator's notices and all.
// FIXTURE=work gives every turn its work (thoughts, tool calls, notices), which a finished turn folds: the
// settled line then also counts rows that showed and are gone by the last frame (goneRows, goneFrames).
// NO_TAIL=1 serves no kept tail; NO_COPY=1 no saved copy (with NO_TAIL=1, an update's revive: nothing kept); WIRE_TRACE=1 prints each daemon request as it arrives (ms from the round's start).
// ROWS_WINDOW=FILE puts the page on the row store (v2): the daemon advertises attach-hold-v1 and the host answers
// `chat.rows.open` with this window (acpmux-core's `bench_first_window` writes it for the same REPLAY), one link round
// trip after the open. The settled line's rowStore says every round drew from it. A chat on the store keeps no
// host tail (direct.ts `rememberCurrentTail`), so none is served. ROWS_ENDED=FILE is the same chat's window once
// its open turn ended, sent ROWS_ENDED_MS (1000) after the first in its place: the rows the reload drew that the
// ended turn folds away are then goneRows.
// PANE_SOURCE_REF=<sha> loads that immutable App/direct/hostRetry revision under this same harness for a baseline.
/// <reference types="bun" />
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { chromium, webkit } from "./browsers";
import type { Browser, Page } from "playwright";
import {
  PAGE_STYLE_ID,
  SNAPSHOT_BOOT_GLOBAL,
  SNAPSHOT_GLOBAL,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_THEME_GLOBAL,
  type ChatSnapshot,
} from "../src/agent-session/acpmux/chatSnapshot/shared";
import { snapshotCss } from "../scripts/agent-pane/snapshotCss.mjs";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { classifyFrames, type FrameMetrics, type FrameRail, type FrameRecord } from "./firstLoadFrames";
import { perfRow } from "./perfRow";
import { newestPage } from "./daemonPage";
import { connectDelay, LinkPipe, linkProfile } from "./linkModel";
import { restartSettled, goneRows, liveTurnLine } from "./restartSettled";
import { longRun } from "../src/agent-session/acpmux/sim/scenarios";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { hostTailOf, keptEvents } from "../src/agent-session/acpmux/tailCache";
import type { EventRecord } from "../src/agent-session/acpmux/direct";

const MODES_ALL = ["down", "slow-init", "native-ready", "native-ready-tail"] as const;
const REOPEN_MODES = ["reopen", "reopen-no-copy", "reopen-spare"] as const;
const REFUSED_MODES = ["refused", "refused-no-copy"] as const;
type Mode = (typeof MODES_ALL)[number] | (typeof REOPEN_MODES)[number] | (typeof REFUSED_MODES)[number];
const MODE = process.env.MODE ?? "all";
const NIGHTLY_MODES: readonly Mode[] = ["down", ...REFUSED_MODES];
const NAMED: readonly string[] = [
  ...MODES_ALL,
  ...REOPEN_MODES,
  ...REFUSED_MODES,
  "reopen-both",
  "reopen-all",
  "nightly",
];
if (MODE !== "all" && !NAMED.includes(MODE)) throw new Error(`MODE must be all, ${NAMED.join(" or ")}`);
const MODES: readonly Mode[] =
  MODE === "all"
    ? MODES_ALL
    : MODE === "reopen-both"
      ? ["reopen", "reopen-no-copy"]
      : MODE === "reopen-all"
        ? REOPEN_MODES
        : MODE === "nightly"
          ? NIGHTLY_MODES
          : [MODE as Mode];
const isRefused = (mode: Mode) => (REFUSED_MODES as readonly string[]).includes(mode);
const isReopen = (mode: Mode) => (REOPEN_MODES as readonly string[]).includes(mode);
const ROUNDS = Number(process.env.ROUNDS ?? 3);
const TURNS = Number(process.env.TURNS ?? 120);
const DOWN_MS = Number(process.env.ACPMUX_DOWN_MS ?? 3000);
for (const [name, value] of [
  ["ROUNDS", ROUNDS],
  ["TURNS", TURNS],
  ["ACPMUX_DOWN_MS", DOWN_MS],
] as const)
  if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number`);
/// LINK=local|rtt50|rtt200|throttled (bench/link-profiles.json): the link between the app and the daemon. The
/// bridge's socket goes through it (bench/linkModel.ts): its connect costs a round trip, and every frame each way
/// waits for the pipe and half a round trip. The copy and the kept tail are the app's own, so they do not cross it.
const LINK_NAME = process.env.LINK ?? "local";
const NO_TAIL = process.env.NO_TAIL === "1";
/// NO_COPY=1 serves no saved copy in any mode: an update's relaunch, whose copy another build wrote, so the page
/// refuses it. With NO_TAIL=1 that is a revive after an update: nothing of the chat is in the page or the host.
const NO_COPY = process.env.NO_COPY === "1";
const WIRE_TRACE = process.env.WIRE_TRACE === "1";
const LINK = linkProfile(LINK_NAME);
/// LINK_ZLIB=1: the link compresses large lines (bench/linkModel.ts `zlibWire`: 16 KiB or more, zlib level 1, both
/// directions), as the machine link that carries a chat on another machine does once both ends support it.
const LINK_ZLIB = process.env.LINK_ZLIB === "1";
/// How long each relaunch is recorded from navigation: acpmux's absence, the page's next retry (at most
/// 2 s apart while it recovers, hostRetry.ts `nextRetryDelay`), the attach and the settle after it.
/// A slow LINK adds its round trips and the attach's bytes on the wire: ten round trips and 6 s more on a
/// throttled one.
const RECORD_MS = DOWN_MS + 4000 + 10 * LINK.rttMs + (LINK.bps > 0 ? 6000 : 0);
/// A refused handshake backs off to 30 s (hostRetry.ts `REFUSED_RETRY_MAX_MS`): 250 ms doubling with jitter,
/// so the ask after DOWN_MS can come up to that long again later.
const recordMs = (mode: Mode) => (isRefused(mode) ? 2 * DOWN_MS + 5000 : RECORD_MS);
/// The warm page is settled once the newest answer painted and nothing in view changed this long.
const SETTLE_QUIET_MS = 600;
/// How the page reaches acpmux. `bridge` (the default) is the app's: the host owns the socket
/// (bridgeSocket.ts, Swift AgentPaneTransport) and the page asks it to open one (`transport.open`); here
/// this process opens it. `websocket` is the browser dev slot's: the page opens a WebSocket itself, and
/// Chromium delays a renderer's WebSocket opens once it has many failed ones (network
/// WebSocketPerProcessThrottler: 1-5 s × 2^min(failed / (succeeded + 1), 16) / 65536, counted over
/// 2-4 min), which the app's transport does not have.
const TRANSPORT = process.env.TRANSPORT ?? "bridge";
if (TRANSPORT !== "bridge" && TRANSPORT !== "websocket") throw new Error("TRANSPORT must be bridge or websocket");
const BRIDGE = TRANSPORT === "bridge";
if (!BRIDGE && (LINK.rttMs > 0 || LINK.bps > 0)) throw new Error("LINK needs TRANSPORT=bridge");
const GATE = process.env.GATE === "1";
const TRACE = process.env.TRACE === "1";
/// PROFILE=1 (MODE=reopen-spare): a CPU profile of each adopt, from the event to the newest answer drawn,
/// printed as the functions with the most self time over all rounds (an unminified build). In a relaunch mode
/// (down, ...): a CPU profile of each relaunch, from first content to settled (the window the page's own fixed cost
/// sits in), and each long task of the load with when it ran (ms from navigation) and what ran most in it. The
/// profiler starts on a blank page of the same origin first, so the relaunch's renderer is not a cold one.
const PROFILE = process.env.PROFILE === "1";
/// BOUND=1: each round also times its settled page drawn from scratch in the same page (the DOM copied, the scroll
/// offset restored, to the next painted frame; median of BOUND_DRAWS draws) as `boundMs`, the settled-page bench's
/// derived bound for open_recent and restart (settled-page.bench.ts `fromRestartBench`).
const BOUND = process.env.BOUND === "1";
const BOUND_DRAWS = Number(process.env.BOUND_DRAWS ?? 3);
const SOURCES = process.env.SOURCES === "1";
/// The theme key the copy is written under and the host says the page gets now (shared.ts `misfit`):
/// the bench's host sends the page no theme, so any fixed key is the same theme on both loads.
const THEME = "bench-theme";
/// The copy is drawn only at the viewport it was written at (shared.ts `misfit`): both loads use this.
const VIEWPORT = { width: 1200, height: 800 };
/// HEIGHT_DELTA=N: the relaunch's viewport is N px shorter than the warm one (0, the default, is the same).
const HEIGHT_DELTA = Number(process.env.HEIGHT_DELTA ?? 0);
if (!Number.isFinite(HEIGHT_DELTA) || Math.abs(HEIGHT_DELTA) > 64) throw new Error("HEIGHT_DELTA must be within 64");
const RELAUNCH_VIEWPORT = { width: VIEWPORT.width, height: VIEWPORT.height - HEIGHT_DELTA };
/// PAGES=N: the recorded page and N-1 other restored chat pages load at once, as a restart restores every
/// workspace's chats (1, the default, is the recorded page alone).
const PAGES = Number(process.env.PAGES ?? 1);
if (!Number.isInteger(PAGES) || PAGES < 1) throw new Error("PAGES must be a whole number of at least 1");
/// FIXTURE=work: each finished turn works first, as an agent's does (the chat simulator's long run,
/// src/agent-session/acpmux/sim/scenarios.ts `longRun`): thoughts, 2-6 tool calls, a progress message,
/// background shells, notices from another lane and a compaction now and then, then a one-line reply. Every
/// finished turn folds under its "Worked for" line. plain (the default) is papercutChat's one-reply turns.
/// FIXTURE=replay REPLAY=FILE: a recorded chat's records (an NDJSON file, `.gz` too, as `chat-sim.ts --sanitize`
/// writes one), served as the daemon would; TURNS is then only a label.
const FIXTURE = process.env.FIXTURE ?? "plain";
if (FIXTURE !== "plain" && FIXTURE !== "work" && FIXTURE !== "replay")
  throw new Error("FIXTURE must be plain, work or replay");
const replayed =
  FIXTURE === "replay"
    ? (() => {
        const file = process.env.REPLAY;
        if (!file) throw new Error("FIXTURE=replay needs REPLAY=FILE");
        const bytes = fs.readFileSync(file);
        // gunzipSync gives a Uint8Array, whose toString is its bytes as numbers.
        const text = new TextDecoder().decode(file.endsWith(".gz") ? Bun.gunzipSync(bytes) : bytes);
        return parseRecords(text);
      })()
    : [];
/// The newest reply's first words, which a replayed chat's frames wait for as the others wait for `Answer N:`.
function replayLatest(records: readonly { kind: string; msg: unknown }[]): string {
  let at = -1;
  records.forEach((record, index) => {
    if (record.kind === "user_message") at = index;
  });
  // The turn's last message, which stays drawn: the ones before it can fold under its "Worked for".
  let text = "";
  let message: unknown;
  for (const record of records.slice(at + 1)) {
    if (record.kind !== "agent_message_chunk") continue;
    const params = (record.msg as { params?: { _meta?: { acpmux?: { subagent?: string } }; update?: any } }).params;
    if (params?._meta?.acpmux?.subagent) continue;
    if (params?.update?.messageId !== message) text = "";
    message = params?.update?.messageId;
    text += String(params?.update?.content?.text ?? "");
  }
  const words = text
    .trim()
    .split("\n")[0]!
    .replace(/[*_`#>]/g, "")
    .trim()
    .slice(0, 24)
    .trim();
  if (!words) throw new Error("the replayed chat's last turn has no reply to wait for");
  return words;
}
/// ROWS_WINDOW=FILE: the store's first window for the replayed chat (a `ChatWindow`'s JSON, `.gz` too), whose
/// `sid` the host sets to the page's own at each open.
const ROWS_WINDOW = (() => {
  const file = process.env.ROWS_WINDOW;
  if (!file) return null;
  const bytes = fs.readFileSync(file);
  const text = new TextDecoder().decode(file.endsWith(".gz") ? Bun.gunzipSync(bytes) : bytes);
  const window = JSON.parse(text) as { sid: string; rows: unknown[]; open: unknown[] };
  if (window.sid !== "bench") throw new Error("ROWS_WINDOW is not a bench_first_window window");
  console.log(`rows window: ${window.rows.length} settled rows, ${window.open.length} open, ${text.length} bytes`);
  return text;
})();
/// ROWS_ENDED=FILE: the window once the chat's open turn ended (same ids: a recording cut before its
/// `turn_end`, and the whole one), and how long after the first window it comes.
const ROWS_ENDED = (() => {
  const file = process.env.ROWS_ENDED;
  if (!file) return null;
  const bytes = fs.readFileSync(file);
  return new TextDecoder().decode(file.endsWith(".gz") ? Bun.gunzipSync(bytes) : bytes);
})();
const ROWS_ENDED_MS = Number(process.env.ROWS_ENDED_MS ?? 1000);
const LATEST =
  FIXTURE === "work" ? `Turn ${TURNS} done.` : FIXTURE === "replay" ? replayLatest(replayed) : `Answer ${TURNS}:`;
const webviews = path.resolve(import.meta.dir, "..");
const chatSnapshotSource = path.join(webviews, "src/agent-session/acpmux/chatSnapshot");

/// RUNNING=1: the chat's last turn is still running when the app restarts, as a working agent's is.
const RUNNING = process.env.RUNNING === "1";
/// CPU=N slows each relaunched page's CPU N times (CDP Emulation.setCPUThrottlingRate), as a loaded
/// Mac does after an update (Leo's cosmic-gray, 2026-11-16: load1 150 on 15 cores, 100-570 ms frames for
/// 40 s after the restart): a settle that takes several frames then shows each of them. 1 (the default) is off.
const CPU = Number(process.env.CPU ?? 1);
if (!Number.isFinite(CPU) || CPU < 1) throw new Error("CPU must be a number of at least 1");
/// ENGINE=webkit draws the chat in WebKit, as the app does when its Chromium did not start (Leo's NIGHTLY,
/// 2026-11-16: 394 of 415 chat pages ran as `webkit:chromium-failed`). WebKit reports no layout-shift
/// entries, so there the frame-by-frame shift count is the measure. CPU throttling is Chromium's (CDP).
const ENGINE = process.env.ENGINE ?? "chromium";
if (ENGINE !== "chromium" && ENGINE !== "webkit") throw new Error("ENGINE must be chromium or webkit");
if (ENGINE === "webkit" && CPU > 1) throw new Error("CPU throttling needs ENGINE=chromium");
/// CONTENT=rich: replies whose heights the height index estimates (model.ts `blockHeight`): a code block
/// every fourth turn, a table whose cells wrap the next, then a list and long paragraphs, then one line.
const CONTENT = process.env.CONTENT ?? "plain";
if (CONTENT !== "plain" && CONTENT !== "rich") throw new Error("CONTENT must be plain or rich");
const richAnswer = (n: number): string => {
  const head = `Answer ${n}:`;
  switch (n % 4) {
    case 0:
      return `${head} the build failed in two places.\n\n\`\`\`ts\n${Array.from(
        { length: 6 + (n % 9) },
        (_, at) =>
          `const step${at} = await run("check-${n}-${at}", { retries: ${at % 3}, timeoutMs: ${1000 * (at + 1)} });`,
      ).join("\n")}\n\`\`\`\n\nBoth come from the same flaky fixture.`;
    case 1:
      return `${head} here is where each check stands.\n\n| Check | State | Why |\n| --- | --- | --- |\n${Array.from(
        { length: 3 + (n % 4) },
        (_, at) =>
          `| check ${at} | ${at % 2 ? "red" : "green"} | ${"the runner lost its cache and rebuilt every crate from scratch, ".repeat(1 + (at % 3))}|`,
      ).join("\n")}`;
    case 2:
      return `${head} three things changed.\n\n- ${"The pane keeps its place across a restart. ".repeat(3)}\n- ${"The copy is drawn before the socket opens. ".repeat(2)}\n- The composer keeps its draft.\n\n${"A long paragraph that wraps over several lines at this width, so its height depends on the font and the column. ".repeat(4)}`;
    default:
      return `${head} the checks on the merged head are green.`;
  }
};
/// The chat's summary names its model and its effort, as acpmux's does (`configOptions`, attach-config-current
/// test): until a summary comes, the composer draws the effort this harness's chats last showed (chipMemory.ts),
/// and a summary with no effort took that away 200 ms after the first frame (reopen-no-copy: layout shift
/// 0.0003, the model chip 163 to 107 px), a shift no chat acpmux reports would have. High, not the Medium a
/// first chat remembers, so a guess that outlived the summary would show.
const REPORTED = {
  model: "claude-sonnet-4-5",
  configOptions: [
    {
      id: "effort",
      name: "Reasoning",
      category: "thought_level",
      type: "select",
      currentValue: "high",
      options: ["low", "medium", "high"].map((level) => ({ value: level, name: level })),
    },
  ],
};
const plain = papercutEvents({
  turns: TURNS,
  running: RUNNING,
  session: REPORTED,
  ...(CONTENT === "rich" ? { answer: richAnswer } : {}),
});
if (FIXTURE !== "plain" && (RUNNING || CONTENT !== "plain"))
  throw new Error(`FIXTURE=${FIXTURE} takes no RUNNING or CONTENT`);
/// OPEN=1 (FIXTURE=work): the last turn never ended, as a coordinator's that keeps working does: its records stop
/// before its `turn_end`, and the chat is running. A reload of it on the v1 attach (no ROWS_WINDOW) then draws the
/// turn as a watcher sees it (liveTurnWork `open`: every finished call in sight until the turn ends), and goneRows
/// counts any row the reload drew that the still-open turn no longer draws. The turn then ends OPEN_ENDS_MS (1500;
/// 0 never) after the relaunched page's attach is answered, as a running turn the reload caught does: its
/// end records (turn_end on) and the session back to ready, pushed live. goneRows then also counts every row the reload drew
/// that the ended turn's fold took away (Leo: "i see this rush and barrage of tool calls and message on a sort of
/// "renewed-load" of chats. but they get folded/hidden anyways").
const OPEN = process.env.OPEN === "1";
if (OPEN && FIXTURE !== "work") throw new Error("OPEN=1 needs FIXTURE=work");
const OPEN_ENDS_MS = OPEN ? Number(process.env.OPEN_ENDS_MS ?? 1500) : 0;
const [workRecords, openEnd] = (() => {
  const all = longRun(TURNS).events;
  if (!OPEN) return [all, null] as const;
  let end = all.length;
  while (end > 0 && all[end - 1]!.kind !== "turn_end") end -= 1;
  if (end === 0) throw new Error("OPEN=1: the work fixture has no turn_end");
  // The end is the turn's own records from its `turn_end` on (turn_end, turn_result, status ready, ...).
  return [all.slice(0, end - 1), all.slice(end - 1)] as const;
})();
/// The open turn's ids (OPEN=1), from its `turn_started`, for the session's `turn`.
const openTurn = (() => {
  if (!OPEN) return null;
  const started = [...workRecords].reverse().find((event: EventRecord) => event.kind === "turn_started");
  const msg = (started?.msg ?? {}) as { turnId?: string; promptId?: string };
  return {
    turnId: msg.turnId ?? `turn-${TURNS}`,
    promptId: msg.promptId ?? "",
    startedAt: started?.at ?? 0,
    prompt: "",
  };
})();
const worked = (FIXTURE === "work" ? workRecords : FIXTURE === "replay" ? replayed : []).map((event) => ({
  ...event,
  sessionId: PAPERCUT_CHAT,
}));
const events = FIXTURE === "plain" ? plain.events : worked;
const session =
  FIXTURE !== "plain"
    ? {
        ...plain.session,
        status: OPEN ? "running" : "ready",
        ...(OPEN ? { turn: openTurn } : {}),
        turnCount: TURNS,
        updatedAt: worked.at(-1)?.at ?? plain.session.updatedAt,
        lastSeq: worked.length,
      }
    : plain.session;
/// The newest page before `beforeSeq`, oldest first, and whether older ones remain: the page the daemon
/// answers an attach or an older-history read with, cut by count and by `maxBytes` (daemonPage.ts).
const newest = (limit: number, beforeSeq = Infinity, maxBytes?: unknown, kinds?: unknown) =>
  newestPage(Array.isArray(kinds) ? events.filter((event) => kinds.includes(event.kind)) : events, {
    limit,
    beforeSeq,
    maxBytes,
  });
/// A turn's prompt as acpmux reads it (server/requests/turn_opener.rs `starts_turn`): not a steer.
const startsTurn = (event: { dir?: string; kind?: string; msg?: unknown }) =>
  event.dir === "mux" && event.kind === "user_message" && (event.msg as { steer?: unknown })?.steer !== true;
/// The prompt of the turn an attach page starts inside (turn_opener.rs `turn_opener`): the attach
/// answers it with the page, so a page that starts mid-turn draws under its prompt from the first frame.
function turnOpener(page: readonly (typeof events)[number][], hasMore: boolean): unknown {
  const first = page[0];
  if (!hasMore || !first || first.seq <= 1 || startsTurn(first)) return null;
  for (let at = events.length - 1; at >= 0; at -= 1) {
    const event = events[at]!;
    if (event.seq < first.seq && startsTurn(event)) return event;
  }
  return null;
}
/// What the app host keeps for this chat and answers `chat.tail.get` with (tailCache.ts `KeptTail`, read
/// back by `tailFromHost`), made the way the page makes it: the attach page it read (the newest records
/// within `OPEN_PAGE_BYTES`, direct.ts `sendAttach`), its newest `KEPT_EVENTS` messages (`keptEvents`),
/// the prompt of the turn the kept page starts inside (direct.ts `currentTail`), and the host's byte
/// bound (`hostTailOf`). A kept page without that prompt draws its turn's work unfolded, which the
/// real page never does, so a stand-in without it measures a reload that does not happen.
const OPEN_PAGE_BYTES = 128 * 1024;
const keptTail = (() => {
  const opened = newest(400, Infinity, OPEN_PAGE_BYTES);
  const kept = keptEvents(opened.page as EventRecord[]);
  const first = kept[0];
  const opener =
    first && !startsTurn(first)
      ? ((kept.length < opened.page.length
          ? opened.page
              .slice(0, opened.page.length - kept.length)
              .reverse()
              .find(startsTurn)
          : undefined) ?? turnOpener(opened.page, opened.hasMore))
      : undefined;
  return hostTailOf({
    events: kept,
    summary: session,
    turnOpener: (opener ?? undefined) as EventRecord | undefined,
    historyExhausted: !opened.hasMore && kept.length === opened.page.length,
    queue: [],
    configSeq: 0,
    usageFromSeq: 0,
  });
})();

const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: 1,
        _meta: {
          acpmux: {
            origin: "local",
            extensions: [],
            operations: [],
            ...(ROWS_WINDOW ? { capabilities: ["attach-hold-v1"] } : {}),
          },
        },
      };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach": {
      // As the daemon does: the newest `limit` events within `maxBytes`, and hasMore while older ones remain.
      const { page, hasMore } = newest(Number(params.limit ?? 400), Infinity, params.maxBytes);
      return {
        session,
        lastSeq: events.at(-1)?.seq ?? 0,
        events: page,
        hasMore,
        turnOpener: turnOpener(page, hasMore),
      };
    }
    case "_acpmux/events": {
      // The prompt index (hub/paging.rs prompt_index): every prompt before `beforeSeq`, each cut to its text.
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
        return { events: prompts, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      if (params.beforeSeq !== undefined) {
        // `kinds` as acpmux reads it (paging.rs EventFilter): the pane's own opener read asks for prompts alone.
        const { page, hasMore } = newest(
          Number(params.limit ?? 400),
          Number(params.beforeSeq),
          params.maxBytes,
          params.kinds,
        );
        return { events: page, hasMore, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      return { events: [], hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
    }
    default:
      return null;
  }
};

/// A painted frame as the page records it: the classified fields, plus what a trace prints.
type Painted = FrameRecord & {
  /// The bottom-most row's text, cut short.
  bottomText: string;
  /// The live root was held clear (opacity 0) with no copy over it: nothing of the chat showed.
  rootHidden: boolean;
};
type LayoutShiftSeen = { at: number; value: number; moved: { node: string; from: number[]; to: number[] }[] };
type Recording = {
  frames: Painted[];
  /// The layout-shift entries' sum over the recording (none with recent input).
  layoutShift: number;
  /// Each of those entries: when (ms from navigation), its value, and each box that moved (`SOURCES=1`).
  shifts: LayoutShiftSeen[];
  latestAt: number;
  /// When the live page itself (no copy over it) first showed the newest answer, else 0.
  liveLatestAt: number;
  changedAt: number;
  done: boolean;
  stop: () => void;
};
type BenchWindow = {
  __firstLoad: Recording;
  __benchHost: {
    tailAskedAt: number;
    tailCalls: number;
    readyAnsweredAt: number;
    asks: number[];
    rowsOpens: number;
    rowsTaken: number;
  };
  __cmuxChatSnapshotMiss?: string;
  __cmuxChatSnapshotShown?: {
    at: number;
    swappedAt?: number;
    hold?: { by: string; at: number; differs?: string };
  };
  captureSnapshot: (doc: Document, theme: string) => ChatSnapshot | undefined;
  captureMiss: () => string;
};

/// The page's host actions this bench answers (as the app's host would), installed before the page's
/// scripts: the kept tail (`chat.tail.get`, null on the warm load: the host holds none) and the reading
/// place (`chat.scrollAnchor.get`: null, the chat opens at its newest message). The page assigns its own
/// `window.cmuxAcpmuxActions` once its client is up (App.tsx); these stay beside its own, as the app's
/// host keeps answering them. Runs in the page, so it closes over nothing.
function installHost({
  tail,
  readyDelayMs,
  refuseUntilMs,
  bridge,
  rows,
}: {
  tail: unknown;
  readyDelayMs: number;
  refuseUntilMs: number;
  bridge: boolean;
  /// ROWS_WINDOW: the store's first window (its JSON) and how long after an open it comes.
  rows: { window: string; delayMs: number; ended: string | null; endedMs: number } | null;
}) {
  /// `asks`: when the page asked for a socket to acpmux (ms from navigation): each `transport.open` over
  /// the bridge, each `new WebSocket` to it on the dev slot's transport.
  const asked = { tailAskedAt: 0, tailCalls: 0, readyAnsweredAt: 0, asks: [] as number[], rowsOpens: 0, rowsTaken: 0 };
  (window as unknown as { __benchHost: typeof asked }).__benchHost = asked;
  if (!bridge) {
    const Native = window.WebSocket;
    window.WebSocket = class extends Native {
      constructor(url: string | URL, protocols?: string | string[]) {
        if (String(url).startsWith("ws:")) asked.asks.push(performance.now());
        super(url, protocols);
      }
    };
  }
  type Own = { ok: true; value: unknown } | { ok: false; code: string; message: string };
  /// The app host's socket calls, answered by the bench's process (`__benchTransport`).
  const transport = (method: string, params: Record<string, unknown> | undefined): Promise<Own> | undefined => {
    if (!bridge || !["transport.open", "transport.send", "transport.close"].includes(method)) return undefined;
    if (method === "transport.open") asked.asks.push(performance.now());
    const call = (window as unknown as { __benchTransport: (method: string, params: unknown) => Promise<Own> })
      .__benchTransport;
    return call(method, params ?? {});
  };
  /// The app host's row store (AgentPaneChatRows.swift), for ROWS_WINDOW: an open is answered with its sid at once
  /// and its first window comes `delayMs` later as one batch; the window is the chat's whole state (an
  /// offline chat: nothing comes after it). A page, blob or close is taken and answered with nothing.
  let batch = 0;
  const rowsCall = (method: string, params: Record<string, unknown> | undefined): Promise<Own> | undefined => {
    if (!rows || !method.startsWith("chat.rows.")) return undefined;
    if (method === "chat.rows.taken") asked.rowsTaken += 1;
    if (method !== "chat.rows.open") return Promise.resolve({ ok: true, value: null });
    asked.rowsOpens += 1;
    const sid = String(params?.sid ?? "");
    const send = (text: string, at: number) => {
      const change = `{"kind":"chatWindow","replaces":true,"window":${text.replace('"sid":"bench"', `"sid":${JSON.stringify(sid)}`)}}`;
      setTimeout(() => {
        const receiver = (window as unknown as { cmuxChatRows?: { receive(event: unknown): void } }).cmuxChatRows;
        receiver?.receive({ batch: (batch += 1), changes: [change] });
      }, at);
    };
    send(rows.window, rows.delayMs);
    if (rows.ended && asked.rowsOpens === 1) send(rows.ended, rows.delayMs + rows.endedMs);
    return Promise.resolve({ ok: true, value: { sid } });
  };
  // Wrap the dev host's real ready answer, withholding it just as a daemon handoff does; over the bridge
  // it names the app's transport (no endpoint, no token), and the socket calls go to this process.
  let webkit: unknown;
  Object.defineProperty(window, "webkit", {
    configurable: true,
    get: () => webkit,
    set: (next) => {
      for (const name of ["agentSession", "cmuxPage"]) {
        const handler = next?.messageHandlers?.[name];
        if (!handler || (readyDelayMs <= 0 && refuseUntilMs <= 0 && !bridge && !rows)) continue;
        const post = handler.postMessage.bind(handler);
        const envelope = name === "cmuxPage";
        handler.postMessage = async (request: {
          t?: string;
          id?: unknown;
          method?: string;
          op?: string;
          params?: Record<string, unknown>;
        }) => {
          if (envelope && request.t !== "call") return post(request);
          const method = (request.method ?? request.op ?? "").replace(/^cmux\.agent\./, "");
          const own = rowsCall(method, request.params) ?? transport(method, request.params);
          if (own) {
            const reply = await own;
            if (envelope)
              return reply.ok
                ? { t: "ok", id: request.id, value: reply.value }
                : { t: "err", id: request.id, code: reply.code, message: reply.message, details: { origin: "native" } };
            return reply.ok
              ? reply
              : { ok: false, error: { code: reply.code, message: reply.message, origin: "native" } };
          }
          if (!["ready", "handshake"].includes(method)) return post(request);
          // A refusal the host names (a coded error, not a recovery): the pane says it at once, with Retry.
          if (performance.now() < refuseUntilMs) {
            const code = "acpmux.unavailable";
            const message = "acpmux is not running";
            return envelope
              ? { t: "err", id: request.id, code, message, details: { origin: "native" } }
              : { ok: false, error: { code, message, origin: "native" } };
          }
          if (readyDelayMs > 0) {
            // fixed-wait: the withheld native handshake is the condition measured by this mode.
            await new Promise((done) => setTimeout(done, Math.max(0, readyDelayMs - performance.now())));
            asked.readyAnsweredAt = performance.now();
          }
          const reply = (await post(request)) as { ok?: boolean; t?: string; value?: Record<string, unknown> };
          if (bridge && (reply?.ok || reply?.t === "ok") && reply.value) {
            const { endpoint: _endpoint, token: _token, ...value } = reply.value;
            return { ...reply, value: { ...value, transport: "acpmux-bridge" } };
          }
          return reply;
        };
      }
      webkit = next;
    },
  });
  const served: Record<string, (params: Record<string, unknown>) => Promise<unknown>> = {
    "chat.tail.get": async () => {
      asked.tailAskedAt ||= performance.now();
      asked.tailCalls += 1;
      // A copy per answer: the page keeps and edits what it is handed.
      return tail === null ? null : structuredClone(tail);
    },
    "chat.scrollAnchor.get": async () => null,
  };
  let current: Record<string, unknown> = { ...served };
  Object.defineProperty(window, "cmuxAcpmuxActions", {
    configurable: true,
    get: () => current,
    set: (next: unknown) => {
      current = next && typeof next === "object" ? (next as Record<string, unknown>) : {};
      for (const [method, run] of Object.entries(served)) if (!(method in current)) current[method] = run;
    },
  });
}

/// Records every painted frame from navigation for `windowMs` (window.cmuxAfterPaint, so each read is of
/// a frame that painted, after its ResizeObservers): the layer on top, which is the copy's shadow root
/// while a `hostTag` element shows, else the live document. Per frame: the transcript rows intersecting
/// the scroller's viewport (`.acpmux-row[data-row-id]`, VirtualTranscript.tsx; a row at opacity 0 is
/// not in view), the composer's box (`.acpmux-composer-box`, ComposerBox.tsx) and the scroller's offset.
/// Also keeps when the newest answer first showed and when what shows last changed (the warm load's
/// settle). Runs in the page, so it closes over nothing.
function recordFrames({ windowMs, latest, hostTag }: { windowMs: number; latest: string; hostTag: string }) {
  type Row = { id: string; top: number };
  type Frame = {
    t: number;
    copyShown: boolean;
    rows: Row[];
    composer: { top: number; height: number } | null;
    scrollTop: number | null;
    bottomText: string;
    rootHidden: boolean;
    rail: FrameRail | null;
  };
  let stopped = false;
  const recording = {
    frames: [] as Frame[],
    layoutShift: 0,
    shifts: [] as LayoutShiftSeen[],
    latestAt: 0,
    liveLatestAt: 0,
    changedAt: 0,
    done: false,
    stop: () => {
      stopped = true;
      recording.done = true;
    },
  };
  (window as unknown as { __firstLoad: typeof recording }).__firstLoad = recording;
  type Source = { node?: Node | null; previousRect: DOMRectReadOnly; currentRect: DOMRectReadOnly };
  /// A box by its class names and its parent's first one ("acpmux-main > div.acpmux-dock").
  const named = (node: Node | null | undefined): string => {
    if (!(node instanceof Element)) return node?.nodeName ?? "?";
    const classes = (element: Element) => [...element.classList].map((name) => `.${name}`).join("");
    const parent = node.parentElement;
    return `${parent ? `${parent.classList[0] ?? parent.tagName.toLowerCase()} > ` : ""}${node.tagName.toLowerCase()}${classes(node)}`;
  };
  const box = (rect: DOMRectReadOnly) => [rect.x, rect.y, rect.width, rect.height].map(Math.round);
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries() as unknown as {
      value: number;
      hadRecentInput: boolean;
      startTime: number;
      sources?: Source[];
    }[]) {
      if (entry.hadRecentInput || entry.startTime > windowMs) continue;
      recording.layoutShift += entry.value;
      recording.shifts.push({
        at: Math.round(entry.startTime),
        value: Number(entry.value.toFixed(5)),
        moved: (entry.sources ?? []).map((source) => ({
          node: named(source.node),
          from: box(source.previousRect),
          to: box(source.currentRect),
        })),
      });
    }
  }).observe({ type: "layout-shift", buffered: true });
  let signature = "";
  const read = (): Frame => {
    // A copy still waiting for its sheets is laid out hidden (paint.ts) and paints nothing: not on top.
    const drawn = document.querySelector<HTMLElement>(hostTag);
    const host = drawn && drawn.style.visibility !== "hidden" && drawn.style.opacity !== "0" ? drawn : null;
    const scope: ParentNode = host?.shadowRoot ?? document;
    // Under a copy the live root is held clear until the swap (chatSnapshot/paint.ts); with no copy over
    // it, a clear root shows nothing of the chat.
    const rootHidden = !host && document.getElementById("root")?.style.opacity === "0";
    const scroller = scope.querySelector<HTMLElement>(".acpmux-scroll");
    const view = rootHidden ? undefined : scroller?.getBoundingClientRect();
    const rows: (Row & { text: string })[] = [];
    if (view)
      for (const row of Array.from(scope.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]"))) {
        const box = row.getBoundingClientRect();
        if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
        if (Number(getComputedStyle(row).opacity) === 0) continue;
        rows.push({ id: row.dataset.rowId ?? "", top: box.top, text: row.textContent ?? "" });
      }
    rows.sort((a, b) => a.top - b.top);
    const composer = rootHidden
      ? undefined
      : Array.from(scope.querySelectorAll(".acpmux-composer-box"))
          .map((element) => element.getBoundingClientRect())
          .find((box) => box.height > 0);
    const railNode = rootHidden ? null : scope.querySelector<HTMLElement>(".acpmux-minimap__rail");
    const railBox = railNode?.getBoundingClientRect();
    const rail: FrameRail | null =
      railNode && railBox && railBox.height > 0
        ? {
            top: railBox.top,
            height: railBox.height,
            rows: Number(railNode.querySelector("[aria-setsize]")?.getAttribute("aria-setsize") ?? 0),
            listTop: railNode.querySelector<HTMLElement>(".acpmux-minimap__list")?.scrollTop ?? 0,
            lit: Array.from(railNode.querySelectorAll<HTMLElement>("[data-tick][aria-current]"))
              .map((tick) => tick.dataset.tick)
              .join(","),
            animating: railNode
              .getAnimations({ subtree: true })
              .filter((animation) => animation.playState === "running").length,
          }
        : null;
    if (!recording.latestAt && rows.some((row) => row.text.includes(latest))) recording.latestAt = performance.now();
    if (!recording.liveLatestAt && !host && !rootHidden && rows.some((row) => row.text.includes(latest)))
      recording.liveLatestAt = performance.now();
    return {
      t: performance.now(),
      copyShown: !!host,
      rows: rows.map(({ id, top, text }) => ({ id, top, text: text.trim().replace(/\s+/g, " ").slice(0, 200) })),
      composer: composer ? { top: composer.top, height: composer.height } : null,
      scrollTop: scroller && !rootHidden ? scroller.scrollTop : null,
      bottomText: (rows.at(-1)?.text ?? "").trim().replace(/\s+/g, " ").slice(0, 48),
      rootHidden,
      rail,
    };
  };
  window.cmuxAfterPaint(() => {
    if (stopped) return false;
    if (performance.now() > ((window as unknown as { __firstLoadUntil?: number }).__firstLoadUntil ?? windowMs)) {
      recording.stop();
      return false;
    }
    const frame = read();
    recording.frames.push(frame);
    const next = JSON.stringify([
      frame.rows.map((row) => [row.id, Math.round(row.top)]),
      frame.composer && [Math.round(frame.composer.top), Math.round(frame.composer.height)],
      frame.scrollTop === null ? null : Math.round(frame.scrollTop),
    ]);
    if (next !== signature) {
      signature = next;
      recording.changedAt = frame.t;
    }
    return true;
  });
}

type CpuProfile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples: number[];
  timeDeltas: number[];
};
/// PROFILE=1: self ms per function over every round's adopt, and how many adopts were profiled.
const selfMs = new Map<string, number>();
/// Inclusive ms: each function counted once per sample it is on the stack of.
const totalMs = new Map<string, number>();
/// A built-in's (no url: style reads, layout, DOM calls) self ms by the nearest bundle function that called it.
const nativeByCaller = new Map<string, number>();
let profiled = 0;
/// MODE=reopen-spare: how long each adopt event's own task ran (ms), the synchronous React pass
/// `useSessionAdoption` flushes inside the event, before the browser can paint anything.
const adoptSyncMs: number[] = [];
/// MODE=reopen-spare: the parked spare's own footprint before its adopt, after a full GC: the page's JS
/// heap (MB) and its DOM nodes (CDP Performance.getMetrics). The renderer's other memory is shared.
const spareHeapMb: number[] = [];
const spareNodes: number[] = [];
const OUTSIDE = new Set(["(idle)", "(program)", "(root)"]);
type ProfileNode = CpuProfile["nodes"][number];
const nodeKey = (frame: ProfileNode["callFrame"]) =>
  `${frame.functionName || "(anonymous)"} ${frame.url.split("/").pop() ?? ""}:${frame.lineNumber + 1}`;
const bump = (map: Map<string, number>, key: string, ms: number) => map.set(key, (map.get(key) ?? 0) + ms);
/// Adds the samples of one adopt: from its first busy sample (the event's own turn, right after the
/// profiler started) for the time it took to the newest answer drawn (`untilMs - atMs`), plus a frame.
function addProfile(profile: CpuProfile, atMs: number, untilMs: number): void {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  let t = 0;
  let from: number | undefined;
  const span = untilMs - atMs + 17;
  profile.samples.forEach((id, index) => {
    const ms = profile.timeDeltas[index] / 1000;
    t += ms;
    const node = byId.get(id);
    if (!node) return;
    const frame = node.callFrame;
    if (from === undefined) {
      if (OUTSIDE.has(frame.functionName)) return;
      from = t;
    }
    if (t - from > span || frame.functionName === "(idle)") return;
    bump(selfMs, nodeKey(frame), ms);
    const seen = new Set<string>();
    let caller: string | undefined;
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const up = byId.get(at);
      if (!up || up.callFrame.functionName === "(root)") break;
      const key = nodeKey(up.callFrame);
      if (!seen.has(key)) bump(totalMs, key, ms);
      seen.add(key);
      if (caller === undefined && at !== id && up.callFrame.url) caller = key;
    }
    if (!frame.url && caller) bump(nativeByCaller, `${frame.functionName} <- ${caller}`, ms);
  });
  profiled += 1;
}
/// PROFILE=1 in a relaunch mode: the long tasks (a busy run of samples of 20 ms or more) of each round, in order.
const relaunchTasks: string[] = [];
/// Adds one relaunch's samples from first content (`fromMs`, from navigation) to settled (`untilMs`), and lists its
/// long tasks to settled. `nowMs` is the page's performance.now() just before the profiler stopped: the profile's
/// end, so each sample's time from navigation is `nowMs - (endTime - t) / 1000`.
function addRelaunchProfile(
  profile: CpuProfile & { startTime: number; endTime: number },
  nowMs: number,
  fromMs: number,
  untilMs: number,
  round: number,
): void {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const stackOf = (id: number) => {
    const keys: string[] = [];
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const up = byId.get(at);
      if (!up || up.callFrame.functionName === "(root)") break;
      if (up.callFrame.url) keys.push(nodeKey(up.callFrame));
    }
    return keys;
  };
  // What ran when, by stretch: the outermost two bundle functions on the stack and the innermost component (a
  // capitalized function) under them, a stretch per run of samples with the same label.
  const labelOf = (id: number) => {
    const keys: string[] = [];
    let component: string | undefined;
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const up = byId.get(at);
      if (!up || up.callFrame.functionName === "(root)") break;
      if (!up.callFrame.url) continue;
      keys.push(up.callFrame.functionName || "(anonymous)");
      if (component === undefined && /^[A-Z]/.test(up.callFrame.functionName)) component = up.callFrame.functionName;
    }
    const outer = keys.slice(-2).reverse().join(" > ") || byId.get(id)!.callFrame.functionName;
    return component ? `${outer} … ${component}` : outer;
  };
  let stretch: { from: number; to: number; label: string } | undefined;
  const stretches: string[] = [];
  const endStretch = () => {
    if (stretch && stretch.to - stretch.from >= 3)
      stretches.push(`    ${stretch.from.toFixed(0)}-${stretch.to.toFixed(0)} ${stretch.label}`);
    stretch = undefined;
  };
  let t = profile.startTime;
  let task: { from: number; to: number; by: Map<string, number> } | undefined;
  const close = () => {
    if (task && task.to - task.from >= 20) {
      const top = [...task.by]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 6)
        .map(([key, ms]) => `${ms.toFixed(0)} ${key}`)
        .join("; ");
      relaunchTasks.push(
        `  round ${round} task ${task.from.toFixed(0)}-${task.to.toFixed(0)} ms (${(task.to - task.from).toFixed(0)} ms): ${top}`,
      );
    }
    endStretch();
    if (task && task.to - task.from >= 20) relaunchTasks.push(...stretches);
    stretches.length = 0;
    task = undefined;
  };
  profile.samples.forEach((id, index) => {
    const ms = profile.timeDeltas[index] / 1000;
    t += profile.timeDeltas[index];
    const at = nowMs - (profile.endTime - t) / 1000;
    const node = byId.get(id);
    if (!node) return;
    if (at > untilMs + 50) return close();
    // (program) is the renderer's own work outside script (style, layout, paint, parsing): busy, not idle.
    if (node.callFrame.functionName === "(idle)") {
      if (task && at - task.to > 2) close();
    } else {
      if (!task) task = { from: at, to: at, by: new Map() };
      task.to = at;
      const label = labelOf(id);
      if (stretch?.label !== label) {
        endStretch();
        stretch = { from: at, to: at, label };
      } else stretch.to = at;
      // Inclusive per bundle function, each once per sample.
      for (const key of new Set(stackOf(id))) bump(task.by, key, ms);
      if (!node.callFrame.url) bump(task.by, `${node.callFrame.functionName} (built-in)`, ms);
    }
    if (at < fromMs || at > untilMs || node.callFrame.functionName === "(idle)") return;
    bump(selfMs, nodeKey(node.callFrame), ms);
    const seen = new Set<string>();
    let caller: string | undefined;
    for (let up: number | undefined = id; up !== undefined; up = parent.get(up)) {
      const one = byId.get(up);
      if (!one || one.callFrame.functionName === "(root)") break;
      const key = nodeKey(one.callFrame);
      if (!seen.has(key)) bump(totalMs, key, ms);
      seen.add(key);
      if (caller === undefined && up !== id && one.callFrame.url) caller = key;
    }
    if (!node.callFrame.url && caller) bump(nativeByCaller, `${node.callFrame.functionName} <- ${caller}`, ms);
  });
  close();
  profiled += 1;
}
function printProfile(): void {
  if (!profiled) return;
  const relaunched = relaunchTasks.length > 0 || !MODES.includes("reopen-spare");
  const what = relaunched ? `${LINK_NAME} relaunch, first content to settled` : "reopen-spare adopt";
  if (relaunched) console.log(`${LINK_NAME} relaunch long tasks (ms from navigation):\n${relaunchTasks.join("\n")}`);
  const total = [...selfMs.values()].reduce((a, b) => a + b, 0);
  const top = (title: string, map: Map<string, number>, count: number) => {
    console.log(title);
    for (const [key, ms] of [...map].sort((a, b) => b[1] - a[1]).slice(0, count))
      console.log(`  ${(ms / profiled).toFixed(2).padStart(7)} ms  ${key}`);
  };
  top(
    `${what} profile: ${(total / profiled).toFixed(1)} ms busy per round (n=${profiled}), top self time:`,
    selfMs,
    30,
  );
  top(`${what} profile, inclusive:`, totalMs, Number(process.env.PROFILE_TOP ?? 45));
  top(`${what} profile, built-ins by caller:`, nativeByCaller, 20);
}

type Round = {
  mode: Mode;
  metrics: FrameMetrics;
  frames: Painted[];
  /// When the live page, with no copy over it, first showed the newest answer (ms from navigation),
  /// else null: a round whose copy never gave way to the read chat has not loaded.
  liveLatestMs: number | null;
  layoutShift: number;
  /// The layout-shift entries that sum to it, with the boxes that moved (printed with SOURCES=1).
  layoutShifts: LayoutShiftSeen[];
  /// When the copy drew and when the live page took over (chatSnapshot/paint.ts, live.ts), ms from navigation.
  copyShownMs: number | null;
  swapMs: number | null;
  /// How the copy's wait for the chat's draft ran out (draftSettleHold.ts): the composer showed the
  /// copy's when the rows came in (`shown`) or later (`match`), the 2 s cap (`cap`, with what still
  /// differed), or the draft read answered first (`read`); null with no copy.
  hold: { by: string; atMs: number | null; differs: string | null } | null;
  /// Why no copy drew (boot.ts), or null when one did.
  copyMiss: string | null;
  tailAskedMs: number | null;
  readyAnsweredMs: number | null;
  /// When the stand-in acpmux started answering, ms from navigation.
  acpmuxUpMs: number;
  /// Socket upgrades refused while acpmux was down.
  refused: number;
  socketOpenedMs: number | null;
  initializeAnsweredMs: number | null;
  attachAnsweredMs: number | null;
  /// BOUND=1: the settled page drawn from scratch, ms (median of BOUND_DRAWS draws); else null.
  boundMs: number | null;
  /// How many times the page asked for a socket, and when it made the ask that opened one (ms from
  /// navigation): the relink is the wait for that ask after acpmux came back, then the ask to the open.
  asks: number;
  lastAskMs: number | null;
  /// Bytes the daemon sent the page over the link this round, as text, and as they crossed the wire (LINK_ZLIB).
  bytesDown: number;
  wireDown: number;
  /// ROWS_WINDOW: the row store's batches the page took (0: it drew the chat by v1).
  rowsTaken: number;
};

/** The settled page served as a static page (BOUND=1): the settled DOM, scripts removed, at the app's own origin
 *  (its stylesheets, fonts), the scroll offset restored by an inline script before the first paint; ms from navigation
 *  to its first contentful paint, the median of BOUND_DRAWS loads in fresh pages of the same context. No restart can
 *  show the settled page sooner than its own HTML loads and paints. */
async function drawBound(page: Page): Promise<number> {
  const html = await page.evaluate(() => {
    const clone = document.documentElement.cloneNode(true) as HTMLElement;
    for (const node of clone.querySelectorAll("script")) node.remove();
    const scrollTop = document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollTop ?? 0;
    const restore = document.createElement("script");
    restore.textContent = `{const s=document.querySelector(".acpmux-scroll");if(s)s.scrollTop=${scrollTop}}`;
    clone.querySelector("body")?.append(restore);
    return `<!doctype html>${clone.outerHTML}`;
  });
  const at = new URL("/__settled-bound.html", page.url()).href;
  const draws: number[] = [];
  for (let draw = 0; draw < Math.max(1, BOUND_DRAWS); draw += 1) {
    const one = await page.context().newPage();
    await one.setViewportSize(page.viewportSize() ?? RELAUNCH_VIEWPORT);
    try {
      await one.route(at, (route) => route.fulfill({ contentType: "text/html", body: html }));
      await one.goto(at, { waitUntil: "load" });
      draws.push(
        await one.evaluate(
          () =>
            new Promise<number>((resolve) => {
              const paint = () =>
                performance.getEntriesByName("first-contentful-paint")[0]?.startTime ??
                performance.getEntriesByType("paint").at(-1)?.startTime;
              requestAnimationFrame(() => setTimeout(() => resolve(paint() ?? performance.now()), 0));
            }),
        ),
      );
    } finally {
      await one.close();
    }
  }
  draws.sort((a, b) => a - b);
  return draws[Math.floor(draws.length / 2)]!;
}

const releases: [string, () => unknown][] = [];
const release = async () => {
  for (const [, stop] of releases.reverse()) await Promise.resolve(stop()).catch(() => undefined);
};

try {
  /// acpmux is unavailable until `downUntil` (epoch ms) in `downMode`; up otherwise.
  let downMode: Mode | undefined;
  let downUntil = 0;
  let wireT0 = 0;
  /// This relaunch's socket timeline (epoch ms).
  let load = { refused: 0, socketOpenedAt: 0, initializeAnsweredAt: 0, attachAnsweredAt: 0, bytesDown: 0, wireDown: 0 };
  /// TRACE: the daemon calls a spare page made before its adopt event.
  const spareCalls: string[] = [];
  let servingSpare = false;
  /// OPEN_ENDS_MS: the relaunched page's attach starts the clock to the open turn's end.
  let endOpenTurn = false;
  const delayedReplies = new Set<ReturnType<typeof setTimeout>>();
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      // As while acpmux restarts: nothing takes the socket, so the page's connect fails and it retries.
      if (downMode === "down" && Date.now() < downUntil) {
        load.refused += 1;
        return new Response("acpmux is restarting", { status: 503 });
      }
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open() {
        load.socketOpenedAt ||= Date.now();
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        if (servingSpare)
          spareCalls.push(
            `${message.method}${message.params?.sessionId ? ` ${String(message.params.sessionId)}` : ""}`,
          );
        if (WIRE_TRACE)
          console.log(
            `wire ${Date.now() - wireT0} ms ${message.method} ${JSON.stringify(message.params ?? {}).slice(0, 160)}`,
          );
        const result = answer(message.method, message.params);
        const reply = () => {
          if (message.method === "initialize") load.initializeAnsweredAt ||= Date.now();
          if (message.method === "_acpmux/attach") load.attachAnsweredAt ||= Date.now();
          if (message.method === "_acpmux/attach" && endOpenTurn && openEnd) {
            endOpenTurn = false;
            // fixed-wait: when the open turn ends is the condition OPEN_ENDS_MS sets; stops with the run.
            const timer = setTimeout(() => {
              delayedReplies.delete(timer);
              const at = Date.now();
              const seq = openEnd.at(-1)!.seq;
              const notify = (method: string, params: unknown) => {
                try {
                  ws.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
                } catch {
                  // Closed: the round is over.
                }
              };
              if (WIRE_TRACE) console.log(`wire ${at - wireT0} ms -> the turn's end through seq ${seq}, session ready`);
              for (const record of openEnd) notify("_acpmux/event", { ...record, sessionId: PAPERCUT_CHAT, at });
              const { turn: _turn, ...ended } = session as typeof session & { turn?: unknown };
              notify("_acpmux/session_changed", {
                kind: "updated",
                session: { ...ended, status: "ready", updatedAt: at, lastSeq: seq },
              });
            }, OPEN_ENDS_MS);
            delayedReplies.add(timer);
          }
          // A socket the page gave up on meanwhile takes nothing.
          try {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          } catch {
            // Closed: the page asks again on its next socket.
          }
        };
        // A slow daemon: the socket is up but its handshake answers only once acpmux is ready.
        const delay = message.method === "initialize" && downMode === "slow-init" ? downUntil - Date.now() : 0;
        // fixed-wait: the slow daemon's answer time is the condition this mode measures; stops with the run.
        if (delay > 0) {
          const timer = setTimeout(() => {
            delayedReplies.delete(timer);
            reply();
          }, delay);
          delayedReplies.add(timer);
        } else reply();
      },
    },
  });
  releases.push([
    "stand-in acpmux",
    () => {
      for (const timer of delayedReplies) clearTimeout(timer);
      delayedReplies.clear();
      return daemon.stop(true);
    },
  ]);

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "first-load-bench-"));
  releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
  const work = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "first-load-bench-work-"));
  releases.push(["bundles", () => fs.rmSync(work, { recursive: true, force: true })]);
  const { build } = await import("vite");
  // An immutable pane source revision under the same harness makes the before/after comparable.
  // Only these presentation sources differ; the page host, daemon fixture and frame recorder stay fixed.
  const sourceRef = process.env.PANE_SOURCE_REF;
  const priorSources = new Map<string, string>();
  // Every pane source under src/agent-session that differs from the ref is read at the ref (a file the
  // ref lacks stays, unread by the ref's sources), so one run builds the before of a whole change.
  if (sourceRef) {
    const changed = execFileSync(
      "git",
      ["diff", "--name-only", "--diff-filter=MD", sourceRef, "--", "src/agent-session", "src/ui"],
      { cwd: webviews, encoding: "utf8" },
    )
      .split("\n")
      .filter(Boolean);
    const top = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: webviews, encoding: "utf8" }).trim();
    for (const file of changed)
      priorSources.set(
        path.join(top, file),
        execFileSync("git", ["show", `${sourceRef}:${file}`], {
          cwd: webviews,
          encoding: "utf8",
          maxBuffer: 8 * 1024 * 1024,
        }),
      );
    console.log(`pane sources read at ${sourceRef}: ${changed.join(", ") || "none"}`);
  }
  console.log(`pane source: ${sourceRef ?? "worktree"}`);
  await build({
    plugins: [{ name: "immutable-pane-baseline", enforce: "pre", load: (id) => priorSources.get(id) }],
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    // PROFILE=1 keeps names, so the adopt profile names the pane's own functions.
    build: { outDir: out, emptyOutDir: true, ...(PROFILE ? { minify: false } : {}) },
    logLevel: "error",
  });
  const bundle = async (entry: string): Promise<string> => {
    // At PANE_SOURCE_REF too: the boot script is a pane source like the bundle's.
    const built = await Bun.build({
      entrypoints: [entry],
      format: "iife",
      target: "browser",
      plugins: [
        {
          name: "immutable-pane-baseline",
          setup: (builder) => {
            builder.onLoad({ filter: /\.tsx?$/ }, (args) => {
              const contents = priorSources.get(args.path);
              return contents === undefined ? undefined : { contents, loader: args.path.endsWith("x") ? "tsx" : "ts" };
            });
          },
        },
      ],
    });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    return await built.outputs[0]!.text();
  };
  // The copy's boot script, as build-agent-pane-web.sh bundles it (chat-snapshot.js), and the writer the
  // warm page runs once settled (test/agent-pane-chat-snapshot.test.ts bundles it the same way).
  const bootScript = await bundle(path.join(chatSnapshotSource, "boot.ts"));
  const captureEntry = path.join(work, "capture-entry.ts");
  fs.writeFileSync(
    captureEntry,
    `import { captureMiss, captureSnapshot } from ${JSON.stringify(path.join(chatSnapshotSource, "capture.ts"))};\n` +
      "Object.assign(globalThis, { captureMiss, captureSnapshot });\n",
  );
  const captureScript = await bundle(captureEntry);
  // The app's host is there before any page script runs (its WebKit handlers, or the page host's): the
  // dev host stands in for it from the document's start here, not from the bundle's dev entry (dev.tsx,
  // which installs it only when the bundle ran and leaves one already there), so a page script that
  // asks the host first (boot.ts) is answered as in the app.
  const hostEntry = path.join(work, "host-entry.ts");
  fs.writeFileSync(
    hostEntry,
    `import { devHostParams, installDevHost } from ${JSON.stringify(path.join(webviews, "src/dev-host/host.ts"))};\n` +
      "const params = devHostParams(location.hash);\nif (params) installDevHost(params);\n",
  );
  const hostScript = await bundle(hostEntry);

  // The page as the app serves it (build-agent-pane-web.sh): every sheet in one linked `pane.css`
  // (id cmux-pane-styles), which the writer leaves out of the copy and whose rules the copy draws under
  // (`pane-copy.css`, rewritten for its shadow tree), and after `<main id="root">` the
  // host's snapshot (async) and the script that draws it, before the module. Vite's own build links its
  // sheets instead; a lazy chunk's sheet comes later, so every sheet of the build goes in, linked ones first.
  let index = fs.readFileSync(path.join(out, "index.html"), "utf8");
  const linked: string[] = [];
  index = index.replace(/<link\b[^>]*\brel="stylesheet"[^>]*>/g, (tag) => {
    const href = /\bhref="([^"]+)"/.exec(tag)?.[1];
    if (href) linked.push(href.replace(/^\.?\//, ""));
    return "";
  });
  const assets = fs.existsSync(path.join(out, "assets")) ? fs.readdirSync(path.join(out, "assets")) : [];
  const sheets = [
    ...linked,
    ...assets
      .filter((name) => name.endsWith(".css"))
      .map((name) => `assets/${name}`)
      .filter((name) => !linked.includes(name))
      .sort(),
  ];
  if (sheets.length === 0) throw new Error("the pane build has no stylesheet");
  const css = sheets
    .map((sheet) =>
      // A sheet's relative url() names a file beside it; joined at the root, it resolves from there.
      fs
        .readFileSync(path.join(out, sheet), "utf8")
        .replace(
          /url\((["']?)(?![a-z]+:|\/|#)([^"')]+)\1\)/gi,
          (_match, quote: string, file: string) =>
            `url(${quote}/${path.posix.join(path.posix.dirname(sheet), file)}${quote})`,
        ),
    )
    .join("\n");
  fs.writeFileSync(path.join(out, "pane.css"), css);
  fs.writeFileSync(path.join(out, "pane-copy.css"), snapshotCss(css));
  // Each joined sheet keeps an inert link of its href, so vite's preload helper finds it there and
  // links none of them again after the page's own sheet (the app's bundle links none): a sheet linked
  // late wins rules the page sheet's order lost them (a 48 px quiet composer row instead of 28).
  const placeholders = sheets.map((sheet) => `<link rel="stylesheet" media="not all" href="/${sheet}">`).join("\n");
  index = index.replace(
    "</head>",
    () =>
      `<link rel="stylesheet" id="${PAGE_STYLE_ID}" href="/pane.css" data-copy="pane-copy.css">\n${placeholders}\n</head>`,
  );
  const ROOT = /<main id="root"><\/main>/;
  if (!ROOT.test(index)) throw new Error('the pane build has no <main id="root"></main>');
  index = index.replace(
    ROOT,
    () =>
      '<main id="root"></main>\n<script async src="/__snapshot/chat.js"></script>\n<script src="/chat-snapshot.js"></script>',
  );

  /// The copy the host serves this load (`__snapshot/chat.js`): null on the warm load, as with none kept.
  let servedCopy: ChatSnapshot | null = null;
  // A spare New Tab page's load (`servingSpare`) is served no restored chat: it is no chat's page until adopted.
  const script = (body: string) =>
    new Response(body, { headers: { "Content-Type": "text/javascript", "Cache-Control": "no-store" } });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      if (pathname === "/" || pathname === "/index.html")
        return new Response(index, { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
      // As the page host answers it (AgentPageResources.swift): the globals, then the boot if it ran first.
      if (pathname === "/__snapshot/chat.js" && servingSpare)
        return script(`self.${SNAPSHOT_GLOBAL}=null;self.${SNAPSHOT_THEME_GLOBAL}=${JSON.stringify(THEME)};`);
      if (pathname === "/__snapshot/chat.js")
        return script(
          `self.${SNAPSHOT_GLOBAL}=${JSON.stringify(servedCopy)};self.${SNAPSHOT_THEME_GLOBAL}=${JSON.stringify(THEME)};self.__cmuxRestoredChat=${JSON.stringify(PAPERCUT_CHAT)};self.dispatchEvent(new Event('cmux-restored-chat'));self.${SNAPSHOT_BOOT_GLOBAL}?.();`,
        );
      if (pathname === "/chat-snapshot.js") return script(bootScript);
      const file = Bun.file(path.join(out, pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux&session=${PAPERCUT_CHAT}`;
  /// The prewarmed spare: a New Tab page with no chat yet (dev-host `newtab`; `new`: a new chat, not the latest one).
  const spareUrl = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux&newtab&new`;
  const browser: Browser =
    ENGINE === "webkit"
      ? await webkit.launch({ headless: true })
      : await chromium.launch({
          headless: true,
          // A released chat opens again in the renderer the app's other chat pages share (one per site).
          args: MODES.some(isReopen) ? ["--process-per-site"] : [],
        });
  releases.push(["browser", () => browser.close()]);
  /// The reopen modes' warm renderer: one context with another chat page open in it for the whole run.
  let warmContext: Awaited<ReturnType<Browser["newContext"]>> | undefined;
  if (MODES.some(isReopen)) {
    warmContext = await browser.newContext({ viewport: VIEWPORT });
    const other = await warmContext.newPage();
    await other.goto(url);
    // A chat whose last turn never ended (ROWS_ENDED) streams its last message on this page, which has no
    // host of the bench's, so it may never draw it whole: a drawn row is enough to keep the renderer warm.
    await other.waitForFunction(
      ({ text, anyRow }) =>
        (document.body.textContent?.includes(text) ?? false) ||
        (anyRow && document.querySelector(".acpmux-row[data-row-id]") !== null),
      { text: LATEST, anyRow: !!ROWS_ENDED },
      { timeout: 120_000, polling: 200 },
    );
  }

  /// The app host's side of the bridge (Swift AgentPaneTransport) for `page`: `transport.open` opens a
  /// socket to the stand-in from this process and answers once it is open, or `transport.connect_failed`
  /// as the app does when acpmux refuses it; its frames and close go to the page's
  /// `cmuxAcpmuxTransport.receive`, in order.
  const serveBridge = async (page: Page) => {
    const sockets = new Map<number, WebSocket>();
    const pipes = new Map<number, { up: LinkPipe; down: LinkPipe }>();
    let next = 0;
    let delivery = Promise.resolve();
    const push = (event: { connection: number; frames?: string[]; closed?: { code: number; reason: string } }) => {
      delivery = delivery
        .then(() =>
          page.evaluate((pushed) => {
            (
              window as unknown as { cmuxAcpmuxTransport?: { receive(event: unknown): void } }
            ).cmuxAcpmuxTransport?.receive(pushed);
          }, event),
        )
        .catch(() => undefined);
    };
    page.on("close", () => {
      for (const { up, down } of pipes.values()) {
        up.close();
        down.close();
      }
      pipes.clear();
      for (const socket of sockets.values()) socket.close();
      sockets.clear();
    });
    await page.exposeFunction("__benchTransport", async (method: string, params: Record<string, unknown>) => {
      if (method === "transport.open") {
        const connection = (next += 1);
        // LINK: the socket's connect costs one round trip of the simulated link before the daemon sees it.
        await connectDelay(LINK);
        const socket = new WebSocket(`ws://127.0.0.1:${daemon.port}/`);
        const opened = await new Promise<boolean>((resolve) => {
          socket.addEventListener("open", () => resolve(true), { once: true });
          socket.addEventListener("error", () => resolve(false), { once: true });
          socket.addEventListener("close", () => resolve(false), { once: true });
        });
        if (!opened) return { ok: false, code: "transport.connect_failed", message: "acpmux refused the socket" };
        sockets.set(connection, socket);
        // LINK: daemon to page and page to daemon each go through one pipe of the simulated link, in order.
        const down = new LinkPipe(LINK, undefined, LINK_ZLIB);
        const up = new LinkPipe(LINK, undefined, LINK_ZLIB);
        pipes.set(connection, { up, down });
        socket.addEventListener("message", (event) => {
          const frame = String(event.data);
          load.bytesDown += Buffer.byteLength(frame);
          const before = down.bytes;
          down.send(frame, (arrived) => push({ connection, frames: [arrived] }));
          load.wireDown += down.bytes - before;
        });
        socket.addEventListener("close", (event) => {
          if (!sockets.delete(connection)) return;
          // The close is the last thing down the pipe; then the pipe stops.
          down.send("", () => {
            push({ connection, closed: { code: event.code, reason: event.reason } });
            down.close();
            up.close();
          });
          pipes.delete(connection);
        });
        return { ok: true, value: { connection } };
      }
      const socket = sockets.get(Number(params.connection));
      if (method === "transport.send") {
        if (!socket) return { ok: false, code: "transport.closed", message: "closed" };
        const pipe = pipes.get(Number(params.connection));
        for (const frame of (params.frames as string[] | undefined) ?? [])
          if (pipe) pipe.up.send(frame, (sent) => socket.readyState === WebSocket.OPEN && socket.send(sent));
          else socket.send(frame);
        return { ok: true, value: null };
      }
      sockets.delete(Number(params.connection));
      const pipe = pipes.get(Number(params.connection));
      pipes.delete(Number(params.connection));
      pipe?.up.close();
      pipe?.down.close();
      socket?.close();
      return { ok: true, value: null };
    });
  };

  /// `ends`: the relaunch's page, which gets ROWS_ENDED; the page the copy is taken from does not (its turn ran
  /// when the app went away).
  const prepare = async (
    page: Page,
    tail: unknown,
    windowMs: number,
    readyDelayMs = 0,
    refuseUntilMs = 0,
    ends = false,
  ) => {
    await installPaintedFrames(page);
    if (BRIDGE) await serveBridge(page);
    await page.addInitScript(installHost, {
      tail,
      readyDelayMs,
      refuseUntilMs,
      bridge: BRIDGE,
      rows: ROWS_WINDOW
        ? { window: ROWS_WINDOW, delayMs: LINK.rttMs, ended: ends ? ROWS_ENDED : null, endedMs: ROWS_ENDED_MS }
        : null,
    });
    // After installHost, whose setter wraps the handlers it installs.
    await page.addInitScript({ content: hostScript });
    await page.addInitScript(recordFrames, { windowMs, latest: LATEST, hostTag: SNAPSHOT_HOST_TAG });
  };

  /// TRACE=1: the boxes in the page's bottom band (from the composer's top down), by class, so a composer
  /// that sits elsewhere in the copy than on the live page names what stands under or over it.
  const bottomBand = () => {
    const composer = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect();
    if (!composer) return ["no composer"];
    const from = composer.top - 40;
    return [...document.querySelectorAll("#root *")]
      .map((element) => ({ element, box: element.getBoundingClientRect() }))
      .filter(({ box }) => box.height > 0 && box.bottom > from && box.height < 200)
      .slice(0, 60)
      .map(
        ({ element, box }) =>
          `${element.tagName.toLowerCase()}.${String(element.className).split(" ").slice(0, 2).join(".")} ${box.top.toFixed(0)}+${box.height.toFixed(0)}`,
      );
  };

  /// The load before the restart: acpmux up, the chat opened and settled, then its copy written as the
  /// page writes it (chatSnapshot/live.ts `watchChatSnapshot`).
  const warm = async (): Promise<ChatSnapshot> => {
    servedCopy = null;
    downMode = undefined;
    downUntil = 0;
    const context = await browser.newContext({ viewport: VIEWPORT });
    try {
      const page = await context.newPage();
      await prepare(page, null, 120_000);
      await page.goto(url);
      await page.waitForFunction(
        (quietMs) => {
          const recording = (window as unknown as BenchWindow).__firstLoad;
          return (
            recording.latestAt > 0 && performance.now() - Math.max(recording.latestAt, recording.changedAt) > quietMs
          );
        },
        SETTLE_QUIET_MS,
        { timeout: 120_000, polling: 100 },
      );
      await page.addScriptTag({ content: captureScript });
      const written = await page.evaluate((theme) => {
        const w = window as unknown as BenchWindow;
        w.__firstLoad.stop();
        const snapshot = w.captureSnapshot(document, theme);
        return { snapshot: snapshot ?? null, miss: snapshot ? "" : w.captureMiss() };
      }, THEME);
      if (TRACE) console.log(`warm bottom band:\n  ${(await page.evaluate(bottomBand)).join("\n  ")}`);
      if (TRACE)
        console.log(
          `warm rows at the copy: ${(
            await page.evaluate(() =>
              Array.from(document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]"))
                .map((row) => [row.dataset.rowId, row.getBoundingClientRect()] as const)
                .filter(([, box]) => box.bottom > 0 && box.top < innerHeight)
                .map(([id, box]) => `${id}@${box.top.toFixed(0)}+${box.height.toFixed(0)}`),
            )
          ).join(" ")}`,
        );
      if (!written.snapshot) throw new Error(`the settled page wrote no copy: ${written.miss}`);
      return written.snapshot;
    } finally {
      await context.close();
    }
  };

  /// The load after the restart: a cold context, the copy and the kept tail served, acpmux unavailable
  /// for DOWN_MS from navigation in `mode`.
  const relaunch = async (mode: Mode, copy: ChatSnapshot): Promise<Round> =>
    mode === "reopen-spare" ? adoptSpare() : openPage(mode, copy);

  /// MODE=reopen-spare: a spare New Tab page loads and settles in the warm renderer (as the app keeps one
  /// prewarmed), then takes the chat with the event the host sends (AgentPaneView.adoptSession), carrying the
  /// kept tail and the place (none kept: the newest message). Every number is ms from that event.
  const adoptSpare = async (): Promise<Round> => {
    if (!warmContext) throw new Error("reopen-spare needs the warm renderer");
    const page = await warmContext.newPage();
    servingSpare = true;
    try {
      if (CPU > 1) await (await warmContext.newCDPSession(page)).send("Emulation.setCPUThrottlingRate", { rate: CPU });
      await page.setViewportSize(RELAUNCH_VIEWPORT);
      await prepare(page, null, 600_000);
      await page.goto(spareUrl);
      await page.waitForFunction(
        (quietMs) => {
          const recording = (window as unknown as BenchWindow).__firstLoad;
          // Settled once it told the host it drew (`pane.painted`, as the app's spare does before it parks) and
          // nothing in view changed since.
          const painted = (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt;
          return painted !== undefined && performance.now() - Math.max(painted, recording.changedAt) > quietMs;
        },
        SETTLE_QUIET_MS,
        { timeout: 120_000, polling: 100 },
      );
      if (TRACE) console.log(`reopen-spare daemon calls before its adopt event: ${spareCalls.splice(0).join(", ")}`);
      if (TRACE)
        console.log(
          `reopen-spare before its adopt event: ${JSON.stringify(
            await page.evaluate(() => ({
              rows: document.querySelectorAll(".acpmux-row[data-row-id]").length,
              liveLatestAt: (window as unknown as BenchWindow).__firstLoad.liveLatestAt,
              now: performance.now(),
              text: (document.getElementById("root")?.textContent ?? "").replace(/\s+/g, " ").slice(0, 160),
            })),
          )}`,
        );
      {
        const metrics = await page.context().newCDPSession(page);
        await metrics.send("HeapProfiler.collectGarbage");
        await metrics.send("Performance.enable");
        const { metrics: read } = (await metrics.send("Performance.getMetrics")) as {
          metrics: { name: string; value: number }[];
        };
        const metric = (name: string) => read.find((entry) => entry.name === name)?.value ?? 0;
        spareHeapMb.push(metric("JSHeapUsedSize") / 1048576);
        spareNodes.push(metric("Nodes"));
        await metrics.send("Performance.disable");
        await metrics.detach();
      }
      const cdp = PROFILE ? await page.context().newCDPSession(page) : null;
      if (cdp) {
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
        await cdp.send("Profiler.start");
      }
      const start = await page.evaluate(
        ({ session, tail, recordMs }) => {
          const w = window as unknown as BenchWindow & { __firstLoadUntil?: number };
          const at = performance.now();
          const shift = w.__firstLoad.layoutShift;
          w.__firstLoadUntil = at + recordMs;
          window.dispatchEvent(
            new CustomEvent("acpmux-session-adopt", { detail: { sessionId: session, tail, scrollAnchor: null } }),
          );
          return { at, shift, syncMs: performance.now() - at };
        },
        { session: PAPERCUT_CHAT, tail: keptTail, recordMs: RECORD_MS },
      );
      adoptSyncMs.push(start.syncMs);
      await page.waitForFunction(() => (window as unknown as BenchWindow).__firstLoad.done, undefined, {
        timeout: RECORD_MS + 60_000,
        polling: 250,
      });
      const got = await page.evaluate(() => {
        const w = window as unknown as BenchWindow;
        return {
          frames: w.__firstLoad.frames,
          layoutShift: w.__firstLoad.layoutShift,
          layoutShifts: w.__firstLoad.shifts,
          live: w.__firstLoad.liveLatestAt,
        };
      });
      if (cdp) {
        const { profile } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
        await cdp.detach();
        addProfile(profile, start.at, got.live > start.at ? got.live : start.at + RECORD_MS);
      }
      if (TRACE)
        console.log(
          `reopen-spare rows in view at the end:\n  ${(
            await page.evaluate(() =>
              Array.from(document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]"))
                .slice(-14)
                .map(
                  (row) =>
                    `${row.dataset.rowId} ${row.getBoundingClientRect().top.toFixed(0)}+${row.getBoundingClientRect().height.toFixed(0)} "${(row.textContent ?? "").trim().slice(0, 60)}"`,
                ),
            )
          ).join("\n  ")}`,
        );
      const frames = got.frames
        .filter((frame) => frame.t >= start.at)
        .map((frame) => ({ ...frame, t: frame.t - start.at }));
      return {
        mode: "reopen-spare",
        metrics: classifyFrames(frames),
        frames,
        liveLatestMs: got.live > start.at ? got.live - start.at : null,
        layoutShift: got.layoutShift - start.shift,
        // Only the entries from the adopt event on, timed from it like the frames.
        layoutShifts: got.layoutShifts
          .filter((shift) => shift.at >= start.at)
          .map((shift) => ({ ...shift, at: shift.at - start.at })),
        copyShownMs: null,
        swapMs: null,
        hold: null,
        copyMiss: "none: the spare draws the carried tail",
        tailAskedMs: null,
        readyAnsweredMs: null,
        acpmuxUpMs: 0,
        refused: 0,
        socketOpenedMs: null,
        initializeAnsweredMs: null,
        attachAnsweredMs: null,
        boundMs: null,
        // The spare connected before its adopt event: no socket ask is timed from the event.
        asks: 0,
        lastAskMs: null,
        bytesDown: 0,
        wireDown: 0,
        rowsTaken: 0,
      };
    } finally {
      servingSpare = false;
      await page.close();
    }
  };

  const openPage = async (mode: Mode, copy: ChatSnapshot): Promise<Round> => {
    servedCopy = NO_COPY || ["native-ready-tail", "reopen-no-copy", "refused-no-copy"].includes(mode) ? null : copy;
    // A reopen builds its page in the warm renderer; a relaunch in a cold context.
    const context =
      isReopen(mode) && warmContext ? warmContext : await browser.newContext({ viewport: RELAUNCH_VIEWPORT });
    // The recorded page first, then the other restored chats' pages (PAGES), all navigated at once.
    const pages = await Promise.all(Array.from({ length: PAGES }, () => context.newPage()));
    if (context === warmContext) for (const one of pages) await one.setViewportSize(RELAUNCH_VIEWPORT);
    const page = pages[0]!;
    const windowMs = recordMs(mode);
    try {
      for (const one of pages) {
        if (CPU > 1) await (await context.newCDPSession(one)).send("Emulation.setCPUThrottlingRate", { rate: CPU });
        await prepare(
          one,
          mode === "reopen-no-copy" || NO_TAIL || ROWS_WINDOW ? null : keptTail,
          windowMs,
          mode.startsWith("native-ready") ? DOWN_MS : 0,
          isRefused(mode) ? DOWN_MS : 0,
          true,
        );
      }
      load = { refused: 0, socketOpenedAt: 0, initializeAnsweredAt: 0, attachAnsweredAt: 0, bytesDown: 0, wireDown: 0 };
      // acpmux is up for a reopen: only the page is new; a refusal comes from the host, the daemon is up.
      downMode = isReopen(mode) || isRefused(mode) ? undefined : mode;
      downUntil = isReopen(mode) ? 0 : Date.now() + DOWN_MS;
      const upAt = downUntil;
      // PROFILE=1: the profiler runs in the renderer the relaunch loads in (a blank page of the same origin first).
      const cdp = PROFILE ? await context.newCDPSession(page) : null;
      if (cdp) {
        await page.goto(new URL("/__profile-blank", url).href);
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
        await cdp.send("Profiler.start");
      }
      wireT0 = Date.now();
      endOpenTurn = OPEN_ENDS_MS > 0;
      await Promise.all(pages.map((one) => one.goto(url, { waitUntil: "commit" })));
      await page.waitForFunction(() => (window as unknown as BenchWindow).__firstLoad.done, undefined, {
        timeout: windowMs + 60_000,
        polling: 250,
      });
      if (TRACE) console.log(`${mode} relaunch bottom band:\n  ${(await page.evaluate(bottomBand)).join("\n  ")}`);
      if (WIRE_TRACE) {
        // The page's own launch marks (perf.ts `launchTimeline`), on the same clock as the wire lines.
        const launch = await page.evaluate(
          () =>
            (
              window as unknown as { cmuxAcpmuxDebug?: { perfStats(): { launch: Record<string, number> } } }
            ).cmuxAcpmuxDebug?.perfStats().launch ?? {},
        );
        const marks = Object.entries(launch)
          .filter(([name]) => name.endsWith("_epoch_ms"))
          .map(([name, at]) => `${name.replace(/_epoch_ms$/, "")} ${at - wireT0}`)
          .join(", ");
        console.log(`wire page marks (ms from the round's start): ${marks}`);
      }
      if (process.env.RES_TRACE === "1")
        console.log(
          "RES " +
            (await page.evaluate(() =>
              [
                ...(performance.getEntriesByType("resource") as PerformanceResourceTiming[]).map(
                  (e) => `${e.name.split("/").pop()} ${e.startTime.toFixed(0)}-${e.responseEnd.toFixed(0)}`,
                ),
                ...performance.getEntriesByType("mark").map((e) => `mark:${e.name} ${e.startTime.toFixed(0)}`),
                `dcl ${(performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming).domContentLoadedEventStart.toFixed(0)}`,
              ].join("\n  "),
            )),
        );
      const got = await page.evaluate(() => {
        const w = window as unknown as BenchWindow;
        return {
          frames: w.__firstLoad.frames,
          layoutShift: w.__firstLoad.layoutShift,
          layoutShifts: w.__firstLoad.shifts,
          origin: performance.timeOrigin,
          miss: w.__cmuxChatSnapshotMiss ?? null,
          shown: w.__cmuxChatSnapshotShown ?? null,
          tailAskedAt: w.__benchHost.tailAskedAt,
          readyAnsweredAt: w.__benchHost.readyAnsweredAt,
          liveLatestAt: w.__firstLoad.liveLatestAt,
          asks: w.__benchHost.asks,
          rowsTaken: w.__benchHost.rowsTaken,
        };
      });
      if (cdp) {
        const nowMs = await page.evaluate(() => performance.now());
        const { profile } = (await cdp.send("Profiler.stop")) as {
          profile: CpuProfile & { startTime: number; endTime: number };
        };
        await cdp.detach();
        const metrics = classifyFrames(got.frames);
        const settledMs = restartSettled(got.frames, metrics, got.liveLatestAt || null).settledMs ?? nowMs;
        addRelaunchProfile(profile, nowMs, metrics.firstContentMs ?? 0, settledMs, profiled + 1);
      }
      if (mode.startsWith("native-ready") && got.readyAnsweredAt < DOWN_MS - 20)
        throw new Error(`native ready delay was not exercised: ${got.readyAnsweredAt}`);
      const since = (epoch: number) => (epoch ? epoch - got.origin : null);
      const boundMs = BOUND ? await drawBound(page) : null;
      return {
        mode,
        metrics: classifyFrames(got.frames),
        frames: got.frames,
        liveLatestMs: got.liveLatestAt || null,
        layoutShift: got.layoutShift,
        layoutShifts: got.layoutShifts,
        copyShownMs: got.shown?.at ?? null,
        swapMs: got.shown?.swappedAt ?? null,
        hold: got.shown
          ? {
              by: got.shown.hold?.by ?? "read",
              atMs: got.shown.hold?.at ?? null,
              differs: got.shown.hold?.differs ?? null,
            }
          : null,
        copyMiss: got.miss,
        tailAskedMs: got.tailAskedAt || null,
        readyAnsweredMs: got.readyAnsweredAt || null,
        acpmuxUpMs: upAt - got.origin,
        refused: load.refused,
        socketOpenedMs: since(load.socketOpenedAt),
        initializeAnsweredMs: since(load.initializeAnsweredAt),
        attachAnsweredMs: since(load.attachAnsweredAt),
        boundMs,
        asks: got.asks.length,
        bytesDown: load.bytesDown,
        wireDown: load.wireDown,
        rowsTaken: got.rowsTaken,
        lastAskMs: (() => {
          const opened = since(load.socketOpenedAt);
          const before = opened === null ? [] : got.asks.filter((at) => at <= opened);
          return before.length ? Math.max(...before) : null;
        })(),
      };
    } finally {
      downMode = undefined;
      downUntil = 0;
      servedCopy = null;
      if (context === warmContext) for (const one of pages) await one.close();
      else await context.close();
    }
  };

  const byMode = new Map<Mode, Round[]>(MODES.map((mode) => [mode, []]));
  for (let round = 0; round < ROUNDS; round += 1)
    // Each relaunch draws the copy its own warm load wrote; modes alternate order so drift hits each alike.
    for (const mode of round % 2 ? [...MODES].reverse() : MODES) {
      const copy = await warm();
      byMode.get(mode)!.push(await relaunch(mode, copy));
    }

  const ms = (value: number | null) => (value === null ? "-" : value.toFixed(0));
  const median = (values: number[]) =>
    values.length ? [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]! : null;
  const max = (values: number[]) => (values.length ? Math.max(...values) : null);
  const numbers = (rounds: Round[], pick: (round: Round) => number | null) =>
    rounds.map(pick).filter((value): value is number => value !== null);
  const PICKS = {
    blankAfterContent: (r: Round) => r.metrics.blankAfterContent,
    shiftFrames: (r: Round) => r.metrics.shiftFrames,
    railFrames: (r: Round) => r.metrics.railFrames,
    finalFirstPaintMs: (r: Round) => r.metrics.finalFirstPaintMs,
    firstContentMs: (r: Round) => r.metrics.firstContentMs,
    layoutShift: (r: Round) => r.layoutShift,
    frames: (r: Round) => r.metrics.frames,
  } as const;
  // How long each round recorded is its mode's (`recordMs`: a refused mode records longer), so it goes with the mode.
  const json: Record<string, unknown> = { turns: TURNS, downMs: DOWN_MS, rounds: ROUNDS };
  let failed = false;
  for (const [mode, rounds] of byMode) {
    console.log(
      `first-load-after-restart [${mode}]: ${TURNS} turns, acpmux unavailable ${DOWN_MS} ms from navigation, recorded ${recordMs(mode)} ms, ${rounds.length} rounds; content ${CONTENT}, ${HEIGHT_DELTA} px shorter, ${PAGES} pages`,
    );
    console.log(
      "round | blank after content | shift frames | rail frames | final first paint ms | first content ms | layout shift | frames | copy drawn ms | swap ms | tail asked ms | acpmux up ms | refused | socket ms | initialize ms | attach ms | live ms",
    );
    rounds.forEach((r, at) =>
      console.log(
        [
          at + 1,
          r.metrics.blankAfterContent,
          r.metrics.shiftFrames,
          r.metrics.railFrames,
          ms(r.metrics.finalFirstPaintMs),
          ms(r.metrics.firstContentMs),
          r.layoutShift.toFixed(4),
          r.metrics.frames,
          r.copyShownMs === null ? `none (${r.copyMiss ?? "?"})` : ms(r.copyShownMs),
          ms(r.swapMs),
          ms(r.tailAskedMs),
          ms(r.acpmuxUpMs),
          r.refused,
          ms(r.socketOpenedMs),
          ms(r.initializeAnsweredMs),
          ms(r.attachAnsweredMs),
          ms(r.liveLatestMs),
        ].join(" | "),
      ),
    );
    if (SOURCES)
      rounds.forEach((r, at) => {
        for (const shift of r.layoutShifts)
          console.log(
            `  round ${at + 1} layout shift at ${shift.at} ms, ${shift.value}: ${shift.moved
              .map((moved) => `${moved.node} ${moved.from.join(",")} -> ${moved.to.join(",")}`)
              .join("; ")}`,
          );
      });
    const summary = (of: (values: number[]) => number | null) =>
      Object.fromEntries(Object.entries(PICKS).map(([key, pick]) => [key, of(numbers(rounds, pick))]));
    const medians = summary(median);
    const maxima = summary(max);
    for (const [label, values] of [
      ["median", medians],
      ["max", maxima],
    ] as const)
      console.log(
        [
          label,
          ...(["blankAfterContent", "shiftFrames", "finalFirstPaintMs", "firstContentMs"] as const).map((key) =>
            ms(values[key] ?? null),
          ),
          (values.layoutShift ?? 0).toFixed(4),
        ].join(" | "),
      );
    if (mode === "down") {
      // How long after acpmux answers again the page finds it (its retry wait, hostRetry.ts) and has its chat
      // back: the socket that opened, and its attach answered, less when acpmux came back. p50 and p95.
      const pct = (values: number[], share: number) =>
        values.length
          ? [...values].sort((a, b) => a - b)[Math.min(values.length - 1, Math.floor(share * values.length))]!
          : null;
      const after = (pick: (r: Round) => number | null) =>
        numbers(rounds, (r) => {
          const at = pick(r);
          return at === null ? null : at - r.acpmuxUpMs;
        });
      const socket = after((r) => r.socketOpenedMs);
      const attach = after((r) => r.attachAnsweredMs);
      console.log(
        `relink after acpmux up (${DOWN_MS} ms down, ${TRANSPORT}): socket p50 ${ms(pct(socket, 0.5))} ms, p95 ${ms(pct(socket, 0.95))} ms; chat attached p50 ${ms(pct(attach, 0.5))} ms, p95 ${ms(pct(attach, 0.95))} ms (n=${rounds.length})`,
      );
      // The relink in two parts: the page's wait for its next ask (its retry schedule), and that ask to the
      // socket opening (the transport: a browser that holds back a renderer's WebSocket opens shows here).
      const askWait = after((r) => r.lastAskMs);
      const askToOpen = numbers(rounds, (r) =>
        r.lastAskMs === null || r.socketOpenedMs === null ? null : r.socketOpenedMs - r.lastAskMs,
      );
      const asks = numbers(rounds, (r) => r.asks);
      console.log(
        `relink parts: next ask after acpmux up p50 ${ms(pct(askWait, 0.5))} ms, p95 ${ms(pct(askWait, 0.95))} ms; ask to socket open p50 ${ms(pct(askToOpen, 0.5))} ms, p95 ${ms(pct(askToOpen, 0.95))} ms; asks p50 ${pct(asks, 0.5)}, refused p50 ${pct(
          numbers(rounds, (r) => r.refused),
          0.5,
        )}`,
      );
      json.relink = {
        transport: TRANSPORT,
        socketP50: pct(socket, 0.5),
        socketP95: pct(socket, 0.95),
        attachP50: pct(attach, 0.5),
        attachP95: pct(attach, 0.95),
        askWaitP50: pct(askWait, 0.5),
        askWaitP95: pct(askWait, 0.95),
        askToOpenP50: pct(askToOpen, 0.5),
        askToOpenP95: pct(askToOpen, 0.95),
        asksP50: pct(asks, 0.5),
      };
    }
    // Where the time to a live chat goes, medians in ms from navigation: daemon ready (acpmux answers or
    // the host stops refusing), the attach (socket open, attach answered), first content, live.
    const split = {
      daemonReady: median(numbers(rounds, (r) => (isReopen(r.mode) ? null : r.acpmuxUpMs))),
      socket: median(numbers(rounds, (r) => r.socketOpenedMs)),
      attach: median(numbers(rounds, (r) => r.attachAnsweredMs)),
      firstContent: median(numbers(rounds, (r) => r.metrics.firstContentMs)),
      live: median(numbers(rounds, (r) => r.liveLatestMs)),
    };
    console.log(
      `restart split [${mode}] (medians, ms from navigation): daemon ready ${ms(split.daemonReady)}, socket open ${ms(split.socket)}, attach answered ${ms(split.attach)}, first content ${ms(split.firstContent)}, live ${ms(split.live)}`,
    );
    json[`${mode}.split`] = split;
    // Restart to settled (bench/restartSettled.ts), what scripts/measure/restart-settled-linux.sh sets beside the
    // terminal's reattach under the same LINK: medians over the rounds.
    const settled = rounds.map((r) => restartSettled(r.frames, r.metrics, r.liveLatestMs, OPEN_ENDS_MS > 0));
    const settledRow = {
      link: LINK_NAME,
      mode,
      downMs: DOWN_MS,
      turns: TURNS,
      engine: ENGINE,
      rounds: rounds.length,
      firstContentMs: median(settled.map((one) => one.firstContentMs).filter((v): v is number => v !== null)),
      settledMs: median(settled.map((one) => one.settledMs).filter((v): v is number => v !== null)),
      notSettled: settled.filter((one) => one.settledMs === null).length,
      liveMs: split.live,
      attachMs: split.attach,
      shifts: median(settled.map((one) => one.shifts)),
      shiftPxMax: max(settled.map((one) => one.shiftPxMax)),
      fixture: FIXTURE,
      open: OPEN,
      openEndsMs: OPEN_ENDS_MS,
      cpu: CPU,
      goneRows: median(settled.map((one) => one.goneRows)),
      goneFrames: median(settled.map((one) => one.goneFrames)),
      goneRowsMax: max(settled.map((one) => one.goneRows)),
      bytesDown: median(rounds.map((r) => r.bytesDown)),
      wireDown: median(rounds.map((r) => r.wireDown)),
      zlib: LINK_ZLIB,
      rowStore: rounds.every((r) => r.rowsTaken > 0),
      settledEach: settled.map((one) => one.settledMs),
    };
    console.log(`RESTART_SETTLED_JSON ${JSON.stringify(settledRow)}`);
    json[`${mode}.settled`] = settledRow;
    // How each round's wait for the draft ran out: a composer that never matches the copy's holds the
    // copy to the 2 s cap, the wait cmux#45669 removed (cmux#45994 review).
    const holds: Record<string, number> = { shown: 0, match: 0, read: 0, cap: 0 };
    for (const r of rounds) if (r.hold) holds[r.hold.by] = (holds[r.hold.by] ?? 0) + 1;
    const differs = [...new Set(rounds.flatMap((r) => (r.hold?.differs ? [r.hold.differs] : [])))];
    const counts = Object.entries(holds).map(([by, count]) => `${by} ${count}`);
    console.log(
      `draft wait [${mode}]: ${counts.join(", ")}${differs.length ? `; at the cap: ${differs.join(" | ")}` : ""}`,
    );
    json[`${mode}.hold`] = holds;
    for (const r of rounds) if (r.copyShownMs === null) console.log(`  warning: a round drew no copy (${r.copyMiss})`);
    // A round that never handed over to the live chat proves nothing: a copy held over the whole
    // recording paints no blank and no shift.
    for (const r of rounds)
      if (r.liveLatestMs === null) console.log("  failed: the live chat never showed the newest answer");
    const bad = rounds.filter(
      (r) =>
        r.metrics.blankAfterContent > 0 ||
        r.metrics.shiftFrames > 0 ||
        r.liveLatestMs === null ||
        r.metrics.firstContentMs === null ||
        r.metrics.firstContentMs > 2000,
    );
    if (bad.length > 0) failed = true;
    if (TRACE) {
      const score = (r: Round) => r.metrics.blankAfterContent + r.metrics.shiftFrames + r.metrics.railFrames;
      const worst = [...rounds].sort(
        (a, b) => score(b) - score(a) || (b.metrics.finalFirstPaintMs ?? 0) - (a.metrics.finalFirstPaintMs ?? 0),
      )[0];
      if (worst) {
        console.log(`trace of the worst ${mode} round (ms from navigation; B blank after content, S shift):`);
        const shifts = new Map(worst.metrics.shiftAt.map(({ index, why }) => [index, why]));
        const railMoves = new Map(worst.metrics.railAt.map(({ index, why }) => [index, why]));
        const blanks = new Set(worst.metrics.blankAt);
        const final = new Set((worst.frames.at(-1)?.rows ?? []).map((row) => row.id));
        worst.frames.forEach((frame, at) => {
          const gone = frame.rows.filter((row) => !final.has(row.id) && !(OPEN_ENDS_MS > 0 && liveTurnLine(row.id)));
          const bottom = frame.rows.at(-1);
          const layer = frame.copyShown ? "copy" : frame.rootHidden ? "hid " : "live";
          const marks = `${blanks.has(at) ? "B" : " "}${shifts.has(at) ? "S" : " "}`;
          const composer = frame.composer
            ? `${frame.composer.top.toFixed(1)}+${frame.composer.height.toFixed(1)}`
            : "-";
          console.log(
            [
              `  ${frame.t.toFixed(0).padStart(6)} ${layer} ${marks} rows ${String(frame.rows.length).padStart(2)}`,
              `bottom ${bottom ? `${bottom.id}@${bottom.top.toFixed(1)}` : "-"} "${frame.bottomText}"`,
              `composer ${composer}`,
              `scrollTop ${frame.scrollTop === null ? "-" : frame.scrollTop.toFixed(0)}`,
              `rail ${frame.rail ? `${frame.rail.top.toFixed(0)}+${frame.rail.height.toFixed(0)} ${frame.rail.rows} rows list ${frame.rail.listTop.toFixed(0)} lit ${frame.rail.lit || "-"}${frame.rail.animating ? ` anim ${frame.rail.animating}` : ""}` : "-"}`,
              ...(railMoves.has(at) ? [`R ${railMoves.get(at)!}`] : []),
              ...(gone.length
                ? [
                    `gone later ${gone.length}: ${gone
                      .map((row) => row.id)
                      .slice(0, 6)
                      .join(" ")}`,
                  ]
                : []),
              ...(shifts.has(at) ? [shifts.get(at)!] : []),
              // A shift names every row in view on both sides of it, so the row that came, went or moved shows.
              ...(shifts.has(at) && at > 0
                ? [
                    `was ${worst.frames[at - 1]!.rows.map((row) => `${row.id}@${row.top.toFixed(0)}`).join(" ")}`,
                    `now ${frame.rows.map((row) => `${row.id}@${row.top.toFixed(0)}`).join(" ")}`,
                  ]
                : []),
            ].join(" | "),
          );
        });
        console.log(
          `  final rows in view:\n    ${(worst.frames.at(-1)?.rows ?? [])
            .map((row) => `${row.id}@${row.top.toFixed(0)} "${(row.text ?? "").trim().slice(0, 50)}"`)
            .join("\n    ")}`,
        );
      }
    }
    if (isReopen(mode)) {
      // What a person sees on reopen: the first content (the copy or the live page), when the live page shows the
      // newest answer (it takes input), blank and shift frames; p50 and p95 over the rounds.
      const pct = (values: number[], share: number) =>
        values.length
          ? [...values].sort((a, b) => a - b)[Math.min(values.length - 1, Math.floor(share * values.length))]!
          : null;
      const first = numbers(rounds, (r) => r.metrics.firstContentMs);
      const live = numbers(rounds, (r) => r.liveLatestMs);
      const blanks = rounds.reduce((sum, r) => sum + r.metrics.blankAfterContent, 0);
      const shifts = rounds.reduce((sum, r) => sum + r.metrics.shiftFrames, 0);
      console.log(
        `${mode}: first content p50 ${ms(pct(first, 0.5))} ms, p95 ${ms(pct(first, 0.95))} ms; live (newest answer, takes input) p50 ${ms(pct(live, 0.5))} ms, p95 ${ms(pct(live, 0.95))} ms; blank frames ${blanks}, shift frames ${shifts} (n=${rounds.length})`,
      );
      const row = mode.replaceAll("-", "_");
      perfRow({
        name: `first_load_after_restart.${row}.first_content`,
        p50: pct(first, 0.5) ?? 0,
        p95: pct(first, 0.95) ?? 0,
        unit: "ms",
      });
      perfRow({
        name: `first_load_after_restart.${row}.live`,
        p50: pct(live, 0.5) ?? 0,
        p95: pct(live, 0.95) ?? 0,
        unit: "ms",
      });
    }
    json[mode] = {
      recordMs: recordMs(mode),
      rounds: rounds.map(({ frames: _frames, metrics: { blankAt: _blankAt, shiftAt, ...metrics }, ...rest }) => ({
        ...rest,
        ...metrics,
        shifts: shiftAt.slice(0, 20),
      })),
      median: medians,
      max: maxima,
      // Rows a frame showed that the settled chat does not (restartSettled.ts `goneRows`), per round.
      gone: rounds.map((r) => goneRows(r.frames, OPEN_ENDS_MS > 0)),
    };
    const row = mode.replace("-", "_");
    for (const [metric, key, unit] of [
      ["blank_after_content", "blankAfterContent", "count"],
      ["shift_frames", "shiftFrames", "count"],
      ["final_first_paint", "finalFirstPaintMs", "ms"],
    ] as const)
      perfRow({
        name: `first_load_after_restart.${row}.${metric}`,
        p50: medians[key] ?? 0,
        p95: maxima[key] ?? 0,
        unit,
      });
  }
  if (adoptSyncMs.length) {
    const sorted = [...adoptSyncMs].sort((a, b) => a - b);
    const at = (share: number) => sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
    console.log(
      `reopen-spare adopt event's own task: p50 ${at(0.5).toFixed(1)} ms, p95 ${at(0.95).toFixed(1)} ms, max ${sorted.at(-1)!.toFixed(1)} ms (n=${sorted.length}${PROFILE ? ", profiled" : ""})`,
    );
    json.adoptSync = { p50: at(0.5), p95: at(0.95), max: sorted.at(-1), n: sorted.length };
    const middle = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)] ?? 0;
    console.log(
      `reopen-spare parked spare before its adopt: JS heap p50 ${middle(spareHeapMb).toFixed(2)} MB, DOM nodes p50 ${middle(spareNodes)}`,
    );
    json.spare = { heapMbP50: middle(spareHeapMb), nodesP50: middle(spareNodes) };
  }
  console.log(`FIRST_LOAD_JSON ${JSON.stringify(json)}`);
  printProfile();
  if (GATE && failed) {
    console.error(
      "first-load-after-restart: a round exceeded 2000 ms to transcript, blanked after content, moved it, or never drew live content (GATE=1)",
    );
    process.exitCode = 1;
  }
} finally {
  await release();
}
