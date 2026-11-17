import { afterEach, describe, expect, test } from "bun:test";
import { setNativeHost } from "../native";
import type { Artifact } from "./artifactPreview";
import { openBeside, opensBeside } from "./writtenArtifacts";

const page: Artifact = { kind: "html", lang: "html", code: "<!doctype html>", path: "/work/report.html" };

afterEach(() => setNativeHost(undefined));

describe("written HTML: Open beside", () => {
  test("only an HTML write with an absolute path opens beside the chat", () => {
    expect(opensBeside(page)).toBe(true);
    expect(opensBeside({ ...page, path: "report.html" })).toBe(false);
    expect(opensBeside({ ...page, path: undefined })).toBe(false);
    expect(opensBeside({ ...page, kind: "svg", path: "/work/drawing.svg" })).toBe(false);
  });

  test("asks the host for the file in a tab, and keeps the in-chat panel when it refuses", async () => {
    const calls: unknown[] = [];
    const shown: Artifact[] = [];
    setNativeHost(async (method, params) => {
      calls.push([method, params]);
      return null;
    });
    await openBeside(page, (artifact) => shown.push(artifact));
    expect(calls).toEqual([["file.open", { path: "/work/report.html", where: "tab" }]]);
    expect(shown).toEqual([]);

    setNativeHost(() => Promise.reject(new Error("transport.path_invalid")));
    await openBeside(page, (artifact) => shown.push(artifact));
    expect(shown).toEqual([page]);
  });
});
