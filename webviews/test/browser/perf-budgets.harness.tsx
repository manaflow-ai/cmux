// Each runtime perf budget's class, reintroduced, beside its fix (perf-budgets.browser.test.ts).
// `?case=` picks one; `window.__perfCase.done` resolves once the case has done everything it does,
// after the budgets' settle second, so the page's load is not what is measured.
import { useEffect, useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { usePageNow } from "../../src/ui/pageClock";
import { VirtualList } from "../../src/ui/VirtualList";

const ROWS = 1000;
const TICKING_ROWS = 50;
const AFTER_SETTLE_MS = 1300;
const kind = new URLSearchParams(location.search).get("case") ?? "";
let finish: () => void = () => {};
(window as unknown as { __perfCase: { done: Promise<void> } }).__perfCase = {
  done: new Promise<void>((resolve) => (finish = resolve)),
};
const afterSettle = (run: () => void) => {
  if (document.readyState === "complete") setTimeout(run, AFTER_SETTLE_MS);
  else window.addEventListener("load", () => setTimeout(run, AFTER_SETTLE_MS), { once: true });
};
const rows = Array.from({ length: ROWS }, (_, index) => `Project ${index}`);

/// #36132: every project a row in the DOM.
function WholeList() {
  useEffect(() => afterSettle(finish), []);
  return (
    <ul className="projects">
      {rows.map((row) => (
        <li key={row}>{row}</li>
      ))}
    </ul>
  );
}

/// The fix: only the visible window.
function WindowedList() {
  useEffect(() => afterSettle(finish), []);
  return (
    <div style={{ height: 400, display: "flex" }}>
      <VirtualList
        count={ROWS}
        estimateSize={() => 24}
        renderRow={(index, style) => <div style={style}>{rows[index]}</div>}
      />
    </div>
  );
}

/// #28753: a timer per activity line.
function TimerRow() {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  return <li>{Math.floor(now / 1000)}</li>;
}

/// The fix: every line on the page clock.
function ClockRow() {
  return <li>{Math.floor(usePageNow(true) / 1000)}</li>;
}

function Ticking({ Row }: { Row: () => React.ReactNode }) {
  useEffect(() => afterSettle(finish), []);
  return (
    <ul>
      {Array.from({ length: TICKING_ROWS }, (_, index) => (
        <Row key={index} />
      ))}
    </ul>
  );
}

/// #24503 / #30543: a box that moves 40 px after it painted; the fix moves it with a transform.
function Moving({ transform }: { transform: boolean }) {
  const [moved, setMoved] = useState(false);
  useEffect(() => afterSettle(() => setMoved(true)), []);
  useEffect(() => {
    if (moved) requestAnimationFrame(() => requestAnimationFrame(() => finish()));
  }, [moved]);
  // Late content above the box (a spacer that grows) pushes it down; the fix keeps the content
  // where it is and moves the box with a transform. flow-root keeps margins from collapsing out.
  return (
    <div style={{ display: "flow-root" }}>
      <div style={{ height: moved && !transform ? 40 : 0 }} />
      <div
        className="moving-box"
        style={{
          width: 300,
          height: 120,
          background: "#888",
          transform: moved && transform ? "translateY(40px)" : undefined,
        }}
      >
        box
      </div>
    </div>
  );
}

/// #34004 / #27911: a commit per chunk, chunks every 2 ms for 1.5 s; the fix commits once a frame.
function stream(perFrame: boolean, add: (chunks: number) => void) {
  const end = performance.now() + 1500;
  let pending = 0;
  let frame = 0;
  const timer = window.setInterval(() => {
    pending += 1;
    if (!perFrame) {
      add(pending);
      pending = 0;
    } else
      frame ||= requestAnimationFrame(() => {
        frame = 0;
        add(pending);
        pending = 0;
      });
    if (performance.now() > end) {
      clearInterval(timer);
      setTimeout(finish, 100);
    }
  }, 2);
}

function Streaming({ perFrame }: { perFrame: boolean }) {
  const [chunks, setChunks] = useState(0);
  useEffect(() => afterSettle(() => stream(perFrame, (more) => setChunks((count) => count + more))), [perFrame]);
  return <p>{chunks} chunks</p>;
}

/// A slow commit: each update renders for 30 ms.
function SlowRender() {
  const [count, setCount] = useState(0);
  useEffect(
    () =>
      afterSettle(() => {
        setCount(1);
        setTimeout(finish, 200);
      }),
    [],
  );
  if (count > 0) {
    const until = performance.now() + 30;
    while (performance.now() < until) {
      // busy
    }
  }
  return <p>{count}</p>;
}

/// A long frame: 120 ms of script in one task.
function Busy() {
  useLayoutEffect(
    () =>
      afterSettle(() => {
        const until = performance.now() + 120;
        while (performance.now() < until) {
          // busy
        }
        setTimeout(finish, 300);
      }),
    [],
  );
  return <p>busy</p>;
}

const CASES: Record<string, () => React.ReactNode> = {
  "whole-list": () => <WholeList />,
  "windowed-list": () => <WindowedList />,
  "timer-per-row": () => <Ticking Row={TimerRow} />,
  "page-clock": () => <Ticking Row={ClockRow} />,
  "layout-move": () => <Moving transform={false} />,
  "transform-move": () => <Moving transform />,
  "commit-per-chunk": () => <Streaming perFrame={false} />,
  "commit-per-frame": () => <Streaming perFrame />,
  "slow-commit": () => <SlowRender />,
  "long-frame": () => <Busy />,
};

createRoot(document.getElementById("root")!).render(CASES[kind]?.() ?? <p>no such case</p>);
