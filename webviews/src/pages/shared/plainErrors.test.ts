// Detector for raw error text in the webview pages: no page puts an error's own text (`error.message`,
// `String(error)`) into what it renders. An owner's message is written for logs (a Swift Debug
// string, a Rust error chain); the page shows `userMessage(error)` (./userMessage.ts), a plain
// sentence by code. A line that reads an error's text for anything else (building the error,
// matching a code in it, a Details tooltip) is in ALLOWED with why.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { OWNER_SENTENCE, userMessage } from "./userMessage";
import { pageError } from "./pageClient";
import table from "./generated/strings.json";

const PAGES = join(import.meta.dir, "..");
const RAW = /\b(?:error|err|e|failure|cause|reason)\.message\b|String\((?:error|err|e|failure|cause|reason)\)/;
/** Tests, galleries, fixtures, mocks and dev-server bridges never reach a person. */
const SKIP = /\.(?:test|gallery)\.tsx?$|fixtures?|[Mm]ock|devBridge\.ts$|galleryFixture/;

/** `file` (relative to pages/) and a piece of the line: why that error text is not shown raw. */
const ALLOWED: readonly { file: string; line: string; why: string }[] = [
  {
    file: "shared/pageClient.ts",
    line: 'pageError("cmux.protocol.closed"',
    why: "builds the error; pages show userMessage",
  },
  { file: "shared/pageClient.ts", line: 'err.message ?? "request failed"', why: "builds the error from the reply" },
  {
    file: "shared/pageClient.ts",
    line: "message: error instanceof Error",
    why: "the page's reply to the host, not shown",
  },
  { file: "shared/daemonSocket.ts", line: 'failure.message ?? "pairing failed"', why: "builds the error" },
  { file: "shared/daemonSocket.ts", line: "String(error.message ?? code)", why: "builds the error" },
  {
    file: "home-channels/daemonHome.ts",
    line: 'pageError("cmux.page.invalid_params", error.message)',
    why: "builds the error",
  },
  {
    file: "home-channels/daemonHome.ts",
    line: "pageError(`cmux.home.${code}`, error.message)",
    why: "builds the error",
  },
  {
    file: "home-channels/daemonPeople.ts",
    line: 'error.message.includes("duplicate_participant")',
    why: "matches a code",
  },
  { file: "cloud/retention.ts", line: '(error.message ?? "").includes(HELD_CAP)', why: "matches a code" },
  { file: "settings/ops.ts", line: "message: String(error)", why: "the wire record; the page shows userMessage" },
  {
    file: "settings/store.ts",
    line: "detail: error.message",
    why: "the row's Details tooltip; the line shows errorText",
  },
  {
    file: "settings/components/SettingRow.tsx",
    line: "error.detail ? error.detail : error.message",
    why: "`error` is the row record: `message` is errorText; agents.chats.roots shows the folder diagnostic",
  },
  {
    file: "bookmarks/BookmarkEditor.tsx",
    line: 'error?.kind === "refused" ? error.message',
    why: "`error` is the editor record, whose message is userMessage (store.ts noticeOf)",
  },
  {
    file: "markdown/diagrams.ts",
    line: "error instanceof Error ? error.message : String(error)",
    why: "the person's own diagram source's syntax error, the line they fix",
  },
  {
    file: "editor/store.ts",
    line: "EDITOR_UNAVAILABLE ? error.message",
    why: "the machine-offline reason; the editor and markdown failure states are their own fix",
  },
  {
    file: "markdown/store.ts",
    line: "MARKDOWN_UNAVAILABLE ? error.message",
    why: "the machine-offline reason; the editor and markdown failure states are their own fix",
  },
];

function* sources(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== "generated" && entry.name !== "node_modules") yield* sources(path);
    } else if (/\.tsx?$/.test(entry.name) && !SKIP.test(relative(PAGES, path))) yield path;
  }
}

function rawSites(): { file: string; line: string }[] {
  const found: { file: string; line: string }[] = [];
  for (const path of sources(PAGES)) {
    const file = relative(PAGES, path);
    for (const line of readFileSync(path, "utf8").split("\n"))
      if (RAW.test(line) && !line.trimStart().startsWith("//") && !line.trimStart().startsWith("*"))
        found.push({ file, line: line.trim() });
  }
  return found;
}

describe("plain errors in the pages", () => {
  test("no page shows an error's own text", () => {
    const raw = rawSites().filter(
      (site) => !ALLOWED.some((allowed) => allowed.file === site.file && site.line.includes(allowed.line)),
    );
    expect(raw.map((site) => `${site.file}: ${site.line}`)).toEqual([]);
  });

  test("every allowed line still exists", () => {
    const sites = rawSites();
    const stale = ALLOWED.filter(
      (allowed) => !sites.some((site) => site.file === allowed.file && site.line.includes(allowed.line)),
    );
    expect(stale).toEqual([]);
  });
});

describe("userMessage", () => {
  const en = (table as Record<string, Record<string, string>>).en;

  test("an unknown failure is the generic sentence, never its own text", () => {
    const text = userMessage(pageError("cmux.page.failed", 'command(cmd: "x", message: "boom", code: Optional("io"))'));
    expect(text).toBe(en["error.generic"]);
    expect(userMessage(new Error("TypeError: undefined is not a function"))).toBe(en["error.generic"]);
    expect(userMessage("boom")).toBe(en["error.generic"]);
    expect(userMessage(null)).toBe(en["error.generic"]);
  });

  test("a lost link and a missing op have their own sentence", () => {
    expect(userMessage(pageError("cmux.protocol.closed", "the link to the owner is closed"))).toBe(
      en["error.disconnected"],
    );
    expect(userMessage(pageError("cmux.protocol.unknown_op", "cmux.x.y"))).toBe(en["error.unsupported"]);
  });

  test("a page's own sentence by code, or the owner's when it words it for the person", () => {
    const refused = pageError("cmux.page.refused", "This build was pulled.");
    expect(userMessage(refused, { "cmux.page.refused": "Not now." })).toBe("Not now.");
    expect(userMessage(refused, { "cmux.page.refused": OWNER_SENTENCE })).toBe("This build was pulled.");
    expect(userMessage(refused)).toBe(en["error.generic"]);
  });

  test("every sentence is in every language", () => {
    const keys = Object.keys(en).sort();
    for (const [language, strings] of Object.entries(table as Record<string, Record<string, string>>))
      expect([language, Object.keys(strings).sort()]).toEqual([language, keys]);
  });
});
