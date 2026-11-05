// Leo, 2026-11-03: "i can neither preview a vid in place nor have it pop up anymore :(". On the shared
// page host (`cmux-page://cmux.agent`) the host grants a video on the page's own origin, the only one
// its CSP plays media from (#34726); the page plays that URL and still refuses any other app URL.
import { afterEach, expect, test } from "bun:test";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { loadPlayableMedia } from "../src/agent-session/acpmux/chips/ReplyMedia";

afterEach(() => setChipHost(undefined));

function grants(src: string) {
  setChipHost(async (method) => (method === "media.load" ? { src } : null));
}

test("a video the page host grants on its own origin plays", async () => {
  const src = "cmux-page://cmux.agent/__media/0123456789abcdef.mov";
  grants(src);
  expect(await loadPlayableMedia("/Users/dev/Desktop/clip.mov")).toBe(src);
});

test("the pane's own host keeps its media URL", async () => {
  const src = "cmux-agent://pane/__media/0123456789abcdef.mov";
  grants(src);
  expect(await loadPlayableMedia("/Users/dev/Desktop/clip.mov")).toBe(src);
});

test("another page's origin or path is never played", async () => {
  for (const src of [
    "cmux-page://cmux.settings/__media/0123456789abcdef.mov",
    "cmux-page://cmux.agent/index.html",
    "cmux-page://cmux.agent/assets/__media/x.mov",
  ]) {
    grants(src);
    expect(await loadPlayableMedia("/Users/dev/Desktop/clip.mov")).toBeUndefined();
  }
});
