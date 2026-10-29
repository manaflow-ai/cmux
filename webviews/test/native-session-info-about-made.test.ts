// l10n-allow-file: test fixture names, paths and URLs, not shipped UI.
// Session Info drawn natively: the about and made blocks' mappers (inspector/native/*.ts) hand the
// App the same titles and values the web sections show, and each click the App sends back runs the
// callback the page registered under that row's action id.
import { expect, test } from "bun:test";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { changesSection } from "../src/agent-session/acpmux/inspector/native/changes";
import { connectorsSection } from "../src/agent-session/acpmux/inspector/native/connectors";
import { contextSection } from "../src/agent-session/acpmux/inspector/native/context";
import { environmentSection } from "../src/agent-session/acpmux/inspector/native/environment";
import { NativeInfoActions } from "../src/agent-session/acpmux/inspector/native/model";
import { outputsSection } from "../src/agent-session/acpmux/inspector/native/outputs";
import { sourcesSection } from "../src/agent-session/acpmux/inspector/native/sources";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { SummaryPullRequest } from "../src/agent-session/acpmux/summary/sessionSummary";
import type { TurnFile } from "../src/agent-session/acpmux/diff";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const t = translatorFor("en");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

async function click(actions: NativeInfoActions, id: string | undefined) {
  expect(id).toBeDefined();
  expect(actions.run(id!)).toBe(true);
  await tick();
}

test("Environment heads the panel bare; its project row opens the folder and Save saves", async () => {
  const actions = new NativeInfoActions();
  const opened: string[] = [];
  let saves = 0;
  let marked = false;
  const summary = { cwd: "/Users/me/src/cmux", branch: "feat/x", host: "mac" } as Summary;
  const section = environmentSection(
    {
      summary,
      machineName: "My Mac",
      repository: "manaflow-ai/cmux",
      onOpenFolder: (path) => opened.push(path),
      onSave: () => {
        saves += 1;
      },
      onSaved: () => {
        marked = true;
      },
    },
    actions,
    t,
  )!;
  expect(section).toMatchObject({ id: "environment", group: "about", bare: true, open: true, foldable: false });
  expect(section.title).toBe(t("rail.environment"));
  expect(section.rows.map((row) => row.id)).toEqual(["machine", "project", "repository", "branch"]);
  expect(section.rows[0]!.title).toBe("My Mac");
  const project = section.rows[1]!;
  expect(project).toMatchObject({ title: "cmux", help: "/Users/me/src/cmux", symbol: "folder" });
  await click(actions, project.action);
  expect(opened).toEqual(["/Users/me/src/cmux"]);
  const save = section.rows[0]!.buttons![0]!;
  expect(save.label).toBe(t("chatInspector.environment.save"));
  await click(actions, save.action);
  await tick();
  expect(saves).toBe(1);
  expect(marked).toBe(true);
  expect(section.rows[3]!.symbol).toBe("arrow.triangle.branch");
});

test("Context reads its percent and meter, rows per part; a subagent's progress is the title's value", () => {
  const actions = new NativeInfoActions();
  const section = contextSection({ usage: { used: 50_000, size: 200_000 }, language: "en", open: true }, actions, t)!;
  expect(section.title).toBe(t("rail.context"));
  expect(section.meta).toBe(t("rail.percent", { percent: 25 }));
  expect(section.meter).toBe(0.25);
  expect(section.symbol).toBe("gauge.with.dots.needle.33percent");
  expect(section.rows.map((row) => row.id)).toEqual(["total", "used", "free"]);
  expect(section.rows[1]!.meter).toBe(0.25);

  const progress = contextSection(
    {
      language: "en",
      open: false,
      agent: { id: "a", parent: null, name: "x", state: "running", startedAt: 0, toolUses: 3 },
    },
    actions,
    t,
  )!;
  expect(progress).toMatchObject({ open: true, foldable: false, rows: [] });
  expect(progress.meta).toBe(t("subagents.toolUses", { n: 3 }));
  expect(contextSection({ language: "en", open: true }, actions, t)).toBeUndefined();
});

test("Connectors: Reconnect only on failed servers, and its click reconnects that one", async () => {
  const actions = new NativeInfoActions();
  const asked: string[] = [];
  const servers = [
    { name: "github", status: "connected" as const },
    { name: "linear", status: "failed" as const },
    { name: "slow", status: "pending" as const },
  ];
  const section = connectorsSection(
    { servers, open: true, onReconnect: async (name) => asked.push(name) },
    actions,
    t,
  )!;
  expect(section.title).toBe(t("rail.connectors"));
  expect(section.meta).toBe(t("chatInspector.connectors.reconnect", { count: 1 }));
  const [github, linear, slow] = section.rows;
  expect(github).toMatchObject({ tone: "done", trailing: t("composer.envConnected") });
  expect(github!.buttons).toBeUndefined();
  expect(slow!.buttons).toBeUndefined();
  expect(linear!.tone).toBe("failed");
  expect(linear!.buttons![0]!.label).toBe(t("chatInspector.connectors.reconnectAction"));
  await click(actions, linear!.buttons![0]!.action);
  expect(asked).toEqual(["linear"]);

  const plain = connectorsSection({ servers, open: true }, new NativeInfoActions(), t)!;
  expect(plain.rows[1]!.buttons).toBeUndefined();
  expect(plain.rows[1]!.trailing).toBe(t("chatInspector.connectors.needsReconnect"));
  const healthy = connectorsSection({ servers: [servers[0]!], open: true }, new NativeInfoActions(), t)!;
  expect(healthy.meta).toBe(t("rail.connected", { count: 1 }));
});

