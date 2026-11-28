import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import { connectionLost, hyperdriveSqlLayer, SqlClient, type Connection, type SqlClientService, withRequestConnection } from "../../src/db/sql.ts";

// 2026-11-28 14:23Z: staging's ownership.find lost its Hyperdrive connection, the request kept sending on the dead
// connection, cmux-vm answered 503 and the platform answered the probe's setup write 502 (run 46154198308).

interface FakeConnection {
  readonly sent: Array<string>;
  ended: boolean;
}

const lost = new Error("Network connection lost.");

/** Each opened connection answers from `answers` in turn: an Error fails the query, anything else is its rows. */
const fakeOpen = (answers: Array<unknown>) => {
  const opened: Array<FakeConnection> = [];
  const open = (): Connection => {
    const connection: FakeConnection = { sent: [], ended: false };
    opened.push(connection);
    return {
      unsafe: async (text: string): Promise<Iterable<unknown>> => {
        connection.sent.push(text);
        const answer = answers.shift();
        if (answer instanceof Error) throw answer;
        return Array.isArray(answer) ? answer : [];
      },
      end: async () => {
        connection.ended = true;
      },
    };
  };
  return { open, opened };
};

const inRequest = <A, E>(open: () => Connection, work: (client: SqlClientService) => Effect.Effect<A, E>) =>
  Effect.runPromise(
    withRequestConnection(Effect.flatMap(SqlClient, work)).pipe(Effect.provide(hyperdriveSqlLayer("postgres://unused", open))),
  );

describe("hyperdriveSqlLayer after a lost connection", () => {
  it("sends a read again on a fresh connection", async () => {
    const { open, opened } = fakeOpen([lost, [{ id: 1 }]]);
    const rows = await inRequest(open, (client) => client.query("ownership.find", "SELECT 1", []));
    expect(rows).toEqual([{ id: 1 }]);
    expect(opened.length).toBe(2);
    expect(opened[0]?.ended).toBe(true);
  });

  it("does not resend a write, and the request's next query opens a fresh connection", async () => {
    const { open, opened } = fakeOpen([lost, [{ ok: true }]]);
    const outcome = await inRequest(open, (client) =>
      Effect.either(client.query("ownership.insert", "INSERT INTO t VALUES (1)", [])).pipe(
        Effect.zip(client.query("ownership.find", "SELECT 1", [])),
      ),
    );
    expect(outcome[0]._tag).toBe("Left");
    expect(outcome[1]).toEqual([{ ok: true }]);
    expect(opened.map((c) => c.sent)).toEqual([["INSERT INTO t VALUES (1)"], ["SELECT 1"]]);
  });

  it("answers a statement error once, on the same connection", async () => {
    const bad = Object.assign(new Error("relation does not exist"), { code: "42P01" });
    const { open, opened } = fakeOpen([bad, [{ id: 2 }]]);
    const outcome = await inRequest(open, (client) =>
      Effect.either(client.query("ownership.find", "SELECT 1", [])).pipe(Effect.zip(client.query("ownership.find", "SELECT 2", []))),
    );
    expect(outcome[0]._tag).toBe("Left");
    expect(opened.length).toBe(1);
    expect(opened[0]?.sent).toEqual(["SELECT 1", "SELECT 2"]);
  });

  it("gives up after one resend", async () => {
    const { open, opened } = fakeOpen([lost, lost, [{ id: 3 }]]);
    const outcome = await inRequest(open, (client) => Effect.either(client.query("ownership.find", "SELECT 1", [])));
    expect(outcome._tag).toBe("Left");
    expect(opened.length).toBe(2);
  });

  it("tells a lost connection by message or driver code", () => {
    expect(connectionLost(lost)).toBe(true);
    expect(connectionLost(Object.assign(new Error("write CONNECTION_CLOSED"), { code: "CONNECTION_CLOSED" }))).toBe(true);
    expect(connectionLost(Object.assign(new Error("duplicate key"), { code: "23505" }))).toBe(false);
    expect(connectionLost("Network connection lost.")).toBe(false);
  });
});
