// l10n-allow-file: deterministic session, repository, file and action fixtures.
import { expect, test } from "bun:test";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { translate, type Translate } from "../src/agent-session/acpmux/i18n";
import type { SummaryPullRequest } from "../src/agent-session/acpmux/summary/sessionSummary";
import { changesSection } from "../src/agent-session/acpmux/session-info/native/changes";
import { contextSection } from "../src/agent-session/acpmux/session-info/native/context";
import { environmentSection } from "../src/agent-session/acpmux/session-info/native/environment";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { outputsSection } from "../src/agent-session/acpmux/session-info/native/outputs";
import { sourcesSection } from "../src/agent-session/acpmux/session-info/native/sources";
import { safeExternalUrl } from "../src/agent-session/acpmux/session-info/native/links";

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
  // The Cloud machine says what it is and how long its files last, as the web panel does.
  expect(section.rows.find((row) => row.id === "machine")!.subtitle).toBe(t("cloudRepository.lifetime"));
  const control = section.rows.find((row) => row.id === "remoteControl")!;
  expect(control).toMatchObject({
    toggle: true,
    symbol: "cursorarrow.click",
    help: t("sessionInfo.environment.remoteControl.help"),
  });
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

test("native external links preserve preview callbacks and use the chip host fallback", async () => {
  const opened: string[] = [];
  const environment = environmentSection(
    {
      summary: { sessionId: "links", hostKind: "local", host: "Maple", cwd: "/repo", branch: "main" },
      repository: "example/project",
      onOpenUrl: (url) => opened.push(url),
    },
    new NativeInfoActions(),
    t,
  )!;
  const environmentActions = new NativeInfoActions();
  const rebuilt = environmentSection(
    {
      summary: { sessionId: "links", hostKind: "local", host: "Maple", cwd: "/repo", branch: "main" },
      repository: "example/project",
      onOpenUrl: (url) => opened.push(url),
    },
    environmentActions,
    t,
  )!;
  environmentActions.run(rebuilt.rows.find((row) => row.id === "repository")!.action!);
  environmentActions.run(rebuilt.rows.find((row) => row.id === "branch")!.action!);
  await Promise.resolve();
  expect(opened).toEqual(["https://github.com/example/project", "https://github.com/example/project/tree/main"]);
  expect(environment.rows.find((row) => row.id === "repository")?.action).toBeDefined();
  expect(environment.rows.find((row) => row.id === "branch")?.action).toBeDefined();

  const changesActions = new NativeInfoActions();
  const changes = changesSection(
    {
      pullRequests: [
        {
          url: "https://github.com/example/project/pull/4",
          repo: "example/project",
          number: 4,
          title: "Links",
          state: "open",
          opened: true,
        },
      ],
      statuses: {},
      onOpenBeside: (url) => opened.push(url),
      open: true,
    },
    changesActions,
    t,
  )!;
  changesActions.run(changes.rows[0]!.action!);
  const sourcesActions = new NativeInfoActions();
  const sources = sourcesSection(
    {
      sources: [{ kind: "url", url: "https://example.com/source", label: "Source" }],
      onOpenBeside: (url) => opened.push(url),
      expanded: false,
      onExpandedChange: () => {},
      open: true,
    },
    sourcesActions,
    t,
  )!;
  sourcesActions.run(sources.rows[0]!.action!);
  await Promise.resolve();
  expect(opened).toEqual([
    "https://github.com/example/project",
    "https://github.com/example/project/tree/main",
    "https://github.com/example/project/pull/4",
    "https://example.com/source",
  ]);

  const calls: { method: string; params: Record<string, unknown> }[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    return undefined;
  });
  const actions = new NativeInfoActions();
  const outputs = outputsSection(
    {
      files: [],
      artifacts: 0,
      links: [{ url: "https://example.com/result", label: "Result" }],
      open: true,
    },
    actions,
    t,
  )!;
  actions.run(outputs.rows[0]!.action!);
  await Promise.resolve();
  await Promise.resolve();
  setChipHost(undefined);
  expect(calls).toEqual([
    { method: "browser.openIn", params: { url: "https://example.com/result", browserId: "cmux" } },
  ]);
  expect(safeExternalUrl("javascript:alert(1)")).toBeUndefined();
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
          { name: "Free", tokens: 600, kind: "free" },
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
  expect(section.rows.find((row) => row.title === "Free")?.subtitle).toBe(
    t("sessionInfo.context.untilAutoCompact", { tokens: "600" }),
  );
  actions.run(section.rows[0]!.buttons![0]!.action);
  actions.run(section.rows.find((row) => row.id === "list:mcpTools")!.action!);
  await Promise.resolve();
  expect(compacted).toBe(true);
  expect(opened).toBe("mcpTools");

  const withoutCompact = contextSection(
    {
      usage: { used: 300, size: 1000 },
      language: "en",
      open: true,
      breakdown: {
        categories: [
          { name: "Messages", tokens: 300, kind: "used" },
          { name: "Buffer", tokens: 100, kind: "buffer" },
          { name: "Free", tokens: 600, kind: "free" },
        ],
        maxTokens: 1000,
      },
    },
    new NativeInfoActions(),
    t,
  )!;
  expect(withoutCompact.rows.find((row) => row.title === "Free")?.subtitle).toBeUndefined();
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
          breakdown: { tests: { additions: 2, deletions: 0 }, code: { additions: 8, deletions: 2 }, docs: undefined },
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
  expect(row.hover!.detail).toContain(`${t("sessionInfo.changes.code")} +8 -2`);
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
  // The App draws the pack's pull-request glyphs (the page's row's own), never SF Symbol arrows.
  const symbols = new Map(section.rows.map((row) => [row.title.split(" ")[0], row.symbol]));
  expect(symbols).toEqual(
    new Map([
      ["open", "cmux:git.pullrequest"],
      ["merged", "cmux:git.pullrequest.merged"],
      ["draft", "cmux:git.pullrequest.draft"],
      ["closed", "cmux:git.pullrequest.closed"],
      ["conflicting", "cmux:git.pullrequest.closed"],
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
