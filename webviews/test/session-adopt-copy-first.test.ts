// A released chat that a prewarmed spare page takes shows its saved copy before the switch's render
// (newtab/adoption.ts `sessionAdoptHandler`). The switch remounts the whole chat in one render (68 ms at 10
// turns, 97 ms at 100: first-load-after-restart.bench.ts MODE=reopen-spare PROFILE=1), so a switch in the
// event's own turn kept the pane on its cover until it ended. Leo, 2026-11-16: "the dream is infinite chats
// of infinite length with flat or no growth in cpu/memory/even disk": a hidden chat gives its page back, and
// the way back to it must stay fast. These hold it:
//   - the copy is drawn first, and the switch renders only after the frame that shows it;
//   - a chat with no copy switches as soon as the host says so, with no frame wait;
//   - a host that answers past ADOPT_COPY_WAIT_MS does not hold the switch, and its late copy draws nothing;
//   - a subagent's pane switches in the event's own turn;
//   - a newer adopt event wins: the older one never switches.
import { expect, test } from "bun:test";
import {
  ADOPT_COPY_WAIT_MS,
  sessionAdoptHandler,
  type AdoptCopy,
  type SessionAdoption,
} from "../src/agent-session/acpmux/newtab/adoption";

type Ask = { sessionId: string; current: () => boolean; answer: (drew: boolean) => void };

/// A fake page: copy asks the test answers, frames and timers the test runs, and a log of what happened.
function fakePage() {
  const log: string[] = [];
  const asks: Ask[] = [];
  const frames: (() => void)[] = [];
  const timers: { at: number; run: () => void }[] = [];
  const copy: AdoptCopy = {
    draw: (sessionId, current) =>
      new Promise<boolean>((resolve) => {
        log.push(`ask ${sessionId}`);
        asks.push({
          sessionId,
          current,
          answer: (drew) => {
            const draws = drew && current();
            if (draws) log.push(`copy ${sessionId}`);
            resolve(draws);
          },
        });
      }),
    afterFrame: (run) => void frames.push(run),
    wait: (run, ms) => void timers.push({ at: ms, run }),
  };
  const adopted: SessionAdoption[] = [];
  const handle = sessionAdoptHandler((adoption) => {
    log.push(`switch ${adoption.sessionId}`);
    adopted.push(adoption);
  }, copy);
  const adopt = (detail: unknown) => handle(new CustomEvent("acpmux-session-adopt", { detail }));
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  const frame = () => frames.splice(0).forEach((run) => run());
  const elapse = (ms: number) => {
    for (const timer of timers.splice(0)) if (timer.at <= ms) timer.run();
  };
  return { log, asks, adopted, adopt, settle, frame, elapse };
}

test("the saved copy is drawn first, and the switch renders after the frame that shows it", async () => {
  const page = fakePage();
  page.adopt({ sessionId: "s-1", tail: { events: [] }, scrollAnchor: null });
  // The event's own turn asks for the copy and does not switch yet.
  expect(page.log).toEqual(["ask s-1"]);
  page.asks[0]!.answer(true);
  await page.settle();
  expect(page.log).toEqual(["ask s-1", "copy s-1"]);
  page.frame();
  expect(page.log).toEqual(["ask s-1", "copy s-1", "switch s-1"]);
  expect(page.adopted[0]).toEqual({ sessionId: "s-1", tail: { events: [] }, scrollAnchor: null });
  // The wait timer that comes after changes nothing: one switch per adopt.
  page.elapse(ADOPT_COPY_WAIT_MS);
  expect(page.adopted.length).toBe(1);
});

test("a chat with no saved copy switches as soon as the host says so", async () => {
  const page = fakePage();
  page.adopt({ sessionId: "s-2", scrollAnchor: null });
  page.asks[0]!.answer(false);
  await page.settle();
  expect(page.log).toEqual(["ask s-2", "switch s-2"]);
});

test("a host that answers late does not hold the switch, and its copy draws nothing", async () => {
  const page = fakePage();
  page.adopt({ sessionId: "s-3", scrollAnchor: null });
  page.elapse(ADOPT_COPY_WAIT_MS);
  expect(page.log).toEqual(["ask s-3", "switch s-3"]);
  expect(page.asks[0]!.current()).toBe(false);
  page.asks[0]!.answer(true);
  await page.settle();
  page.frame();
  expect(page.log).toEqual(["ask s-3", "switch s-3"]);
});

test("a subagent's pane switches in the event's own turn", () => {
  const page = fakePage();
  page.adopt({ sessionId: "s-4", revealTurn: "subagent:task-1", scrollAnchor: null });
  expect(page.log).toEqual(["switch s-4"]);
});

test("a newer adopt wins: the older one never switches", async () => {
  const page = fakePage();
  page.adopt({ sessionId: "s-5", scrollAnchor: null });
  page.adopt({ sessionId: "s-6", scrollAnchor: null });
  expect(page.asks[0]!.current()).toBe(false);
  page.asks[0]!.answer(true);
  page.asks[1]!.answer(true);
  await page.settle();
  page.frame();
  expect(page.log).toEqual(["ask s-5", "ask s-6", "copy s-6", "switch s-6"]);
});
