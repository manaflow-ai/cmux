// motionTokens.ts: a motion token is read through getComputedStyle once per page and theme, so a send's
// commit forces no style recalc; a change of the root's inline tokens or of the attributes over the node
// reads it again at once, and an observed change (a sheet) on the next read.
import { expect, test } from "bun:test";
import { motionToken } from "./motionTokens";

function fixture() {
  let reads = 0;
  let value = "123ms";
  let notify: (() => void) | undefined;
  const attributes: Record<string, string> = {};
  const root = { getAttribute: (name: string) => attributes[name] ?? null };
  const view = {
    getComputedStyle: () => ({
      getPropertyValue: () => {
        reads += 1;
        return ` ${value} `;
      },
    }),
    MutationObserver: class {
      constructor(callback: () => void) {
        notify = callback;
      }
      observe() {}
    },
    setTimeout: () => 0,
    clearTimeout: () => {},
  };
  const doc = { documentElement: root, head: {}, defaultView: view };
  let minimal = false;
  const node = {
    ownerDocument: doc,
    isConnected: true,
    closest: (selector: string) => (minimal && selector.includes("minimal") ? {} : null),
  } as unknown as Element;
  return {
    node,
    reads: () => reads,
    set: (next: string) => (value = next),
    setRootStyle: (style: string) => (attributes.style = style),
    setMinimal: (on: boolean) => (minimal = on),
    mutate: () => notify?.(),
  };
}

test("a token is read once, then kept", () => {
  const page = fixture();
  expect(motionToken(page.node, "--agent-motion-send")).toBe("123ms");
  expect(motionToken(page.node, "--agent-motion-send")).toBe("123ms");
  expect(motionToken(page.node, "--agent-motion-send")).toBe("123ms");
  expect(page.reads()).toBe(1);
});

test("the root's inline tokens changing reads it again in the same task", () => {
  const page = fixture();
  motionToken(page.node, "--agent-motion-send");
  page.set("0ms");
  page.setRootStyle("--agent-motion-send: 0ms");
  expect(motionToken(page.node, "--agent-motion-send")).toBe("0ms");
  expect(page.reads()).toBe(2);
});

test("a chat's minimal motion over the node reads it again", () => {
  const page = fixture();
  motionToken(page.node, "--agent-motion-send");
  page.set("0ms");
  page.setMinimal(true);
  expect(motionToken(page.node, "--agent-motion-send")).toBe("0ms");
});

test("an observed change (a sheet, a root attribute) reads it again", () => {
  const page = fixture();
  motionToken(page.node, "--agent-motion-move");
  page.set("90ms");
  page.mutate();
  expect(motionToken(page.node, "--agent-motion-move")).toBe("90ms");
  expect(page.reads()).toBe(2);
});
