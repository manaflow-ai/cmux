// l10n-allow-file: deterministic session, repository, file and action fixtures.
import { expect, test } from "bun:test";
import { translate, type Translate } from "../src/agent-session/acpmux/i18n";
import type { SummaryPullRequest } from "../src/agent-session/acpmux/summary/sessionSummary";
import { changesSection } from "../src/agent-session/acpmux/session-info/native/changes";
import { contextSection } from "../src/agent-session/acpmux/session-info/native/context";
import { environmentSection } from "../src/agent-session/acpmux/session-info/native/environment";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { outputsSection } from "../src/agent-session/acpmux/session-info/native/outputs";
import { sourcesSection } from "../src/agent-session/acpmux/session-info/native/sources";

const t: Translate = (key, values) => translate(key, values, "en");

test("Cloud environment actions retain anchors, grants and one Remote Control switch", async () => {
  const actions = new NativeInfoActions();
  let anchored: unknown;
  let revoked = false;
  let remote = true;
  const section = environmentSection(
    {
      summary: { sessionId: "cloud-chat", hostKind: "cloud", host: "Maple", cwd: "/repo" },
      cloudRepositoryAvailable: true,
      attachedCloudRepos: [{ repo: "example/current" }, { repo: "example/extra" }],
      pendingCloudRepos: [{ repo: "example/pending", phase: "Cloning" }],
      repository: "example/current",
      onAddCloudRepository: (rect) => {
        anchored = rect;
      },
      remoteControl: {
        on: remote,
        set: (on) => {
          remote = on;
        },
      },
      grants: [
        {
          id: "files",
          label: "Folder access",
          onRemove: () => {
            revoked = true;
          },
        },
      ],
    },
    actions,
    t,
  )!;
  expect(section.bare).toBe(true);
  expect(section.rows.find((row) => row.id === "machine")!.trailing).toBe(t("composer.cloud"));
  const control = section.rows.find((row) => row.id === "remoteControl")!;
  expect(control).toMatchObject({ toggle: true, symbol: "cursorarrow.click" });
  expect(control.buttons).toBeUndefined();
  const rect = { left: 10, top: 20, right: 90, bottom: 46 };
  actions.run(section.rows.find((row) => row.id === "cloud-add-repository")!.action!, rect);
  actions.run(control.action!);
  actions.run(section.rows.find((row) => row.id === "grant:files")!.buttons![0]!.action);
  await Promise.resolve();
  expect(anchored).toEqual(rect);
  expect(remote).toBe(false);
  expect(revoked).toBe(true);
  expect(section.rows.some((row) => row.id === "cloud-repository:example/extra")).toBe(true);
  expect(section.rows.some((row) => row.id === "cloud-pending:example/pending")).toBe(true);
});

test("Context keeps measured colored segments, expandable lists and Compact", async () => {
  let compacted = false;
  let opened: unknown;
  const actions = new NativeInfoActions();
  const section = contextSection(
    {
      usage: { used: 300, size: 1000 },
      language: "en",
      open: true,
      breakdown: {
        categories: [
          { name: "Messages", tokens: 300, kind: "used" },
          { name: "Buffer", tokens: 100, kind: "buffer" },
        ],
        maxTokens: 1000,
        mcpTools: [{ name: "mcp__files__read", serverName: "files", tokens: 20 }],
      },
      onCompact: () => {
        compacted = true;
      },
      onToggleList: (id) => {
        opened = id;
      },
    },
    actions,
    t,
  )!;
  expect(section.segments).toEqual([
    { share: 0.3, color: "context0" },
    { share: 0.1, color: "buffer" },
  ]);
  expect(section.rows.find((row) => row.title === "Messages")).toMatchObject({
    symbol: "square.fill",
    symbolColor: "context0",
  });
  actions.run(section.rows[0]!.buttons![0]!.action);
  actions.run(section.rows.find((row) => row.id === "list:mcpTools")!.action!);
  await Promise.resolve();
  expect(compacted).toBe(true);
  expect(opened).toBe("mcpTools");
});

test("Outputs folds the combined list to five and View all invokes the page choice", async () => {
  const actions = new NativeInfoActions();
  let expanded = false;
  const section = outputsSection(
    {
      files: [],
      artifacts: 0,
      links: Array.from({ length: 7 }, (_, i) => ({ url: `https://example.com/${i}`, label: `Result ${i}` })),
      open: true,
      onExpandedChange: (next) => {
        expanded = next;
      },
    },
    actions,
    t,
  )!;
  expect(section.rows).toHaveLength(5);
  actions.run(section.more!.action);
  await Promise.resolve();
  expect(expanded).toBe(true);
});

test("Changes exposes current overflow actions and line breakdown", async () => {
  const actions = new NativeInfoActions();
  const copied: string[] = [];
  const url = "https://github.com/example/project/pull/7";
  const section = changesSection(
    {
      pullRequests: [{ url, repo: "example/project", number: 7, title: "Update panel", state: "open", opened: true }],
      statuses: {
        [url]: {
          additions: 10,
          deletions: 2,
          breakdown: { code: { additions: 8, deletions: 2 }, tests: { additions: 2, deletions: 0 } },
        },
      },
      open: true,
      onCopyText: (text) => {
        copied.push(text);
      },
    },
    actions,
    t,
  )!;
  const row = section.rows[0]!;
  expect(row.hover!.detail).toContain("+8 -2");
  expect(row.menuLabel).toBe(t("sessionInfo.changes.more", { reference: "example/project#7" }));
  expect(row.symbolColor).toBe("green");
  for (const item of row.menu!) actions.run(item.action);
  await Promise.resolve();
  expect(copied).toEqual([url, "example/project#7"]);
});

test("Changes uses the state color for every pull-request glyph", () => {
  const states = ["open", "merged", "draft", "closed", "conflicting"] as const;
  const pullRequests: SummaryPullRequest[] = states.map((state, index) => ({
    url: `https://github.com/example/project/pull/${index + 1}`,
    repo: "example/project",
    number: index + 1,
    title: `${state} change`,
    state: state === "merged" ? "merged" : state === "closed" ? "closed" : "open",
    opened: true,
  }));
  const statuses = Object.fromEntries(
    states.map((state, index) => [
      pullRequests[index]!.url,
      state === "conflicting" ? { mergeable: "conflicting" } : state === "open" ? {} : { state },
    ]),
  );
  const section = changesSection({ pullRequests, statuses, open: true }, new NativeInfoActions(), t)!;
  const colors = new Map(section.rows.map((row) => [row.title.split(" ")[0], row.symbolColor]));
  expect(colors).toEqual(
    new Map([
      ["open", "green"],
      ["merged", "purple"],
      ["draft", "yellow"],
      ["closed", "red"],
      ["conflicting", "red"],
    ]),
  );
});

test("Sources preserves scoped paths and renders refused opens", () => {
  const section = sourcesSection(
    {
      sources: [
        { kind: "file", label: "src/main.ts" },
        { kind: "file", label: "../secret" },
      ],
      cwd: "/repo",
      failures: { "/repo/src/main.ts": "Could not open" },
      onOpenFile: () => {},
      open: true,
      expanded: false,
      onExpandedChange: () => {},
    },
    new NativeInfoActions(),
    t,
  )!;
  expect(section.rows[0]).toMatchObject({ tone: "failed", subtitle: "Could not open" });
  expect(section.rows[0]!.action).toBeUndefined();
  expect(section.rows[1]!.action).toBeUndefined();
});
