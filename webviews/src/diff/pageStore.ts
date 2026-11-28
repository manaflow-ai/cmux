// The diff page's stores on the shared page host (coordinator decision PAGE-PREFS,
// plans/cmux-next/diff-host.md): the display prefs are `diff.*` settings and the "Viewed" marks
// are kept by the host, read and written only through these ops. Web storage is never used on the
// page host: the page host pool clears it on reset. Installed at boot when the config's `ops` lists
// them; otherwise (classic host, dev server) viewer-prefs.ts and viewed-files.ts keep their paths.
import type { PageClient } from "../pages/shared/pageClient";

export const DIFF_PREFS_GET_OP = "cmux.diff.prefs.get";
export const DIFF_PREFS_SET_OP = "cmux.diff.prefs.set";
export const DIFF_VIEWED_LIST_OP = "cmux.diff.viewed.list";
export const DIFF_VIEWED_SET_OP = "cmux.diff.viewed.set";
export const DIFF_VIEWED_CLEAR_OP = "cmux.diff.viewed.clear";

let prefsClient: PageClient | null = null;
let viewedClient: PageClient | null = null;

/** Routes prefs and viewed marks to the host when its config lists the ops (null page removes). */
export function installPageDiffStore(page: PageClient | null, ops: readonly string[] | undefined): void {
  const serves = (op: string) => page != null && Array.isArray(ops) && ops.includes(op);
  prefsClient = serves(DIFF_PREFS_GET_OP) && serves(DIFF_PREFS_SET_OP) ? page : null;
  viewedClient = [DIFF_VIEWED_LIST_OP, DIFF_VIEWED_SET_OP, DIFF_VIEWED_CLEAR_OP].every(serves) ? page : null;
}

/** The host that stores the prefs, else null. */
export function pageDiffPrefsClient(): PageClient | null {
  return prefsClient;
}

/** The host that stores the viewed marks, else null. */
export function pageDiffViewedClient(): PageClient | null {
  return viewedClient;
}
