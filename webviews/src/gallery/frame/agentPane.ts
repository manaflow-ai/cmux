// The agent pane host: the real pane entry (acpmux/main.tsx, so AcpmuxApp under its boundary and
// the desktop layer) on a stand-in for the app's pane bridge (`webkit.messageHandlers.agentSession`
// plus `window.cmuxAcpmuxBridge`). `ready` answers the state's host fields with the `preview`
// transport, which runs no client; the state's snapshot then arrives through `receive`, as the
// app's own snapshot does. The theme goes through `applyTheme` (AgentPaneTheme.swift's values) and
// the font through `applyCustomization` (the user's agent pane theme.css), the app's own inputs.
import type { AgentPaneVariant } from "../format";
import { addPseudoLocales } from "../pseudo";
import type { StageContext } from "./context";
import { installChipHost } from "./chips";
import { resetSummaryCards } from "../../agent-session/acpmux/summary/cardState";

type Message = { id?: string; method?: string; params?: Record<string, unknown> };

/** The user stylesheet a font control writes: the pane's own type variables. */
export function agentPaneFontCSS(font: string, size: number): string {
  const rules: string[] = [];
  if (font) rules.push(`--cv-font: ${font};`, `--agent-host-font-family: ${font};`);
  if (size) rules.push(`--cv-font-size: ${size}px;`, `--cv-line-height: ${Math.round(size * 1.625 * 100) / 100}px;`);
  return rules.length ? `:root { ${rules.join(" ")} }` : "";
}

export async function mountAgentPane(state: AgentPaneVariant, context: StageContext): Promise<void> {
  const strings = (await import("../../agent-session/acpmux/generated/strings.json")).default as unknown as Record<
    string,
    Record<string, string>
  >;
  addPseudoLocales(strings);
  globalThis.__cmuxPaneStrings = strings as never;
  installChipHost(state.chipHost);
  resetSummaryCards();
  if (state.mockHarnesses)
    (globalThis as { cmuxAcpmuxMockHarnesses?: unknown[] }).cmuxAcpmuxMockHarnesses = state.mockHarnesses;
  const snapshot = structuredClone(state.snapshot);
  const answer = (value: unknown) => ({ ok: true, value });
  const deliver = () => {
    const bridge = window.cmuxAcpmuxBridge;
    if (!bridge) return;
    bridge.applyTheme({ ...context.agentTheme, ...state.theme });
    bridge.applyCustomization({ themeCSS: agentPaneFontCSS(context.env.fontFamily, context.env.fontSize) });
    bridge.applySessionStatus?.(state.sessionStatus === true);
    bridge.receive(structuredClone(snapshot));
  };
  const next = (method: string | undefined) => {
    const after =
      method && state.afterCall && Object.hasOwn(state.afterCall, method) ? state.afterCall[method] : undefined;
    // In a task after the answer, as the app's transport sends a snapshot.
    if (after) setTimeout(() => window.cmuxAcpmuxBridge?.receive(structuredClone(after)), 0);
  };
  const handle = (message: Message) => {
    context.log(message.method ?? "?", message.params);
    next(message.method);
    switch (message.method) {
      case "ready":
        // The snapshot follows the answer, as the app's transport sends it: in a task after the
        // pane has read the answer (a new chat or New Tab page resets its snapshot right then).
        setTimeout(deliver, 0);
        return answer({ protocolVersion: 1, transport: "preview", machineName: "This Mac", ...state.ready });
      case "project.list":
      case "file.search":
        return answer(state.native?.[message.method] ?? []);
      default: {
        const value = state.native?.[message.method ?? ""] ?? null;
        // `{ nativeError: {code, userMessage?} }` answers as the app's refusal of the call.
        if (value && typeof value === "object" && "nativeError" in value)
          return { ok: false, error: (value as { nativeError: unknown }).nativeError };
        return answer(value);
      }
    }
  };
  (window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: Message) => {
          const reply = handle(message);
          const delay = state.nativeDelayMs?.[message.method ?? ""];
          return delay ? new Promise((resolve) => setTimeout(() => resolve(reply), delay)) : Promise.resolve(reply);
        },
      },
    },
  };
  document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
  // Before the pane's scripts run, as AgentPaneTunables.documentScript sets them in the app.
  for (const [name, value] of Object.entries(state.documentAttributes ?? {}))
    document.documentElement.setAttribute(`data-${name}`, value);
  // The desktop layer first (the pane's main.tsx imports it): it inserts desktop.css and the liquid
  // glass (ui/glass/glass.css) on their own, and the pane's sheet, which holds them in the shipped
  // order ahead of the pane's own sheets, must come after so a surface's rules outrank `.ui-glass`
  // as they do in the app.
  await import("../../pages/shared/desktop");
  await import("virtual:cmux-gallery/agent-pane.css");
  await import("katex/dist/katex.min.css");
  await import("../../agent-session/acpmux/main");
}
