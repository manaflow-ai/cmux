// The page host boot of the diff viewer (page.ts has the ops): config, optional comments and the
// user language pack, then render. Kept apart from surfaces/diffSurface so it is testable without
// the viewer.
import { installPageDiffComments } from "../comments/bridge";
import type { DiffLanguageHostAPI } from "../diff-languages/host";
import type { PageClient } from "../pages/shared/pageClient";
import type { DiffViewerConfig } from "../types";
import { DIFF_PAGE_COMMENTS_OP, diffPageServes, loadPageDiffConfig, startPageDiffLanguages } from "./page";

/** Renders the viewer with its config and initial language pack, and installs the language API. */
export type DiffSurfaceRender = (config: DiffViewerConfig, languages: unknown) => void;

export async function bootPageDiff(
  page: PageClient,
  render: DiffSurfaceRender,
  languageAPI: () => DiffLanguageHostAPI | undefined = () => globalThis.window?.cmuxDiffViewerLanguages,
  reload?: () => void,
): Promise<DiffViewerConfig> {
  const config = await loadPageDiffConfig(page);
  // Comments, viewed files and prefs go to the host only when it serves the op; otherwise comments
  // stay hidden and the rest is local.
  installPageDiffComments(diffPageServes(config, DIFF_PAGE_COMMENTS_OP) ? page : null);
  const early: unknown[] = [];
  let api: DiffLanguageHostAPI | undefined;
  const pack = await startPageDiffLanguages(
    page,
    (next) => {
      if (api) return api.apply(next as never);
      // A change before the viewer renders waits for the language API.
      early.push(next);
      return undefined;
    },
    reload,
  );
  render(config, pack ?? config.payload?.languages);
  api = languageAPI();
  for (const next of early.splice(0)) api?.apply(next as never);
  return config;
}
