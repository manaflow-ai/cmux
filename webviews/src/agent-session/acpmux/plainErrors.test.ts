// The detector for raw error text in the agent chat pane (Leo, 2026-11-12: "we want good error
// states. We don't want busted errors."). A notice, toast, card or line says what happened in plain
// words and the one action; a caught error's own text (`error.message`, `String(error)`,
// `errorMessage(error) || String(error)`: acpmux's CLI English, "Failed to fetch", "Error: …") stays
// in the log, or behind an existing Details / Copy error. transportErrors.ts `knownRefusalText` is
// the pane's own words for a refusal it knows, and is the one thing a "Couldn't …: {reason}" says.
//
// This scans every pane source (tests and galleries aside) for a caught error's text flowing into
// a t()/translate() argument, a toast or notice, or a state setter whose value a notice shows.
// Each use that is fine (log-only, Details-only, already the person's language) is named below
// with why.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = join(import.meta.dir, "..");

/// A caught error's own text.
const ERR = String.raw`(?:error|err|e|failure|cause|caught)`;
const RAW = String.raw`(?:errorMessage\(${ERR}\)|errorText\(${ERR}\)|String\(${ERR}\)|${ERR}\s+instanceof\s+Error\s*(?:\?|&&)\s*\(?${ERR}\.message|${ERR}\.message\b)`;

/// Where raw text becomes visible.
const SINKS: [kind: string, pattern: RegExp][] = [
  ["message || String(error)", new RegExp(String.raw`errorMessage\(${ERR}\)\s*\|\|\s*String\(${ERR}\)`, "g")],
  ["t() argument", new RegExp(String.raw`\b(?:t|translate)\(\s*"[\w.#]+"\s*,\s*\{[^}]*?:\s*\(?${RAW}`, "g")],
  [
    "toast or notice",
    new RegExp(String.raw`\b(?:transient|failed|notice|toastSink|refuse)\(\s*(?:\w+,\s*)?\(?${RAW}`, "g"),
  ],
  ["shown state field", new RegExp(String.raw`\.state\.error\s*=\s*\(?${RAW}`, "g")],
  [
    "shown error state",
    new RegExp(
      String.raw`\bset\w*(?:Error|Failure|Refused|Reconnect)\w*\(\s*(?:\(?\w*\)?\s*=>\s*)?(?:\{[^}]*?:\s*)?\(?${RAW}`,
      "g",
    ),
  ],
  ["JSX text", new RegExp(String.raw`>\s*\{\s*${ERR}\.message\s*\}\s*<`, "g")],
];

/// `file:line` (relative to webviews/src/agent-session) → why its raw text is fine. A line moves
/// with edits above it, so entries are by file and the start of the matched text, not line number.
const ALLOWED: Record<string, string> = {
  // Details-only.
  "acpmux/App.tsx|errorMessage(error) || String(error)":
    "setHostError: hostLine.ts hostLineText puts every text that is not the pane's own behind the line's Details",
  "acpmux/newtab/NewTabScreen.tsx|setStartError({ harness: args[0], error: errorMessage(error)":
    "StartFailure with a harness: startFailureView says a plain sentence and keeps the text behind ErrorDetails",

  // Raw, outside the 2026-11-12 pane audit's rows: named so a new site fails, and left for a
  // follow-up that gives each a plain sentence and Details.
  "acpmux/newtab/NewTabScreen.tsx|setStartError({ error: errorMessage(error)":
    "follow-up: New Tab card open/archive refusal",
  "acpmux/conversation/DiagramBlock.tsx|setFailure(error instanceof Error ? error.message":
    "follow-up: diagram render error, shown with the diagram's code",
  'acpmux/AddAccountDialog.tsx|t("environment.saveFailed", { reason: failure instanceof Error ? failure.message':
    "follow-up: Add Account save",
  'acpmux/SavedEnvironmentPanel.tsx|t("environment.saveFailed", { reason: failure instanceof Error ? failure.message':
    "follow-up: saved environment save",
  "acpmux/Composer.tsx|setAttachError(error instanceof Error ? error.message": "follow-up: attachment intake",
  "acpmux/planBuild/PlanBuildCard.tsx|setError(failure instanceof Error ? failure.message":
    "follow-up: plan build card",
  "acpmux/header/ChatHeaderTools.tsx|setNeedsYouFailure({ itemId: item.id, action, ...(error instanceof Error && error.message":
    "follow-up: Needs You header action",
  "acpmux/AddProjectPanel.tsx|setError(failure instanceof Error ? failure.message": "follow-up: Add Project",
  "acpmux/AddProjectPanel.tsx|setRevealError(failure instanceof Error ? failure.message":
    "follow-up: Add Project reveal",
  "acpmux/run-board/RunBoard.tsx|setApiError(error instanceof Error ? error.message": "follow-up: run board",
  "acpmux/run-board/variants/timeline/TimelineRunBoard.tsx|setError(cause instanceof Error ? cause.message":
    "follow-up: run board (timeline variant)",
  "acpmux/run-board/variants/compare/CompareRunBoard.tsx|setApiError(error instanceof Error ? error.message":
    "follow-up: run board (compare variant)",
  "acpmux/newtab/useNewTabCommand.tsx|setFileError(error instanceof Error ? error.message":
    "follow-up: New Tab /import file error (App.tsx importFile now throws nothing raw)",
  "acpmux/TaskGoalStrip.tsx|setError(error instanceof Error ? error.message": "follow-up: task goal strip",
  "acpmux/needsYou/NeedsYou.tsx|setError(failure instanceof Error && failure.message": "follow-up: Needs You",
  "acpmux/session-info/SourcesSection.tsx|setFailure(error instanceof Error ? error.message":
    "follow-up: Session Info sources",
  "acpmux/permissions/client.ts|.state.error = errorMessage(error)":
    "follow-up: grouped permissions panel (its local refusals are the pane's words, acpmux's are not)",
};

function* sources(dir: string): Generator<string> {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== "node_modules" && name !== "generated") yield* sources(path);
    } else if (/\.tsx?$/.test(name) && !/\.(?:test|gallery)\.tsx?$/.test(name)) yield path;
  }
}

/// Every raw site the allowlist does not name, and the allowlist entries that named one.
function rawErrorSites(root = ROOT): { found: string[]; used: Set<string> } {
  const found: string[] = [];
  const used = new Set<string>();
  for (const file of sources(root)) {
    const text = readFileSync(file, "utf8");
    const rel = relative(root, file);
    for (const [kind, pattern] of SINKS)
      for (const match of text.matchAll(pattern)) {
        const said = match[0].replace(/\s+/g, " ");
        const key = Object.keys(ALLOWED).find((entry) => {
          const [path, start] = entry.split("|") as [string, string];
          return path === rel && said.startsWith(start);
        });
        if (key) used.add(key);
        else found.push(`${rel}:${text.slice(0, match.index).split("\n").length} [${kind}] ${said.slice(0, 120)}`);
      }
  }
  return { found, used };
}

const scan = rawErrorSites();

test("no caught error's own text reaches a notice, toast, card or line in the pane", () => {
  // Say what happened and the one action (a "…Failed" key, knownRefusalText for a reason the pane
  // words); log the error, or keep it behind the surface's ErrorDetails. Only then add it above.
  expect(scan.found).toEqual([]);
});

test("every allowlist entry still names a site, and says why", () => {
  for (const [entry, why] of Object.entries(ALLOWED)) {
    expect(why.length).toBeGreaterThan(10);
    expect(scan.used.has(entry) ? entry : `stale: ${entry}`).toBe(entry);
  }
});
