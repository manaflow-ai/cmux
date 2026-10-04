// Mounts the diff empty state into the page root until the user opens a repository. The diff
// boot (pageBoot.ts on the page host, diff/dev.ts in dev) awaits the config it resolves with and
// renders the viewer into the same root.
import { createRoot } from "react-dom/client";
import { createDiffViewerLabelResolver, diffViewerLanguage } from "../labels";
import type { PageClient } from "../pages/shared/pageClient";
import { DiffEmptyState } from "./DiffEmptyState";
import { viewerEmptyStrings } from "./strings";

export interface PickDiffOptions {
  /** `payload.labels` of the empty config, for the source names. */
  labels?: Record<string, string>;
}

/** Shows the diff empty state in `root`; resolves with the config `cmux.diff.open` answered. */
export function pickDiffConfig(
  rootElement: HTMLElement,
  client: PageClient,
  options: PickDiffOptions = {},
): Promise<unknown> {
  // The viewer speaks English and Japanese; the empty state follows it so the page is one language.
  const strings = viewerEmptyStrings([diffViewerLanguage()]);
  const label = createDiffViewerLabelResolver(options.labels);
  document.documentElement.dataset.cmuxDiffEmpty = "true";
  return new Promise((resolve) => {
    const root = createRoot(rootElement);
    root.render(
      <DiffEmptyState
        client={client}
        strings={strings}
        label={label}
        onOpened={(config) => {
          // Unmount before the viewer renders into the same element.
          queueMicrotask(() => {
            root.unmount();
            delete document.documentElement.dataset.cmuxDiffEmpty;
            resolve(config);
          });
        }}
      />,
    );
  });
}
