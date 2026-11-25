import { expect, test } from "bun:test";
import { descriptionRestatesName, filterPaletteSections, type PaletteSection } from "./paletteMenuModel";

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

test("a description restates its title only when it adds no word of its own", () => {
  expect(descriptionRestatesName("New Browser Tab", "Open a browser tab")).toBe(true);
  expect(descriptionRestatesName("Search Tabs", "Find an open tab")).toBe(true);
  expect(descriptionRestatesName("Search Chats", "Find a recent conversation")).toBe(false);
  expect(descriptionRestatesName("New Terminal", "Open a terminal tab")).toBe(false);
  expect(descriptionRestatesName("Run App Command", "Choose an app command")).toBe(false);
  expect(descriptionRestatesName("Anything", undefined)).toBe(false);
  expect(descriptionRestatesName("Anything", "  ")).toBe(false);
});
