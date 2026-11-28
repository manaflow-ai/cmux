// Host glass for any page on the shared page host (RFD 0207, "Host glass for pages"): the floating
// surfaces a page marks `data-host-glass="<level>"` (ui/glass/hostGlass.ts) are reported with
// `cmux.app.glass {surfaces, zoom}` (PageNativeOp.hostGlass), and the page view puts the App's own
// glass under each (PageHostGlassLayer), as the agent pane does with `pane.glass`. No page calls this
// yet: a page opts in once it marks a surface, so nothing looks different until then.
import { reportHostGlass, type HostGlassCover } from "../../ui/glass/hostGlass";
import { findReplyHandler, type PageClient } from "./pageClient";

/** The op every page view serves (PageDescriptor.swift `PageNativeOp.hostGlass`). */
export const PAGE_HOST_GLASS_OP = "cmux.app.glass";

/** Reports the page's marked surfaces to its page view until the returned stop runs; nothing for a
 * mock client (the dev loop, the gallery) or none. */
export function reportPageHostGlass(
  client: PageClient | null,
  doc: Document = document,
  cover?: HostGlassCover,
  inApp: boolean = findReplyHandler() !== null,
): () => void {
  if (!client || !inApp) return () => undefined;
  return reportHostGlass(doc, (surfaces, zoom) => client.call(PAGE_HOST_GLASS_OP, { surfaces, zoom }), cover);
}
