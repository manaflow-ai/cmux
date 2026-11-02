// The chat's right-hand panel is called Session Info, never Inspector, in anything a person reads
// (Leo, 2026-10-22: "shouldnt be called inspector"; 2026-10-31: "WTF STOP CALLING IT FUCKIING
// INSPECTOR WTF IS INSPECTOR"). The code keeps its `inspector` ids (design/session-panel.md); this
// reads every locale of every string the panel, its toggle, its Settings row, its palette action and
// its debug setting show, and the gallery's and release notes' names for it. The other inspectors
// (the Event, Memory and Web Inspector) are other panels and keep their names.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const repo = path.resolve(import.meta.dir, "../..");
const read = (file: string) => readFileSync(path.join(repo, file), "utf8");
/// Inspector in English and the words the catalogs translate it to.
const INSPECTOR = /inspe[ck]t|インスペクタ|检查器|檢查器|인스펙터|инспектор/i;

/// The panel's string keys in each catalog.
const CATALOGS: [file: string, keys: RegExp][] = [
  ["webviews/src/agent-session/acpmux/Localizable.xcstrings", /^sessionInfo\./],
  [
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings",
    /^settings\.(agentPane\.display\.inspector|choice\.agentChatInspector)/,
  ],
  ["Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/Localizable.xcstrings", /^agentPane\.sessionInfo\./],
  ["Packages/macOS/CmuxNext/Sources/CmuxNextActions/Localizable.xcstrings", /^action\.agentPane\.toggleSessionInfo$/],
];

type Catalog = { strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }> };

describe("Session Info is never called Inspector", () => {
  for (const [file, keys] of CATALOGS)
    test(file, () => {
      const catalog = JSON.parse(read(file)) as Catalog;
      const panel = Object.entries(catalog.strings).filter(([key]) => keys.test(key));
      expect(panel.length).toBeGreaterThan(0);
      const named = panel.flatMap(([key, entry]) =>
        Object.entries(entry.localizations ?? {})
          .filter(([, one]) => INSPECTOR.test(one.stringUnit?.value ?? ""))
          .map(([locale, one]) => `${key} [${locale}]: ${one.stringUnit?.value}`),
      );
      expect(named).toEqual([]);
    });

  test("Swift defaults, the gallery and release notes", () => {
    const sources = [
      // The debug setting's and the Settings row's English defaults.
      [
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneTunables.swift",
        /"agent\.inspector", PageTunables\.section, "([^"]*)",\s*help: "([^"]*)"/,
      ],
      [
        "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/AgentPaneDisplaySettingsSchema.swift",
        /settings\.agentPane\.display\.inspector(?:\.help)?",\s*"([^"]*)"/g,
      ],
      [
        "webviews/src/agent-session/acpmux/session-info/SessionInfo.gallery.tsx",
        /id: "agent-pane\.chat-inspector",\s*title: "([^"]*)"/,
      ],
      ["release-notes/next/highlights/agent-chat-environment-line.md", /([^\n]*)/g],
    ] as const;
    const named: string[] = [];
    for (const [file, pattern] of sources) {
      const text = read(file);
      const matches = pattern.global ? [...text.matchAll(pattern)] : [text.match(pattern)];
      expect(matches.some(Boolean)).toBe(true);
      for (const match of matches)
        for (const said of (match ?? []).slice(1)) if (said && INSPECTOR.test(said)) named.push(`${file}: ${said}`);
    }
    expect(named).toEqual([]);
  });
});
