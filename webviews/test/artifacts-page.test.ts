// The Artifacts page's store over its host ops (`cmux.artifacts.*`, the mock host): the tree is read
// one folder per call and flattened to file paths, the first file opens with its history and the
// newest revision's change, a revision click compares it with its parent, a reply for a file the
// person already left is dropped, nothing saved yet reads as empty, and a missing host says so.
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

test("the first file opens with its history and the newest revision's change", async () => {
  const store = new ArtifactsStore(new MockArtifactsProvider());
  await store.start();
  await store.select("memory/claude/artifacts-pane.md");
  const snapshot = store.getSnapshot();
  expect(snapshot.file?.content).toContain("History compares a revision with its parent");
  expect(snapshot.history.map((commit) => commit.message)).toEqual([
    "Note how history compares revisions",
    "Save the artifacts pane notes",
  ]);
  expect(snapshot.selectedCommit).toBe(snapshot.history[0]!.sha);
  expect(snapshot.diff?.before).not.toContain("History compares");
  expect(snapshot.diff?.after).toContain("History compares");
});

test("a revision with no parent shows the whole file as added", async () => {
  const store = new ArtifactsStore(new MockArtifactsProvider());
  await store.start();
  await store.select("memory/claude/artifacts-pane.md");
  const first = store.getSnapshot().history[1]!;
  await store.selectCommit(first);
  const { diff, selectedCommit } = store.getSnapshot();
  expect(selectedCommit).toBe(first.sha);
  expect(diff?.sha).toBe(first.sha);
  expect(diff?.before).toBeUndefined();
  expect(diff?.after).not.toContain("History compares");
});

test("a parent where the file did not exist yet reads as added, not as a failure", async () => {
  const head = "a".repeat(40);
  const parent = "b".repeat(40);
  const host = new Host((op, params) => {
    if (op === ArtifactsOps.tree)
      return { ref: "main", sha: head, entries: [{ name: "a.md", path: "a.md", type: "blob" }] };
    if (op === ArtifactsOps.history)
      return {
        commits: [{ sha: head, parents: [parent], message: "Add a", authorName: "cmux", time: 0, trailers: {} }],
      };
    if (params.ref === parent) throw pageError("cmux.artifacts.not_found", "Nothing has been saved here yet.");
    return { path: "a.md", size: 2, contentType: "text/markdown", commit: head, content: "a\n" };
  });
  const store = new ArtifactsStore(host);
  await store.start();
  const snapshot = store.getSnapshot();
  expect(snapshot.fileFailure).toBeUndefined();
  expect(snapshot.diff).toEqual({ sha: head, before: undefined, after: "a\n" });
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
