import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";

/**
 * Status-outside-the-dot detector (RFD 0128, "One composer status dot"): the composer's status lives in one
 * place, the dot (ComposerStatusDot.tsx) and its items table (composerStatusModel.ts). Before the dot, every
 * status grew its own row with a sentence; the RFD's meta-problem is that nothing made "add a row" the hard
 * path and "add an item" the easy one. This check makes a new row fail.
 *
 * Two kinds, over every .ts/.tsx under src/ (tests and galleries exempt):
 *   dot-key     a `status.<StatusKind>.*` catalog key (an item's words) named outside the dot's own files.
 *               Draw it by sending the item; the dot draws its words.
 *   dot-words   a catalog key whose English says what a dot item says (the same words once `{placeholders}`,
 *               punctuation and case are set aside: "Reconnecting…" and "Reconnecting", "Sending when ready")
 *               named in a file that ALLOWED does not list for it. A second sentence for the same status is
 *               the row the dot replaced: add a `StatusKind` (acpmux `composer_status.rs`) instead.
 *
 * ALLOWED is every place such words stand today, each with why it is not a second status row. The surfaces
 * the RFD's Building table keeps outside the dot (the host failure card, the peer copy banner, header
 * "Disconnected", the rate-limit transcript copy) share no words with an item, so they need no row here;
 * they stay legal because they say something no item says. A finding is fixed by moving the status into
 * the dot, or by an ALLOWED row whose reason says why it is not a composer status (an action label, another
 * page, another object's state). No override flag: the way past is the item or a reason in review.
 *
 *   bun scripts/check-status-outside-dot.ts           report and fail on a finding
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const SRC = join(ROOT, "src");
const CATALOG = join(SRC, "agent-session/acpmux/Localizable.xcstrings.d");
const MODEL = join(SRC, "agent-session/acpmux/composerStatusModel.ts");

/** The dot's own files: the only places a `status.<StatusKind>.*` key is named. */
export const DOT_FILES: ReadonlySet<string> = new Set([
  "agent-session/acpmux/ComposerStatusDot.tsx",
  "agent-session/acpmux/composerStatusModel.ts",
  "agent-session/acpmux/composerStatusCard.tsx",
]);

/** file -> catalog key -> why these words there are not a second status row. */
export const ALLOWED: Readonly<Record<string, Readonly<Record<string, string>>>> = {
  "agent-session/acpmux/ComposerQueue.tsx": {
    "composer.queuePaused": "the queue's note for an acpmux that sends no queuePaused item (cmux#57554)",
    "composer.queuePausedWhy": "the queue's note for an acpmux that sends no queuePaused item (cmux#57554)",
  },
  "agent-session/acpmux/Composer.tsx": {
    "composer.sendingWhenReady": "drawn only while the dot is not mounted (`statusDotMounts`)",
  },
  "agent-session/acpmux/newtab/NewTabScreen.tsx": {
    "composer.sendingWhenReady": "the new-tab screen has no chat yet, so no dot; its held send says so here",
  },
  "agent-session/acpmux/HostError.tsx": {
    "host.restoringSessions": "yields to the dot once mounted (`useDotSaysRecovery`); the host line before it",
  },
  "agent-session/acpmux/MachineLinkStatus.tsx": {
    "machineLink.reconnecting": "the link words the dot's own card and the sidebar machine header draw",
  },
  "agent-session/acpmux/environmentPickerModel.ts": {
    "header.reconnecting": "an environment row's state in the picker, not this chat's",
  },
  "agent-session/acpmux/conversation/PromptDelivery.tsx": {
    "prompt.delivery.whenReady": "one sent prompt's delivery mark in the transcript, not the session's status",
  },
  "agent-session/acpmux/session-info/ConnectorsSection.tsx": {
    "sessionInfo.connectors.reconnecting": "one MCP connector's Reconnect button while it runs",
  },
  "agent-session/acpmux/session-info/native/connectors.ts": {
    "sessionInfo.connectors.reconnecting": "one MCP connector's Reconnect button while it runs",
  },
  "agent-session/guest/GuestPage.tsx": {
    "guest.live.reconnecting": "the guest share page, which has no composer",
  },
  "chief-web/ChiefWeb.tsx": {
    "guest.live.reconnecting": "the chief web page, which has no composer",
  },
  "agent-session/acpmux/HarnessHealthNotice.tsx": {
    "auth.fix.signInTo": "a sign-in button's label, an action, not a status",
  },
  "agent-session/acpmux/sessionAuth.ts": {
    "auth.fix.signInTo": "a sign-in button's label, an action, not a status",
  },
  "agent-session/acpmux/ComposerPickers.tsx": {
    "picker.setup.signInChip": "a picker row's sign-in chip, an action, not a status",
  },
  "agent-session/acpmux/QuickModelColumns.tsx": {
    "picker.signInTo": "a model column's sign-in button, an action, not a status",
  },
  "agent-session/acpmux/SwitchNotice.tsx": {
    "switch.action.signInTo": "the switch notice's sign-in button, an action, not a status",
  },
};

export type Kind = "dot-key" | "dot-words";
export interface Finding {
  file: string;
  line: number;
  kind: Kind;
  key: string;
  /** For dot-words: the dot item whose words it repeats. */
  item?: string;
}

