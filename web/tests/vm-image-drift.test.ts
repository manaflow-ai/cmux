import { describe, expect, test } from "bun:test";
import { devboxImageInputPaths, driftedInputs, pinProblems } from "../scripts/check-devbox-image-drift";

describe("devbox image drift", () => {
  test("every file the image is built from is an input", () => {
    const paths = devboxImageInputPaths();
    // The shell config is the case that motivated the check: it merged to main
    // and reached no machine, because nothing rebaked the snapshot.
    expect(paths).toContain("web/services/vms/images/devbox/cmux-bashrc");
    expect(paths).toContain("web/services/vms/images/devbox/Dockerfile");
    expect(paths).toContain("web/scripts/build-devbox-freestyle.ts");
    expect(paths).toContain("web/services/vms/images/devbox/desktop/cmux-desktop-boot");
    expect(new Set(paths).size).toBe(paths.length);
  });

  test("an input that changed since the bake is drift", () => {
    const baked = new Map([["a", "one"], ["b", "two"]]);
    const tree = new Map([["a", "one"], ["b", "two-changed"]]);
    expect(driftedInputs(baked, tree)).toEqual(["b"]);
  });

  test("an input added or deleted since the bake is drift", () => {
    expect(driftedInputs(new Map([["a", null]]), new Map([["a", "new file"]]))).toEqual(["a"]);
    expect(driftedInputs(new Map([["a", "was there"]]), new Map([["a", null]]))).toEqual(["a"]);
  });

  test("an unchanged tree is not drift", () => {
    const inputs = new Map([["a", "one"], ["b", "two"]]);
    expect(driftedInputs(inputs, new Map(inputs))).toEqual([]);
  });
});

describe("devbox image pin", () => {
  const landed = () => true;

  test("one bake feeds one size ladder", () => {
    // The shape a hand-resolved manifest conflict takes: valid JSON, one
    // default per size, and sm running a different image from md.
    const problems = pinProblems(
      [
        { version: "base-sm", kind: "base", repoCommit: "aaaaaaaaaa" },
        { version: "base-md", kind: "base", repoCommit: "bbbbbbbbbb" },
      ],
      landed,
    );
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("mixes bakes");
  });

  test("kinds may sit on different bakes", () => {
    // Base and desktop are promoted separately by design.
    expect(
      pinProblems(
        [
          { version: "base-sm", kind: "base", repoCommit: "aaaaaaaaaa" },
          { version: "desktop-sm", kind: "desktop", repoCommit: "bbbbbbbbbb" },
        ],
        landed,
      ),
    ).toEqual([]);
  });

  test("a default baked off main is rejected", () => {
    const problems = pinProblems(
      [{ version: "base-sm", kind: "base", repoCommit: "cccccccccc" }],
      () => false,
    );
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("not in this history");
  });

  test("a commit this clone cannot see is not called a branch bake", () => {
    // A shallow checkout must report nothing rather than a false accusation.
    expect(pinProblems([{ version: "base-sm", kind: "base", repoCommit: "dddddddddd" }], () => null)).toEqual([]);
  });
});
