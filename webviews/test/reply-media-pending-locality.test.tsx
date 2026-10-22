// A chat's media while the host doesn't yet know whether the chat runs on this Mac (plans
// media-safety R0, leo-workspace#874): between a handshake that names a session and that
// session's attach reply, the host answers `image.load`, `media.load` and `link.inspect` with
// `{pending: true}`. The page treats that as "wait", not as a failure: no unavailable card, no
// fallback text, no repeated asks. When the host sends the `locality` event, the page asks again,
// and a local chat then shows its images and plays its videos.
import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const IMAGE = "data:image/png;base64,iVBORw0KGgo=";
const MEDIA = "cmux-agent://pane/__media/token-1";
const POLICY = { outsideRoots: "confirm", remoteImages: "click" } as const;

/// A fake host whose answers follow `locality`, the way the native gate will: `unknown` answers
/// pending for every file read it gates (`gateInspect` adds `link.inspect`).
function fakeHost() {
  const host = {
    locality: "unknown" as "unknown" | "local" | "remote",
    gateInspect: false,
    calls: [] as Array<{ method: string; params: Record<string, unknown> }>,
    count(method: string, match?: (params: Record<string, unknown>) => boolean) {
      return host.calls.filter((call) => call.method === method && (!match || match(call.params))).length;
    },
    async answer(method: string, params: Record<string, unknown>): Promise<unknown> {
      host.calls.push({ method, params });
      const paths = (params.paths as string[] | undefined) ?? [];
      if (method === "link.inspect") {
        if (paths.length && host.gateInspect && host.locality === "unknown") return { pending: true, policy: POLICY };
        const place = host.locality === "remote" ? "missing" : "root";
        return { paths: Object.fromEntries(paths.map((path) => [path, { place, folder: false }])), policy: POLICY };
      }
      if (method !== "image.load" && method !== "media.load") return undefined;
      if (host.locality === "unknown") return { pending: true };
      if (host.locality === "remote") return { remote: true };
      return { src: method === "image.load" ? IMAGE : MEDIA };
    },
  };
  return host;
}

