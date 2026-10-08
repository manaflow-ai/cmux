import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../model";
import { toolImages } from "../toolImages";
import { ToolRow } from "../conversation/ToolRow";
import { mediaKind } from "./ReplyMedia";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const tool = (fields: Partial<Tool>): Tool => ({ id: "t", title: "Tool", status: "completed", ...fields });

describe("video and audio an agent writes or links", () => {
  test("a media file is video or audio by its extension", () => {
    expect(mediaKind("/repo/out/demo.mp4")).toBe("video");
    expect(mediaKind("/repo/out/demo.MOV")).toBe("video");
    expect(mediaKind("file:///repo/out/clip.webm")).toBe("video");
    expect(mediaKind("/repo/out/voice.m4a")).toBe("audio");
    expect(mediaKind("/repo/out/shot.png")).toBeUndefined();
    expect(mediaKind("/repo/out/demo.mp4.txt")).toBeUndefined();
  });

  test("a recording a tool saves joins the tool's media strip", () => {
    expect(toolImages(tool({ kind: "execute", output: "Recorded 12 s to /tmp/rec/login-flow.mp4\n" }))).toEqual([
      "/tmp/rec/login-flow.mp4",
    ]);
  });

  test("before the host answers, a video shows as its name in a media frame, not an image", () => {
    const item: AcpmuxActivity = {
      kind: "tool",
      text: "Record",
      tool: tool({ title: "Record", output: "saved /tmp/rec/login-flow.mp4" }),
    };
    const html = renderToStaticMarkup(createElement(ToolRow, { item }));
    expect(html).toContain('class="cv-media is-video"');
    expect(html).toContain("login-flow.mp4");
    expect(html).not.toContain("<img");
  });
});
