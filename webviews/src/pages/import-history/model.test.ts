import { describe, expect, test } from "bun:test";
import { canImport, ImportHistoryStore, OPS, type ImportReport } from "./model";

const report = (added = 3, written?: number): ImportReport => ({
  plan: { total: 3, new: added, duplicate: 3 - added, secrets: 0 },
  est_cost_usd: 0.01,
  written,
});
type Call = { op: string; params: Record<string, unknown> };
function host(handle?: (call: Call) => unknown | Promise<unknown>) {
  const calls: Call[] = [];
  return {
    calls,
    call: async <R>(op: string, params: unknown): Promise<R> => {
      const call = { op, params: params as Record<string, unknown> };
      if (Object.hasOwn(call.params, "origin")) throw new Error("origin is set by the host");
      calls.push(call);
      if (handle) {
        const result = await handle(call);
        if (result !== undefined) return result as R;
      }
      switch (op) {
        case OPS.detect:
          return {
            sources: [
              { source: "claude-code", kind: "claude-code" },
              { source: "codex", kind: "codex" },
            ],
          } as R;
        case OPS.pickZip:
          return {
            source: `zip:/selected/${String(call.params.kind)}.zip`,
            name: "export.zip",
          } as R;
        case OPS.prepareText:
          return { source: `text:/private/${String(call.params.summaryOrigin)}.txt` } as R;
        case OPS.dryRun:
          return report() as R;
        case OPS.write:
          return report(3, 3) as R;
        default:
          return {} as R;
      }
    },
  };
}

