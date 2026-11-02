// Shared by the run sheet and the full inline transcript; every stored step stays in order.
import { memo, useMemo } from "react";
import { AgentNamesContext } from "../../agent-session/acpmux/conversation/agentNames";
import { Markdown } from "../../agent-session/acpmux/conversation/Markdown";
import { ToolRows } from "../../agent-session/acpmux/conversation/TurnRows";
import { useT as usePaneT } from "../../agent-session/acpmux/i18n";
import { runBlocks } from "./runBlocks";
import { safeLink } from "./runs";
import type { HomeRun, HomeRunStep } from "./types";

export const RunSteps = memo(function RunSteps({
  run,
  steps,
  agentNames,
}: {
  run: HomeRun;
  steps: readonly HomeRunStep[];
  agentNames: ReadonlyMap<string, string>;
}) {
  const blocks = useMemo(() => runBlocks(run, steps), [run, steps]);
  const byId = useMemo(() => new Map(steps.map((step) => [step.id, step])), [steps]);
  const stepLinks = (step: HomeRunStep) =>
    step.links.some((link) => safeLink(link.url)) && (
      <p className="lg-run-links">
        {step.links
          .filter((link) => safeLink(link.url))
          .map((link, index) => (
            <a key={`${index}-${link.url}`} href={link.url} target="_blank" rel="noreferrer">
              {link.label}
            </a>
          ))}
      </p>
    );
  // Links and pictures of tool steps go after their block (the agent pane's rows draw the call).
  const extras = (block: (typeof blocks)[number]) => {
    if (block.kind !== "tools") return null;
    const owned = (block.row.items ?? []).flatMap((item) => {
      const step = item.tool ? byId.get(item.tool.id) : undefined;
      return step && (step.links.length > 0 || step.attachments.length > 0) ? [step] : [];
    });
    return owned.map((step) => (
      <div key={`extras-${step.id}`} className="lg-run-extras">
        {stepLinks(step)}
        {step.attachments.length > 0 && (
          <p className="lg-run-files">
            {step.attachments.map((file, index) => (
              <span key={`${index}-${file.hash}`} className="hc-chip attachment">
                <span className="hc-chip-title">{file.name}</span>
              </span>
            ))}
          </p>
        )}
      </div>
    ));
  };
  return (
    <>
      {blocks.map((block) =>
        block.kind === "tools" ? (
          <div key={block.key} className="lg-run-block">
            <AgentNamesContext.Provider value={agentNames}>
              <ToolRows row={block.row} />
            </AgentNamesContext.Provider>
            {extras(block)}
          </div>
        ) : block.kind === "thought" ? (
          <Thought key={block.key} text={block.step.text ?? ""} />
        ) : (
          <div key={block.key} className={`lg-run-block ${block.kind}`}>
            {block.step.text && <Markdown className="hc-md">{block.step.text}</Markdown>}
            {stepLinks(block.step)}
          </div>
        ),
      )}
    </>
  );
});

/** Thoughts use the same folded disclosure in the sheet and inline transcript. */
function Thought({ text }: { text: string }) {
  const t = usePaneT();
  if (!text.trim()) return null;
  return (
    <details className="lg-run-block thought">
      <summary>{t("tools.thought")}</summary>
      <p dir="auto">{text.trim()}</p>
    </details>
  );
}
