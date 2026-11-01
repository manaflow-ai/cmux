// The Artifacts page's store over its host ops (`cmux.artifacts.*`, the mock host): the tree is read
// one folder per call and flattened to file paths, the first file opens at the tree's head, a reply
// for a file the person already left is dropped, nothing saved yet reads as empty, and a missing
// host says so.
import { expect, test } from "bun:test";
import { pageError, type PageClient, type PageHandler } from "../src/pages/shared/pageClient";
import { MockArtifactsProvider } from "../src/pages/artifacts/mockProvider";
import { ArtifactsStore, MAX_FOLDERS } from "../src/pages/artifacts/store";
import { ArtifactsOps, type ArtifactsTree } from "../src/pages/artifacts/types";

/** A host whose answers come from `answer`; every call is recorded. */
class Host implements PageClient {
  calls: { op: string; params: Record<string, unknown> }[] = [];
  constructor(private readonly answer: (op: string, params: Record<string, unknown>) => unknown) {}
  async call<R>(op: string, params: unknown): Promise<R> {
    const p = (params ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params: p });
    return (await this.answer(op, p)) as R;
  }
  async subscribe(): Promise<() => void> {
    return () => {};
  }
  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

test("the tree is read one folder per call and flattened to sorted file paths", async () => {
  const mock = new MockArtifactsProvider();
  const host = new Host((op, params) => mock.call(op, params));
  const store = new ArtifactsStore(host);
  await store.start();
  const snapshot = store.getSnapshot();
  expect(snapshot.status).toBe("ready");
  expect(snapshot.paths).toEqual([
    "artifacts/release-dashboard/data.json",
    "artifacts/release-dashboard/index.html",
    "memory/claude/artifacts-pane.md",
    "notes/launch.md",
  ]);
  const folders = host.calls
    .filter((call) => call.op === ArtifactsOps.tree)
    .map((call) => String(call.params.path ?? ""));
  expect(folders.sort((a, b) => a.localeCompare(b))).toEqual([
    "",
    "artifacts",
    "artifacts/release-dashboard",
    "memory",
    "memory/claude",
    "notes",
  ]);
});

test("the first file opens at the tree's head, and choosing another file reads it", async () => {
  const store = new ArtifactsStore(new MockArtifactsProvider());
  await store.start();
  expect(store.getSnapshot()).toMatchObject({
    selected: "artifacts/release-dashboard/data.json",
    fileLoading: false,
    file: { path: "artifacts/release-dashboard/data.json", contentType: "application/json" },
  });
  await store.select("memory/claude/artifacts-pane.md");
  const snapshot = store.getSnapshot();
  expect(snapshot.file?.content).toContain("History compares a revision with its parent");
  expect(snapshot.file?.commit).toBe(snapshot.headSha);
});

test("a reply for a file the person already left is dropped", async () => {
  let release: () => void = () => {};
  const slow = new Promise<void>((resolve) => (release = resolve));
  const mock = new MockArtifactsProvider();
  const host = new Host(async (op, params) => {
    if (op === ArtifactsOps.file && params.path === "notes/launch.md") await slow;
    return mock.call(op, params);
  });
  const store = new ArtifactsStore(host);
  await store.start();
  const leaving = store.select("notes/launch.md");
  await store.select("memory/claude/artifacts-pane.md");
  release();
  await leaving;
  const snapshot = store.getSnapshot();
  expect(snapshot.selected).toBe("memory/claude/artifacts-pane.md");
  expect(snapshot.file?.path).toBe("memory/claude/artifacts-pane.md");
});

test("a deep tree stops at the folder cap and says so", async () => {
  const host = new Host((_op, params) => {
    const path = String(params.path ?? "");
    const prefix = path ? `${path}/` : "";
    const tree: ArtifactsTree = {
      ref: "main",
      sha: "c".repeat(40),
      entries: [0, 1, 2].map((n) => ({ name: `d${n}`, path: `${prefix}d${n}`, type: "tree" as const })),
    };
    return tree;
  });
  const store = new ArtifactsStore(host);
  await store.start();
  expect(host.calls.length).toBeLessThanOrEqual(MAX_FOLDERS);
  expect(store.getSnapshot().truncated).toBe(true);
});

test("nothing saved yet reads as empty, a refusal as failed, a missing host as unavailable", async () => {
  const empty = new ArtifactsStore(new MockArtifactsProvider("empty"));
  await empty.start();
  expect(empty.getSnapshot().status).toBe("empty");

  const signedOut = new ArtifactsStore(
    new Host(() => {
      throw pageError("cmux.artifacts.signed_out", "Sign in to cmux to see your artifacts.", true);
    }),
  );
  await signedOut.start();
  expect(signedOut.getSnapshot()).toMatchObject({
    status: "failed",
    failure: { code: "cmux.artifacts.signed_out", message: "Sign in to cmux to see your artifacts." },
  });

  const none = new ArtifactsStore(null);
  await none.start();
  expect(none.getSnapshot().status).toBe("unavailable");
});

