import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "./direct";
import { MockAcpmuxSocket, mockHost } from "./mock";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { FORK_OP, servesOperation } from "./operations";
import { TurnFooter } from "./conversation/TurnRows";
import { TurnActionsContext } from "./conversation/turnActions";

const until = async (done: () => boolean) => {
  for (let tries = 0; tries < 200 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

/// An acpmux that serves no forks: its `initialize` lists no operations.
class NoForkSocket extends MockAcpmuxSocket {
  readonly sent: string[] = [];
  override send(raw: string): void {
    const request = JSON.parse(raw) as { id?: number; method: string };
    this.sent.push(request.method);
    if (request.method === "initialize")
      return (this as any).deliver({ jsonrpc: "2.0", id: request.id, result: { protocolVersion: 1 } });
    super.send(raw);
  }
}

const connect = (snapshots: AcpmuxSnapshot[], socket: () => MockAcpmuxSocket) => {
  (globalThis as any).window ??= globalThis;
  return AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => snapshots.push(snapshot),
    undefined,
    socket as unknown as () => WebSocket,
  );
};

describe("fork support", () => {
  test("acpmux serves a fork only when its initialize lists the operation", () => {
    expect(servesOperation({ _meta: { acpmux: { operations: [FORK_OP] } } }, FORK_OP)).toBe(true);
    expect(servesOperation({ _meta: { acpmux: { operations: ["acp.session.rename"] } } }, FORK_OP)).toBe(false);
    expect(servesOperation({ _meta: { acpmux: { operations: FORK_OP } } }, FORK_OP)).toBe(false);
    expect(servesOperation({ protocolVersion: 1 }, FORK_OP)).toBe(false);
    expect(servesOperation(undefined, FORK_OP)).toBe(false);
  });

  /// The pane's fork runs end to end against the mock, which serves `acp.session.fork`.
  test("forking through a turn opens a new session holding the conversation up to that turn", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connect(snapshots, () => new MockAcpmuxSocket(() => Promise.resolve()));
    expect(snapshots.at(-1)?.canFork).toBe(true);
    await client.create();
    const summaries = () => snapshots.at(-1)?.rows.filter((row) => row.kind === "turnSummary") ?? [];
    await client.send("first");
    await until(() => summaries().length === 1);
    await client.send("second");
    await until(() => summaries().length === 2);
    const source = snapshots.at(-1)!.sessionId;
    const through = summaries()[0]!.seq!;
    expect(through).toBeGreaterThan(0);

    const forked = await client.fork(through);
    expect(forked).toBeDefined();
    expect(forked).not.toBe(source);
    await until(() => snapshots.at(-1)?.sessionId === forked && summaries().length === 1);
    const rows = snapshots.at(-1)!.rows;
    expect(rows.filter((row) => row.kind === "user").map((row) => row.text)).toEqual(["first"]);
    expect(summaries()).toHaveLength(1);
    // The source keeps both turns, and both sessions are listed.
    expect(snapshots.at(-1)!.sessions.map((entry) => entry.sessionId)).toEqual(
      expect.arrayContaining([source, forked]),
    );
  });

  test("an acpmux that does not serve forks is never asked", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    let socket: NoForkSocket | undefined;
    const client = await connect(snapshots, () => (socket = new NoForkSocket(() => Promise.resolve())));
    expect(snapshots.at(-1)?.canFork).toBe(false);
    expect(await client.fork(1)).toBeUndefined();
    expect(socket!.sent).not.toContain(FORK_OP);
  });
});

describe("turn footer fork", () => {
  const summary: AcpmuxRow = { id: "s", version: 1, at: 0, kind: "turnSummary", seq: 42, text: "Done.", folded: true };
  const html = (fork?: (seq: number) => void, row = summary) =>
    renderToStaticMarkup(
      createElement(TurnActionsContext.Provider, { value: fork ? { fork } : {} }, createElement(TurnFooter, { row })),
    );

  test("the footer offers fork only when acpmux serves forks", () => {
    expect(html(() => {})).toContain('aria-label="Fork from here"');
    expect(html()).not.toContain("Fork from here");
    // A summary without its event (a row the client did not number) has nothing to fork through.
    expect(html(() => {}, { ...summary, seq: undefined })).not.toContain("Fork from here");
  });
});
