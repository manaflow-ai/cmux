// Videos in agent replies (Leo 2026-10-21: "id like to be able to watch .mp4s direclty in cmux next
// somehow"): which sources are video and how each opens in a tab, and the thumbnail a video draws
// before it plays (poster frame, play button, length, the pointing hand), then click-to-play.
import { afterEach, describe, expect, jest, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  formatDuration,
  isRemoteMedia,
  mediaKind,
  mediaOpenRequest,
  MediaPlayer,
} from "../src/agent-session/acpmux/chips/ReplyMedia";
import { MEDIA_PREVIEW_DWELL } from "../src/ui/hoverIntent";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";

describe("which sources are video", () => {
  const cases: Array<[source: string, kind: ReturnType<typeof mediaKind>]> = [
    ["/Users/you/out/demo.mp4", "video"],
    ["./out/clip.MOV", "video"],
    ["~/Movies/reel.webm", "video"],
    ["file:///tmp/a.m4v", "video"],
    ["https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/3969193/reel.mp4", "video"],
    ["https://x.test/a.mp4?raw=1#t=3", "video"],
    ["/tmp/voice.m4a", "audio"],
    ["/tmp/shot.png", undefined],
    ["/tmp/notes.mp4.txt", undefined],
  ];
  test.each(cases)("%s", (source, kind) => {
    expect(mediaKind(source)).toBe(kind);
  });

  test("web media is https only, without credentials", () => {
    expect(isRemoteMedia("https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/23650/tour.mp4")).toBe(true);
    expect(isRemoteMedia("https://github.com/user-attachments/assets/0f4c8a2e-1b7d-4e5a-9c3f-2d6b8e1a7c90")).toBe(true);
    expect(isRemoteMedia("http://x.test/a.mp4")).toBe(false);
    expect(isRemoteMedia("https://me:pw@x.test/a.mp4")).toBe(false);
    expect(isRemoteMedia("https://x.test/page")).toBe(false);
  });
});

describe("how a video opens in a tab", () => {
  test("a file opens through the path chip's request (cmux's file pages)", () => {
    expect(mediaOpenRequest("/Users/you/out/demo.mp4")).toEqual({
      method: "link.openPath",
      params: { path: "/Users/you/out/demo.mp4" },
    });
    expect(mediaOpenRequest("file:///tmp/a.mov")).toEqual({ method: "link.openPath", params: { path: "/tmp/a.mov" } });
  });
  test("a web video opens in a cmux browser tab", () => {
    const url = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/3969193/reel.mp4";
    expect(mediaOpenRequest(url)).toEqual({ method: "browser.openIn", params: { url, browserId: "cmux" } });
  });
  test("anything else opens nothing", () => {
    expect(mediaOpenRequest("http://x.test/a.mp4")).toBeUndefined();
    expect(mediaOpenRequest("javascript:alert(1)//a.mp4")).toBeUndefined();
    expect(mediaOpenRequest("file://elsewhere/tmp/a.mp4")).toBeUndefined();
    expect(mediaOpenRequest("~/.ssh/a.mp4")).toBeUndefined();
  });
});

