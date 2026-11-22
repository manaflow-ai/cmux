import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../model";
import { toolImages } from "../toolImages";
import { ToolRow } from "../conversation/ToolRow";
import { Markdown } from "../conversation/Markdown";
import { isRemoteMedia, mediaKind } from "./ReplyMedia";

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

describe("video an agent links on the web", () => {
  test("a GitHub attachment or an https media file is web media; a page is not", () => {
    expect(isRemoteMedia("https://github.com/user-attachments/assets/2f0c0b4e-1d2a-4c4e-9d55-0a1b2c3d4e5f")).toBe(true);
    expect(isRemoteMedia("https://artifacts.example.dev/run/812/login-flow.mp4?sig=abc")).toBe(true);
    expect(isRemoteMedia("https://example.com/docs/page")).toBe(false);
    expect(isRemoteMedia("http://artifacts.example.dev/run/812/login-flow.mp4")).toBe(false);
  });

  test("a link alone on its line, or an image of it, shows a load placeholder with its site", () => {
    const alone = renderToStaticMarkup(
      <Markdown>
        {"Recording:\n\nhttps://github.com/user-attachments/assets/2f0c0b4e-1d2a-4c4e-9d55-0a1b2c3d4e5f\n"}
      </Markdown>,
    );
    expect(alone).toContain('class="cv-media is-video is-remote"');
    expect(alone).toContain("github.com");
    const image = renderToStaticMarkup(
      <Markdown>{"![run 812](https://artifacts.example.dev/run/812/login-flow.mp4)\n"}</Markdown>,
    );
    expect(image).toContain('class="cv-media is-video is-remote"');
    expect(image).toContain("artifacts.example.dev");
    // A link inside a sentence stays a link.
    expect(
      renderToStaticMarkup(
        <Markdown>{"See https://artifacts.example.dev/run/812/login-flow.mp4 for the run.\n"}</Markdown>,
      ),
    ).not.toContain("cv-media");
  });
});
