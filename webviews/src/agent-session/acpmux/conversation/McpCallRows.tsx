// Calls to one MCP tool, drawn as one line that says what they did ("Sent 4 messages to
// Coordination hub"). Several calls open to a row each; a call opens to its request and response,
// pretty-printed (mcpCalls.ts). Nothing of a call's JSON is drawn until it is opened, and opening
// draws it at once, with no animation.
import { useFindReveal } from "./chatFind";
import { useContext, useId, useMemo, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { toolImages } from "../toolImages";
import { ChevronRight, Spinner, ToolGroup } from "./icons";
import { menuPartRef } from "./menuParts";
import { mcpCall, mcpLabel, McpNamesContext, mcpRawName, prettyOutput, prettyValue, type McpCall } from "./mcpCalls";
import { isFailed, isRunning } from "./toolGroups";
import { OutputMore, useOutput } from "./toolOutput";
import { ToolImages } from "./ToolRow";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

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
        title={mcpRawName(items[0]!.tool!, calls[0]!)}
        onClick={() => setOpen((value) => !value)}
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
      {open && (
        <div className="cv-tool-group" id={detailsId}>
          {items.map((item, index) => (
            <McpCallRow key={item.tool!.id || index} item={item} />
          ))}
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
  const detailsId = useId();
  const tool = item.tool!;
  const call = useMemo(() => mcpCall(tool)!, [tool]);
  // The machine name stays at hand: the line's tooltip and the opened call's first line.
  const raw = mcpRawName(tool, call);
  const images = useMemo(() => toolImages(tool), [tool]);
  const running = isRunning(tool);
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        title={raw}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__icon">
          {running ? <Spinner size={16} /> : <ToolGroup size={16} strokeWidth={1.2} />}
        </span>
        <span className="cv-tool__text" data-find-skip>
          {mcpLabel(t, [call], names)}
          {tool.status === "failed" && <span className="cv-tool__detail"> {t("tools.failed")}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {images.length > 0 && <ToolImages sources={images} />}
      {open && <McpCallDetails id={detailsId} call={call} raw={raw} output={tool.output} reveal={reveal} />}
    </>
  );
}

/// The opened call: its request, then its response (only its end while long), each as a tight
/// block; a block with nothing in it is left out.
function McpCallDetails({
  id,
  call,
  raw,
  output,
  reveal,
}: {
  id: string;
  call: McpCall;
  raw: string;
  output?: string;
  reveal: number;
}) {
  const t = useT();
  const request = useMemo(() => prettyValue(call.args), [call]);
  const response = useOutput(
    useMemo(() => prettyOutput(output), [output]),
    reveal,
  );
  return (
    <div id={id} className="cv-mcp-call" ref={menuPartRef({ output: response.text })}>
      <code className="cv-mcp-call__name selectable">{raw}</code>
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
