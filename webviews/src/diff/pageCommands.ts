// The diff page's host commands on `cmux.page.command` (plans/cmux-next/diff-host.md S4). The app's
// one key dispatcher sends them for the `diffViewer*` actions (`DiffPageCommand` in CmuxNextPages);
// each runs the viewer's own navigation action, the code its toolbar, header carets and find bar
// run (App.tsx `useNativeViewerNavigation`). The page adds no key handling for them.
import type { PageClient } from "../pages/shared/pageClient";
import { subscribePageStreams } from "../pages/shared/pageStreams";

/** The navigation action each page command runs. */
export const DIFF_PAGE_COMMAND_ACTIONS: Readonly<Record<string, string>> = {
  nextLine: "diffViewerScrollDown",
  previousLine: "diffViewerScrollUp",
  halfPageDown: "diffViewerScrollHalfPageDown",
  halfPageUp: "diffViewerScrollHalfPageUp",
  goToTop: "diffViewerScrollToTop",
  goToBottom: "diffViewerScrollToBottom",
  nextHunk: "diffViewerNextHunk",
  previousHunk: "diffViewerPreviousHunk",
  nextFile: "diffViewerNextFile",
  previousFile: "diffViewerPreviousFile",
  toggleViewed: "diffViewerToggleViewed",
  collapseFile: "diffViewerCollapseFile",
  expandFile: "diffViewerExpandFile",
  // The shared page commands: Find opens the find bar, focusSearch the file search.
  find: "diffViewerOpenFind",
  focusSearch: "diffViewerOpenFileSearch",
};

/** Runs one navigation action; false when the viewer is not ready or does not take it. */
export type DiffNavigationPerform = (action: string) => boolean;

function performInViewer(action: string): boolean {
  return globalThis.window?.__cmuxPerformDiffViewerNavigationAction?.(action) ?? false;
}

/** Runs a host command; false for an unknown command or one the viewer did not take. */
export function runDiffPageCommand(
  command: { command?: unknown },
  perform: DiffNavigationPerform = performInViewer,
): boolean {
  const action = typeof command?.command === "string" ? DIFF_PAGE_COMMAND_ACTIONS[command.command] : undefined;
  return action ? perform(action) : false;
}

/** Subscribes to the host's commands for the life of the page; a host without the stream is fine. */
export function startPageDiffCommands(
  page: PageClient,
  perform: DiffNavigationPerform = performInViewer,
): Promise<() => void> {
  return subscribePageStreams(page, { onCommand: (command) => void runDiffPageCommand(command, perform) });
}
