import { describe, expect, test } from "bun:test";
import { DEFAULT_BROWSE, readBrowse, writeBrowse } from "../src/gallery/shell/browseModel";

describe("gallery browse URL state", () => {
  test("reads the shareable contact-sheet controls", () => {
    expect(
      readBrowse(
        new URLSearchParams("browse-filter=transcript&browse-kind=motion&browse-mode=variants&browse-cycle=1"),
      ),
    ).toEqual({ filter: "transcript", kind: "motion", mode: "variants", cycle: true, page: 1, picks: {} });
  });

  test("writes only non-default controls so a browse link stays short", () => {
    const params = writeBrowse({
      filter: " transcript ",
      kind: "motion",
      mode: "variants",
      cycle: true,
      page: 1,
      picks: { "z entry": "last state", "a/entry": "first=state" },
    });
    expect(params.toString()).toBe(
      "browse-filter=transcript&browse-kind=motion&browse-mode=variants&browse-cycle=1&browse-pick=a%252Fentry%3Dfirst%253Dstate&browse-pick=z%2520entry%3Dlast%2520state",
    );
    expect(readBrowse(params)).toEqual({
      filter: "transcript",
      kind: "motion",
      mode: "variants",
      cycle: true,
      page: 1,
      picks: { "z entry": "last state", "a/entry": "first=state" },
    });
  });

  test("ignores invalid controls and removes stale browse keys", () => {
    const params = new URLSearchParams("browse-filter=old&browse-kind=bad&browse-mode=bad&browse-cycle=1&keep=yes");
    const state = readBrowse(new URLSearchParams("browse-kind=bad&browse-mode=bad&browse-cycle=0"));
    expect(state).toEqual(DEFAULT_BROWSE);
    writeBrowse(DEFAULT_BROWSE, params);
    expect(params.toString()).toBe("keep=yes");
  });

  test("reads repeated picks deterministically and ignores malformed values", () => {
    const params = new URLSearchParams("browse-pick=b%252Fentry%3Done&browse-pick=bad%25ZZ");
    expect(readBrowse(params).picks).toEqual({ "b/entry": "one" });
  });

  test("round-trips the preview page so large contact sheets are shareable", () => {
    const params = new URLSearchParams("browse-page=3");
    expect(readBrowse(params).page).toBe(3);
    const written = writeBrowse({ ...DEFAULT_BROWSE, page: 3 });
    expect(written.get("browse-page")).toBe("3");
  });
});
