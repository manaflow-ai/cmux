// A chat's media while the host doesn't yet know whether the chat runs on this Mac (plans
// media-safety R0, leo-workspace#874): between a handshake that names a session and that
// session's attach reply, the host answers `image.load`, `media.load` and `link.inspect` with
// `{pending: true}`. The page treats that as "wait", not as a failure: no unavailable card, no
// fallback text, no repeated asks. When the host sends the `locality` event, the page asks again,
// and a local chat then shows its images and plays its videos.
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
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
    /// The next `method` call is answered `reply`, but only on `release()`: an answer that comes
    /// back after the locality changed.
    late: undefined as undefined | { method: string; reply: unknown; held?: boolean; release?: () => void },
    calls: [] as Array<{ method: string; params: Record<string, unknown> }>,
    count(method: string, match?: (params: Record<string, unknown>) => boolean) {
      return host.calls.filter((call) => call.method === method && (!match || match(call.params))).length;
    },
    async answer(method: string, params: Record<string, unknown>): Promise<unknown> {
      host.calls.push({ method, params });
      const late = host.late;
      if (late && late.method === method && !late.held) {
        late.held = true;
        return new Promise((resolve) => (late.release = () => resolve(late.reply)));
      }
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

/// Pages a test left mounted (it failed before its unmount): unmounted after it, so they don't ask
/// the next test's host.
const mounted = new Set<() => Promise<void>>();
afterEach(async () => {
  for (const unmount of mounted) await unmount();
});

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
  const unmount = async () => {
    mounted.delete(unmount);
    await act(async () => root.unmount());
    container.remove();
    setChipHost(undefined);
    resetLinkStore();
  };
  mounted.add(unmount);
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
    async click(selector: string) {
      const button = container.querySelector<HTMLButtonElement>(selector);
      expect(button).not.toBeNull();
      await act(async () => button!.click());
      await settle();
    },
    async release() {
      await act(async () => host.late?.release?.());
      await settle();
    },
    /// The host's `locality` event, as the shared page host delivers it.
    async locality(value: unknown) {
      await act(async () => applyHostEvent({ kind: "locality", value }));
      await settle();
    },
    unmount,
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

    // Waiting: the reply's and the tool's images in their frames, the video as its name.
    expect(container.querySelectorAll(".cv-thumb.is-waiting").length).toBe(2);
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
    page.host.late = { method: "image.load", reply: { pending: true } };
    await page.render("![Late](/tmp/delayed-race/late.png)");
    page.host.locality = "local";
    await page.locality({ locality: "local" });
    await page.release();
    expect(page.host.count("image.load")).toBe(2);
    expect(page.container.querySelector(`img[src="${IMAGE}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a malformed or repeated locality event asks nothing again", async () => {
    const page = await setup();
    await page.render("![Shot](/tmp/delayed-noise/shot.png)");
    const { host } = page;
    expect(host.count("image.load")).toBe(1);
    for (const value of [
      undefined,
      "local",
      { locality: "nearby" },
      { locality: 1 },
      { locality: "local", machine: 123 },
      { locality: "unknown" },
    ])
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

describe("review fixes (#24346)", () => {
  const LATE = "data:image/png;base64,TEFURQ==";
  const LATE_MEDIA = "cmux-agent://pane/__media/late";
  // Each test has its own web addresses: a clicked image and a granted video stay for the page's life.
  const webImage = (name: string) => `https://images.example.com/${name}.png`;
  const webVideo = (name: string) => `https://videos.example.com/${name}.mp4`;
  beforeEach(async () => {
    const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
    applyHostEvent({ kind: "locality", value: { locality: "unknown" } });
  });

  test("a clicked web image answered after the locality changed is dropped and asked again", async () => {
    const page = await setup();
    page.host.late = { method: "image.load", reply: { src: LATE } };
    await page.render(`![Web](${webImage("t0")})`);
    await page.click(".cv-image-placeholder__load");
    page.host.locality = "local";
    await page.locality({ locality: "local" });
    await page.release();
    expect(page.host.count("image.load")).toBe(2);
    expect(page.container.querySelector(`img[src="${LATE}"]`)).toBeNull();
    expect(page.container.querySelector(`img[src="${IMAGE}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a web video answered after the locality changed is dropped and asked again", async () => {
    const page = await setup();
    page.host.late = { method: "media.load", reply: { src: LATE_MEDIA } };
    await page.render(`![Clip](${webVideo("t1")})`);
    await page.click(".cv-media.is-remote .cv-image-placeholder__load");
    page.host.locality = "local";
    await page.locality({ locality: "local" });
    await page.release();
    expect(page.host.count("media.load")).toBe(2);
    expect(page.container.querySelector(`video[src="${LATE_MEDIA}"]`)).toBeNull();
    expect(page.container.querySelector(`video[src="${MEDIA}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a refusal answered after the locality changed is asked again, not a failure", async () => {
    const page = await setup();
    page.host.late = { method: "image.load", reply: {} };
    await page.render("![Late](/tmp/stale-refusal/late.png)");
    page.host.locality = "local";
    await page.locality({ locality: "local" });
    await page.release();
    expect(page.host.count("image.load")).toBe(2);
    expect(page.container.querySelector(".cv-image-file")).toBeNull();
    expect(page.container.querySelector(`img[src="${IMAGE}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a link.inspect answer from before the locality changed keeps no paths, sites or policy", async () => {
    const page = await setup();
    const path = "/tmp/stale-inspect/notes.md";
    page.host.late = {
      method: "link.inspect",
      reply: {
        paths: { [path]: { place: "missing", folder: false } },
        sites: { "https://example.com/page": { title: "Stale" } },
        policy: { outsideRoots: "text", remoteImages: "never" },
      },
    };
    await page.render(`See \`${path}\` and https://example.com/page ![Web](${webImage("t3")})`);
    page.host.locality = "local";
    await page.locality({ locality: "local" });
    await page.release();
    const asked = (key: string, value: string) =>
      page.host.count("link.inspect", (params) => ((params[key] as string[]) ?? []).includes(value));
    expect(asked("paths", path)).toBe(2);
    expect(asked("urls", "https://example.com/page")).toBe(2);
    // The stale "never" policy would have drawn the web image as its link only.
    expect(page.container.querySelector(".cv-image-placeholder__load")).not.toBeNull();
    expect(page.container.querySelector(`.cv-chip.is-path[data-path="${path}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a load the reader started and the host answered pending is asked again on the event", async () => {
    const page = await setup();
    await page.render(`![Web](${webImage("t4")})\n\n![Clip](${webVideo("t4")})`);
    await page.click(".cv-thumb .cv-image-placeholder__load");
    await page.click(".cv-media.is-remote .cv-image-placeholder__load");
    expect([page.host.count("image.load"), page.host.count("media.load")]).toEqual([1, 1]);
    page.host.locality = "local";
    await page.locality({ locality: "local" });
    expect([page.host.count("image.load"), page.host.count("media.load")]).toEqual([2, 2]);
    expect(page.container.querySelector(`img[src="${IMAGE}"]`)).not.toBeNull();
    expect(page.container.querySelector(`video[src="${MEDIA}"]`)).not.toBeNull();
    await page.unmount();
  });

  test("a pending image or video that scrolls away and back waits without asking again", async () => {
    const page = await setup();
    const markdown = "![Shot](/tmp/remount/shot.png)\n\n![Clip](/tmp/remount/clip.mp4)";
    await page.render(markdown);
    expect([page.host.count("image.load"), page.host.count("media.load")]).toEqual([1, 1]);
    await page.render("");
    await page.render(markdown);
    expect([page.host.count("image.load"), page.host.count("media.load")]).toEqual([1, 1]);
    expect(page.container.querySelector(".cv-thumb.is-waiting")).not.toBeNull();
    page.host.locality = "local";
    await page.locality({ locality: "local" });
    expect([page.host.count("image.load"), page.host.count("media.load")]).toEqual([2, 2]);
    await page.unmount();
  });

  test("a tool's image waits in its frame while pending, never as its file name", async () => {
    for (const gateInspect of [false, true]) {
      const page = await setup();
      page.host.gateInspect = gateInspect;
      await page.render("", [`/tmp/tool-wait-${gateInspect}/shot.png`]);
      const strip = page.container.querySelector(".cv-tool-images")!;
      expect(strip.querySelector(".cv-thumb.is-waiting")).not.toBeNull();
      expect(strip.querySelector(".cv-chip-plain")).toBeNull();
      await page.unmount();
    }
  });

  test("the image viewer closes when the chat leaves this Mac", async () => {
    const { act, createElement } = await import("react");
    const { createRoot } = await import("react-dom/client");
    const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
    const { useImageView } = await import("../src/agent-session/acpmux/conversation/useImageView");
    let view: ReturnType<typeof useImageView> | undefined;
    const rows = () => [];
    function Probe() {
      view = useImageView(rows, "session-1");
      return null;
    }
    const root = createRoot(dom.window.document.createElement("div"));
    await act(async () => root.render(createElement(Probe)));
    const open = () => act(async () => view!.openImage(IMAGE, "Shot", "/tmp/viewer/shot.png"));
    const event = (locality: string) => act(async () => applyHostEvent({ kind: "locality", value: { locality } }));
    await open();
    await event("local");
    expect(view!.imageView?.images[0]?.src).toBe(IMAGE);
    await open();
    await event("remote");
    expect(view!.imageView).toBeUndefined();
    await act(async () => root.unmount());
  });

  test.each([
    ["image", "image.load", "shot.png", ".cv-thumb.is-waiting", `img[src="${IMAGE}"]`],
    ["video", "media.load", "clip.mp4", ".cv-media.is-video .cv-media__name", `video[src="${MEDIA}"]`],
  ] as const)(
    "a local %s that failed waits once the host answers pending, then loads",
    async (kind, method, name, waiting, shown) => {
      const page = await setup();
      page.host.locality = "local";
      await page.locality({ locality: "local" });
      page.host.late = { method, reply: {} };
      await page.render(`![Shot](/tmp/failed-pending/${name})`);
      await page.release();
      // A refusal: the image's unavailable card; the video falls back to its link (no player).
      expect(page.container.querySelector(kind === "image" ? ".cv-image-file" : ".cv-media")).toEqual(
        kind === "image" ? expect.anything() : null,
      );
      // The chat's locality is unknown again and the host answers its paths pending: it waits.
      page.host.locality = "unknown";
      page.host.gateInspect = true;
      await page.locality({ locality: "unknown" });
      expect(page.container.querySelector(waiting)).not.toBeNull();
      expect(page.container.querySelector(".cv-image-file")).toBeNull();
      // Local again: asked again, and it loads.
      page.host.locality = "local";
      await page.locality({ locality: "local" });
      expect(page.container.querySelector(shown)).not.toBeNull();
      await page.unmount();
    },
  );

  test("a link.inspect answered pending with only URLs still applies its policy", async () => {
    const page = await setup();
    const policy = { outsideRoots: "confirm", remoteImages: "never" };
    page.host.late = { method: "link.inspect", reply: { pending: true, policy } };
    await page.render(`See https://example.com/only and ![Web](${webImage("t8")})`);
    await page.release();
    const inspects = page.host.calls.filter((call) => call.method === "link.inspect");
    expect(inspects.map((call) => call.params.paths)).toEqual(inspects.map(() => []));
    // "never": the web image draws as its link, with no Load button.
    expect(page.container.querySelector(".cv-image-placeholder__load")).toBeNull();
    await page.unmount();
  });
});
