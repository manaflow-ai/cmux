// The agent pane's stylesheets, as repo paths in the order its page applies them: the ones
// scripts/cmux-next/build-agent-pane-web.sh lists, then (once the page's sheets come from its
// import graph) the ones webviews/src/agent-session/acpmux/pageStyles.ts imports. A component's own
// `import "./x.css"` ships after these; `importedSheetsShip` says whether the page ships those.
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const REPO = path.resolve(import.meta.dir, "../../..");
const SCRIPT = "scripts/cmux-next/build-agent-pane-web.sh";
const PAGE_STYLES = "webviews/src/agent-session/acpmux/pageStyles.ts";

export function paneSheets(): string[] {
  const script = readFileSync(path.join(REPO, SCRIPT), "utf8");
  const listed = [...script.matchAll(/"\$(SRC|ROOT)\/([^"]+\.css)"/g)].map(([, root, file]) =>
    root === "SRC" ? `webviews/src/agent-session/${file}` : file,
  );
  const imported = existsSync(path.join(REPO, PAGE_STYLES))
    ? [...readFileSync(path.join(REPO, PAGE_STYLES), "utf8").matchAll(/^import\s+"([^"]+\.css)";/gm)].map(([, file]) =>
        path.relative(REPO, path.resolve(REPO, path.dirname(PAGE_STYLES), file)),
      )
    : [];
  return [...new Set([...listed, ...imported])];
}

/// Whether the page ships every sheet the pane imports, with no list to update.
export function importedSheetsShip(): boolean {
  return existsSync(path.join(REPO, PAGE_STYLES));
}
