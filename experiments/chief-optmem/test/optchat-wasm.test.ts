import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vite-plus/test";
import { initSync, OptChat, sizeCheck } from "../src/optchat-wasm/optchat_wasm.js";

/** The JS side of the hosted placement: what the MemoryDO keeps in SQLite. */
class Store {
  messages: Array<{ kind: string; text: string }> = [];
  nodes = new Map<string, string>();
  message(i: number) {
    return this.messages[i]!;
  }
  node(l: number, i: number) {
    return this.nodes.get(`${l}:${i}`);
  }
}

type Work = { kind: "free"; l: number; i: number; text: string } | { kind: "model"; l: number; i: number };

/** Builds every node the pump asks for: free ones as given, model ones with a fixed summary. */
function drain(memory: OptChat, store: Store, summary: (l: number, i: number) => string) {
  for (;;) {
    const work = JSON.parse(memory.pump(store)) as Array<Work>;
    if (work.length === 0) return;
    for (const w of work) {
      const text = w.kind === "free" ? w.text : summary(w.l, w.i);
      store.nodes.set(`${w.l}:${w.i}`, text);
      if (w.kind === "model") memory.complete(w.l, w.i, text);
    }
  }
}

describe("optchat-core as WebAssembly (hosted placement)", () => {
  beforeAll(() => {
    initSync({ module: readFileSync(new URL("../src/optchat-wasm/optchat_wasm_bg.wasm", import.meta.url)) });
  });

  it("keeps short messages verbatim, folds, zooms and renders through a JS store", () => {
    const store = new Store();
    const memory = new OptChat(0);
    for (const [kind, text] of [
      ["user", "keep CSV and add JSON"],
      ["talk", "done"],
      ["tool", "x".repeat(2_000)],
      ["echo", "ok"],
    ] as const) {
      store.messages.push({ kind, text });
      expect(memory.append()).toBe(store.messages.length - 1);
    }
    drain(memory, store, (l, i) => `summary of ${l}:${i}`);
    expect(memory.settled()).toBe(true);
    expect(memory.zoom(store, 0, 1)).toBe("0+0|user: keep CSV and add JSON");
    expect(memory.zoom(store, 0, 2)).toBe("0+1|user: keep CSV and add JSON\n1+1|talk: done");
    expect(() => memory.zoom(store, 1, 2)).toThrow("No line 1+2.");
    const view = JSON.parse(memory.renderView(store)) as { text: string; marks: number[] };
    expect(view.text.startsWith("<chat>\n") && view.text.endsWith("</chat>")).toBe(true);
    expect(view.text).toContain("summary of 0:2");
  });

  it("reloads to the same view and builds compactor requests with the chosen prompt", () => {
    const store = new Store();
    const memory = new OptChat(4_000);
    for (let k = 0; k < 300; k++) {
      store.messages.push({ kind: k % 2 ? "talk" : "user", text: "w".repeat(k % 3 === 0 ? 40 : 900) });
      memory.append();
      drain(memory, store, (l, i) => `s${l}:${i} `.padEnd(200, "."));
    }
    const built = [...store.nodes].map(([key, text]) => {
      const [l, i] = key.split(":").map(Number);
      return [l, i, new TextEncoder().encode(text).length];
    });
    const reloaded = OptChat.load(memory.len(), JSON.stringify(built), 4_000);
    expect(reloaded.view()).toBe(memory.view());
    expect(memory.viewSize()).toBeLessThanOrEqual(4_000);

    store.messages.push({ kind: "echo", text: "z".repeat(3_000) });
    memory.append();
    const work = JSON.parse(memory.pump(store)) as Array<Work>;
    expect(work).toEqual([{ kind: "model", l: 0, i: 300 }]);
    const request = JSON.parse(memory.compactRequest(store, 0, 300, "cmux", "", "Chief")) as Record<string, string>;
    expect(request.system!.startsWith("You write the memory of Chief")).toBe(true);
    expect(request.system).toContain("Never copy a secret into a line");
    expect(request.step).toContain("Compress this message into one line, in at most 512 bytes:\necho: zzz");
  });

  it("runs the size loop", () => {
    expect(JSON.parse(sizeCheck(JSON.stringify(["  short  "])))).toEqual({ accept: "short" });
    expect(JSON.parse(sizeCheck(JSON.stringify(["a".repeat(600)]))).retry).toContain("That line is 600 bytes");
    expect(JSON.parse(sizeCheck(JSON.stringify([" "])))).toEqual({ fail: true });
  });
});
