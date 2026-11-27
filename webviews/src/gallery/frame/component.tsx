// The component host: one component with the state's props, under the page base styles and the
// shared UI provider (overlays, direction), as a page mounts it.
import { createRoot } from "react-dom/client";
import type { ComponentEntry, ComponentVariant } from "../format";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import type { StageContext } from "./context";
import { applyAgentTheme } from "../../agent-session/shared/theme";
import { installChipHost } from "./chips";
import { applyOptions } from "../options";
import { installPaneStrings } from "./paneStrings";

export async function mountComponent(
  entry: ComponentEntry<Record<string, unknown>>,
  state: ComponentVariant<Record<string, unknown>>,
  context: StageContext,
): Promise<void> {
  if (state.experiments) globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, ...state.experiments };
  await installPaneStrings();
  applyAgentTheme(context.agentTheme as never);
  installChipHost(state.chipHost);
  if (entry.pane) document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
  await import("../../pages/shared/desktop");
  // After desktop.ts: it inserts desktop.css and the liquid glass (ui/glass/glass.css) on their own,
  // and the pane's sheet, which holds them in the shipped order ahead of the pane's own sheets, must
  // come last so a surface's rules outrank `.ui-glass` as they do in the app.
  if (entry.pane) await import("virtual:cmux-gallery/agent-pane.css");
  await import("../../pages/shared/pageBase.css");
  await import("../../ui/ui.css");
  await entry.styles?.();
  const Component = await entry.load();
  const root = document.getElementById("root")!;
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(context.env.locale)}>
      <Component {...(applyOptions(entry.options, context.options, state.props) as typeof state.props)} />
    </UiProvider>,
  );
}
