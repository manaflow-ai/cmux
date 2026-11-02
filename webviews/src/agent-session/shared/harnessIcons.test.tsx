// User 12922: a custom harness draws the icon acpmux resolved for it (`iconSpec` on each
// `_acpmux/harnesses` entry) wherever an AgentMark is given its id: the model picker's rail, New
// Tab, Home and subagent rows. Its own icon wins over the mark its id suggests; an SF Symbol draws
// its monogram (the pages' CSP allows only `data:` images); a malformed spec is ignored.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { normalizeCatalog } from "../acpmux/direct";
import { AgentMark, hasAgentMark } from "./AgentMark";
import {
  harnessIcon,
  harnessSymbolsSnapshot,
  loadHarnessSymbol,
  parseHarnessIconSpec,
  setHarnessSymbolHost,
} from "./harnessIcons";

const draw = (agent: string, fallback?: string) =>
  renderToStaticMarkup(<AgentMark agent={agent} size={16} {...(fallback ? { fallback } : {})} />);

test("a harness list's icons reach every AgentMark given the harness id", () => {
  const catalog = normalizeCatalog({
    harnesses: {
      fox: { iconSpec: { kind: "emoji", text: "🦊", source: "profile" } },
      "zeta-bot": { iconSpec: { kind: "monogram", text: "ZB", hue: 200, source: "default" } },
      "my-gem": { iconSpec: { kind: "brand", brand: "gemini", source: "command" } },
      "claude-sr2": { iconSpec: { kind: "emoji", text: "🐙", source: "profile" } },
      "claude-sr3": { iconSpec: { kind: "brand", brand: "claude", source: "id" } },
      hammer: { iconSpec: { kind: "symbol", name: "hammer.fill", text: "H", hue: 10, source: "profile" } },
      logo: { iconSpec: { kind: "image", mime: "image/png", data: "iVBORw==", source: "profile" } },
      bad: { iconSpec: { kind: "image", mime: "text/html", data: "PHNjcmlwdD4=", source: "profile" } },
    },
  });
  expect(catalog.find((entry) => entry.id === "fox")?.iconSpec).toEqual({
    kind: "emoji",
    text: "🦊",
    source: "profile",
  });
  expect(draw("fox")).toContain("🦊");
  expect(draw("zeta-bot")).toContain(">ZB<");
  expect(draw("zeta-bot")).toContain("hsl(200");
  // A detected brand draws that agent's mark.
  expect(draw("my-gem")).toContain('data-agent="gemini"');
  // The profile's own icon beats the mark its id suggests; a detected one does not.
  expect(draw("claude-sr2")).toContain("🐙");
  expect(draw("claude-sr3")).toContain('data-agent="claude"');
  expect(draw("hammer")).toContain(">H<");
  expect(draw("logo")).toContain('src="data:image/png;base64,iVBORw=="');
  // A spec no page may draw is dropped: the fallback shows.
  expect(harnessIcon("bad")).toBeUndefined();
  expect(draw("bad", "generic")).toBe("generic");
  expect(hasAgentMark("fox")).toBe(true);
  expect(hasAgentMark("bad")).toBe(false);
});

test("an iconSpec is only one of the shapes acpmux sends", () => {
  expect(parseHarnessIconSpec({ kind: "monogram", text: "AB", hue: 360, source: "default" })).toBeUndefined();
  expect(parseHarnessIconSpec({ kind: "glyph", name: "rm -rf", source: "profile" })).toBeUndefined();
  expect(parseHarnessIconSpec({ kind: "emoji", text: "", source: "profile" })).toBeUndefined();
  expect(parseHarnessIconSpec(null)).toBeUndefined();
  expect(parseHarnessIconSpec({ kind: "brand", brand: "goose", source: "?" })).toEqual({
    kind: "brand",
    brand: "goose",
    source: "default",
  });
});

test("replacing the native symbol host ignores stale replies and retains the new request", async () => {
  const name = "gearshape.fill";
  const oldPng = "data:image/png;base64,T0xE";
  const newPng = "data:image/png;base64,TkVX";
  let oldReply: (url: string | null) => void = () => {};
  let newReply: (url: string | null) => void = () => {};
  let newRequests = 0;
  const releaseOld = setHarnessSymbolHost(() => new Promise<string | null>((resolve) => (oldReply = resolve)));
  loadHarnessSymbol(name);
  const releaseNew = setHarnessSymbolHost(
    () =>
      new Promise<string | null>((resolve) => {
        newRequests++;
        newReply = resolve;
      }),
  );
  try {
    // Old and new hosts both had a request for this symbol in flight.
    // The old cleanup, and its late answer, must never disturb the newer owner.
    releaseOld();
    loadHarnessSymbol(name);
    oldReply(oldPng);
    await Promise.resolve();
    expect(harnessSymbolsSnapshot().has(name)).toBe(false);
    loadHarnessSymbol(name);
    expect(newRequests).toBe(1);
    newReply(newPng);
    await Promise.resolve();
    expect(harnessSymbolsSnapshot().get(name)).toBe(newPng);
  } finally {
    releaseNew();
  }
});
