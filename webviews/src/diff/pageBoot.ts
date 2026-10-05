// The page host boot of the diff viewer (page.ts has the ops): config, optional comments and the
// user language pack, then render, then the host's diffViewer* commands (pageCommands.ts). Kept apart from surfaces/diffSurface so it is testable without
// the viewer.
import { installPageDiffComments } from "../comments/bridge";
import type { DiffLanguageHostAPI } from "../diff-languages/host";
import type { PageClient } from "../pages/shared/pageClient";
import type { DiffViewerConfig } from "../types";
import { diffConfigNeedsPick } from "../viewer-empty/ops";
import {
  DIFF_PAGE_COMMENTS_OP,
  diffPageServes,
  loadPageDiffConfig,
  normalizePageDiffConfig,
  startPageDiffLanguages,
  type DiffPageConfig,
} from "./page";
import { type DiffNavigationPerform, startPageDiffCommands } from "./pageCommands";
import { installPageDiffStore } from "./pageStore";

/** Renders the viewer with its config and initial language pack, and installs the language API. */
export type DiffSurfaceRender = (config: DiffViewerConfig, languages: unknown) => void;

/** Shows the empty state for a config without a repository; resolves with the opened config. */
export type DiffSurfacePick = (config: DiffPageConfig) => Promise<unknown>;

export async function bootPageDiff(
  page: PageClient,
  render: DiffSurfaceRender,
  languageAPI: () => DiffLanguageHostAPI | undefined = () => globalThis.window?.cmuxDiffViewerLanguages,
  reload?: () => void,
  pick?: DiffSurfacePick,
  perform?: DiffNavigationPerform,
): Promise<DiffViewerConfig> {
  let config = await loadPageDiffConfig(page);
  // No repository yet (diff-host.md "Empty state"): the user picks one, `cmux.diff.open` answers
  // its config, and the boot goes on with that.
  if (pick && diffConfigNeedsPick(config)) config = normalizePageDiffConfig(await pick(config));
  // Comments, viewed files and prefs go to the host only when it serves the op; otherwise comments
  // stay hidden and the rest is local.
  installPageDiffComments(diffPageServes(config, DIFF_PAGE_COMMENTS_OP) ? page : null);
  // Prefs and viewed marks go to the host's stores when it serves them (never web storage).
  installPageDiffStore(page, config.ops);
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
  // The key dispatcher's diffViewer* commands run the viewer's own navigation actions.
  try {
    await startPageDiffCommands(page, perform);
  } catch (error) {
    console.warn("cmux diff page commands unavailable", error);
  }
  return config;
}
