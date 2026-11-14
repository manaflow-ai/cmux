import { expect, test } from "bun:test";
import type { Translate } from "../i18n";
import { sentUIPickSegments } from "../conversation/sentUIPickModel";
import { isUIPick, parseUIPick, pickSnippet, UI_PICK_COLLAPSE, UI_PICK_LABEL, uiPickRows } from "./uiPickModel";

const REPORT = [
  "cmux NEXT app-owned webview selection",
  "Component: span",
  "Source: unavailable",
  "Selector: .cv-li__text",
  "Text: the Cloud version-check and Cloud Desktop fixes;",
  "Computed styles: [:]",
  'DOM: <span class="cv-li__text">the Cloud version-check and Cloud Desktop fixes;</span>',
].join("\n");

const t = ((key: string, values?: Record<string, string>) =>
  key === "composer.uiPick.kind" ? "UI element" : `“${values?.text ?? ""}”`) as Translate;

test("a pick is known by its id or by its report's first line", () => {
  expect(isUIPick({ id: "ui-pointer-1", text: "anything" })).toBe(true);
  expect(isUIPick({ id: "file-1", text: REPORT })).toBe(true);
  expect(isUIPick({ id: "file-1", text: "notes\ncmux NEXT app-owned webview selection" })).toBe(false);
});

test("the report's fields parse; unavailable reads as unset", () => {
  expect(parseUIPick(REPORT)).toEqual({
    component: "span",
    selector: ".cv-li__text",
    text: "the Cloud version-check and Cloud Desktop fixes;",
  });
  expect(parseUIPick("Selector: span")).toBeUndefined();
});

test("the snippet ends at a word, never through one", () => {
  expect(pickSnippet("the Cloud version-check and Cloud Desktop fixes;")).toBe("the Cloud version-check and…");
  expect(pickSnippet("short")).toBe("short");
  expect(pickSnippet("x".repeat(40))).toBe(`${"x".repeat(28)}…`);
});

test("the label is the element and its snippet over the kind and selector; a report that does not parse falls back", () => {
  expect(UI_PICK_LABEL).toBe("element-snippet");
  expect(UI_PICK_COLLAPSE).toBe("footer");
  const rows = uiPickRows(t, "UI: span", REPORT);
  expect(rows.title.map((part) => part.text)).toEqual(["span", "“the Cloud version-check and…”"]);
  expect(rows.caption.map((part) => part.text)).toEqual(["UI element", ".cv-li__text"]);
  const fallback = uiPickRows(t, "UI: button", "garbled");
  expect(fallback.title.map((part) => part.text)).toEqual(["UI: button"]);
  expect(fallback.caption.map((part) => part.text)).toEqual(["UI element"]);
});

test("a sent prompt splits around each pick's fenced block, the rest kept", () => {
  const sent = `Why?\n\nUI: span\n\`\`\`\n${REPORT}\n\`\`\`\n\nnotes.md\n\`\`\`md\n# Title\n\`\`\``;
  expect(sentUIPickSegments(sent)).toEqual([
    { kind: "text", text: "Why?" },
    { kind: "pick", name: "UI: span", text: REPORT },
    { kind: "text", text: "notes.md\n```md\n# Title\n```" },
  ]);
  expect(sentUIPickSegments("plain prompt")).toBeUndefined();
});
