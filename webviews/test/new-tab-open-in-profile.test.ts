// Lawrence 2026-11-05: "for new tab page, if i type a URL i want to be able to open it in certain
// profile (aka open in profile and enumerate all profiles, make it easily searchable too) as well as
// open url in a completely new profile". A typed address lists Open in Profile… (a searchable list of
// every browser profile) and Open in New Profile under its own row; the list matches names by prefix,
// word start, substring and in-order letters, and ends with a new profile named after the search.
import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, omnibarContext, type OmnibarContext } from "../src/agent-session/acpmux/omnibar";
import { profileRows, screenRows, type ScreenRow } from "../src/agent-session/acpmux/newtab/screenModel";

const ask = { harness: "claude", agent: "Claude Code" };
const profiles: NonNullable<OmnibarContext["profiles"]> = [
  { id: "default", name: "Default" },
  { id: "p-work", name: "Work", color: "blue" },
  { id: "p-austin", name: "Austin Test" },
  { id: "p-personal", name: "Personal" },
];
const context = (fields: Partial<OmnibarContext>) => ({ omnibar: { ...EMPTY_OMNIBAR, ...fields }, ask });
const types = (rows: ScreenRow[]) => rows.map((row) => row.type);

test("a typed address offers Open in Profile… and Open in New Profile right under its row", () => {
  const rows = screenRows("github.com/manaflow-ai", context({ profiles }));
  expect(types(rows).slice(0, 3)).toEqual(["open", "inProfile", "newProfile"]);
  expect(rows[1]).toEqual({ type: "inProfile", url: "https://github.com/manaflow-ai", text: "github.com/manaflow-ai" });
  expect(rows[2]).toEqual({ type: "newProfile", url: "https://github.com/manaflow-ai" });
});

test("with one profile there is nothing to pick: only Open in New Profile", () => {
  const rows = screenRows("example.com", context({ profiles: [{ id: "default", name: "Default" }] }));
  expect(types(rows)).toContain("newProfile");
  expect(types(rows)).not.toContain("inProfile");
});

test("a prompt, a search or a host without profiles lists no profile rows", () => {
  expect(types(screenRows("why is the sky blue", context({ profiles })))).not.toContain("inProfile");
  expect(types(screenRows("why is the sky blue", context({ profiles })))).not.toContain("newProfile");
  const without = types(screenRows("example.com", context({})));
  expect(without).not.toContain("inProfile");
  expect(without).not.toContain("newProfile");
});

test("the empty search lists every profile, in order, then a new profile", () => {
  const rows = profileRows("", "https://example.com", profiles);
  expect(rows.map((row) => (row.type === "profile" ? row.id : row.type))).toEqual([
    "default",
    "p-work",
    "p-austin",
    "p-personal",
    "newProfile",
  ]);
  expect(rows.at(-1)).toEqual({ type: "newProfile", url: "https://example.com" });
});

test("the search matches a prefix, a word start, a substring and letters in order", () => {
  const ids = (query: string) =>
    profileRows(query, "https://example.com", profiles).flatMap((row) => (row.type === "profile" ? [row.id] : []));
  expect(ids("wo")).toEqual(["p-work"]);
  expect(ids("test")).toEqual(["p-austin"]);
  expect(ids("ers")).toEqual(["p-personal"]);
  expect(ids("pnl")).toEqual(["p-personal"]);
  // A prefix ranks above a letters-in-order match.
  expect(ids("p")[0]).toBe("p-personal");
});

test("a search no profile is named offers a new profile with that name", () => {
  const rows = profileRows("Client X", "https://example.com", profiles);
  expect(rows.at(-1)).toEqual({ type: "newProfile", url: "https://example.com", name: "Client X" });
  // A search that names a profile exactly offers no second profile of that name.
  const exact = profileRows("work", "https://example.com", profiles);
  expect(exact.at(-1)).toEqual({ type: "newProfile", url: "https://example.com" });
  expect(exact[0]).toMatchObject({ type: "profile", id: "p-work", name: "Work" });
});

test("the handshake's profiles are read, dropping entries without an id or a name", () => {
  const read = omnibarContext({
    profiles: [{ id: "default", name: "Default" }, { id: "p-work", name: "Work", color: "blue" }, { id: "x" }, 4],
  });
  expect(read?.profiles).toEqual([
    { id: "default", name: "Default" },
    { id: "p-work", name: "Work", color: "blue" },
  ]);
  expect(omnibarContext({})?.profiles).toBeUndefined();
});
