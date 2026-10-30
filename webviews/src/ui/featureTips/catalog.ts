// Feature tips come from the What's New highlights (release-notes/next/highlights/*.md), so one
// file drives a feature's What's New entry and its tip. A highlight gets a tip with a `tip:` line
// naming the control the tip points at (a page's anchor table, e.g. `tip: agent.browser`); the tip
// is the highlight's title and the first sentence of its body. Only New and Improved highlights
// carry one. scripts/gen-feature-tips.ts writes tips.generated.json from the files.
import type { FeatureTipEntry } from "./policy";

/** The tip a highlight file declares, or null. Throws on a `tip:` line it cannot use. */
export function highlightTip(file: string, text: string): FeatureTipEntry | null {
  const [head = "", ...rest] = text.replace(/\r\n/g, "\n").split("\n\n");
  const meta = new Map<string, string>();
  for (const line of head.split("\n")) {
    const colon = line.indexOf(":");
    if (colon > 0) meta.set(line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1).trim());
  }
  const anchor = meta.get("tip");
  if (!anchor) return null;
  const id = file.replace(/^.*\//, "").replace(/\.md$/, "");
  const category = meta.get("category") ?? "new";
  if (category !== "new" && category !== "improved")
    throw new Error(`${file}: a tip goes on a New or Improved highlight`);
  if (!/^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+$/.test(anchor))
    throw new Error(`${file}: tip: names a control id (agent.browser)`);
  const title = meta.get("title");
  const body = rest.join(" ").replace(/\s+/g, " ").trim();
  if (!title || !body) throw new Error(`${file}: a tip needs the highlight's title and body`);
  return { id, anchor, title, body: firstSentence(body) };
}

/** The body's first whole sentence. */
export function firstSentence(body: string): string {
  const match = /^.+?[.!?](?=\s+[A-Z0-9"“(]|$)/.exec(body);
  return (match ? match[0] : body).trim();
}

/** Every tip of a set of highlight files, by id. */
export function tipsFromHighlights(files: readonly { file: string; text: string }[]): FeatureTipEntry[] {
  return files
    .map(({ file, text }) => highlightTip(file, text))
    .filter((tip): tip is FeatureTipEntry => tip !== null)
    .sort((a, b) => a.id.localeCompare(b.id));
}
