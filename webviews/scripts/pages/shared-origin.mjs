// The shared chunk origin of the built pages and the agent pane, and how a loopback server of a
// built page answers it. The app serves cmux-page://cmux.shared/ from Resources/pages/_shared
// (PageSharedChunks in CmuxNextPages); a browser has no cmux-page:// scheme, so a server that
// shows a built page to one (the daemon's /pages/, cmux-tui page_files.rs; the browser tests and
// benches of the agent pane) names each shared chunk by a path on itself instead.
import fs from "node:fs";
import path from "node:path";
import { SHARED_ORIGIN } from "../shared/shared-react.mjs";

/** The origin every built page imports its shared chunks from (PageID.sharedOrigin). */
export { SHARED_ORIGIN };
/** Where a loopback server of one built page answers the shared chunks. */
export const SHARED_PATH = "/_shared/";

/**
 * The file a loopback server answers `pathname` with: under `shared` (the pages' _shared folder)
 * for SHARED_PATH, else under `page` (the page's folder; `/` is index.html). Undefined for a path
 * that leaves its folder or names no file.
 */
export function builtPageFile(pathname, { page, shared }) {
  const [root, rest] = pathname.startsWith(SHARED_PATH)
    ? [shared, pathname.slice(SHARED_PATH.length)]
    : [page, pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "")];
  const base = path.resolve(root);
  const file = path.resolve(base, decodeURIComponent(rest));
  if (!file.startsWith(base + path.sep)) return undefined;
  return fs.existsSync(file) && fs.statSync(file).isFile() ? file : undefined;
}

/** `body` with every shared chunk URL named by SHARED_PATH (page_files.rs with_shared_chunks_here). */
export function withSharedChunksHere(body) {
  return body.replaceAll(SHARED_ORIGIN, SHARED_PATH);
}

/** The body a loopback server sends for `file`: HTML and scripts name the shared chunks by SHARED_PATH. */
export function builtPageBody(file) {
  return /\.(?:html|m?js)$/.test(file) ? withSharedChunksHere(fs.readFileSync(file, "utf8")) : fs.readFileSync(file);
}
