import { describe, expect, test } from "bun:test";
import { parseImportCards } from "./ImportCards";

const card = {
  id: "browser.chrome",
  kind: "browser",
  title: "Chrome",
  facts: "3 profiles",
  benefit: "Stay signed in.",
  state: "running",
  progress: 1.7,
  primary: { action: "start", title: "Import" },
  secondary: [{ action: "dismiss", title: "Not Now" }, { action: "Bad-Action", title: "x" }, { action: "more" }],
  dismissed: false,
};

describe("parseImportCards", () => {
  test("keeps a well-formed card, clamps progress and drops bad buttons", () => {
    const list = parseImportCards({ title: "Found", cards: [card] });
    expect(list?.cards).toHaveLength(1);
    expect(list?.cards[0]?.progress).toBe(1);
    expect(list?.cards[0]?.primary).toEqual({ action: "start", title: "Import" });
    expect(list?.cards[0]?.secondary).toEqual([{ action: "dismiss", title: "Not Now" }]);
  });

  test("drops cards without an id or title; an unknown state reads as ready", () => {
    const list = parseImportCards({
      title: "",
      cards: [
        { ...card, id: "" },
        { ...card, title: 3 },
        { ...card, id: "b", state: "weird" },
      ],
    });
    expect(list?.cards.map((c) => c.id)).toEqual(["b"]);
    expect(list?.cards[0]?.state).toBe("ready");
  });

  test("takes only PNG data URLs as icons", () => {
    const list = parseImportCards({
      cards: [
        { ...card, icon: "https://example.com/x.png" },
        { ...card, id: "b", icon: "data:image/png;base64,AAAA" },
      ],
    });
    expect(list?.cards[0]?.icon).toBeUndefined();
    expect(list?.cards[1]?.icon).toBe("data:image/png;base64,AAAA");
  });

  test("an empty list draws only when it has empty text", () => {
    expect(parseImportCards({ cards: [] })).toBeNull();
    expect(parseImportCards({ cards: [], empty: "Nothing here." })?.empty).toBe("Nothing here.");
    expect(parseImportCards(null)).toBeNull();
    expect(parseImportCards({ cards: "x" })).toBeNull();
  });
});
