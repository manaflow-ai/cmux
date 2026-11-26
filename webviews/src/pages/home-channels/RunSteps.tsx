// Shared by the run sheet and the full inline transcript; every stored step stays in order.
import { memo, useMemo } from "react";
import { Markdown } from "../../agent-session/acpmux/conversation/Markdown";
import { UrlChip } from "../../agent-session/acpmux/chips/LinkChips";
import { detailParts, type ChatDetail } from "../../agent-session/acpmux/chatDetail";
import { HomeToolGroup } from "./HomeToolGroup";
import { useT as usePaneT } from "../../agent-session/acpmux/i18n";
import { runBlocks } from "./runBlocks";
import { safeLink } from "./runs";
import type { HomeRun, HomeRunStep } from "./types";

export const RunSteps = memo(function RunSteps({
  run,
  steps,
  agentNames,
  detail,
}: {
  run: HomeRun;
  steps: readonly HomeRunStep[];
  agentNames: ReadonlyMap<string, string>;
  /** The inline transcript's ladder level; the run sheet passes none and opens tool groups. */
  detail?: ChatDetail;
}) {
  const parts = detail ? detailParts(detail) : undefined;
  const blocks = useMemo(() => runBlocks(run, steps), [run, steps]);
  const byId = useMemo(() => new Map(steps.map((step) => [step.id, step])), [steps]);
  const stepLinks = (step: HomeRunStep) =>
    step.links.some((link) => safeLink(link.url)) && (
      <p className="lg-run-links">
        {step.links
          .filter((link) => safeLink(link.url))
          .map((link, index) => (
            <UrlChip key={`${index}-${link.url}`} href={link.url} target="_blank">
              {link.label}
            </UrlChip>
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
            <HomeToolGroup
              row={block.row}
              steps={(block.row.items ?? []).flatMap((item) => {
                const step = item.tool ? byId.get(item.tool.id) : undefined;
                return step ? [step] : [];
              })}
              agentNames={agentNames}
              collapsed={parts ? !parts.toolsOpen : false}
            />
            {extras(block)}
          </div>
        ) : block.kind === "thought" ? (
          <Thought key={block.key} text={block.step.text ?? ""} open={parts?.thoughtsOpen ?? false} />
        ) : (
          <div key={block.key} className={`lg-run-block ${block.kind}`}>
            {block.step.text && (
              <Markdown className="hc-md" messageAt={block.step.at}>
                {block.step.text}
              </Markdown>
            )}
            {stepLinks(block.step)}
          </div>
        ),
      )}
    </>
  );
});

/** Thoughts use the same folded disclosure in the sheet and inline transcript. */
function Thought({ text, open }: { text: string; open: boolean }) {
  const t = usePaneT();
  if (!text.trim()) return null;
  return (
    <details className="lg-run-block thought" open={open}>
      <summary>{t("tools.thought")}</summary>
      <p dir="auto">{text.trim()}</p>
    </details>
  );
}