describe("Bring your history", () => {
  test("detected local sources are prechecked", async () => {
    const client = host();
    const store = new ImportHistoryStore(client);
    await store.start();
    expect(client.calls).toEqual([{ op: OPS.detect, params: {} }]);
    expect(
      store
        .getSnapshot()
        .rows.filter((row) => row.selected)
        .map((row) => row.id),
    ).toEqual(["claude-code", "codex"]);
    expect(store.getSnapshot().rows.some((row) => row.id === "dot")).toBe(false);
    expect(canImport(store.getSnapshot())).toBe(true);
  });
  test("export discovery is opt-in after the passive mount scan", async () => {
    const client = host(({ op, params }) =>
      op === OPS.detect
        ? {
            sources: params.exports
              ? [{ source: "zip:/Downloads/chatgpt.zip", kind: "chatgpt-export" }]
              : [{ source: "codex", kind: "codex" }],
          }
        : undefined,
    );
    const store = new ImportHistoryStore(client);
    await store.start();
    await store.findExports();
    expect(client.calls).toEqual([
      { op: OPS.detect, params: {} },
      { op: OPS.detect, params: { exports: true } },
    ]);
    expect(store.getSnapshot().rows.find((row) => row.id === "chatgpt")?.detected).toBe(true);
  });
  test("recognized export archives are prechecked and retain their path", async () => {
    const client = host(({ op }) =>
      op === OPS.detect
        ? {
            sources: [
              {
                source: "zip:/Downloads/chatgpt.zip",
                kind: "chatgpt-export",
                path: "/Downloads/chatgpt.zip",
              },
            ],
          }
        : undefined,
    );
    const store = new ImportHistoryStore(client);
    await store.start();
    const row = store.getSnapshot().rows.find((candidate) => candidate.id === "chatgpt");
    expect(row?.selected).toBe(true);
    expect(row?.detected).toBe(true);
    expect(row?.source).toBe("zip:/Downloads/chatgpt.zip");
  });
  test("detected Dot archives use the saved Dot export label", async () => {
    const client = host(({ op }) =>
      op === OPS.detect ? { sources: [{ source: "zip:/Downloads/dot.zip", kind: "dots-export" }] } : undefined,
    );
    const store = new ImportHistoryStore(client);
    await store.start();
    const row = store.getSnapshot().rows.find((candidate) => candidate.id === "detected-0");
    expect(row?.title).toBe("Dot export (.zip)");
    expect(row?.selected).toBe(true);
  });
  test("detected archives can be replaced without adding another row", async () => {
    const client = host(({ op }) =>
      op === OPS.detect ? { sources: [{ source: "zip:/Downloads/dot.zip", kind: "dots-export" }] } : undefined,
    );
    const store = new ImportHistoryStore(client);
    await store.start();
    await store.pickZip("detected-0");
    const archives = store.getSnapshot().rows.filter((row) => row.source?.startsWith("zip:"));
    expect(archives).toHaveLength(1);
    expect(archives[0]).toMatchObject({
      id: "detected-0",
      source: "zip:/selected/dot.zip",
      detected: false,
      selected: true,
    });
  });
  test("retry replaces old detections and preserves manually picked archives", async () => {
    let sources = [
      { source: "zip:/Downloads/dot.zip", kind: "dots-export" },
      { source: "zip:/Downloads/chatgpt.zip", kind: "chatgpt-export" },
    ];
    const client = host(({ op }) => (op === OPS.detect ? { sources } : undefined));
    const store = new ImportHistoryStore(client);
    await store.start();
    await store.retryDetection();
    expect(store.getSnapshot().rows.filter((row) => row.id.startsWith("detected-"))).toHaveLength(1);
    await store.pickZip("claude");
    await store.pickZip("chatgpt");
    await store.retryDetection();
    expect(store.getSnapshot().rows.find((row) => row.id === "chatgpt")?.source).toBe("zip:/selected/chatgpt.zip");
    sources = [];
    await store.retryDetection();
    expect(store.getSnapshot().rows.some((row) => row.id.startsWith("detected-"))).toBe(false);
    expect(store.getSnapshot().rows.find((row) => row.id === "codex")?.source).toBeUndefined();
    expect(store.getSnapshot().rows.find((row) => row.id === "claude")?.source).toBe("zip:/selected/claude.zip");
  });
  test("app hints require pasted text and prepare a text source before import", async () => {
    const client = host(({ op }) => (op === OPS.detect ? { sources: [{ source: "muse", kind: "muse" }] } : undefined));
    const store = new ImportHistoryStore(client);
    await store.start();
    expect(canImport(store.getSnapshot())).toBe(false);
    store.paste("muse", "Prefers tea.");
    await store.run();
    expect(client.calls.find((call) => call.op === OPS.prepareText)?.params).toEqual({
      summaryOrigin: "muse",
      text: "Prefers tea.",
    });
    expect(client.calls.find((call) => call.op === OPS.write)?.params.source).toBe("text:/private/muse.txt");
  });
  test("Dot exists only after a person picks its saved export; cancel changes nothing", async () => {
    let cancelled = true;
    const client = host(({ op }) => (op === OPS.pickZip && cancelled ? null : undefined));
    const store = new ImportHistoryStore(client);
    await store.start();
    await store.pickZip("dot");
    expect(store.getSnapshot().rows.some((row) => row.id === "dot")).toBe(false);
    cancelled = false;
    await store.pickZip("dot");
    expect(store.getSnapshot().rows.find((row) => row.id === "dot")?.source).toBe("zip:/selected/dot.zip");
    expect(store.getSnapshot().rows.find((row) => row.id === "dot")?.selected).toBe(true);
  });
  test("picking and editing sources during detection cannot start a write before its reply", async () => {
    let finishDetection!: (result: { sources: { source: string }[] }) => void;
    const detected = new Promise<{ sources: { source: string }[] }>((resolve) => {
      finishDetection = resolve;
    });
    const client = host(({ op }) => (op === OPS.detect ? detected : undefined));
    const store = new ImportHistoryStore(client);
    const starting = store.start();
    await store.pickZip("dot");
    expect(canImport(store.getSnapshot())).toBe(false);
    store.paste("muse", "My favourite editor is Helix.");
    expect(canImport(store.getSnapshot())).toBe(false);
    store.select("codex", false);
    expect(store.getSnapshot().phase).toBe("detecting");
    expect(canImport(store.getSnapshot())).toBe(false);
    await store.run();
    expect(client.calls.map(({ op }) => op)).toEqual([OPS.detect, OPS.pickZip]);

    finishDetection({ sources: [] });
    await starting;
    expect(store.getSnapshot().phase).toBe("ready");
    expect(canImport(store.getSnapshot())).toBe(true);
    expect(store.getSnapshot().rows.find((row) => row.id === "dot")?.selected).toBe(true);
    await store.run();
    expect(store.getSnapshot().phase).toBe("done");
    expect(client.calls.filter(({ op }) => op === OPS.begin)).toHaveLength(1);
    expect(client.calls.filter(({ op }) => op === OPS.write).map(({ params }) => params.source)).toContain(
      "zip:/selected/dot.zip",
    );
  });
  test("all plans precede any write, unchecked sources stay out, one batch owns Undo", async () => {
    const client = host();
    const store = new ImportHistoryStore(client);
    await store.start();
    store.select("codex", false);
    await store.pickZip("chatgpt");
    await store.run();
    const imports = client.calls.filter(({ op }) =>
      [OPS.begin, OPS.dryRun, OPS.write].includes(op as typeof OPS.begin),
    );
    expect(imports.map(({ op }) => op)).toEqual([OPS.begin, OPS.dryRun, OPS.dryRun, OPS.write, OPS.write]);
    expect(imports.filter(({ op }) => op === OPS.write).map(({ params }) => params.source)).toEqual([
      "claude-code",
      "zip:/selected/chatgpt.zip",
    ]);
    expect(new Set(imports.map(({ params }) => params.batch)).size).toBe(1);
    expect(store.getSnapshot().phase).toBe("done");
    expect(store.getSnapshot().canUndo).toBe(true);
    await store.undo();
    expect(client.calls.at(-1)).toEqual({
      op: OPS.undo,
      params: { batch: imports[0]?.params.batch },
    });
    expect(store.getSnapshot().canUndo).toBe(false);
  });
  test("pasting prepares no file until Import and carries the assistant origin through plan and write", async () => {
    const client = host();
    const store = new ImportHistoryStore(client);
    await store.start();
    store.select("claude-code", false);
    store.select("codex", false);
    store.paste("muse", "I work on a garden.");
    expect(client.calls.some(({ op }) => op === OPS.prepareText)).toBe(false);
    await store.run();
    const ops = client.calls.slice(1);
    expect(ops.map(({ op }) => op)).toEqual([OPS.begin, OPS.prepareText, OPS.dryRun, OPS.write]);
    expect(ops[1]?.params).toEqual({ summaryOrigin: "muse", text: "I work on a garden." });
    expect(ops[2]?.params.summaryOrigin).toBe("muse");
    expect(ops[3]?.params.summaryOrigin).toBe("muse");
  });
  test("zero-new and unsafe-cost plans never write", async () => {
    const client = host(({ op, params }) =>
      op === OPS.dryRun ? (params.source === "codex" ? { ...report(), est_cost_usd: 21 } : report(0)) : undefined,
    );
    const store = new ImportHistoryStore(client);
    await store.start();
    await store.run();
    expect(client.calls.some(({ op }) => op === OPS.write)).toBe(false);
    expect(store.getSnapshot().rows.find((row) => row.id === "codex")?.phase).toBe("error");
    expect(store.getSnapshot().rows.find((row) => row.id === "claude-code")?.phase).toBe("done");
    expect(store.getSnapshot().canUndo).toBe(false);
  });
  test("a failed source preserves successful imports and their Undo", async () => {
    const client = host(({ op, params }) => {
      if (op === OPS.write && params.source === "codex") throw new Error("cannot read source");
    });
    const store = new ImportHistoryStore(client);
    await store.start();
    await store.run();
    expect(store.getSnapshot().phase).toBe("error");
    expect(store.getSnapshot().canUndo).toBe(true);
    expect(store.getSnapshot().rows.find((row) => row.id === "claude-code")?.phase).toBe("done");
    expect(store.getSnapshot().rows.find((row) => row.id === "codex")?.error).toBe("cannot read source");
  });
  test("retry and a zero-new rerun retain the batch and Undo for earlier successful sources", async () => {
    let failCodex = true;
    const imported = new Set<string>();
    const client = host(({ op, params }) => {
      const source = String(params.source);
      if (op === OPS.dryRun) return report(imported.has(source) ? 0 : 3);
      if (op === OPS.write) {
        if (source === "codex" && failCodex) throw new Error("source unavailable");
        imported.add(source);
        return report(3, 3);
      }
    });
    const store = new ImportHistoryStore(client);
    await store.start();
    await store.run();
    const originalBatch = store.getSnapshot().batch;
    expect(store.getSnapshot().canUndo).toBe(true);
    failCodex = false;
    await store.run();
    expect(store.getSnapshot().phase).toBe("done");
    expect(store.getSnapshot().batch).toBe(originalBatch);
    await store.run();
    expect(store.getSnapshot().canUndo).toBe(true);
    expect(client.calls.filter(({ op }) => op === OPS.begin).map(({ params }) => params.batch)).toEqual([
      originalBatch,
      originalBatch,
      originalBatch,
    ]);
    await store.undo();
    expect(client.calls.at(-1)).toEqual({ op: OPS.undo, params: { batch: originalBatch } });
  });
  test("double submit never duplicates writes and Skip remains callable during import", async () => {
    let resume!: () => void;
    const held = new Promise<void>((resolve) => {
      resume = resolve;
    });
    const client = host(async ({ op }) => {
      if (op === OPS.begin) await held;
    });
    const store = new ImportHistoryStore(client);
    await store.start();
    const first = store.run();
    await store.run();
    store.select("codex", false);
    expect(store.getSnapshot().rows.find((row) => row.id === "codex")?.selected).toBe(true);
    await store.finish(false);
    expect(client.calls.filter(({ op }) => op === OPS.begin)).toHaveLength(1);
    expect(client.calls.some(({ op, params }) => op === OPS.finish && params.completed === false)).toBe(true);
    resume();
    await first;
    expect(client.calls.filter(({ op }) => op === OPS.write)).toHaveLength(0);
  });
  test.each(["begin", "plan"] as const)(
    "a failed %s retries the same granted batch before any successful write",
    async (failure) => {
      let attempt = 0;
      let granted: unknown;
      const client = host(({ op, params }) => {
        if (op === OPS.begin) {
          if (granted && granted !== params.batch) throw new Error("cannot replace existing batch");
          granted = params.batch;
          attempt += 1;
          if (attempt === 1 && failure === "begin") throw new Error("begin reply lost");
        }
        if (op === OPS.dryRun && attempt === 1 && failure === "plan") throw new Error("source unavailable");
        if (op === OPS.undo) granted = undefined;
      });
      const store = new ImportHistoryStore(client);
      await store.start();
      await store.run();
      const originalBatch = store.getSnapshot().batch;
      expect(store.getSnapshot().phase).toBe("error");
      expect(store.getSnapshot().canUndo).toBe(false);
      expect(client.calls.some(({ op }) => op === OPS.write)).toBe(false);
      await store.run();
      expect(store.getSnapshot().phase).toBe("done");
      expect(store.getSnapshot().batch).toBe(originalBatch);
      expect(store.getSnapshot().canUndo).toBe(true);
      expect(client.calls.filter(({ op }) => op === OPS.begin).map(({ params }) => params.batch)).toEqual([
        originalBatch,
        originalBatch,
      ]);
      await store.undo();
      expect(store.getSnapshot().batch).toBeUndefined();
      await store.run();
      expect(store.getSnapshot().batch).not.toBe(originalBatch);
      expect(store.getSnapshot().phase).toBe("done");
    },
  );
});
