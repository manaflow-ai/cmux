import { describe, expect, test } from "bun:test";
import { dashboardBasepath } from "../dashboard-app/lib/basepath";
import { localeHomeHref, localeHref } from "../dashboard-app/lib/locale-href";
import { parseFlatSearch, stringifyFlatSearch } from "../dashboard-app/lib/search";

describe("flat search params", () => {
  test("parse keeps every value a string", () => {
    expect(parseFlatSearch("?q=123&team=007&flag=true&empty=")).toEqual({
      q: "123",
      team: "007",
      flag: "true",
      empty: "",
    });
    expect(parseFlatSearch("")).toEqual({});
  });

  test("a repeated key keeps the last value", () => {
    expect(parseFlatSearch("?team=a&team=b")).toEqual({ team: "b" });
  });

  test("stringify drops empty values and never JSON-quotes", () => {
    expect(stringifyFlatSearch({ q: "123", team: undefined, a: null, b: "" })).toBe("?q=123");
    expect(stringifyFlatSearch({ n: 5, ok: true })).toBe("?n=5&ok=true");
    expect(stringifyFlatSearch({})).toBe("");
  });

  test("round-trips reserved characters", () => {
    const search = { q: "a b&c=d/é", team: "t#1" };
    expect(parseFlatSearch(stringifyFlatSearch(search))).toEqual(search);
  });
});

describe("dashboardBasepath", () => {
  test.each([
    ["/dashboard", ""],
    ["/dashboard/billing", ""],
    ["/ja/dashboard/settings", "/ja"],
    ["/ja", "/ja"],
    ["/en/dashboard", ""],
    ["/xx/dashboard", ""],
    ["/", ""],
    ["", ""],
  ])("%p -> %p", (pathname, basepath) => {
    expect(dashboardBasepath(pathname)).toBe(basepath);
  });
});

describe("localeHref", () => {
  test("the default locale has no prefix", () => {
    expect(localeHref("en", "/pricing")).toBe("/pricing");
    expect(localeHref("en", "pricing")).toBe("/pricing");
    expect(localeHomeHref("en")).toBe("/");
  });

  test("other locales are prefixed, and home has no trailing slash", () => {
    expect(localeHref("ja", "/pricing")).toBe("/ja/pricing");
    expect(localeHomeHref("ja")).toBe("/ja");
  });
});
