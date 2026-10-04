/// <reference types="vite/client" />
// Streaming bench: replays a recorded agent turn (fixtures/*-turn.json) with its recorded timing
// into one assistant message, two ways, so before and after numbers come from the same input.
//
//   /bench/stream/?mode=before   the pane's behavior today: every chunk re-renders the whole message
//                                through the production <Markdown>, revealed as it arrives
//   /bench/stream/?mode=after    RevealPacer (pacer.ts) + StreamingMarkdown (incremental parse,
//                                streaming-safe tail, soft reveal) + a glide when pinned to the end
//   /bench/stream/?mode=parse    parse cost per delta: whole-message re-parse vs the incremental split
//   &fixture=claude|codex  &speed=1  &limit=MS (replay only the first MS of the turn)  &reduced
//
// Instrumented by instrument.js (Playwright addInitScript); the runner is run-bench.mjs.
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "./bench.css";
import { Profiler, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { Markdown, parseMarkdown } from "../../src/agent-session/acpmux/conversation/Markdown";
import { markdownBlocks } from "../../src/agent-session/acpmux/model";
import { RevealPacer, safeCut, wordCut } from "./pacer";
import { FADE_MS, StableSplitter, StreamingMarkdown, safeTail, type Reveal } from "./StreamingMarkdown";

type Step = { atMs: number; update: { content: { text: string } } };
type StreamState = {
  ws: unknown[];
  react: number[];
  phase: string;
  done?: boolean;
  parse?: unknown;
  [key: string]: unknown;
};

const params = new URLSearchParams(location.search);
const mode = params.get("mode") ?? "after";
const fixture = params.get("fixture") ?? "claude";
const speed = Number(params.get("speed") ?? 1) || 1;
const limit = Number(params.get("limit") ?? 0) || Infinity;
/// `hz`: at most this many React commits a second (fades still run on the compositor every frame).
const commitHz = Number(params.get("hz") ?? 0) || 0;
const reduced = params.has("reduced") || matchMedia("(prefers-reduced-motion: reduce)").matches;
const stream = () => (window as unknown as { __stream: StreamState }).__stream;

const loaded = (await (await fetch(`./fixtures/${fixture}-turn.json`)).json()) as { steps: [number, string][] };
const steps: Step[] = loaded.steps
  .filter(([atMs]) => atMs <= limit)
  .map(([atMs, text]) => ({ atMs, update: { content: { text } } }));
const full = steps.map((step) => step.update.content.text).join("");

/** Replays the steps with their recorded spacing; `onEnd` after the last. */
function replay(onChunk: (text: string, now: number) => void, onEnd: () => void): void {
  const start = performance.now() + 50;
  for (const step of steps)
    setTimeout(
      () => {
        const now = performance.now();
        const text = step.update.content.text;
        stream().ws.push([now, text.length + 420, "agent_message_chunk", text.length]);
        onChunk(text, now);
      },
      Math.max(0, start + step.atMs / speed - performance.now()),
    );
  setTimeout(onEnd, Math.max(0, start + (steps.at(-1)?.atMs ?? 0) / speed + 30 - performance.now()));
}

/** Keeps the end in view while pinned. `glide` animates each growth as a translate (compositor only). */
function usePinnedScroll(
  scroller: React.RefObject<HTMLDivElement | null>,
  content: React.RefObject<HTMLDivElement | null>,
  glide: boolean,
) {
  const pinned = useRef(true);
  const lastHeight = useRef(0);
  useLayoutEffect(() => {
    const node = scroller.current;
    const inner = content.current;
    if (!node || !inner) return;
    const height = node.scrollHeight;
    const grew = height - lastHeight.current;
    lastHeight.current = height;
    if (!pinned.current) return;
    node.scrollTop = height - node.clientHeight;
    if (glide && grew > 0.5 && grew < node.clientHeight)
      inner.animate([{ transform: `translateY(${grew}px)` }, { transform: "translateY(0)" }], {
        duration: 180,
        easing: "cubic-bezier(0.2, 0, 0, 1)",
        composite: "add",
      });
  });
  const onScroll = () => {
    const node = scroller.current;
    if (!node) return;
    pinned.current = node.scrollTop >= node.scrollHeight - node.clientHeight - 2;
    lastHeight.current = node.scrollHeight;
  };
  return onScroll;
}

const onRender = (_id: string, _phase: string, actualDuration: number) => stream()?.react.push(actualDuration);

function Before() {
  "use no memo";
  const [text, setText] = useState("");
  const [streaming, setStreaming] = useState(true);
  const scroller = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLDivElement>(null);
  const onScroll = usePinnedScroll(scroller, content, false);
  const started = useRef(false);
  if (!started.current) {
    started.current = true;
    let source = "";
    replay(
      (delta) => {
        source += delta;
        setText(source);
      },
      () => {
        setStreaming(false);
        stream().done = true;
      },
    );
  }
  return (
    <div ref={scroller} className="sv-scroll acpmux-scroll" onScroll={onScroll}>
      <div ref={content} className="sv-thread">
        <article className="acpmux-row acpmux-assistant" data-streaming={streaming || undefined}>
          <Profiler id="message" onRender={onRender}>
            <Markdown>{text}</Markdown>
          </Profiler>
        </article>
      </div>
    </div>
  );
}

function After() {
  "use no memo";
  const [view, setView] = useState({ shown: 0, now: 0, streaming: true, waiting: false });
  const scroller = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLDivElement>(null);
  const onScroll = usePinnedScroll(scroller, content, !reduced);
  const state = useRef<{
    source: string;
    pacer: RevealPacer;
    splitter: StableSplitter;
    reveals: Reveal[];
    nextId: number;
    ended: boolean;
    last: number;
    committed: number;
    waiting: boolean;
  } | null>(null);
  if (!state.current) {
    const s = {
      source: "",
      pacer: new RevealPacer(),
      splitter: new StableSplitter(),
      reveals: [] as Reveal[],
      nextId: 1,
      ended: false,
      last: 0,
      committed: 0,
      waiting: false,
    };
    state.current = s;
    replay(
      (delta, now) => {
        s.source += delta;
        s.pacer.arrived(now, delta.length);
      },
      () => {
        s.ended = true;
        s.pacer.finish();
      },
    );
    const frame = (now: number) => {
      if (commitHz && !s.ended && now - s.committed < 1000 / commitHz - 2) {
        requestAnimationFrame(frame);
        return;
      }
      let shown = safeCut(s.source, s.pacer.tick(now));
      if (reduced) shown = wordCut(s.source, shown, s.ended ? s.source.length : s.pacer.received);
      while (s.reveals.length && now - s.reveals[0].born > FADE_MS) s.reveals.shift();
      const done = s.ended && shown >= s.source.length;
      if (shown > s.last) s.reveals.push({ id: s.nextId++, count: shown - s.last, born: now });
      const changed = shown !== s.last || done;
      const waiting = !done && shown >= s.pacer.received;
      s.last = shown;
      if (changed || waiting !== s.waiting) {
        s.waiting = waiting;
        s.committed = now;
        flushSync(() => setView({ shown, now, streaming: !done, waiting }));
      }
      if (done) {
        stream().done = true;
        return;
      }
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }
  const s = state.current;
  return (
    <div ref={scroller} className={`sv-scroll acpmux-scroll${view.waiting ? " sv-waiting" : ""}`} onScroll={onScroll}>
      <div ref={content} className="sv-thread">
        <article className="acpmux-row acpmux-assistant">
          <Profiler id="message" onRender={onRender}>
            <StreamingMarkdown
              source={s.source.slice(0, view.shown)}
              splitter={s.splitter}
              reveals={view.streaming ? s.reveals : []}
              now={view.now}
              streaming={view.streaming}
              fade={!reduced}
            />
          </Profiler>
        </article>
      </div>
    </div>
  );
}

/**
 * Parse cost over the cumulative message, both ways. Timers are coarse (0.1 ms or worse without
 * cross-origin isolation), so each figure times a whole pass: every delta's parse in sequence, and
 * the full message parsed REPEAT times for the per-delta cost at the end of the turn.
 */
function parseBench() {
  const REPEAT = 50;
  const time = (fn: () => void) => {
    const start = performance.now();
    fn();
    return performance.now() - start;
  };
  const prefixes: string[] = [];
  let source = "";
  for (const step of steps) prefixes.push((source += step.update.content.text));
  const incrementalPass = () => {
    const splitter = new StableSplitter();
    const parsed = new Set<number>();
    for (const prefix of prefixes) {
      splitter.update(prefix);
      const bounds = splitter.boundaries;
      // A closed segment parses once, the first time it is closed.
      for (let index = 0; index < bounds.length - 1; index += 1)
        if (!parsed.has(bounds[index])) {
          parsed.add(bounds[index]);
          parseMarkdown(prefix.slice(bounds[index], bounds[index + 1]));
        }
      parseMarkdown(safeTail(prefix.slice(bounds.at(-1) ?? 0)).text);
    }
  };
  // Warm the JIT once.
  for (const prefix of prefixes.slice(0, 50)) parseMarkdown(prefix);
  incrementalPass();
  const r = (value: number) => Math.round(value * 1000) / 1000;
  const wholeTotal = time(() => prefixes.forEach((prefix) => parseMarkdown(prefix)));
  const lexerTotal = time(() => prefixes.forEach((prefix) => markdownBlocks(prefix)));
  const incrementalTotal = time(incrementalPass);
  const wholeLast = time(() => {
    for (let index = 0; index < REPEAT; index += 1) parseMarkdown(full);
  });
  const lexerLast = time(() => {
    for (let index = 0; index < REPEAT; index += 1) markdownBlocks(full);
  });
  const splitter = new StableSplitter();
  splitter.update(full.slice(0, -40));
  const tailLast = time(() => {
    for (let index = 0; index < REPEAT; index += 1) {
      splitter.update(full);
      parseMarkdown(safeTail(full.slice(splitter.boundaries.at(-1) ?? 0)).text);
    }
  });
  stream().parse = {
    deltas: steps.length,
    chars: full.length,
    totalMs: {
      renderParse: r(wholeTotal),
      layoutLexer: r(lexerTotal),
      both: r(wholeTotal + lexerTotal),
      incremental: r(incrementalTotal),
    },
    perDeltaAtEndMs: {
      renderParse: r(wholeLast / REPEAT),
      layoutLexer: r(lexerLast / REPEAT),
      incrementalTail: r(tailLast / REPEAT),
    },
  };
  stream().done = true;
}

const root = document.getElementById("root")!;
if (mode === "parse") parseBench();
else
  createRoot(root).render(
    <>
      {mode === "before" ? <Before /> : <After />}
      <div className="sv-composer" />
    </>,
  );
