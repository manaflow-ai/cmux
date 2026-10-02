import { describe, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "./direct";
import { MockAcpmuxSocket, mockHost, mockReply } from "./mock";
import type { AcpmuxSnapshot } from "./model";
import { readChangeSet } from "./changes/model";
import { GROUP_ROWS, sessionMark, sidebarSections } from "./sessionList";
import { workedTurn } from "./mockFixture";
import { turnView } from "./conversation/turns";

describe("mock transport", () => {
  const connectMock = async (
    snapshots: AcpmuxSnapshot[],
    delay: (ms: number) => Promise<void> = () => Promise.resolve(),
  ) => {
    (globalThis as any).window ??= globalThis;
    return AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(delay) as unknown as WebSocket,
    );
  };
  const until = async (done: () => boolean) => {
    for (let tries = 0; tries < 50 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  };

  /// Mock mode runs the real client against the in-page daemon, so a mock turn goes through the
  /// same event folding as an agent's.
  test("a prompt streams a scripted turn through the real client", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    (globalThis as any).window ??= globalThis;
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
    );
    expect(snapshots.at(-1)?.summary?.harness).toBe("claude");
    expect(snapshots.at(-1)?.commands?.map((command) => command.name)).toContain("compact");
    expect((await client.harnesses()).map((harness) => harness.id)).toEqual(["claude", "codex"]);
    // The scripted turn runs in a new chat, so its rows are the only ones.
    await client.create();
    await client.send("hello");
    for (let tries = 0; tries < 20 && !snapshots.at(-1)?.rows.some((row) => row.kind === "turnSummary"); tries += 1)
      await new Promise((resolve) => setTimeout(resolve, 0));
    const rows = snapshots.at(-1)!.rows;
    expect(snapshots.at(-1)?.isWorking).toBe(false);
    expect(rows.find((row) => row.kind === "user")?.text).toBe("hello");
    expect(rows.filter((row) => row.kind === "assistant").at(-1)?.text).toContain(mockReply("hello"));
    // The turn edits files, so it has changes to review.
    const diffs = rows.flatMap((row) => row.items ?? []).flatMap((item) => item.tool?.diffs ?? []);
    expect(diffs.map((diff) => diff.path)).toEqual(["/mock/project/src/greeting.ts", "/mock/project/NOTES.md"]);
    // The reply splits around its tool calls, and the summary counts all three.
    expect(rows.map((row) => row.kind)).toEqual([
      "user",
      "assistant",
      "activity",
      "assistant",
      "activity",
      "assistant",
      "turnSummary",
    ]);
    expect(rows.find((row) => row.kind === "turnSummary")?.toolCount).toBe(3);
    // The new chat has had a turn now.
    await until(() => snapshots.at(-1)?.summary?.turnCount === 1);
    expect(snapshots.at(-1)?.summary?.turnCount).toBe(1);
    client.close();
  });

  test("the pane opens on a seeded workspace with a worked turn", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    client.snapshot();
    const snapshot = snapshots.at(-1)!;
    // Five projects and 20 sessions, in every state the sidebar draws.
    expect(snapshot.sessions).toHaveLength(20);
    expect(new Set(snapshot.sessions.map((entry) => entry.cwd)).size).toBe(5);
    const marks = snapshot.sessions.map((entry) => sessionMark(entry, false));
    for (const mark of ["input", "running", "error", "unread"] as const) expect(marks).toContain(mark);
    expect(snapshot.sessions.filter((entry) => entry.pinned).map((entry) => entry.displayTitle)).toEqual([
      "Add retry backoff to the fleet uploader",
      "Resume sessions after a daemon restart",
    ]);
    expect(new Set(snapshot.sessions.map((entry) => entry.hostKind))).toEqual(new Set(["local", "cloud"]));
    expect(
      snapshot.sessions.filter((entry) => entry.pullRequest?.reviewReady).map((entry) => entry.pullRequest!.number),
    ).toEqual([18204, 212, 88]);
    expect(snapshot.sessions.every((entry) => entry.preview)).toBe(true);
    // Pinned sessions list on their own; cmux, local and cloud together, is still long enough to fold behind Show more.
    const sections = sidebarSections(snapshot.sessions);
    expect(sections.pinned).toHaveLength(2);
    expect(sections.groups.find((group) => group.label === "cmux")!.sessions.length).toBeGreaterThan(GROUP_ROWS + 1);
    // The worked session: its context, one finished turn with tools and three edited files.
    expect(snapshot.summary).toMatchObject({
      cwd: "~/code/cmux",
      turnCount: 1,
      host: "This Mac",
      hostKind: "local",
      branch: "feat-upload-retry",
      worktree: "~/code/cmux-worktrees/upload-retry",
      model: "claude-opus-5-5",
      effort: "medium",
    });
    expect(snapshot.summary?.modes?.currentModeId).toBe("bypassPermissions");
    const rows = snapshot.rows;
    expect(rows[0]?.kind).toBe("user");
    expect(rows.at(-1)?.kind).toBe("turnSummary");
    expect(rows.find((row) => row.kind === "turnSummary")?.toolCount).toBe(7);
    // The answer outside the fold carries a code block too, so a capture shows one.
    expect(rows.filter((row) => row.kind === "assistant").at(-1)?.text).toContain("```ts");
    const diffs = rows
      .flatMap((row) => row.items ?? [])
      .flatMap((item) => item.tool?.diffs ?? [])
      .map((diff) => diff.path);
    // The turn reports context usage, for the composer's usage ring.
    expect(
      workedTurn
        .map((step) => ("update" in step ? step.update : undefined))
        .find((update) => update?.sessionUpdate === "usage_update"),
    ).toEqual({ sessionUpdate: "usage_update", used: 33_551, size: 200_000 });
    expect(diffs).toEqual([
      "~/code/cmux/Sources/Fleet/retry.ts",
      "~/code/cmux/Sources/Fleet/upload.ts",
      "~/code/cmux/Sources/Fleet/upload.test.ts",
    ]);
    client.close();
  });

  test("every seeded session opens on its own history", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    await client.select("mock-sidebar-flicker");
    await until(() => snapshots.at(-1)?.sessionId === "mock-sidebar-flicker" && snapshots.at(-1)!.rows.length > 0);
    const snapshot = snapshots.at(-1)!;
    expect(snapshot.rows.find((row) => row.kind === "user")?.text).toBe("Fix sidebar flicker on theme change");
    // Its turn is still running on a cloud machine.
    expect(snapshot.isWorking).toBe(true);
    expect(snapshot.summary).toMatchObject({ host: "hearty-beige-elk", hostKind: "cloud" });
    // It is in the middle of a call, so the pane shows it working over that call.
    const tools = snapshot.rows.flatMap((row) => row.items ?? []).flatMap((item) => (item.tool ? [item.tool] : []));
    expect(tools.map(({ title, status }) => ({ title, status }))).toEqual([
      { title: "Run bun test Sources/Sidebar", status: "in_progress" },
    ]);
    expect(turnView(snapshot.rows, new Set(), { working: true }).map((row) => row.kind)).toEqual([
      "user",
      "working",
      "assistant",
      "activity",
    ]);
    client.close();
  });

  test("Stop ends a seeded running turn, and the session goes idle", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    await client.select("mock-sidebar-flicker");
    await until(() => snapshots.at(-1)?.isWorking === true);
    await client.cancel();
    await until(() => snapshots.at(-1)?.isWorking === false);
    expect(snapshots.at(-1)?.isWorking).toBe(false);
    expect(snapshots.at(-1)?.rows.find((row) => row.kind === "turnSummary")?.status).toBe("cancelled");
    // The call it was running settles with the turn.
    const tool = snapshots
      .at(-1)!
      .rows.flatMap((row) => row.items ?? [])
      .find((item) => item.tool)?.tool;
    expect(tool?.status).toBe("failed");
    expect(snapshots.at(-1)?.sessions.find((entry) => entry.sessionId === "mock-sidebar-flicker")?.status).toBe("idle");
    client.close();
  });

  test("a session needing input opens on its permission card, and answering it ends the turn", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    await client.select("mock-tab-strip");
    await until(() => snapshots.at(-1)?.permission !== undefined);
    const permission = snapshots.at(-1)!.permission!;
    expect(permission).toMatchObject({ title: "Run bun run lint:ci", kind: "execute" });
    expect(permission.options.map((option) => option.name)).toEqual(["Allow", "Always allow", "Deny"]);
    expect(snapshots.at(-1)?.rows.some((row) => row.kind === "turnSummary")).toBe(false);
    await client.permission(permission.permissionId, "allow_once");
    await until(
      () =>
        snapshots.at(-1)?.permission === undefined && snapshots.at(-1)!.rows.some((row) => row.kind === "turnSummary"),
    );
    expect(snapshots.at(-1)?.permission).toBeUndefined();
    const entry = snapshots.at(-1)?.sessions.find((session) => session.sessionId === "mock-tab-strip");
    expect([entry?.status, entry?.pendingPermissions]).toEqual(["idle", 0]);
    client.close();
  });

  test("opening a session reads it, and its history runs out", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    await client.select("mock-prorate");
    await until(() => snapshots.at(-1)?.sessionId === "mock-prorate" && snapshots.at(-1)!.rows.length > 0);
    await until(() => snapshots.at(-1)?.sessions.find((entry) => entry.sessionId === "mock-prorate")?.unread === false);
    expect(snapshots.at(-1)?.sessions.find((entry) => entry.sessionId === "mock-prorate")?.unread).toBe(false);
    await client.loadOlder();
    expect(snapshots.at(-1)?.canLoadOlder).toBe(false);
    client.close();
  });

  test("a new chat opens in the project of the session it was started from, with Claude's commands", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    await client.select("mock-zsh");
    await until(() => snapshots.at(-1)?.sessionId === "mock-zsh" && snapshots.at(-1)!.rows.length > 0);
    await client.create();
    await until(() => (snapshots.at(-1)?.commands?.length ?? 0) > 0);
    expect(snapshots.at(-1)?.summary).toMatchObject({ cwd: "~/code/dotfiles", branch: "main", turnCount: 0 });
    expect(snapshots.at(-1)?.commands?.map((command) => command.name)).toContain("compact");
    client.close();
  });

  test("a prompt sent during a turn shows in the queue until it starts", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    (globalThis as any).window ??= globalThis;
    const waiting: (() => void)[] = [];
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(() => new Promise<void>((resolve) => waiting.push(resolve))) as unknown as WebSocket,
    );
    const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
    // The seeded session already holds worked turns; count only the two this test sends.
    const summaries = () => snapshots.at(-1)?.rows.filter((row) => row.kind === "turnSummary").length ?? 0;
    const users = () =>
      snapshots
        .at(-1)
        ?.rows.filter((row) => row.kind === "user")
        .map((row) => row.text) ?? [];
    for (let tries = 0; tries < 20 && snapshots.length === 0; tries += 1) await tick();
    const before = summaries();
    const earlier = users();
    void client.send("first");
    void client.send("second");
    for (let tries = 0; tries < 20 && !snapshots.at(-1)?.queue.length; tries += 1) await tick();
    expect(snapshots.at(-1)?.queue.map((entry) => entry.prompt)).toEqual(["second"]);
    // Let every step of both turns through.
    for (let tries = 0; tries < 200 && summaries() !== before + 2; tries += 1) {
      waiting.splice(0).forEach((resolve) => resolve());
      await tick();
    }
    expect(snapshots.at(-1)?.queue).toEqual([]);
    expect(users()).toEqual([...earlier, "first", "second"]);
    client.close();
  });

  test("closing the daemon stops a queued prompt too", async () => {
    let steps = 0;
    const waiting: (() => void)[] = [];
    const socket = new MockAcpmuxSocket(() => {
      steps += 1;
      return new Promise<void>((resolve) => waiting.push(resolve));
    });
    const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
    await tick();
    const prompt = (id: number) =>
      socket.send(
        JSON.stringify({
          jsonrpc: "2.0",
          id,
          method: "session/prompt",
          params: { sessionId: mockHost.sessionId, prompt: [{ type: "text", text: `p${id}` }] },
        }),
      );
    prompt(1);
    prompt(2);
    await tick();
    expect(steps).toBe(1);
    socket.close();
    for (let round = 0; round < 5; round += 1) {
      while (waiting.length) waiting.shift()!();
      await tick();
    }
    expect(steps).toBe(1);
  });

  test("Stop ends the scripted turn as cancelled", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    let release: () => void = () => {};
    const client = await connectMock(
      snapshots,
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        }),
    );
    const sent = client.send("hello");
    await until(() => snapshots.at(-1)?.isWorking === true);
    await client.cancel();
    release();
    await sent;
    // The seeded turn has its own summary; the stopped turn's comes after it.
    const summaries = () => snapshots.at(-1)?.rows.filter((row) => row.kind === "turnSummary") ?? [];
    await until(() => summaries().length === 2);
    expect(summaries().map((row) => row.status)).toEqual(["completed", "cancelled"]);
    expect(snapshots.at(-1)?.isWorking).toBe(false);
    client.close();
  });

  test("a new chat is a session of its own with an empty transcript", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    const created = await client.create();
    client.snapshot();
    expect(created).not.toBe(mockHost.sessionId);
    expect(snapshots.at(-1)?.sessionId).toBe(created);
    expect(snapshots.at(-1)?.rows).toEqual([]);
    // It opens in the current project with no turns, so the pane can show its empty state.
    expect(snapshots.at(-1)?.summary).toMatchObject({ cwd: "~/code/cmux", turnCount: 0 });
    expect(snapshots.at(-1)?.sessions.map((entry) => entry.sessionId)).toContain(created);
    client.close();
  });

  test("a recorded turn replays with its own timestamps and no greeting", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    (globalThis as any).window ??= globalThis;
    const script = {
      steps: [
        {
          atMs: 2_000,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Recorded answer." } },
        },
      ],
      endAtMs: 15_000,
    };
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(() => Promise.resolve(), script) as unknown as WebSocket,
    );
    client.snapshot();
    expect(snapshots.at(-1)?.rows).toEqual([]);
    await client.send("replay");
    await until(() => snapshots.at(-1)?.rows.some((row) => row.kind === "turnSummary") === true);
    const rows = snapshots.at(-1)!.rows;
    expect(rows.filter((row) => row.kind === "assistant").map((row) => row.text)).toEqual(["Recorded answer."]);
    const user = rows.find((row) => row.kind === "user")!;
    expect(rows.find((row) => row.kind === "assistant")!.at - user.at).toBeGreaterThanOrEqual(2_000);
    expect(rows.find((row) => row.kind === "turnSummary")!.at - user.at).toBeGreaterThanOrEqual(15_000);
    client.close();
  });
});

