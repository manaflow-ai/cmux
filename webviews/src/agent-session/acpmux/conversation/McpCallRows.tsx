// Calls to one MCP tool, drawn as one line that says what they did ("Sent 4 messages to
// Coordination hub"). Several calls open to a row each; a call opens to its request and response,
// pretty-printed (mcpCalls.ts). Nothing of a call's JSON is drawn until it is opened; opening and
// closing play the transcript's fold (fold.ts).
import { useFindReveal } from "./chatFind";
import { useContext, useId, useMemo, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { stripsEnvelopeImages, toolImages } from "../toolImages";
import { ChevronRight, Spinner, ToolGroup } from "./icons";
import { menuPartRef } from "./menuParts";
import { mcpCall, mcpLabel, McpNamesContext, mcpRawName, prettyOutput, prettyValue, type McpCall } from "./mcpCalls";
import { isFailed, isRunning } from "./toolGroups";
import { OutputMore, useOutput } from "./toolOutput";
import { ToolImages } from "./ToolRow";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { toolFailure } from "./toolFailure";
import { failureWord, InlineFailureCause, ToolFailureCause } from "./ToolFailureCause";

export function McpCallRows({ items, disclosureKey }: { items: readonly AcpmuxActivity[]; disclosureKey: string }) {
  return items.length === 1 ? (
    <McpCallRow item={items[0]!} />
  ) : (
    <McpGroupRow items={items} disclosureKey={disclosureKey} />
  );
}

function McpGroupRow({ items, disclosureKey }: { items: readonly AcpmuxActivity[]; disclosureKey: string }) {
  const t = useT();
  const names = useContext(McpNamesContext);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  useFindReveal(items, () => setOpen(true));
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const detailsId = useId();
  const calls = useMemo(() => items.map((item) => mcpCall(item.tool!)!), [items]);
  const running = items.some((item) => isRunning(item.tool!));
  const failures = items.filter((item) => isFailed(item.tool!)).length;
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">
          {running ? <Spinner size={16} /> : <ToolGroup size={16} strokeWidth={1.2} />}
        </span>
        <span className="cv-tool__text" data-find-skip>
          {mcpLabel(t, calls, names)}
          {failures > 0 && <span className="cv-tool__failed"> {t("tools.failedCount", { n: failures })}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <div className="cv-tool-group" id={detailsId}>
            {items.map((item, index) => (
              <McpCallRow key={item.tool!.id || index} item={item} />
            ))}
          </div>
        </div>
      )}
    </>
  );
}

function McpCallRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  const names = useContext(McpNamesContext);
  const [open, setOpen] = useState(false);
  const [reveal, setReveal] = useState(0);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => {
      setOpen(true);
      setReveal((count) => count + 1);
    },
  );
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const detailsId = useId();
  const tool = item.tool!;
  const call = useMemo(() => mcpCall(tool)!, [tool]);
  // The machine name stays at hand as the opened call's first line (no tooltip: the line's text
  // already shows, test/tooltip-rules.ts).
  const raw = mcpRawName(tool, call);
  const images = useMemo(() => toolImages(tool), [tool]);
  const running = isRunning(tool);
  // An MCP server's error is often JSON: its message, in one line (toolFailure.ts).
  const failure = useMemo(() => (tool.status === "failed" ? toolFailure(tool) : undefined), [tool]);
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">
          {running ? <Spinner size={16} /> : <ToolGroup size={16} strokeWidth={1.2} />}
        </span>
        <span className="cv-tool__text" data-find-skip>
          {mcpLabel(t, [call], names)}
          {failure && <span className="cv-tool__failed"> {failureWord(t, failure)}</span>}
          <InlineFailureCause failure={failure} />
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      <ToolFailureCause failure={failure} />
      {images.length > 0 && <ToolImages sources={images} />}
      {fold.present && (
        <div {...fold.bodyProps}>
          <McpCallDetails
            id={detailsId}
            call={call}
            raw={raw}
            output={tool.output}
            strip={stripsEnvelopeImages(tool)}
            reveal={reveal}
          />
        </div>
      )}
    </>
  );
}

/// The opened call: its request, then its response (only its end while long), each as a tight
/// block; a block with nothing in it is left out. A sub-session card's Raw shows the same.
export function McpCallDetails({
  id,
  call,
  raw,
  output,
  strip,
  reveal,
}: {
  id: string;
  call: McpCall;
  raw: string;
  output?: string;
  /// Whether the call's strip shows its envelope's images, which its response then leaves out.
  strip: boolean;
  reveal: number;
}) {
  const t = useT();
  const request = useMemo(() => prettyValue(call.args), [call]);
  const response = useOutput(
    useMemo(() => prettyOutput(output, strip), [output, strip]),
    reveal,
  );
  return (
    <div id={id} className="cv-mcp-call" ref={menuPartRef({ output: response.text })}>
      <code className="cv-mcp-call__name selectable" data-find-skip>
        {raw}
      </code>
      {request && (
        <div className="cv-mcp-call__part">
          <div className="cv-mcp-call__head">{t("tools.mcp.request")}</div>
          <pre className="cv-mcp-call__body selectable">{request}</pre>
        </div>
      )}
      {response.text && (
        <div className="cv-mcp-call__part">
          <div className="cv-mcp-call__head">{t("tools.mcp.response")}</div>
          <pre className="cv-mcp-call__body selectable">
            {response.cut && (
              <span className="cv-output-cut" aria-hidden="true">
                …{"\n"}
              </span>
            )}
            {response.shown}
          </pre>
          <OutputMore output={response} />
        </div>
      )}
    </div>
  );
}
