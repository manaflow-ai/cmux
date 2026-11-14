// A chat widget under a tool call: an installed extension's card (`cmux.chat.widget/1`), drawn with
// the same scene renderer as sidebar and Session Info sections. The daemon picks the extension and
// builds the context (`apps.chat_widgets.route`); this row only names the call it is under and draws
// the scene it gets. cmux ships no widgets of its own, so with no extension installed nothing shows.
import { createContext, memo, useContext, useEffect, useMemo, useSyncExternalStore } from "react";
import type { PageClient } from "../../../pages/shared/pageClient";
import { ChatWidgetMount, type ChatWidgetTool } from "../../../apps/scene/chatWidgetClient";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { SceneMount } from "../../../apps/scene/panels";
import { pageHostClient } from "../pageHost";
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/** The page client widgets mount through; galleries and tests provide their own. */
export const ChatWidgetClientContext = createContext<PageClient | null | undefined>(undefined);

function parse(text: string | undefined): unknown {
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/** The call as the daemon routes it: an MCP call by its `mcp__<server>__<tool>` name with its
 * arguments (Codex nests them; Claude Code passes them as the input), any other call by the name its
 * harness gave it. */
export function widgetTool(tool: Tool): ChatWidgetTool {
  const mcp = mcpCall(tool);
  const name = mcp
    ? `mcp__${mcp.server}__${mcp.tool}`
    : (tool.provenance?.claudeCodeToolName ?? tool.provenance?.claudeTool ?? tool.title).trim();
  const input = mcp ? mcp.args : parse(tool.inputSummary);
  return {
    name: name.slice(0, 128),
    ...(tool.title && { title: tool.title }),
    status: tool.status,
    ...(input !== undefined && { input }),
    ...(tool.output && { output: tool.output }),
  };
}

/// The widget an installed extension draws under a finished call, or nothing.
export const ToolWidget = memo(function ToolWidget({ tool }: { tool: Tool }) {
  const injected = useContext(ChatWidgetClientContext);
  const client = injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
  const done = tool.status === "completed";
  // One route per finished call: a re-render, or another call streaming, never asks again.
  const owner = useMemo(
    () =>
      done && client ? new ChatWidgetMount(client, { key: `tool:${tool.id}`, tool: widgetTool(tool) }) : undefined,
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the call's id and its end name it; its text is final then.
    [client, tool.id, done],
  );
  const mounted = useSyncExternalStore(
    owner?.subscribe ?? noSubscribe,
    owner?.getSnapshot ?? noSnapshot,
    owner?.getSnapshot ?? noSnapshot,
  );
  useEffect(() => {
    if (!owner) return;
    owner.start();
    const stop = () => owner.stop();
    globalThis.addEventListener?.("pagehide", stop);
    return () => {
      globalThis.removeEventListener?.("pagehide", stop);
      owner.stop();
    };
  }, [owner]);
  if (!mounted) return null;
  return (
    <div className="cv-tool-widget" data-app={mounted.panel.app} aria-label={mounted.panel.title}>
      <SceneMount mounted={mounted} />
    </div>
  );
});

const noSubscribe = () => () => undefined;
const noSnapshot = () => undefined;