/** The dot's item kinds, read from the model's KINDS set so a new kind is covered without editing this. */
export function dotKinds(modelText: string): string[] {
  const block = /const KINDS[^=]*=\s*new Set<StatusKind>\(\[([\s\S]*?)\]\)/.exec(modelText)?.[1] ?? "";
  return [...block.matchAll(/"(\w+)"/g)].map((m) => m[1]!);
}

/** A sentence with its placeholders, punctuation and case set aside: what two keys share when they say the same. */
export function words(text: string): string {
  return text
    .replace(/\{[^}]*\}/g, " ")
    .toLowerCase()
    .replace(/[^\p{L}\p{N} ]+/gu, " ")
    .split(/\s+/)
    .filter(Boolean)
    .join(" ");
}

/** Every catalog key's English, from the one-key-per-file catalog. */
export function readCatalog(dir = CATALOG): Map<string, string> {
  const out = new Map<string, string>();
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(".xcstrings")) continue;
    const doc = JSON.parse(readFileSync(join(dir, name), "utf8")) as {
      strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }>;
    };
    for (const [key, entry] of Object.entries(doc.strings))
      out.set(key, entry.localizations?.en?.stringUnit?.value ?? key);
  }
  return out;
}

export interface Rules {
  /** `status.<kind>.` prefixes. */
  dotPrefixes: string[];
  /** Non-dot key -> the dot key whose words it repeats. */
  repeats: Map<string, string>;
}

export function rules(catalog: Map<string, string>, kinds: string[]): Rules {
  const dotPrefixes = kinds.map((kind) => `status.${kind}.`);
  const isDot = (key: string) => dotPrefixes.some((prefix) => key.startsWith(prefix));
  const byWords = new Map<string, string>();
  for (const [key, english] of catalog) if (isDot(key) && words(english)) byWords.set(words(english), key);
  const repeats = new Map<string, string>();
  for (const [key, english] of catalog) {
    if (isDot(key)) continue;
    const item = byWords.get(words(english));
    if (item) repeats.set(key, item);
  }
  return { dotPrefixes, repeats };
}

export function exempt(file: string): boolean {
  return (
    /\.(?:test|spec|gallery|bench|fixtures)\.|\.gallery\b|\.d\.ts$/.test(file) ||
    /(?:^|\/)(?:__tests__|test|tests)\//.test(file) ||
    // The dev server's canned sessions (mockFixture.ts) stand in for acpmux: they send items, not rows.
    /(?:^|\/)mock[A-Z][\w]*\.tsx?$/.test(file)
  );
}

/** The findings in one source file (path relative to src/). */
export function findInSource(file: string, text: string, r: Rules): Finding[] {
  if (exempt(file)) return [];
  // Parse only a file that names a key this check cares about: most of src/ names none, and parsing all of it
  // is most of the run.
  if (
    !text.includes('"status.') &&
    !text.includes("`status.") &&
    ![...r.repeats.keys()].some((key) => text.includes(key))
  )
    return [];
  const source = ts.createSourceFile(
    file,
    text,
    ts.ScriptTarget.Latest,
    true,
    file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const out: Finding[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      const key = node.text;
      const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
      if (r.dotPrefixes.some((prefix) => key.startsWith(prefix))) {
        if (!DOT_FILES.has(file)) out.push({ file, line, kind: "dot-key", key });
      } else {
        const item = r.repeats.get(key);
        if (item && !ALLOWED[file]?.[key]) out.push({ file, line, kind: "dot-words", key, item });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return out;
}

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" || entry.name === "generated" ? [] : sources(path);
    return /\.tsx?$/.test(entry.name) ? [path] : [];
  });
}

/** Every finding under src/, and ALLOWED rows that no longer match anything (stale: drop them). */
export function findAll(): { findings: Finding[]; stale: string[] } {
  const r = rules(readCatalog(), dotKinds(readFileSync(MODEL, "utf8")));
  const findings: Finding[] = [];
  const seen = new Set<string>();
  for (const path of sources(SRC)) {
    const file = relative(SRC, path);
    const text = readFileSync(path, "utf8");
    findings.push(...findInSource(file, text, r));
    for (const key of Object.keys(ALLOWED[file] ?? {})) if (text.includes(`"${key}"`)) seen.add(`${file} ${key}`);
  }
  const stale = Object.entries(ALLOWED).flatMap(([file, keys]) =>
    Object.keys(keys)
      .filter((key) => !seen.has(`${file} ${key}`))
      .map((key) => `${file} ${key}`),
  );
  return { findings, stale };
}

if (import.meta.main) {
  const { findings, stale } = findAll();
  for (const f of findings)
    console.error(
      f.kind === "dot-key"
        ? `src/${f.file}:${f.line}: dot-key ${f.key} is the status dot's words; send the item and let ComposerStatusDot draw it (RFD 0128)`
        : `src/${f.file}:${f.line}: dot-words ${f.key} says what the dot's ${f.item} says; add or reuse a StatusKind item instead of a second row (RFD 0128), or add an ALLOWED row in scripts/check-status-outside-dot.ts saying why it is not a status`,
    );
  for (const row of stale)
    console.error(`scripts/check-status-outside-dot.ts: ALLOWED row ${row} matches nothing now; drop it`);
  if (findings.length || stale.length) process.exitCode = 1;
  else console.log("check-status-outside-dot: no status drawn outside the composer status dot");
}
