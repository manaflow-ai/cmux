// A chat widget under a tool call: an installed extension's card (`cmux.chat.widget/1`), drawn with
// the same scene renderer as sidebar and Session Info sections. The daemon picks the extension and
// builds the context (`apps.chat_widgets.route`); this row only names the call it is under and draws
// the scene it gets. cmux ships no widgets of its own, so with no extension installed nothing shows.
// Off by default: Settings > Advanced > Experiments > Extension Chat Widgets (`experiments.chatWidgets`);
// while it is off no call is routed and no card is drawn.
import { memo, useContext, useEffect, useState, useSyncExternalStore } from "react";
import type { PageClient } from "../../../pages/shared/pageClient";
import { ChatWidgetMount } from "../../../apps/scene/chatWidgetClient";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { SceneMount } from "../../../apps/scene/panels";
import { useExperimentSwitch } from "../../../experiments/switches";
import { pageHostClient } from "../pageHost";
import type { AcpmuxActivity } from "../model";
import { ChatWidgetClientContext, widgetTool } from "./toolWidgetModel";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The widget an installed extension draws under a finished call, or nothing.
export const ToolWidget = memo(function ToolWidget({ tool }: { tool: Tool }) {
  const on = useExperimentSwitch("chatWidgets");
  const injected = useContext(ChatWidgetClientContext);
  const client = injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
  const key = on && tool.status === "completed" ? `tool:${tool.id}` : undefined;
  // One route per finished call: the mount made when the call ended is kept for that call and
  // client, so a re-render, or another call streaming, never asks again.
  const [held, setHeld] = useState<{ key: string; client: PageClient; owner: ChatWidgetMount }>();
  let owner = held && held.key === key && held.client === client ? held.owner : undefined;
  if (!owner && key && client) {
    owner = new ChatWidgetMount(client, { key, tool: widgetTool(tool) });
    setHeld({ key, client, owner });
  }
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
