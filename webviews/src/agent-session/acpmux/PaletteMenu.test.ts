import { expect, test } from "bun:test";
import { filterPaletteSections, type PaletteSection } from "./PaletteMenu";

const sections: PaletteSection[] = [
  {
    title: "Tools",
    choices: [{ id: "browser", name: "Browser", description: "Open a web tab", keywords: ["internet"] }],
  },
  {
    title: "Sessions",
    choices: [{ id: "recent", name: "Recent conversations", description: "Find chats", keywords: ["lanes"] }],
  },
];

test("palette search includes descriptions and keywords while keeping sections", () => {
  expect(filterPaletteSections(sections, "internet").map((section) => section.title)).toEqual(["Tools"]);
  expect(filterPaletteSections(sections, "lanes")[0]?.choices[0]?.name).toBe("Recent conversations");
  expect(filterPaletteSections(sections, "missing")).toEqual([]);
});
