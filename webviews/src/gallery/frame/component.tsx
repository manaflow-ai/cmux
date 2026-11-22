// The component host: one component with the state's props, under the page base styles and the
// shared UI provider (overlays, direction), as a page mounts it.
import { createRoot } from "react-dom/client";
import type { ComponentEntry, ComponentVariant } from "../format";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import type { StageContext } from "./context";
import { addPseudoLocales } from "../pseudo";
import { applyAgentTheme } from "../../agent-session/shared/theme";
import { installChipHost } from "./chips";

export async function mountComponent(
  entry: ComponentEntry<Record<string, unknown>>,
  state: ComponentVariant<Record<string, unknown>>,
  context: StageContext,
): Promise<void> {
  const strings = (await import("../../agent-session/acpmux/generated/strings.json")).default as unknown as Record<
    string,
    Record<string, string>
  >;
  addPseudoLocales(strings);
  globalThis.__cmuxPaneStrings = strings;
  applyAgentTheme(context.agentTheme as never);
  installChipHost(state.chipHost);
  if (entry.pane) {
    const strings = (await import("../../agent-session/acpmux/generated/strings.json")).default as unknown as Record<
      string,
      Record<string, string>
    >;
    (await import("../pseudo")).addPseudoLocales(strings);
    globalThis.__cmuxPaneStrings = strings as never;
    const { applyAgentTheme } = await import("../../agent-session/shared/theme");
    applyAgentTheme(context.agentTheme as never);
    document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
    await import("virtual:cmux-gallery/agent-pane.css");
  }
  await import("../../pages/shared/desktop");
  await import("../../pages/shared/pageBase.css");
  await import("../../ui/ui.css");
  await entry.styles?.();
  const Component = await entry.load();
  const root = document.getElementById("root")!;
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(context.env.locale)}>
      <Component {...state.props} />
    </UiProvider>,
  );
}
