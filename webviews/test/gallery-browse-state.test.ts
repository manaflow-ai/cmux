import { describe, expect, test } from "bun:test";
import { DEFAULT_BROWSE, readBrowse, writeBrowse } from "../src/gallery/shell/browseModel";

describe("gallery browse URL state", () => {
  test("reads the shareable contact-sheet controls", () => {
    expect(
      readBrowse(
        new URLSearchParams(
          "browse-filter=transcript&browse-kind=motion&browse-mode=variants&browse-cycle=1",
        ),
      ),
    ).toEqual({ filter: "transcript", kind: "motion", mode: "variants", cycle: true });
  });

  test("writes only non-default controls so a browse link stays short", () => {
    const params = writeBrowse({ filter: " transcript ", kind: "motion", mode: "variants", cycle: true });
    expect(params.toString()).toBe("browse-filter=transcript&browse-kind=motion&browse-mode=variants&browse-cycle=1");
    expect(readBrowse(params)).toEqual({ filter: "transcript", kind: "motion", mode: "variants", cycle: true });
  });

  test("ignores invalid controls and removes stale browse keys", () => {
    const params = new URLSearchParams("browse-filter=old&browse-kind=bad&browse-mode=bad&browse-cycle=1&keep=yes");
    const state = readBrowse(new URLSearchParams("browse-kind=bad&browse-mode=bad&browse-cycle=0"));
    expect(state).toEqual(DEFAULT_BROWSE);
    writeBrowse(DEFAULT_BROWSE, params);
    expect(params.toString()).toBe("keep=yes");
  });
});