test("Changes: one row per pull request by URL, its click opens it beside the chat", async () => {
  const actions = new NativeInfoActions();
  const opened: string[] = [];
  const pr = (number: number, state: SummaryPullRequest["state"]): SummaryPullRequest => ({
    url: `https://github.com/o/r/pull/${number}`,
    repo: "o/r",
    number,
    title: `PR ${number}`,
    state,
    opened: true,
    touched: number,
  });
  const section = changesSection(
    {
      pullRequests: [pr(1, "merged"), pr(2, "open")],
      statuses: { "https://github.com/o/r/pull/2": { failing: 2, additions: 3, deletions: 1 } },
      open: true,
      onOpenBeside: (url) => opened.push(url),
    },
    actions,
    t,
  )!;
  expect(section.title).toBe(t("header.changes"));
  expect(section.meta).toBe("2");
  expect(section.rows.map((row) => row.id)).toEqual(["https://github.com/o/r/pull/2", "https://github.com/o/r/pull/1"]);
  expect(section.rows[0]).toMatchObject({ tone: "failed", trailing: t("chatInspector.changes.failing", { count: 2 }) });
  expect(section.rows[0]!.subtitle).toBe("r #2  +3 -1");
  expect(section.rows[1]!.symbol).toBe("arrow.triangle.merge");
  await click(actions, section.rows[1]!.action);
  expect(opened).toEqual(["https://github.com/o/r/pull/1"]);
  expect(section.more).toBeUndefined();
});

test("Sources: five then View all N, Show fewer when expanded; files and links open", async () => {
  const sources = [
    { kind: "file" as const, label: "src/a.ts" },
    ...Array.from({ length: 6 }, (_, index) => ({
      kind: "url" as const,
      label: `site ${index}`,
      url: `https://example.com/${index}`,
    })),
  ];
  const changes: boolean[] = [];
  const files: unknown[] = [];
  const urls: string[] = [];
  const input = {
    sources,
    cwd: "/repo",
    open: true,
    onOpenFile: (path: string) => files.push(path),
    onOpenBeside: (url: string) => urls.push(url),
    onExpandedChange: (next: boolean) => changes.push(next),
  };
  const actions = new NativeInfoActions();
  const folded = sourcesSection({ ...input, expanded: false }, actions, t)!;
  expect(folded.title).toBe(t("summary.sources"));
  expect(folded.meta).toBe("7");
  expect(folded.rows).toHaveLength(5);
  expect(folded.more!.label).toBe(t("summary.viewAll", { n: 7 }));
  await click(actions, folded.more!.action);
  expect(changes).toEqual([true]);
  await click(actions, folded.rows[0]!.action);
  expect(files).toEqual(["/repo/src/a.ts"]);
  await click(actions, folded.rows[1]!.action);
  expect(urls).toEqual(["https://example.com/0"]);

  const expandedActions = new NativeInfoActions();
  const expanded = sourcesSection({ ...input, expanded: true }, expandedActions, t)!;
  expect(expanded.rows).toHaveLength(7);
  expect(expanded.more!.label).toBe(t("summary.showFewer"));
  await click(expandedActions, expanded.more!.action);
  expect(changes).toEqual([true, false]);

  expect(sourcesSection({ ...input, sources: sources.slice(0, 5), expanded: false }, actions, t)!.more).toBeUndefined();
});

test("Outputs: documents, the gallery, files and links, each opening what it names", async () => {
  const actions = new NativeInfoActions();
  const opened: string[] = [];
  let gallery = 0;
  const file = { path: "/repo/src/a.ts", displayPath: "src/a.ts", additions: 4, deletions: 2, created: false };
  const section = outputsSection(
    {
      files: [file as unknown as TurnFile],
      links: [{ url: "https://example.com/x", label: "example.com/x" }],
      artifacts: 2,
      open: true,
      onOpenFile: (path) => opened.push(path),
      onOpenArtifacts: () => {
        gallery += 1;
      },
      onOpenUrl: (url) => opened.push(url),
    },
    actions,
    t,
  )!;
  expect(section.title).toBe(t("rail.outputs"));
  expect(section.meta).toBeUndefined();
  expect(section.rows.map((row) => row.id)).toEqual(["gallery", "file:/repo/src/a.ts", "link:https://example.com/x"]);
  expect(section.rows[1]).toMatchObject({ title: "a.ts", detail: "src", trailing: "+4 -2" });
  await click(actions, section.rows[0]!.action);
  expect(gallery).toBe(1);
  await click(actions, section.rows[1]!.action);
  await click(actions, section.rows[2]!.action);
  expect(opened).toEqual(["/repo/src/a.ts", "https://example.com/x"]);
  expect(outputsSection({ files: [], links: [], artifacts: 0, open: true }, actions, t)).toBeUndefined();
});
