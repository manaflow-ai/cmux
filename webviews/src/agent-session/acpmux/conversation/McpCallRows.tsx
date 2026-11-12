// Calls to one MCP tool, drawn as one line that says what they did ("Sent 4 messages to
// Coordination hub"). Several calls open to a row each; a call opens to its arguments as labeled
// fields and its response (ToolDetail.tsx), or to its request and response pretty-printed
// (mcpCalls.ts). A call with nothing to open beyond its line (a description and a lifecycle
// note) is inert. Opening and closing play the transcript's fold (fold.ts).
import { useFindReveal } from "./chatFind";
import { memo, type ReactNode, useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { stripsEnvelopeImages, toolImages } from "../toolImages";
import { ApprovedMark } from "./ApprovedMark";
import { ChevronRight, CodeBrackets, ToolGroup } from "./icons";
import { menuPartRef } from "./menuParts";
import {
  cleanText,
  mcpCall,
  mcpDescription,
  mcpLabel,
  mcpOutcome,
  McpNamesContext,
  mcpOutputResult,
  mcpRawName,
  prettyOutput,
  type McpCall,
} from "./mcpCalls";
import { callLine, cmuxTitle, execParts, execView, isCmuxExec } from "./cmuxExec";
import { CODE_ROLE_COLOR, jsTokens, type CodeToken } from "./jsHighlight";
import { RawToggle } from "./SentMessageLine";
import { isFailed, isRunning } from "./toolGroups";
import { ToolOutput } from "./ToolOutputBody";
import { isMcpLifecycleOutput, usefulMcpResponse } from "./mcpPresentation";
import { ToolDetail } from "./ToolDetail";
import { argsSource, inputFields, requestText, type InputField } from "./toolInputFields";
import { ToolImages } from "./ToolRow";
import { toolIcon } from "./toolRowModel";
import { ToolVisualRow } from "./ToolVisualPreview";
import { VideoFramesCard } from "./VideoFramesCard";
import { videoFrames } from "./videoFrames";
import {
  callDisclosureKeys,
  FoldPin,
  useFoldPin,
  useRowDisclosure,
  useTranscriptDisclosure,
} from "./transcriptDisclosureModel";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { ToolLabel } from "./ToolVerb";
import { useMoreBelow } from "./moreBelow";
import { toolFailure } from "./toolFailure";
import { InlineFailureCause, ToolFailureCause } from "./ToolFailureCause";
import { failureWord } from "./toolFailureCauseModel";

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
  // The Verbose transcript view opens the calls; a call the reader opened before it was grouped too.
  const members = useMemo(() => callDisclosureKeys(items), [items]);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, false, true, { members });
  const pin = useFoldPin(disclosureKey);
  useFindReveal(items, () => setOpen(true));
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const detailsId = useId();
  const calls = useMemo(() => items.map((item) => mcpCall(item.tool!)!), [items]);
  const running = items.some((item) => isRunning(item.tool!));
  // The cmux server's own tools say what they did (cmuxExec.ts); any other server's, mcpLabel's line.
  const label = useMemo(
    () =>
      cmuxTitle(
        t,
        calls,
        items.map((item) => item.tool!),
        names,
      ) ?? mcpLabel(t, calls, names, running),
    [t, calls, items, names, running],
  );
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
          <ToolGroup size={16} />
        </span>
        <span className="cv-tool__text" data-find-skip>
          <ToolLabel text={label} />
          {failures > 0 && <span className="cv-tool__failed"> {t("tools.failedCount", { n: failures })}</span>}
        </span>
        <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <FoldPin.Provider value={pin}>
            <div className="cv-tool-group" id={detailsId}>
              {items.map((item, index) => (
                <McpCallRow key={item.tool!.id || index} item={item} grouped />
              ))}
            </div>
          </FoldPin.Provider>
        </div>
      )}
    </>
  );
}

