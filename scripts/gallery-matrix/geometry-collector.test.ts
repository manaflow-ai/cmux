import { expect, test } from "bun:test";
import { chromium } from "playwright";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { collectGeometry, parseSelectorMap, parseSelections } from "./geometry-collector";
import { parseArtifact } from "./geometry";

const fleetTest = process.env.CMUX_GALLERY_IN_VM === "1" ? test : test.skip;
fleetTest("collector captures every header and nearest row, excluding transparent controls", async () => {
  const dir = await mkdtemp(join(process.cwd(), "geometry-collector-"));
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 400, height: 400 }, deviceScaleFactor: 1 });
    await page.setContent(`<style>button{width:24px;height:24px}.row{height:28px}.hidden{opacity:0}</style>
      <header><button><span>Copy</span></button><button>×</button></header>
      <header><button>Copy</button><button>×</button></header>
      <div class="row"><span class="spinner">◌</span><button class="hidden">×</button></div>
      <section><div class="row"><button>×</button></div></section>`);
    await page.screenshot({ path: join(dir, "fixture.png"), fullPage: true });
    const path = await collectGeometry(page, [
      { group: "actions", selector: "header button", containerSelector: "header", containerGroup: "headers" },
      { group: "text", selector: "header:first-of-type button", containerSelector: "header", containerGroup: "headers", measurement: "text-range" },
      { group: "indicators", selector: ".row .spinner", containerSelector: ".row", containerGroup: "rows", part: "spinner" },
      { group: "indicators", selector: ".row button", containerSelector: ".row", containerGroup: "rows", part: "control" },
    ], { schemaVersion: 1, revision: { sha: "a".repeat(40), source: "browser fixture" }, capture: { caseId: "fixture", engine: "chromium", theme: "light", viewport: { width: 400, height: 400 }, deviceScaleFactor: 1, screenshot: "fixture.png", screenshotSha256: "", coordinateSpace: "css-px" } }, dir);
    const artifact = parseArtifact(JSON.parse(await readFile(join(dir, path), "utf8")));
    const actions = artifact.elements.filter((element) => element.group === "actions");
    expect(actions.map((element) => element.containerId)).toEqual(["headers:0", "headers:0", "headers:1", "headers:1"]);
    const text = artifact.elements.filter((element) => element.group === "text");
    expect(text).toHaveLength(2);
    expect(text.every((element) => element.rectSource === "text-range" && element.style?.baseline === undefined)).toBe(true);
    const indicators = artifact.elements.filter((element) => element.group === "indicators");
    expect(indicators.map((element) => [element.part, element.containerId])).toEqual([["spinner", "rows:0"], ["control", "rows:1"]]);
    expect(new Set(artifact.elements.map((element) => element.id)).size).toBe(artifact.elements.length);
  } finally {
    await browser.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("collector rejects ambiguous container/child groups before creating evidence", async () => {
  const page = {} as Parameters<typeof collectGeometry>[0];
  const identity = {} as Parameters<typeof collectGeometry>[2];
  await expect(collectGeometry(page, [{ group: "rows", selector: "button", containerSelector: ".row", containerGroup: "rows" }], identity, ".")).rejects.toThrow("must be distinct");
  await expect(collectGeometry(page, [{ group: "parts", selector: "button", containerSelector: ".row", containerGroup: "rows" }, { group: "rows", selector: "section" }], identity, ".")).rejects.toThrow("must be distinct");
});

test("selector JSON rejects unknown measurements and keys instead of measuring element boxes", async () => {
  const page = {} as Parameters<typeof collectGeometry>[0];
  const identity = {} as Parameters<typeof collectGeometry>[2];
  // A typo must never fall back to the element box while recording a bogus rectSource.
  await expect(collectGeometry(page, JSON.parse('[{"group":"labels","selector":"button","measurement":"text_range"}]'), identity, ".")).rejects.toThrow("measurement must be one of element, text-range");
  expect(() => parseSelections([{ group: "labels", selector: "button", measurment: "text-range" }])).toThrow('unknown selection key "measurment"');
  expect(() => parseSelections([{ group: "labels", selector: "button", secondary: "yes" }])).toThrow("secondary must be a boolean");
  expect(() => parseSelections([{ group: "labels", selector: "" }])).toThrow("selector must be a non-empty string");
  expect(() => parseSelections([{ group: "labels", selector: "button", containerSelector: ".row" }])).toThrow("must be paired");
  expect(() => parseSelectorMap({ fixture: [{ group: "labels", selector: "button", measurement: "range" }] }, "selectors.json")).toThrow("selectors.json.fixture[0]: measurement");
  expect(parseSelections([{ group: "labels", selector: "button", measurement: "text-range" }])).toEqual([{ group: "labels", selector: "button", measurement: "text-range" }]);
});
