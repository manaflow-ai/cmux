import { describe, expect, test } from "bun:test";
import { createCodeMountNotifier } from "./codeSurface";

describe("code surface mount", () => {
  test("starts the native sidecar once when the launcher mounts", () => {
    const messages: unknown[] = [];
    const notify = createCodeMountNotifier((message) => messages.push(message));
    notify();
    notify();
    notify();

    expect(messages).toEqual([{ type: "mount" }]);
  });

  test("inlines the classic launcher script for local WebKit pages", async () => {
    const htmlURL = new URL(
      "../../../Resources/markdown-viewer/webviews-app/code.html",
      import.meta.url,
    );
    const html = await Bun.file(htmlURL).text();

    expect(html).toContain("window.webkit?.messageHandlers?.cmuxCode?.postMessage");
    expect(html).not.toContain('src="./code-launcher.js"');
    expect(html).not.toContain('type="module"');
  });
});