describe("mock daemon", () => {
  /// Drives the daemon over raw JSON-RPC and records every message it sends back.
  const open = (script?: ConstructorParameters<typeof MockAcpmuxSocket>[1]) => {
    (globalThis as any).window ??= globalThis;
    const socket = new MockAcpmuxSocket(() => Promise.resolve(), script);
    const sent: any[] = [];
    socket.onmessage = ({ data }) => sent.push(JSON.parse(data));
    let id = 0;
    const call = async (method: string, params: Record<string, unknown> = {}) => {
      const request = ++id;
      socket.send(JSON.stringify({ jsonrpc: "2.0", id: request, method, params }));
      for (let tries = 0; tries < 50 && !sent.some((message) => message.id === request); tries += 1)
        await new Promise((resolve) => setTimeout(resolve, 0));
      return sent.find((message) => message.id === request)?.result;
    };
    return { socket, sent, call };
  };
  const toolUpdates = (sent: any[], target: string) =>
    sent.filter(
      (message) =>
        message.method === "_acpmux/event" &&
        message.params?.sessionId === target &&
        message.params?.msg?.params?.update?.sessionUpdate === "tool_call_update",
    );

  test("Stop on a session waiting for permission settles its pending tool as failed", async () => {
    const { socket, sent, call } = open();
    await call("_acpmux/attach", { sessionId: "mock-tab-strip" });
    socket.send(JSON.stringify({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: "mock-tab-strip" } }));
    // The daemon answers a notification on a later tick; a call behind it waits for it.
    await call("_acpmux/watch");
    expect(toolUpdates(sent, "mock-tab-strip").map((message) => message.params.msg.params.update.status)).toEqual([
      "failed",
    ]);
  });

  test("answering a permission twice settles its tool once", async () => {
    const { sent, call } = open();
    await call("_acpmux/permission_respond", { sessionId: "mock-tab-strip", optionId: "allow_once" });
    await call("_acpmux/permission_respond", { sessionId: "mock-tab-strip", optionId: "deny" });
    expect(toolUpdates(sent, "mock-tab-strip").map((message) => message.params.msg.params.update.status)).toEqual([
      "completed",
    ]);
  });

  test("a new chat opens on the machine of the session it was started from", async () => {
    const { call } = open();
    await call("_acpmux/attach", { sessionId: "mock-sidebar-flicker" });
    const { sessionId } = await call("session/new");
    const { sessions } = await call("_acpmux/watch");
    const from = sessions.find((entry: any) => entry.sessionId === "mock-sidebar-flicker");
    const created = sessions.find((entry: any) => entry.sessionId === sessionId);
    expect([created.host, created.hostKind, created.cwd]).toEqual([from.host, from.hostKind, from.cwd]);
  });

  test("a new chat in a replayed script uses the script's model", async () => {
    const { call } = open({ steps: [] });
    const { sessionId } = await call("session/new");
    const { sessions } = await call("_acpmux/watch");
    expect(sessions.find((entry: any) => entry.sessionId === sessionId)?.model).toBe("claude-sonnet");
  });

  test("each waiting session's pending count matches the permissions it asks for", async () => {
    const { call } = open();
    const { sessions } = await call("_acpmux/watch");
    for (const entry of sessions.filter((session: any) => session.pendingPermissions)) {
      const { events } = await call("_acpmux/attach", { sessionId: entry.sessionId });
      const asked = events.filter((event: any) => event.kind === "permission_request").length;
      expect([entry.sessionId, asked]).toEqual([entry.sessionId, entry.pendingPermissions]);
    }
  });

  test("the worked session's git scopes hold the turn's edits, half staged, over one commit", async () => {
    const { call, sent } = open();
    const paths = async (scope: string, sessionId = "mock-session") =>
      ((await call("git.diff", { sessionId, scope, include_patch: true }))?.files ?? []).map((file: any) => file.path);
    expect(await paths("staged")).toEqual(["Sources/Fleet/retry.ts"]);
    expect(await paths("unstaged")).toEqual(["Sources/Fleet/upload.ts", "Sources/Fleet/upload.test.ts"]);
    expect(await paths("uncommitted")).toEqual([
      "Sources/Fleet/retry.ts",
      "Sources/Fleet/upload.ts",
      "Sources/Fleet/upload.test.ts",
    ]);
    expect(await paths("committed")).toEqual(["Sources/Fleet/manifest.ts"]);
    expect((await paths("branch")).length).toBe(4);
    // Each file carries its counts and a patch from its first hunk; the set carries its totals.
    const branch = await call("git.diff", { sessionId: "mock-session", scope: "branch", include_patch: true });
    expect(branch.root).toBe("~/code/cmux");
    expect([branch.total_files, branch.files_omitted]).toEqual([4, 0]);
    // The view reads the catalog's snake_case reply (cmux-tui GitDiffResult).
    expect(readChangeSet({ ...branch, files_omitted: 2, untracked_skipped: 3 }, "branch")).toMatchObject({
      totalFiles: 4,
      filesOmitted: 2,
      untrackedSkipped: 3,
    });
    const renamed = { path: "b.ts", previous_path: "a.ts", status: "renamed", additions: 0, deletions: 0 };
    expect(readChangeSet({ files: [{ ...renamed, patch_truncated: true }] }, "staged")?.files[0]).toMatchObject({
      previousPath: "a.ts",
      patchTruncated: true,
    });
    for (const file of branch.files) {
      expect(file.patch.startsWith("@@ -")).toBe(true);
      expect(file.patch.split("\n").filter((line: string) => line.startsWith("+")).length).toBe(file.additions);
    }
    expect(branch.additions).toBe(branch.files.reduce((sum: number, file: any) => sum + file.additions, 0));
    expect(await call("git.status", { sessionId: "mock-session" })).toEqual({
      root: "~/code/cmux",
      detached: false,
      branch: "feat-upload-retry",
      upstream: "origin/main",
      base: "main",
      ahead: 1,
      behind: 0,
    });
    // As on the session host: patches only when asked, a base only where the scope compares
    // with one, and no scope outside the catalog's five.
    const plain = await call("git.diff", { sessionId: "mock-session", scope: "committed" });
    expect(Object.keys(plain.files[0]).sort()).toEqual(["additions", "deletions", "path", "status"]);
    expect(plain.base).toBe("4be1c2e~1");
    const staged = await call("git.diff", { sessionId: "mock-session", scope: "staged" });
    expect("base" in staged).toBe(false);
    expect(await call("git.diff", { sessionId: "mock-session", scope: "lastTurn" })).toBeUndefined();
    expect(sent.at(-1)?.error?.message).toBe("Unknown scope lastTurn");
    // Another project's session has no changes; a folder outside git fails to load.
    const { sessions } = await call("_acpmux/watch");
    const other = sessions.find((entry: any) => entry.cwd === "~/code/acpmux").sessionId;
    expect(await paths("uncommitted", other)).toEqual([]);
    const dotfiles = sessions.find((entry: any) => entry.cwd === "~/code/dotfiles").sessionId;
    expect(await call("git.diff", { sessionId: dotfiles, scope: "branch" })).toBeUndefined();
    expect(sent.at(-1)?.error?.message).toBe("Not a git repository");
  });
});
