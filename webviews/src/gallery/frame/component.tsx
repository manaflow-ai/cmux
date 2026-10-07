// The component host: one component with the state's props, under the page base styles and the
// shared UI provider (overlays, direction), as a page mounts it.
import { createRoot } from "react-dom/client";
import type { ComponentEntry, ComponentVariant } from "../format";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import type { StageContext } from "./context";

export async function mountComponent(
  entry: ComponentEntry<Record<string, unknown>>,
  state: ComponentVariant<Record<string, unknown>>,
  context: StageContext,
): Promise<void> {
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
