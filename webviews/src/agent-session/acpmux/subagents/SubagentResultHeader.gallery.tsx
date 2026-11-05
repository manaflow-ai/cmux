// l10n-allow-file: gallery fixtures (a completed subagent report and transcript), not shipped UI.
// ChatGPT opens a finished subagent on its answer first. These scenes exercise the same head in a
// wide split pane, a short Background tasks dock, and a report that grows while its transcript stays
// at the same geometry.
import { useState, type CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { SubagentResultHeader } from "./SubagentResultHeader";
import type { Subagent } from "./subagentFold";
import "../backgroundTasks/backgroundTasks.css";
import "./subagents.css";

const LONG_RESULT = Array.from(
  { length: 14 },
  (_, index) =>
    `**${index + 1}.** Checked the worker output and kept the useful detail in this report.`,
).join("\n\n");
const SHORT_RESULT = "The result is ready. The transcript below keeps the tool calls available.";

const baseAgent: Subagent = {
  id: "gallery-worker",
  parent: null,
  name: "Review worker",
  state: "completed",
  startedAt: 1_000,
  endedAt: 12_000,
  result: LONG_RESULT,
};

function rows(count: number): AcpmuxRow[] {
  return Array.from({ length: count }, (_, index) => ({
    id: `row-${index}`,
    version: 1,
    at: index,
    kind: "assistant" as const,
    text: `Transcript row ${index + 1}: the finished subagent's full context remains available.`,
    streaming: false,
  }));
}

type Props = { report: "long" | "short"; viewport: "split" | "dock" | "one-tab"; stream: boolean };

function ResultHeadScene({ report, viewport, stream }: Props) {
  const [extra, setExtra] = useState("");
  const agent: Subagent = {
    ...baseAgent,
    result: `${report === "long" ? LONG_RESULT : SHORT_RESULT}${extra}`,
  };
  const oneTab = viewport === "one-tab";
  const style: CSSProperties = {
    display: "flex",
    flexDirection: "column",
    width: viewport === "split" ? 760 : 420,
    height: viewport === "split" ? 620 : oneTab ? 300 : 240,
  };
  const transcript = (
    <div className={oneTab ? "acpmux-scroll" : "acpmux-bg__transcript"} data-result-transcript>
      {rows(viewport === "split" ? 18 : 8).map((row) => (
        <p key={row.id} className="acpmux-bg__reply" data-row-id={row.id}>
          {row.text}
        </p>
      ))}
    </div>
  );
  const streamButton = stream && (
    <button
      type="button"
      data-stream-result
      style={{ position: "absolute", opacity: 0, pointerEvents: "none" }}
      onClick={() =>
        setExtra(
          `\n\n${LONG_RESULT}\n\nA final streamed sentence settles without changing the transcript's box.`,
        )
      }
    >
      stream
    </button>
  );
  if (oneTab) {
    return (
      <div
        className="acpmux-shell"
        data-tab-row
        data-solo-tab
        style={style}
        data-result-scene="one-tab"
      >
        <div className="acpmux-main" style={{ display: "flex", flex: 1, minHeight: 0 }}>
          <div
            className="acpmux-stage"
            data-solo-tab
            style={{ display: "flex", flex: 1, minHeight: 0, flexDirection: "column" }}
          >
            <header
              className="acpmux-header"
              data-tab-row
              style={{ flex: "0 0 var(--acpmux-tab-row-height, 28px)" }}
            />
            <SubagentResultHeader agent={agent} />
            {transcript}
            {streamButton}
          </div>
        </div>
      </div>
    );
  }
  return (
    <div
      className={viewport === "dock" ? "acpmux-bg" : "acpmux-result-scene"}
      style={style}
      data-result-scene={viewport}
    >
      <SubagentResultHeader agent={agent} />
      {transcript}
      {streamButton}
    </div>
  );
}

async function play(ctx: PlayContext) {
  const transcript = ctx.document.querySelector<HTMLElement>("[data-result-transcript]");
  const head = ctx.document.querySelector<HTMLElement>(".cv-subagent-result");
  if (!head || !transcript) throw new Error("result head scene did not mount");
  const report = ctx.document.querySelector<HTMLElement>(".cv-subagent-result__report");
  if (!report) throw new Error("result report did not mount");
  if (
    ctx.document.querySelector<HTMLElement>("[data-result-scene='dock']") &&
    report.scrollHeight <= report.clientHeight
  )
    throw new Error("dock result did not retain a scrollable report");
  const stream = ctx.document.querySelector<HTMLButtonElement>("[data-stream-result]");
  if (stream) {
    const before = transcript.getBoundingClientRect().top;
    stream.click();
    await ctx.waitFor(
      () =>
        ctx.document
          .querySelector<HTMLElement>(".cv-subagent-result__report")
          ?.textContent?.includes("final streamed"),
      {
        capMs: 2_000,
      },
    );
    const after = transcript.getBoundingClientRect().top;
    if (Math.abs(after - before) > 0.5)
      throw new Error(`streaming moved transcript by ${after - before}px`);
    if (report.scrollHeight <= report.clientHeight)
      throw new Error("streaming did not exercise report overflow");
  }
}

export default componentEntry<Props>({
  id: "agent-pane.subagent-result-header",
  title: "Subagent result first",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 440, normal: 780 },
  covers: ["agent-session/acpmux/subagents/SubagentResultHeader.tsx"],
  load: async () => ResultHeadScene,
  variants: {
    "split-long": {
      note: "A wide split pane keeps a long completed report above its full transcript.",
      props: { report: "long", viewport: "split", stream: false },
      play,
    },
    "dock-long": {
      note: "A short Background tasks dock bounds a long report and leaves transcript rows reachable.",
      props: { report: "long", viewport: "dock", stream: false },
      play,
    },
    "dock-short": {
      note: "A short Background tasks dock keeps a concise result above its transcript.",
      props: { report: "short", viewport: "dock", stream: false },
      play: async (ctx) => {
        const transcript = ctx.document.querySelector<HTMLElement>("[data-result-transcript]");
        if (!transcript || transcript.getBoundingClientRect().height <= 0)
          throw new Error("short dock transcript did not mount");
      },
    },
    "stream-stable": {
      note: "A report settling with one more streamed sentence keeps the transcript's top edge fixed.",
      props: { report: "short", viewport: "split", stream: true },
      play,
    },
    "one-tab": {
      note: "A one-tab stage keeps the result head and the last report lines clickable below the native tab row.",
      props: { report: "long", viewport: "one-tab", stream: false },
      play,
    },
  },
});