test("a refresh keeps the tree on screen and the chosen file open", async () => {
  const store = new ArtifactsStore(new MockArtifactsProvider());
  await store.start();
  await store.select("notes/launch.md");
  const seen: string[] = [];
  store.subscribe(() => seen.push(store.getSnapshot().status));
  await store.start();
  expect(seen).not.toContain("loading");
  expect(store.getSnapshot().selected).toBe("notes/launch.md");
});

test("a refresh after a new save reads the chosen file again, keeping it on screen meanwhile", async () => {
  const shas = ["1".repeat(40), "2".repeat(40)];
  let head = 0;
  const texts = ["first\n", "first\nsecond\n"];
  const host = new Host((op, params) => {
    const sha = shas[head]!;
    if (op === ArtifactsOps.tree) return { ref: "main", sha, entries: [{ name: "a.md", path: "a.md", type: "blob" }] };
    const at = params.ref ? shas.indexOf(String(params.ref)) : head;
    return { path: "a.md", size: 1, contentType: "text/markdown", commit: shas[at], content: texts[at] };
  });
  const store = new ArtifactsStore(host);
  await store.start();
  expect(store.getSnapshot().file?.content).toBe("first\n");
  head = 1;
  const seen: (string | undefined)[] = [];
  store.subscribe(() => seen.push(store.getSnapshot().file?.content));
  await store.start();
  expect(seen).not.toContain(undefined);
  const snapshot = store.getSnapshot();
  expect(snapshot.file?.content).toBe("first\nsecond\n");
  expect(snapshot.file?.commit).toBe(shas[1]);
});

test("a refresh with the head unchanged reads only the tree", async () => {
  const mock = new MockArtifactsProvider();
  const host = new Host((op, params) => mock.call(op, params));
  const store = new ArtifactsStore(host);
  await store.start();
  const before = host.calls.length;
  await store.start();
  expect(host.calls.slice(before).every((call) => call.op === ArtifactsOps.tree)).toBe(true);
});

test("folders and the chosen file are read at the root's commit", async () => {
  const mock = new MockArtifactsProvider();
  const host = new Host((op, params) => mock.call(op, params));
  const store = new ArtifactsStore(host);
  await store.start();
  const root = store.getSnapshot().headSha;
  const reads = host.calls.filter((call) => call.op === ArtifactsOps.tree && call.params.path);
  expect(reads.length).toBeGreaterThan(0);
  expect(reads.every((call) => call.params.ref === root)).toBe(true);
  const fileRead = host.calls.find((call) => call.op === ArtifactsOps.file);
  expect(fileRead?.params.ref).toBe(root);
});

test("a reload that failed is tried again on the next refresh, and by choosing the file again", async () => {
  const shas = ["1".repeat(40), "2".repeat(40)];
  let head = 0;
  let failing = false;
  const host = new Host((op, params) => {
    const sha = shas[head]!;
    if (op === ArtifactsOps.tree) return { ref: "main", sha, entries: [{ name: "a.md", path: "a.md", type: "blob" }] };
    if (failing) throw pageError("cmux.artifacts.unavailable", "Artifacts could not be reached.", true);
    return {
      path: "a.md",
      size: 1,
      contentType: "text/markdown",
      commit: params.ref ?? sha,
      content: `at ${String(params.ref)}`,
    };
  });
  const store = new ArtifactsStore(host);
  await store.start();
  head = 1;
  failing = true;
  await store.start();
  expect(store.getSnapshot().fileFailure?.code).toBe("cmux.artifacts.unavailable");
  failing = false;
  await store.select("a.md");
  expect(store.getSnapshot().file?.content).toBe(`at ${shas[1]}`);
  expect(store.getSnapshot().fileFailure).toBeUndefined();

  head = 0;
  failing = true;
  await store.start();
  failing = false;
  await store.start();
  expect(store.getSnapshot().file?.content).toBe(`at ${shas[0]}`);
});

test("folders under the root are read several at once", async () => {
  let inFlight = 0;
  let most = 0;
  // Each folder read waits until the next microtask turns after every read started in its batch.
  const host = new Host(async (_op, params) => {
    inFlight += 1;
    most = Math.max(most, inFlight);
    for (let turn = 0; turn < 8; turn++) await Promise.resolve();
    inFlight -= 1;
    const path = String(params.path ?? "");
    const entries = path
      ? [{ name: "f.md", path: `${path}/f.md`, type: "blob" as const }]
      : [0, 1, 2, 3, 4, 5].map((n) => ({ name: `d${n}`, path: `d${n}`, type: "tree" as const }));
    return { ref: "main", sha: "5".repeat(40), entries };
  });
  const store = new ArtifactsStore(host);
  await store.start();
  expect(store.getSnapshot().paths).toHaveLength(6);
  expect(most).toBeGreaterThan(1);
  expect(most).toBeLessThanOrEqual(4);
});
