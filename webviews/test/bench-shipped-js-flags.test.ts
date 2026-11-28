// bench/browsers.ts starts every bench's renderers with the V8 flags cmux's Chromium ships (SHIPPED_JS_FLAGS, from
// CEFSwitches.youngGeneration). Chromium reads only the last `--js-flags`, so they must join a bench's own one.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { SHIPPED_JS_FLAGS, withShippedJsFlags } from "../bench/browsers";

const jsFlags = (args: string[] | undefined) => (args ?? []).filter((arg) => arg.startsWith("--js-flags="));

describe("withShippedJsFlags", () => {
  test("a launch with no args gets the shipped flags", () => {
    expect(withShippedJsFlags(undefined).args).toEqual(["--js-flags=--min-semi-space-size=32"]);
    expect(withShippedJsFlags({ headless: true })).toEqual({
      headless: true,
      args: ["--js-flags=--min-semi-space-size=32"],
    });
  });

  test("a bench's own --js-flags keeps its flags and gains the shipped ones, in one argument", () => {
    const out = withShippedJsFlags({ args: ["--process-per-site", "--js-flags=--expose-gc"] });
    expect(out.args).toEqual(["--process-per-site", "--js-flags=--expose-gc --min-semi-space-size=32"]);
    expect(jsFlags(out.args)).toHaveLength(1);
  });

  test("two --js-flags arguments become one", () => {
    const out = withShippedJsFlags({ args: ["--js-flags=--expose-gc", "--js-flags=--trace-gc"] });
    expect(out.args).toEqual(["--js-flags=--expose-gc --trace-gc --min-semi-space-size=32"]);
  });

  test("a bench that sets its own young generation keeps its value", () => {
    const out = withShippedJsFlags({ args: ["--js-flags=--min-semi-space-size=8"] });
    expect(out.args).toEqual(["--js-flags=--min-semi-space-size=8"]);
  });

  test("the shipped flags are the app's CEF switch", () => {
    const swift = fs.readFileSync(
      path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSwitches.swift"),
      "utf8",
    );
    const shipped = /static let youngGeneration = "js-flags=([^"]*)"/.exec(swift)?.[1];
    expect(shipped?.split(/\s+/)).toEqual(SHIPPED_JS_FLAGS);
  });
});
