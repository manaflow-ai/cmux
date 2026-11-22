import { describe, expect, test } from "bun:test";
import { filterExceptions, filterPasskeys, filterPasswords, groupBySite, siteInitial } from "./model";
import { sampleData } from "./mockProvider";

const data = sampleData();
const rows = data.passwords.default!;

describe("passwords model", () => {
  test("search matches every token over site, username and url", () => {
    expect(filterPasswords(rows, "github octo-work").map((r) => r.id)).toEqual(["p2"]);
    expect(filterPasswords(rows, "EXAMPLE.ORG").map((r) => r.id)).toEqual(["p3"]);
    expect(filterPasswords(rows, "  ").length).toBe(rows.length);
    expect(filterPasskeys(data.passkeys.default!, "sample person").length).toBe(1);
    expect(filterExceptions(data.exceptions.default!, "nothing").length).toBe(0);
  });

  test("site sort groups by site name and rows by username", () => {
    const groups = groupBySite(rows, "site");
    expect(groups.map((g) => g.site)).toEqual(["example.org", "github.com", "news.example.com"]);
    expect(groups[1]!.rows.map((r) => r.username)).toEqual(["octo-work", "octo@example.com"]);
  });

  test("recent and most used sorts put the best site first", () => {
    expect(groupBySite(rows, "mostUsed")[0]!.site).toBe("github.com");
    expect(groupBySite(rows, "mostUsed")[0]!.rows[0]!.id).toBe("p1");
    const recent = groupBySite(rows, "recent");
    expect(recent[0]!.site).toBe("github.com");
    expect(recent.at(-1)!.site).toBe("example.org");
  });

  test("site initials skip www and punctuation", () => {
    expect(siteInitial("www.github.com")).toBe("G");
    expect(siteInitial("_x.example")).toBe("X");
    expect(siteInitial("")).toBe("?");
  });
});
