// l10n-allow-file: test fixture rows, not shipped UI.
// Session Info's expandable lists at any length (Leo, 2026-11-06: "If I open up this 5,427 finished,
// it'll lag"). `?list=<kind>&n=<N>` draws one section in a panel body 640 px tall, as Session Info's
// is, with N rows behind its expander; `window.__expand()` presses the expander and answers the ms
// from the press to the painted frame and the rows drawn in it (test/session-info-expand-cost.test.ts).
import { useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { TasksSection } from "../../src/agent-session/acpmux/session-info/TasksSection";
import { SubagentsSection } from "../../src/agent-session/acpmux/session-info/SubagentsSection";
import { OutputsSection } from "../../src/agent-session/acpmux/session-info/OutputsSection";
import { SourcesSection } from "../../src/agent-session/acpmux/session-info/SourcesSection";
import { ChangesSection } from "../../src/agent-session/acpmux/session-info/ChangesSection";
import { UsageSection } from "../../src/agent-session/acpmux/session-info/UsageSection";
import { AlsoHereSection } from "../../src/agent-session/acpmux/session-info/AlsoHereSection";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/session-info/sessionInfo.css";

const params = new URLSearchParams(location.search);
const kind = params.get("list") ?? "tasks";
const n = Number(params.get("n") ?? "10");
const at = Date.UTC(2026, 10, 6, 12);
const range = Array.from({ length: n }, (_, index) => index);

/// The section's expander, and the list it opens.
const EXPANDERS: Record<string, { press: string; list: string }> = {
  tasks: { press: "[data-section=tasks] .acpmux-session-info-fold", list: "ul[data-finished]" },
  subagents: { press: ".acpmux-session-info-subagents__ended", list: ".acpmux-session-info-subagents__list" },
  outputs: { press: ".acpmux-session-info-fold", list: "ul[data-section=outputs]" },
  sources: { press: ".acpmux-session-info-sources-fold", list: "ul[data-section=sources]" },
  changes: { press: ".acpmux-session-info-pr-fold", list: "ul[data-section=changes]" },
  usage: { press: ".acpmux-session-info-usage-fold", list: "ul[data-sort]" },
  alsoHere: { press: "#open", list: "ul[data-also-here]" },
};

function Sources() {
  const [expanded, setExpanded] = useState(false);
  return (
    <SourcesSection
      sources={range.map((index) => ({
        url: `https://example.com/page/${index}`,
        label: `example.com/page/${index}`,
        kind: "url",
      }))}
      expanded={expanded}
      onExpandedChange={setExpanded}
    />
  );
}

/// A section that opens as a whole (Also working here): a press mounts it, as its fold does.
function Opens({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button id="open" type="button" onClick={() => setOpen(!open)}>
        open
      </button>
      {open && children}
    </>
  );
}

function Section() {
  switch (kind) {
    case "tasks":
      return (
        <TasksSection
          commands={range.map((index) => ({
            id: `command-${index}`,
            command: `bun test shard ${index}`,
            state: "completed" as const,
            startedAt: at - 60_000 - index * 1000,
            endedAt: at - index * 1000,
          }))}
        />
      );
    case "subagents":
      return (
        <SubagentsSection
          waiting={new Set()}
          agents={range.map((index) => ({
            id: `agent-${index}`,
            parent: null,
            name: `Reviewer ${index}`,
            state: "completed",
            startedAt: at - 60_000 - index * 1000,
            endedAt: at - index * 1000,
          }))}
        />
      );
    case "outputs":
      return (
        <OutputsSection
          artifacts={0}
          onOpenFile={() => {}}
          files={range.map((index) => ({ path: `/repo/out/file-${index}.ts`, displayPath: `out/file-${index}.ts` }))}
        />
      );
    case "sources":
      return <Sources />;
    case "changes":
      return (
        <ChangesSection
          statuses={{}}
          pullRequests={range.map((index) => ({
            url: `https://github.com/acme/app/pull/${index + 1}`,
            repo: "acme/app",
            number: index + 1,
            title: `Change ${index + 1}`,
            state: "open" as const,
            opened: true,
          }))}
        />
      );
    case "usage":
      return (
        <UsageSection
          onOpen={() => {}}
          sessions={range.map((index) => ({
            sessionId: `chat-${index}`,
            title: `Chat ${index}`,
            usageStats: {
              autocompact: "capped" as const,
              // Context sorts them the other way round from cost, so a sort switch replaces every drawn row.
              contextTokens: 10_000 - index,
              costUsd24h: index,
              updatedAt: at,
            },
          }))}
        />
      );
    default:
      return (
        <Opens>
          <AlsoHereSection
            onOpen={() => {}}
            rows={range.map((index) => ({
              entry: { sessionId: `here-${index}`, title: `Also here ${index}`, status: "idle" },
              why: "folder" as const,
            }))}
          />
        </Opens>
      );
  }
}

const root = document.getElementById("root")!;
createRoot(root).render(
  <aside className="acpmux-session-info" style={{ position: "fixed", top: 0, right: 0, width: 320, height: 640 }}>
    <div className="acpmux-session-info__body" style={{ height: 640, overflowY: "auto" }}>
      <Section />
    </div>
  </aside>,
);

declare global {
  interface Window {
    __expand(): Promise<{ ms: number; rows: number; listHeight: number }>;
  }
}

const painted = () =>
  new Promise<void>((resolve) =>
    requestAnimationFrame(() => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => resolve();
      channel.port2.postMessage(0);
    }),
  );

window.__expand = async () => {
  const { press, list } = EXPANDERS[kind]!;
  const button = document.querySelector<HTMLElement>(press)!;
  const start = performance.now();
  button.click();
  await painted();
  const ms = performance.now() - start;
  const shown = document.querySelector<HTMLElement>(list);
  const rows = shown ? shown.querySelectorAll(":scope > li:not([data-rows-rest])").length : 0;
  return { ms, rows, listHeight: shown?.scrollHeight ?? 0 };
};