async function setup() {
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { ToolImages } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const host = fakeHost();
  resetLinkStore();
  setChipHost((method, params) => host.answer(method, params));
  const container = dom.window.document.createElement("div");
  dom.window.document.body.append(container);
  const root = createRoot(container);
  const settle = async () => {
    for (let i = 0; i < 4; i++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  };
  return {
    host,
    container,
    settle,
    async render(markdown: string, tools: string[] = []) {
      await act(async () =>
        root.render(
          createElement(
            "div",
            null,
            createElement(Markdown, null, markdown),
            tools.length ? createElement(ToolImages, { sources: tools }) : null,
          ),
        ),
      );
      await settle();
    },
    /// The host's `locality` event, as the shared page host delivers it.
    async locality(value: unknown) {
      await act(async () => applyHostEvent({ kind: "locality", value }));
      await settle();
    },
    async unmount() {
      await act(async () => root.unmount());
      container.remove();
      setChipHost(undefined);
      resetLinkStore();
    },
  };
}

describe("media while the chat's locality is pending", () => {
  beforeEach(async () => {
    const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
    applyHostEvent({ kind: "locality", value: { locality: "unknown" } });
  });

  test("a pending image, video and tool image wait, then load once the chat is local", async () => {
    const page = await setup();
    await page.render("![Shot](/tmp/delayed/shot.png)\n\n![Clip](/tmp/delayed/clip.mp4)", ["/tmp/delayed/tool.png"]);
    const { container, host } = page;

    // Waiting: the reply's thumbnail keeps its waiting frame and the video its name; no card says
    // the file is unavailable and nothing fell back to text.
    expect(container.querySelectorAll(".cv-thumb.is-waiting").length).toBe(1);
    expect(container.querySelector(".cv-image-file")).toBeNull();
    expect(container.querySelector(".cv-media.is-video .cv-media__name")?.textContent).toBe("Clip");
    expect(container.querySelector("img")).toBeNull();
    expect(container.querySelector("video")).toBeNull();
    // Each source asked once: a pending answer is not retried until the host says something new.
    const imageLoads = host.count("image.load");
    expect(imageLoads).toBe(2);
    expect(host.count("media.load")).toBe(1);
    await page.settle();
    expect(host.count("image.load")).toBe(imageLoads);
    expect(host.count("media.load")).toBe(1);

    host.locality = "local";
    await page.locality({ locality: "local" });

    expect(host.count("image.load")).toBe(4);
    expect(host.count("media.load")).toBe(2);
    expect(container.querySelector(".cv-thumb img.cv-thumb__img")?.getAttribute("src")).toBe(IMAGE);
    expect(container.querySelector(".cv-tool-images img")?.getAttribute("src")).toBe(IMAGE);
    expect(container.querySelector("video")?.getAttribute("src")).toBe(MEDIA);
    expect(container.querySelector(".cv-image-file")).toBeNull();
    await page.unmount();
  });

  test("paths the host would not inspect yet stay chips and are asked again", async () => {
    const page = await setup();
    page.host.gateInspect = true;
    await page.render("See `/tmp/delayed-inspect/notes.md` and ![Shot](/tmp/delayed-inspect/shot.png)");
    const { container, host } = page;
    const inspected = (path: string) =>
      host.count("link.inspect", (params) => (params.paths as string[]).includes(path));

    expect(inspected("/tmp/delayed-inspect/notes.md")).toBe(1);
    expect(container.querySelector('.cv-chip.is-path[data-path="/tmp/delayed-inspect/notes.md"]')).not.toBeNull();
    // The image waits for its path's answer: it is not asked for, and not a failure.
    expect(host.count("image.load")).toBe(0);
    expect(container.querySelector(".cv-image-file")).toBeNull();

    host.locality = "local";
    await page.locality({ locality: "local" });

    expect(inspected("/tmp/delayed-inspect/notes.md")).toBe(2);
    expect(inspected("/tmp/delayed-inspect/shot.png")).toBe(2);
    expect(host.count("image.load")).toBe(1);
    expect(container.querySelector(`img[src="${IMAGE}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a pending answer that arrives after the locality event is asked again", async () => {
    const page = await setup();
    const { host } = page;
    // The host answers the first load only after it has sent the event.
    let release: () => void = () => {};
    const answer = host.answer;
    host.answer = async (method, params) => {
      if (method !== "image.load" || host.count("image.load") > 0) return answer(method, params);
      const reply = answer(method, params);
      await new Promise<void>((resolve) => (release = resolve));
      return reply;
    };
    await page.render("![Late](/tmp/delayed-race/late.png)");
    expect(host.count("image.load")).toBe(1);
    host.locality = "local";
    await page.locality({ locality: "local" });
    release();
    await page.settle();

    expect(host.count("image.load")).toBe(2);
    expect(page.container.querySelector(`img[src="${IMAGE}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a malformed or repeated locality event asks nothing again", async () => {
    const page = await setup();
    await page.render("![Shot](/tmp/delayed-noise/shot.png)");
    const { host } = page;
    expect(host.count("image.load")).toBe(1);
    for (const value of [undefined, "local", { locality: "nearby" }, { locality: 1 }, { locality: "unknown" }])
      await page.locality(value);
    expect(host.count("image.load")).toBe(1);
    expect(page.container.querySelector(".cv-thumb.is-waiting")).not.toBeNull();
    await page.unmount();
  });

  test("a file read on this Mac stops drawing, and leaves the cache, once the chat is no longer local", async () => {
    const page = await setup();
    const { container, host } = page;
    const markdown = "![Shot](/tmp/delayed-move/shot.png)\n\n![Clip](/tmp/delayed-move/clip.mp4)";
    host.locality = "local";
    await page.locality({ locality: "local" });
    await page.render(markdown);
    expect(host.count("image.load")).toBe(1);
    expect(container.querySelector(`img[src="${IMAGE}"]`)).not.toBeNull();
    expect(container.querySelector(`video[src="${MEDIA}"]`)).not.toBeNull();

    // Still mounted: the image and the video this Mac read are gone in the same render.
    host.locality = "remote";
    await page.locality({ locality: "remote", machine: "big-red" });
    expect(container.querySelector(`img[src="${IMAGE}"]`)).toBeNull();
    expect(container.querySelector("video")).toBeNull();

    // Drawn again: nothing comes from the cache, and the host's new answer decides.
    await page.render("");
    await page.render(markdown);
    expect(container.querySelector(`img[src="${IMAGE}"]`)).toBeNull();
    expect(container.querySelector("video")).toBeNull();
    expect(host.count("image.load")).toBe(1);
    expect(host.count("media.load")).toBe(1);
    const inspected = host.count("link.inspect", (params) =>
      (params.paths as string[]).includes("/tmp/delayed-move/shot.png"),
    );
    expect(inspected).toBe(2);
    await page.unmount();
  });
});
