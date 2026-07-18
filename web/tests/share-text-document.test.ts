import { describe, expect, test } from "bun:test";
import {
  ReplicatedTextDocument,
  parseTextOperation,
  snapshotFromText,
  type TextOperation,
} from "../services/share/textDocument";

function counter(): () => number {
  let value = 0;
  return () => ++value;
}

function id(clock: number, client: string): string {
  return `${String(clock).padStart(12, "0")}:${client}`;
}

describe("shared TextBox document", () => {
  test("concurrent Japanese and emoji edits converge in either delivery order", () => {
    const snapshot = snapshotFromText("doc", "start ");
    const alice = new ReplicatedTextDocument(snapshot);
    const bob = new ReplicatedTextDocument(snapshot);
    const aliceOps = alice.localChange("start 🙂", "alice", counter());
    const bobOps = bob.localChange("start 日本", "bob", counter());

    for (const operation of bobOps) alice.apply(operation);
    for (const operation of aliceOps) bob.apply(operation);

    expect(alice.view().text).toBe(bob.view().text);
    expect(alice.view().text).toContain("🙂");
    expect(alice.view().text).toContain("日本");
  });

  test("a delete delivered before its insert remains deleted", () => {
    const document = new ReplicatedTextDocument(snapshotFromText("doc", ""));
    const insert: TextOperation = {
      opId: id(2, "alice"),
      docId: "doc",
      kind: "insert",
      atoms: [{ id: id(1, "alice"), afterId: null, value: "🙂", deleted: false }],
    };
    const remove: TextOperation = {
      opId: id(1, "bob"),
      docId: "doc",
      kind: "delete",
      atomIds: [id(1, "alice")],
    };
    document.apply(remove);
    document.apply(insert);
    expect(document.view().text).toBe("");
  });

  test("duplicate operations are idempotent", () => {
    const document = new ReplicatedTextDocument(snapshotFromText("doc", "a"));
    const operation: TextOperation = {
      opId: id(3, "alice"),
      docId: "doc",
      kind: "insert",
      atoms: [{ id: id(2, "alice"), afterId: id(1, "host"), value: "b", deleted: false }],
    };
    expect(document.apply(operation)).toBe(true);
    expect(document.apply(operation, 9)).toBe(false);
    expect(document.view().text).toBe("ab");
    expect(document.view().revision).toBe(9);
  });

  test("inserting in the middle stays before the existing suffix", () => {
    const document = new ReplicatedTextDocument(snapshotFromText("doc", "abc"));
    document.localChange("a🙂bc", "alice", counter());
    expect(document.view().text).toBe("a🙂bc");
  });

  test("an IME commit preserves edits received during composition", () => {
    const snapshot = snapshotFromText("doc", "abc");
    const alice = new ReplicatedTextDocument(snapshot);
    const bob = new ReplicatedTextDocument(snapshot);
    const composition = alice.beginComposition();
    const bobOperations = bob.localChange("a日bc", "bob", counter());
    for (const operation of bobOperations) alice.apply(operation);

    const aliceOperations = alice.localChangeFrom(composition, "a🙂bc", "alice", counter());
    for (const operation of aliceOperations) bob.apply(operation);

    expect(alice.view().text).toBe(bob.view().text);
    expect(alice.view().text).toContain("日");
    expect(alice.view().text).toContain("🙂");
    expect(alice.view().text).toContain("bc");
  });

  test("large replacements are split into bounded operations", () => {
    const document = new ReplicatedTextDocument(snapshotFromText("doc", ""));
    const operations = document.localChange("x".repeat(600), "alice", counter());
    expect(operations.length).toBe(3);
    expect(operations.every((operation) => operation.kind !== "insert" || operation.atoms.length <= 256)).toBe(true);
    expect(document.view().text).toBe("x".repeat(600));
  });

  test("insert atoms require the canonical tombstone field", () => {
    const base = {
      opId: id(2, "alice"),
      docId: "doc",
      kind: "insert",
      atoms: [{ id: id(1, "alice"), afterId: null, value: "x", deleted: false }],
    };
    expect(parseTextOperation(base)).not.toBeNull();
    expect(parseTextOperation({
      ...base,
      atoms: [{ id: id(1, "alice"), afterId: null, value: "x" }],
    })).toBeNull();
  });

  test("rejects remote clocks that could exhaust the host clock", () => {
    expect(parseTextOperation({
      opId: "999999999999:viewer",
      docId: "doc",
      kind: "delete",
      atomIds: [id(1, "host")],
    })).toBeNull();
  });

  test("stops local edits at the shared identifier clock ceiling", () => {
    const document = new ReplicatedTextDocument({
      docId: "doc",
      revision: 1,
      atoms: [{ id: id(999_999_999, "viewer"), afterId: null, value: "x", deleted: false }],
    });
    expect(document.localChange("xy", "viewer", counter())).toEqual([]);
    expect(document.view().text).toBe("x");
  });

  test("uses the shared 64-byte UTF-8 atom limit", () => {
    const base = {
      opId: id(2, "viewer"),
      docId: "doc",
      kind: "insert",
    };
    expect(parseTextOperation({
      ...base,
      atoms: [{ id: id(1, "viewer"), afterId: null, value: "👨‍👩‍👧‍👦", deleted: false }],
    })).not.toBeNull();
    expect(parseTextOperation({
      ...base,
      atoms: [{ id: id(1, "viewer"), afterId: null, value: `e${"\u0301".repeat(32)}`, deleted: false }],
    })).toBeNull();
  });

  test("bounds replicated operation and unknown tombstone history", () => {
    const document = new ReplicatedTextDocument(snapshotFromText("doc", ""));
    for (let clock = 1; clock <= 32_768; clock += 1) {
      document.apply({
        opId: id(clock, "attacker"),
        docId: "doc",
        kind: "delete",
        atomIds: [id(clock, "unknown")],
      });
    }
    expect(document.apply({
      opId: id(1, "attacker"),
      docId: "doc",
      kind: "delete",
      atomIds: [id(1, "unknown")],
    })).toBe(true);
    document.apply({
      opId: id(32_769, "attacker"),
      docId: "doc",
      kind: "insert",
      atoms: [{ id: id(8_001, "unknown"), afterId: null, value: "x", deleted: false }],
    });
    expect(document.view().text).toBe("x");
  });
});
