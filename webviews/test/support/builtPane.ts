// The shipped agent pane as a loopback server answers it to a real browser: the pane's folder
// (Resources/agent-pane), and the pages' shared folder (Resources/pages/_shared, React's library), which the pane
// imports from cmux-page://cmux.shared/, at /_shared/ (scripts/pages/shared-origin.mjs). Both are
// build output: CI builds the web bundles before the suites; locally run
// scripts/cmux-next/build-agent-pane-web.sh first.
import path from "node:path";
import { builtPageBody, builtPageFile } from "../../scripts/pages/shared-origin.mjs";

const sources = path.resolve(import.meta.dir, "../../../Packages/macOS/CmuxNext/Sources");
/** The built agent pane's folder. */
export const BUILT_PANE = path.join(sources, "CmuxNextAgentPane/Resources/agent-pane");
/** The built pages' shared chunks. */
export const BUILT_SHARED = path.join(sources, "CmuxNextPages/Resources/pages/_shared");

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
};

/** The response to a GET of `pathname`, with `headers`; a 404 for a file the pane does not have. */
export function builtPaneResponse(pathname: string, headers: Record<string, string> = {}): Response {
  const file = builtPageFile(pathname, { page: BUILT_PANE, shared: BUILT_SHARED });
  if (!file) return new Response("not found", { status: 404 });
  const type = TYPES[path.extname(file)] ?? "application/octet-stream";
  return new Response(builtPageBody(file), { headers: { "Content-Type": type, ...headers } });
}
