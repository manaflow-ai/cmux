// Boots the page shell (`cmux-page://cmux.shell/`, webviews/shell-page.html): React and the theme
// are loaded once (the host injects the theme bootstrap), the bridge client answers `page.claim`
// and `page.reset`, and every registered page chunk is loaded after the first idle moment so a
// claim mounts with no network or parse on its path.
import { createPageClient } from "../shared/pageClient";
import "react";
import "react-dom";
import "react-dom/client";
import { SHELL_PAGES } from "./pages";
import { PageShell } from "./shell";
// Inline, so the markdown page (which bundles pageBase.css into its own stylesheet) keeps its
// cascade; installed before the shell's head snapshot, so a reset keeps it.
import pageBase from "../shared/pageBase.css?inline";
import shellStyles from "./shell.css?inline";

for (const css of [pageBase, shellStyles]) {
  const style = document.createElement("style");
  style.textContent = css;
  document.head.append(style);
}
const root = document.getElementById("root");
const client = createPageClient();
if (root && client) {
  const shell = new PageShell({ client, root, pages: SHELL_PAGES, win: window });
  (globalThis as { cmuxShell?: PageShell }).cmuxShell = shell;
  shell.keepCurrentGlobals();
  // The host may ask before this module ran (a load can finish first): it waits on this hook.
  const booted = (globalThis as { __cmuxShellOnBoot?: () => void }).__cmuxShellOnBoot;
  booted?.();
  const idle = (run: () => void) =>
    typeof requestIdleCallback === "function" ? requestIdleCallback(run, { timeout: 500 }) : setTimeout(run, 0);
  idle(() => void shell.preload());
}