describe("a video's length", () => {
  test.each([
    [7.2, "0:07"],
    [65, "1:05"],
    [3725, "1:02:05"],
    [0.4, "0:01"],
  ])("%p s is %s", (seconds, text) => {
    expect(formatDuration(seconds)).toBe(text);
  });
  test("an unknown length shows none", () => {
    expect(formatDuration(Number.NaN)).toBeUndefined();
    expect(formatDuration(Number.POSITIVE_INFINITY)).toBeUndefined();
    expect(formatDuration(0)).toBeUndefined();
  });
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

const DIALOG_GLOBALS = [
  "Node",
  "Element",
  "SVGElement",
  "HTMLIFrameElement",
  "DocumentFragment",
  "ShadowRoot",
  "Event",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "MutationObserver",
  "getComputedStyle",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "IS_REACT_ACT_ENVIRONMENT",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    ...DIALOG_GLOBALS,
  ])
    saved.set(key, scope[key]);
  // The dialog (Base UI, portaled) reads these DOM globals.
  for (const key of DIALOG_GLOBALS) scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  // The dialog (Base UI) schedules its focus with animation frames.
  const frame = (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: frame,
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  Object.assign(dom.window, { requestAnimationFrame: frame, cancelAnimationFrame: (id: number) => clearTimeout(id) });
  const media = dom.window.HTMLMediaElement.prototype as unknown as Record<string, unknown>;
  media.play = function play(this: HTMLMediaElement) {
    this.dataset.played = this.muted ? "muted" : "sound";
    return Promise.resolve();
  };
  media.pause = () => {};
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  jest.useRealTimers();
  setChipHost(undefined);
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

describe("the inline player", () => {
  const SOURCE = "/Users/you/src/atlas-web/out/login-tests.mp4";

  async function mount() {
    const container = installDom();
    const calls: Array<[string, Record<string, unknown>]> = [];
    setChipHost(async (method, params) => {
      calls.push([method, params]);
      return undefined;
    });
    await act(async () => {
      root = createRoot(container);
      root.render(
        <MediaPlayer
          src="data:video/mp4;base64,AAAA"
          source={SOURCE}
          kind="video"
          name="login-tests.mp4"
          onError={() => {}}
        />,
      );
    });
    const video = container.querySelector("video")!;
    Object.defineProperty(video, "duration", { configurable: true, value: 65 });
    await act(async () => {
      video.dispatchEvent(new dom!.window.Event("loadedmetadata"));
    });
    return { container, video, calls };
  }

  test("draws its poster frame, a play button and its length before it plays", async () => {
    const { container, video } = await mount();
    expect(video.controls).toBe(false);
    expect(video.muted).toBe(true);
    expect(video.getAttribute("preload")).toBe("metadata");
    // The poster: the player is moved just past the start so it draws that frame.
    expect(video.currentTime).toBeCloseTo(0.1);
    const poster = container.querySelector<HTMLButtonElement>("button.cv-media__poster");
    expect(poster?.getAttribute("aria-label")).toBe("Play video, 1:05");
    expect(poster?.querySelector(".cv-media__play.ui-glass svg")).not.toBeNull();
    expect(container.querySelector(".cv-media__duration")?.textContent).toBe("1:05");
  });

  test("a click plays it with sound and the player's controls", async () => {
    const { container, video } = await mount();
    await act(async () => container.querySelector<HTMLButtonElement>("button.cv-media__poster")!.click());
    expect(container.querySelector("button.cv-media__poster")).toBeNull();
    expect(container.querySelector(".cv-media__frame.is-playing")).not.toBeNull();
    expect(video.controls).toBe(true);
    expect(video.muted).toBe(false);
    expect(video.dataset.played).toBe("sound");
  });

  function hover(container: HTMLElement, enter = true) {
    container
      .querySelector("button.cv-media__poster")!
      .dispatchEvent(new dom!.window.MouseEvent(enter ? "mouseover" : "mouseout", { bubbles: true }));
  }

  test("a pointer sweep never starts a preview; a deliberate rest does", async () => {
    const { container, video } = await mount();
    jest.useFakeTimers();
    await act(async () => hover(container));
    expect(video.dataset.played).toBeUndefined();
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL - 1));
    expect(video.dataset.played).toBeUndefined();
    await act(async () => hover(container, false));
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
    expect(video.dataset.played).toBeUndefined();
    await act(async () => hover(container));
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
    expect(video.dataset.played).toBe("muted");
  });

  for (const [attribute, value] of [
    ["agentMotion", "off"],
    ["cmuxMotion", "off"],
    ["cmuxMotion", "reduced"],
  ] as const) {
    test(`${attribute} ${value} blocks hover but keeps click-to-play with sound`, async () => {
      const { container, video } = await mount();
      document.documentElement.dataset[attribute] = value;
      jest.useFakeTimers();
      await act(async () => hover(container));
      await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
      expect(video.dataset.played).toBeUndefined();
      await act(async () => container.querySelector<HTMLButtonElement>("button.cv-media__poster")!.click());
      expect(video.dataset.played).toBe("sound");
      expect(video.muted).toBe(false);
    });
  }

  test("Reduce Motion blocks a preview and a live change stops one", async () => {
    const { container, video } = await mount();
    document.documentElement.dataset.cmuxMotion = "reduced";
    await act(async () => await Promise.resolve());
    video.pause = () => {
      video.dataset.paused = "yes";
    };
    jest.useFakeTimers();
    await act(async () => hover(container));
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
    expect(video.dataset.played).toBeUndefined();
    await act(async () => hover(container, false));
    delete document.documentElement.dataset.cmuxMotion;
    await act(async () => await Promise.resolve());
    await act(async () => hover(container));
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
    expect(video.dataset.played).toBe("muted");
    delete video.dataset.paused;
    document.documentElement.dataset.cmuxMotion = "reduced";
    await act(async () => await Promise.resolve());
    expect(video.getAttribute("data-paused")).toBe("yes");
  });

  test("scroll, page-away and live motion-off cancel pending and active previews", async () => {
    const { container, video } = await mount();
    video.pause = () => {
      video.dataset.paused = "yes";
    };
    jest.useFakeTimers();
    for (const interrupt of [
      () => container.dispatchEvent(new dom!.window.Event("scroll", { bubbles: true })),
      () => document.dispatchEvent(new dom!.window.Event("visibilitychange")),
      () => dom!.window.dispatchEvent(new dom!.window.Event("pagehide")),
      () => {
        document.documentElement.dataset.agentMotion = "off";
      },
    ]) {
      await act(async () => hover(container));
      await act(async () => {
        interrupt();
      });
      await act(async () => await Promise.resolve());
      await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
      expect(video.dataset.played).toBeUndefined();
      await act(async () => hover(container, false));
      delete document.documentElement.dataset.agentMotion;
      await act(async () => await Promise.resolve());
    }
    await act(async () => hover(container));
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
    expect(video.dataset.played).toBe("muted");
    delete video.dataset.paused;
    await act(async () => {
      document.dispatchEvent(new dom!.window.Event("scroll"));
    });
    expect(video.getAttribute("data-paused")).toBe("yes");
    delete video.dataset.paused;
    await act(async () => hover(container, false));
  });

  test("page interruptions do not pause explicit playback after it is muted", async () => {
    const { container, video } = await mount();
    video.pause = () => {
      video.dataset.paused = "yes";
    };
    await act(async () => hover(container));
    await act(async () => container.querySelector<HTMLButtonElement>("button.cv-media__poster")!.click());
    video.muted = true;
    await act(async () => {
      document.dispatchEvent(new dom!.window.Event("scroll"));
      document.dispatchEvent(new dom!.window.Event("visibilitychange"));
      dom!.window.dispatchEvent(new dom!.window.Event("pagehide"));
    });
    expect(video.dataset.paused).toBeUndefined();
  });

  test("unmount cancels a pending preview and pauses an active one", async () => {
    const { container, video } = await mount();
    video.pause = () => {
      video.dataset.paused = "yes";
    };
    jest.useFakeTimers();
    await act(async () => hover(container));
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
    expect(video.dataset.played).toBe("muted");
    await act(async () => root!.unmount());
    root = undefined;
    expect(video.getAttribute("data-paused")).toBe("yes");
  });

  test("unmount cancels a pending preview", async () => {
    const { container, video } = await mount();
    video.pause = () => {
      video.dataset.paused = "yes";
    };
    jest.useFakeTimers();
    await act(async () => hover(container));
    await act(async () => root!.unmount());
    root = undefined;
    expect(video.dataset.played).toBeUndefined();
    expect(video.dataset.paused).toBe("yes");
  });

  test("Open in tab asks the host to open the file, never the granted URL", async () => {
    const { container, calls } = await mount();
    const open = container.querySelector<HTMLButtonElement>('button.cv-media__action[aria-label="Open in tab"]');
    expect(open).not.toBeNull();
    await act(async () => open!.click());
    expect(calls).toEqual([["link.openPath", { path: SOURCE }]]);
  });

  test("Expand opens the player paused: nothing plays with sound until Play is pressed", async () => {
    const { container, video } = await mount();
    // The pointer resting on the thumbnail previews it muted, then Expand opens the large player.
    jest.useFakeTimers();
    await act(async () => {
      container
        .querySelector("button.cv-media__poster")!
        .dispatchEvent(new dom!.window.MouseEvent("mouseover", { bubbles: true }));
    });
    await act(async () => void jest.advanceTimersByTime(MEDIA_PREVIEW_DWELL));
    expect(video.dataset.played).toBe("muted");
    jest.useRealTimers();
    await act(async () =>
      container.querySelector<HTMLButtonElement>('button.cv-media__action[aria-label="Expand"]')!.click(),
    );
    const stage = dom!.window.document.querySelector(".cv-media-stage");
    expect(stage).not.toBeNull();
    const large = stage!.querySelector("video")!;
    expect(large.hasAttribute("autoplay")).toBe(false);
    expect(large.dataset.played).toBeUndefined();
    // Play in the large player plays it with sound.
    const play = stage!.querySelector<HTMLButtonElement>("button.cv-media__poster");
    expect(play).not.toBeNull();
    await act(async () => play!.click());
    expect(large.muted).toBe(false);
    expect(large.dataset.played).toBe("sound");
  });

  test("its hover transitions run only when motion is allowed", () => {
    const css = readFileSync(new URL("../src/agent-session/acpmux/chips/chips.css", import.meta.url), "utf8");
    const media = css.slice(css.indexOf("/* Video and audio (ReplyMedia)"), css.indexOf(".cv-media-stage {"));
    const outside = media.replace(/@media \(prefers-reduced-motion: no-preference\) \{[\s\S]*?\n\}/g, "");
    expect(outside).not.toContain("transition");
    expect(media).toContain("var(--cmux-motion-micro");
  });

  test("a local video keeps its path for the file menu and drag-out (data-path)", async () => {
    const container = installDom();
    await act(async () => {
      root = createRoot(container);
      root.render(
        <MediaPlayer
          src="data:video/mp4;base64,AAAA"
          source={SOURCE}
          path={SOURCE}
          kind="video"
          name="login-tests.mp4"
          onError={() => {}}
        />,
      );
    });
    expect(container.querySelector(".cv-media.is-video")?.getAttribute("data-path")).toBe(SOURCE);
    expect(container.querySelector("button.cv-media__poster")?.closest("[data-path]")).not.toBeNull();
  });

  test("every control a click lands on shows the pointing hand", () => {
    const css = readFileSync(new URL("../src/agent-session/acpmux/chips/chips.css", import.meta.url), "utf8");
    const rule = (selector: string) => {
      const start = css.indexOf(`\n${selector} {`);
      expect(start).toBeGreaterThan(-1);
      return css.slice(start, css.indexOf("}", start));
    };
    expect(rule(".cv-media__poster")).toContain("cursor: pointer;");
    expect(rule(".cv-media__action")).toContain("cursor: pointer;");
    expect(css).toMatch(/\.cv-media__frame\.is-playing video,[^{]*\{\s*cursor: pointer;/);
  });
});
