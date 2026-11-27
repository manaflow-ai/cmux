import { afterEach, describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { setExperimentSwitches } from "../../../experiments/switches";
import { setNativeHost } from "../native";
import { type Artifact, ArtifactContext } from "./artifactPreview";
import { openBeside, opensBeside, WrittenArtifactButtons } from "./writtenArtifacts";

const page: Artifact = { kind: "html", lang: "html", code: "<!doctype html>", path: "/work/report.html" };
const write = {
  kind: "edit",
  status: "completed",
  title: "Write",
  inputSummary: JSON.stringify({ file_path: "/work/report.html", content: "<!doctype html><title>r</title>" }),
} as never;

afterEach(() => {
  setNativeHost(undefined);
  setExperimentSwitches({});
});

const card = () =>
  renderToStaticMarkup(
    <ArtifactContext.Provider value={() => {}}>
      <WrittenArtifactButtons tools={[write]} />
    </ArtifactContext.Provider>,
  );

describe("written HTML: Open beside chat (experiments.writtenHTMLOpenBeside)", () => {
  test("only an HTML write with an absolute path opens beside the chat", () => {
    expect(opensBeside(page)).toBe(true);
    expect(opensBeside({ ...page, path: "report.html" })).toBe(false);
    expect(opensBeside({ ...page, path: undefined })).toBe(false);
    expect(opensBeside({ ...page, kind: "svg", path: "/work/drawing.svg" })).toBe(false);
  });

  test("the card draws no Open beside while the switch is off (the default), and draws it once on", () => {
    setNativeHost(async () => null);
    const off = card();
    expect(off).toContain("report.html");
    expect(off).not.toContain("Open beside chat");
    setExperimentSwitches({ writtenHTMLOpenBeside: true });
    expect(card()).toContain("Open beside chat");
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
