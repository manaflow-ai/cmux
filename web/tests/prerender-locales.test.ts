import { describe, expect, test } from "bun:test";
import { prerenderLocales } from "../i18n/prerender";
import { locales } from "../i18n/routing";

describe("prerenderLocales", () => {
  test("builds every locale when unset", () => {
    expect(prerenderLocales(undefined)).toEqual(locales);
    expect(prerenderLocales(" , ")).toEqual(locales);
  });

  test("limits the build to the requested locales in routing order", () => {
    expect(prerenderLocales("en")).toEqual(["en"]);
    expect(prerenderLocales(" ko, ja ")).toEqual(["en", "ja", "ko"]);
  });

  test("rejects unknown locales instead of silently building fewer pages", () => {
    expect(() => prerenderLocales("en,xx")).toThrow(/unknown locales: xx/);
  });
});