export const McpCallRow = memo(function McpCallRow({ item }: { item: AcpmuxActivity; grouped?: boolean }) {
  const t = useT();
  const names = useContext(McpNamesContext);
  // Closed, or open in the Verbose transcript view.
  const [open, setOpen] = useRowDisclosure(item.tool?.id);
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
  // The original tool identity stays available in Raw without crowding the useful detail.
  const raw = mcpRawName(tool, call);
  // A look at a video's frames reads as one ("Looked at 8 video frames") over its filmstrip, which
  // names the video (videoFrames.ts); opened, the call's response is the tool's note without the frames.
  const video = useMemo(() => videoFrames(tool), [tool]);
  const running = isRunning(tool);
  // A described call is titled with its description, as a shell call is (mcpDescription).
  const label = useMemo(
    () =>
      video
        ? t("tools.videoFrames", { n: video.count })
        : (mcpDescription(call) ?? cmuxTitle(t, [call], [tool], names) ?? mcpLabel(t, [call], names, running)),
    [t, video, call, tool, names, running],
  );
  // A condensed tool's one-line outcome trails its words, muted; its own "failed" reads as a
  // failed call does (mcpOutcome).
  const outcome = useMemo(
    () => (running || video ? undefined : mcpOutcome(tool.output, call)),
    [running, video, tool, call],
  );
  const exec = isCmuxExec(call);
  const images = useMemo(() => (video ? [] : toolImages(tool)), [video, tool]);
  // An MCP server's error is often JSON: its message, in one line (toolFailure.ts).
  const failure = useMemo(() => (tool.status === "failed" ? toolFailure(tool) : undefined), [tool]);
  const summary = usefulMcpResponse(outcome?.summary);
  const hasArgs =
    call.args != null &&
    (typeof call.args === "object"
      ? Object.keys(call.args).some((key) => key !== "description")
      : String(call.args).trim().length > 0);
  const hasOutput = !isMcpLifecycleOutput(tool.output);
  const hasDetails = Boolean(
    reveal > 0 || exec || hasArgs || hasOutput || images.length || video || failure || tool.diffs?.length,
  );
  const labelRef = useRef<HTMLSpanElement>(null);
  const [clipped, setClipped] = useState(false);
  const expandable = hasDetails || clipped;
  // An empty step is inert unless its one-line description needs room to be read.
  useLayoutEffect(() => {
    const node = labelRef.current;
    if (hasDetails || open || !node) return;
    const measure = () => setClipped(node.clientWidth > 0 && node.scrollWidth > node.clientWidth);
    measure();
    const Observer = node.ownerDocument.defaultView?.ResizeObserver;
    if (!Observer) return;
    const observer = new Observer(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [hasDetails, open, label, expandable]);
  const Row = expandable ? "button" : "div";
  // An object of arguments opens as one labeled field each (ToolDetail.tsx); any other shape, and a
  // hook's refusal, as the request and response it came as.
  const fields = useMemo(
    () => (fold.present ? inputFields(call.args, argsSource(tool)) : undefined),
    [fold.present, call, tool],
  );
  return (
    <>
      <ToolVisualRow sources={images} label={label} opened={open}>
        <Row
          type={expandable ? "button" : undefined}
          className={`cv-tool${expandable ? " is-toggle is-whole-open" : ""}${running ? " is-live" : " is-strong"}`}
          aria-expanded={expandable ? open : undefined}
          aria-controls={hasDetails && open ? detailsId : undefined}
          ref={fold.headerRef}
          onClick={expandable ? fold.toggle : undefined}
        >
          <span className="cv-tool__icon">{toolIcon(tool.kind)}</span>
          <span ref={labelRef} className="cv-tool__text" data-find-skip>
            <ToolLabel text={label} />
            {failure ? (
              <span className="cv-tool__failed"> {failureWord(t, failure)}</span>
            ) : (
              outcome?.failed && <span className="cv-tool__failed"> {t("tools.failed")}</span>
            )}
            {summary && <span className="cv-tool__detail">{`  ${summary}`}</span>}
            <InlineFailureCause failure={failure} />
          </span>
          {/* The person approved this call's ask: it says so on its row (ApprovedMark.tsx). */}
          {tool.approved && (
            <span className="cv-command__meta cv-tool__meta">
              <ApprovedMark />
            </span>
          )}
          {expandable && (
            <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
          )}
        </Row>
      </ToolVisualRow>
      <ToolFailureCause failure={failure} />
      {video && <VideoFramesCard video={video} />}
      {hasDetails && fold.present && (
        <div {...fold.bodyProps}>
          {/* A capture's images show once its row opens, one small image at the row's edge until then
              (ToolVisualRow), so a run of browser captures stays a list of lines (Lucas, 2026-11-11),
              as the Codex app's rows draw them. */}
          {images.length > 0 && <ToolImages sources={images} />}
          {exec && failure?.kind !== "hook" ? (
            <CmuxExecDetails id={detailsId} tool={tool} call={call} raw={raw} reveal={reveal} />
          ) : fields && failure?.kind !== "hook" ? (
            <McpCallFields
              id={detailsId}
              call={call}
              raw={raw}
              fields={fields}
              output={video ? video.text : tool.output}
              tool={tool}
              strip={stripsEnvelopeImages(tool)}
              reveal={reveal}
            />
          ) : (
            <McpCallDetails
              id={detailsId}
              call={call}
              raw={raw}
              output={video ? video.text : tool.output}
              tool={tool}
              strip={stripsEnvelopeImages(tool)}
              reveal={reveal}
            />
          )}
        </div>
      )}
    </>
  );
});

/// Pair a Raw string argument with its rendered presentation. Find uses the rendered copy only
/// when it can highlight every indexed occurrence; hidden URLs and shadow-root code use Raw.
/// Keys, other arguments and the response remain searchable.
function requestPresentation(request: string, alternatives: Readonly<Record<string, string>>): ReactNode {
  if (!Object.keys(alternatives).length) return request;
  const parts: ReactNode[] = [];
  let from = 0;
  for (const match of request.matchAll(/^  ("(?:\\.|[^"\\])*"): ("(?:\\.|[^"\\])*")/gm)) {
    const primary = alternatives[JSON.parse(match[1]!)];
    if (!primary) continue;
    const start = match.index + 2 + match[1]!.length + 2;
    parts.push(request.slice(from, start));
    parts.push(
      <span key={start} data-find-fallback={primary}>
        {match[2]}
      </span>,
    );
    from = start + match[2]!.length;
  }
  if (!from) return request;
  parts.push(request.slice(from));
  return parts;
}

/// The opened call: its request as a tight block, then its response in the same readable body as
/// other tool outputs (ToolOutputBody.tsx: rendered Markdown or Raw, all lines on request); a part
/// with nothing in it is left out. A sub-session card's Raw shows the same.
export function McpCallDetails({
  id,
  call,
  raw,
  output,
  tool,
  strip,
  reveal,
  requestFindAlternatives = {},
}: {
  id: string;
  call: McpCall;
  raw: string;
  output?: string;
  /// The original call distinguishes a hook refusal from output that merely quotes one.
  tool?: NonNullable<AcpmuxActivity["tool"]>;
  /// Whether the call's strip shows its envelope's images, which its response then leaves out.
  strip: boolean;
  reveal: number;
  /// Maps string arguments to their rendered data-find-primary identity.
  requestFindAlternatives?: Readonly<Record<string, string>>;
}) {
  const t = useT();
  const request = useMemo(() => requestText(call.args, tool && argsSource(tool)), [call, tool]);
  const failure = useMemo(() => (tool ? toolFailure(tool) : undefined), [tool]);
  const blocked = failure?.kind === "hook";
  const shownOutput = blocked ? failure.output : output;
  const response = useMemo(() => mcpOutputResult(shownOutput, strip, call.tool), [shownOutput, strip, call.tool]);
  const requestBox = useMoreBelow<HTMLPreElement>(request);
  return (
    <div id={id} className="cv-mcp-call" ref={menuPartRef({ output: response?.text })}>
      <code className="cv-mcp-call__name selectable" data-find-skip>
        {raw}
      </code>
      {request && (
        <div className="cv-mcp-call__part">
          <div className="cv-mcp-call__head" data-find-skip>
            {t("tools.mcp.request")}
          </div>
          <pre ref={requestBox} className="cv-mcp-call__body selectable">
            {requestPresentation(request, requestFindAlternatives)}
          </pre>
        </div>
      )}
      {(response || blocked) && (
        <div className="cv-mcp-call__part">
          <div className="cv-mcp-call__head" data-find-skip>
            {blocked ? t("tools.blockedByHook") : t("tools.mcp.response")}
          </div>
          {response && <ToolOutput result={response} reveal={reveal} />}
        </div>
      )}
    </div>
  );
}

/// An opened call whose arguments are an object: its machine name, then Input as one labeled field
/// per argument and Output with its copy button (ToolDetail.tsx); the request and response as they
/// came stay behind Raw.
function McpCallFields({
  id,
  call,
  raw,
  fields,
  output,
  tool,
  strip,
  reveal,
}: {
  id: string;
  call: McpCall;
  raw: string;
  fields: readonly InputField[];
  output?: string;
  tool: NonNullable<AcpmuxActivity["tool"]>;
  strip: boolean;
  reveal: number;
}) {
  const response = useMemo(() => mcpOutputResult(output, strip, call.tool), [output, strip, call.tool]);
  const [rawOpen, setRawOpen] = useState(false);
  return (
    <ToolDetail
      id={id}
      fields={fields}
      result={response}
      reveal={reveal}
      head={
        <code className="cv-mcp-call__name selectable" data-find-skip>
          {raw}
        </code>
      }
      after={
        <div className="cv-cmux-exec__raw" data-find-skip>
          <RawToggle
            open={rawOpen}
            onOpenChange={setRawOpen}
            icon={
              <span className="cv-tool__icon">
                <CodeBrackets size={16} />
              </span>
            }
          >
            <McpCallDetails
              id={`${id}-raw`}
              call={call}
              raw={raw}
              output={output}
              tool={tool}
              strip={strip}
              reveal={reveal}
            />
          </RawToggle>
        </div>
      }
    />
  );
}

/// Code tokens as spans in their roles' colors, line breaks kept (jsHighlight.ts, valueTree.ts).
function CodeSpans({ tokens }: { tokens: readonly CodeToken[] }) {
  return tokens.map((token, index) =>
    token.role ? (
      // oxlint-disable-next-line react/no-array-index-key -- a token's place is its identity.
      <span key={index} data-role={token.role} style={{ color: CODE_ROLE_COLOR[token.role] }}>
        {token.text}
      </span>
    ) : (
      token.text
    ),
  );
}

/// A tree's lines (valueTree.ts), each its own line.
function TreeLines({ lines }: { lines: readonly CodeToken[][] }) {
  return lines.map((line, index) => (
    // oxlint-disable-next-line react/no-array-index-key -- a line's place is its identity.
    <span key={index}>
      {index > 0 && "\n"}
      <CodeSpans tokens={line} />
    </span>
  ));
}

/// An opened `cmux_exec` call (cmuxExec.ts): its script as JavaScript with its real line breaks,
/// the tools it called, what it returned as a key/value tree (never escaped JSON), its error and
/// console logs. The call's machine name and its request and response as they came stay behind
/// "Raw", so nothing of the call is lost.
export function CmuxExecDetails({
  id,
  tool,
  call,
  raw,
  reveal,
}: {
  id: string;
  tool: NonNullable<AcpmuxActivity["tool"]>;
  call: McpCall;
  raw: string;
  reveal: number;
}) {
  const t = useT();
  const parts = useMemo(() => execParts(execView(tool, call.args), cleanText), [tool, call]);
  const script = useMemo(() => (parts.script ? jsTokens(parts.script) : undefined), [parts]);
  const response = useMemo(
    () => (parts.rawResponse ? prettyOutput(tool.output, stripsEnvelopeImages(tool)) : undefined),
    [parts, tool],
  );
  const [rawOpen, setRawOpen] = useState(false);
  const scriptBox = useMoreBelow<HTMLPreElement>(script);
  const resultBox = useMoreBelow<HTMLPreElement>(parts.result);
  const logsBox = useMoreBelow<HTMLPreElement>(parts.logs);
  const responseBox = useMoreBelow<HTMLPreElement>(response);
  const part = (head: string, body: ReactNode) => (
    <div className="cv-mcp-call__part">
      <div className="cv-mcp-call__head" data-find-skip>
        {head}
      </div>
      {body}
    </div>
  );
  return (
    <div id={id} className="cv-mcp-call cv-cmux-exec" ref={menuPartRef({ output: tool.output ?? "" })}>
      {script &&
        part(
          t("tools.cmux.head.script"),
          <pre
            ref={scriptBox}
            className="cv-mcp-call__body cv-cmux-exec__code selectable"
            data-lang="javascript"
            data-find-join=""
          >
            <CodeSpans tokens={script} />
          </pre>,
        )}
      {parts.calls.length > 0 &&
        part(
          t("tools.cmux.head.calls"),
          <div className="cv-cmux-exec__calls selectable">
            {parts.calls.map((entry) => (
              <div key={entry.name} className="cv-cmux-exec__call">
                <code>{callLine(entry)}</code>
                {entry.failed > 0 && (
                  <span className="cv-tool__failed" data-find-skip>
                    {" "}
                    {t("tools.failedCount", { n: entry.failed })}
                  </span>
                )}
              </div>
            ))}
          </div>,
        )}
      {parts.result &&
        part(
          t("tools.cmux.head.result"),
          <pre ref={resultBox} className="cv-mcp-call__body cv-cmux-exec__code selectable" data-tree data-find-join="">
            <TreeLines lines={parts.result} />
          </pre>,
        )}
      {parts.error &&
        part(
          t("tools.cmux.head.error"),
          <pre className="cv-mcp-call__body cv-cmux-exec__code selectable" data-tree data-find-join="">
            <TreeLines lines={parts.error} />
          </pre>,
        )}
      {parts.logs &&
        part(
          t("tools.cmux.head.logs"),
          <pre ref={logsBox} className="cv-mcp-call__body selectable">
            {parts.logs}
          </pre>,
        )}
      {response &&
        part(
          t("tools.mcp.response"),
          <pre ref={responseBox} className="cv-mcp-call__body selectable">
            {response}
          </pre>,
        )}
      <div className="cv-cmux-exec__raw" data-find-skip>
        <RawToggle
          open={rawOpen}
          onOpenChange={setRawOpen}
          icon={
            <span className="cv-tool__icon">
              <CodeBrackets size={16} />
            </span>
          }
        >
          <McpCallDetails
            id={`${id}-raw`}
            call={call}
            raw={raw}
            output={tool.output}
            tool={tool}
            strip={stripsEnvelopeImages(tool)}
            reveal={reveal}
          />
        </RawToggle>
      </div>
    </div>
  );
}
