// l10n-allow-file: benchmark output, not shipped UI.
// What a page draws while nothing happens (cmuxterm-hq goals/chats-flat-at-any-length.md): over one window, from a CDP
// trace of the renderer, the frames it drew (compositor DrawFrame), the main-thread frames among them
// (BeginMainThreadFrame), its main-thread paints and their area, and its layout, style and paint time; and, from the
// page, the animations that run and what each animates. An animation of transform or opacity only runs on the
// compositor: frames, but no main-thread frame and no paint. One of background-position, color, width, a mask or a
// filter repaints its layer on the main thread every frame, and when that layer is the transcript's, the whole
// transcript.
/// <reference types="bun" />
import type { CDPSession, Page } from "playwright";

const CATEGORIES = [
  "__metadata",
  "toplevel",
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "disabled-by-default-devtools.timeline.frame",
  "blink.animations",
];

type TraceEvent = {
  name: string;
  ph: string;
  pid: number;
  tid: number;
  ts: number;
  dur?: number;
  id?: string;
  id2?: { local?: string };
  args?: { name?: string; data?: Record<string, unknown> };
};

export type RunningAnimation = {
  name: string;
  target: string;
  /** The properties its keyframes set. */
  properties: string[];
  /** Only transform, opacity and their individual forms: the kind the compositor can run alone. */
  compositable: boolean;
  /** Its target's box meets the viewport. */
  onScreen: boolean;
};

export type PaintWindow = {
  seconds: number;
  /** Compositor frames drawn, a second. */
  framesPerS: number;
  /** Main-thread frames (BeginMainThreadFrame), a second: the frames that ran style, layout or paint. */
  mainFramesPerS: number;
  /** Main-thread Paint events, a second. */
  paintsPerS: number;
  /** Main-thread time, ms a second. */
  paintMsPerS: number;
  layoutMsPerS: number;
  styleMsPerS: number;
  /** Every main-thread task (toplevel RunTask), ms a second. */
  taskMsPerS: number;
  /** The largest paint's area (CSS px²) and the painted area a second. */
  maxPaintArea: number;
  paintAreaPerS: number;
  /** What the trace says of each animation the compositor would not run (Chromium's compositeFailed and
   * unsupportedProperties), by animation name. */
  notComposited: string[];
  animations: RunningAnimation[];
  /// requestAnimationFrame callbacks a second, by the site that asked for them, most first.
  frameSources: [site: string, perS: number][];
  /// CSS animations and transitions started a second, by name or property and target, most first.
  startedPerS: [what: string, perS: number][];
};

const COMPOSITABLE = new Set(["transform", "opacity", "translate", "rotate", "scale"]);

/// The animations running in `page` (pure page script).
export async function runningAnimations(page: Page): Promise<RunningAnimation[]> {
  const list = await page.evaluate(() => {
    const label = (element: Element) =>
      `${element.tagName.toLowerCase()}${typeof element.className === "string" && element.className ? `.${element.className.trim().split(/\s+/).join(".")}` : ""}`;
    return document
      .getAnimations()
      .filter((animation) => animation.playState === "running")
      .map((animation) => {
        const effect = animation.effect as KeyframeEffect | null;
        const target = effect?.target ?? null;
        const pseudo = effect?.pseudoElement ?? "";
        const properties = new Set<string>();
        for (const frame of effect?.getKeyframes() ?? [])
          for (const key of Object.keys(frame))
            if (!["offset", "computedOffset", "easing", "composite"].includes(key)) properties.add(key);
        const rect = target?.getBoundingClientRect();
        const onScreen =
          !!rect && rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth;
        return {
          name: (animation as CSSAnimation).animationName ?? animation.id ?? "?",
          target: target ? `${label(target)}${pseudo}` : "?",
          properties: [...properties].map((p) => p.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)),
          onScreen,
        };
      });
  });
  return list.map((animation) => ({
    ...animation,
    compositable: animation.properties.every((property) => COMPOSITABLE.has(property)),
  }));
}

/// Traces `seconds` of `page` through `cdp` (a session of that page). The page's running loops are paused and played
/// again at the window's start, so the trace sees each start on (or refused by) the compositor.
export async function paintWindow(
  page: Page,
  cdp: CDPSession,
  seconds: number,
  /// A bundle position (file name, 0-based line and column) to its source (bench/sourceMapper.ts), for the frame
  /// requests' sites.
  mapSource?: (file: string, line: number, column: number) => string,
): Promise<PaintWindow> {
  // What asks for frames over the window: each requestAnimationFrame callback that ran, by the site that asked for it
  // (two stack frames), and each CSS animation and transition that started, by name or property and target.
  await page.evaluate(() => {
    type Probe = { on: boolean; frames: Map<string, number>; started: Map<string, number> };
    const w = window as unknown as { __cmuxFrameSources?: Probe };
    const label = (target: EventTarget | null) =>
      target instanceof Element
        ? `${target.tagName.toLowerCase()}${typeof target.className === "string" && target.className ? `.${target.className.trim().split(/\s+/).slice(0, 3).join(".")}` : ""}`
        : "?";
    if (!w.__cmuxFrameSources) {
      const probe: Probe = { on: false, frames: new Map(), started: new Map() };
      w.__cmuxFrameSources = probe;
      const raf = window.requestAnimationFrame.bind(window);
      window.requestAnimationFrame = (callback: FrameRequestCallback) => {
        if (!probe.on) return raf(callback);
        const site =
          new Error().stack
            ?.split("\n")
            .slice(2, 4)
            .map((line) => line.trim())
            .join(" < ") ?? "?";
        return raf((time) => {
          if (probe.on) probe.frames.set(site, (probe.frames.get(site) ?? 0) + 1);
          callback(time);
        });
      };
      const note = (key: string) => probe.on && probe.started.set(key, (probe.started.get(key) ?? 0) + 1);
      document.addEventListener(
        "animationstart",
        (event) => note(`animation ${event.animationName} on ${label(event.target)}`),
        true,
      );
      document.addEventListener(
        "transitionrun",
        (event) => note(`transition ${event.propertyName} on ${label(event.target)}`),
        true,
      );
    }
    const probe = w.__cmuxFrameSources;
    probe.frames.clear();
    probe.started.clear();
    probe.on = true;
  });
  const events: TraceEvent[] = [];
  const collect = (payload: { value: object[] }) => {
    for (const event of payload.value) events.push(event as TraceEvent);
  };
  cdp.on("Tracing.dataCollected", collect);
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: { includedCategories: CATEGORIES, excludedCategories: ["*"] },
  });
  try {
    await page.evaluate(() => {
      for (const animation of document.getAnimations()) {
        if (animation.playState !== "running") continue;
        const time = animation.currentTime;
        animation.pause();
        animation.currentTime = time;
        animation.play();
      }
    });
    // fixed-wait: the window itself.
    await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
  } finally {
    const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
    await cdp.send("Tracing.end");
    await done;
    cdp.off("Tracing.dataCollected", collect);
  }
  const animations = await runningAnimations(page);
  const probed = await page.evaluate(() => {
    const probe = (
      window as unknown as {
        __cmuxFrameSources: { on: boolean; frames: Map<string, number>; started: Map<string, number> };
      }
    ).__cmuxFrameSources;
    probe.on = false;
    return { frames: [...probe.frames], started: [...probe.started] };
  });
  // A stack line `at name (http://host/assets/file.js:L:C)` to its source, when a map is given.
  const mapSite = (site: string) =>
    mapSource
      ? site.replace(
          /(?:https?:\/\/[^\s)]*\/)?assets\/([^\s/:)]+\.js):(\d+):(\d+)/g,
          (_, file: string, line: string, column: string) => mapSource(file, Number(line) - 1, Number(column) - 1),
        )
      : site;
  const frameSources = probed.frames
    .map(([site, count]) => [mapSite(site), count / seconds] as [string, number])
    .sort((a, b) => b[1] - a[1]);
  const startedPerS = probed.started
    .map(([key, count]) => [key, count / seconds] as [string, number])
    .sort((a, b) => b[1] - a[1]);
  const threads = new Map<string, string>();
  const renderers = new Set<number>();
  for (const event of events) {
    if (event.ph !== "M") continue;
    if (event.name === "thread_name" && event.args?.name) threads.set(`${event.pid}:${event.tid}`, event.args.name);
    if (event.name === "process_name" && event.args?.name === "Renderer") renderers.add(event.pid);
  }
  const main = (event: TraceEvent) =>
    renderers.has(event.pid) && threads.get(`${event.pid}:${event.tid}`) === "CrRendererMain";
  let frames = 0;
  let mainFrames = 0;
  let paints = 0;
  let paintMs = 0;
  let layoutMs = 0;
  let styleMs = 0;
  let taskMs = 0;
  let maxPaintArea = 0;
  let paintArea = 0;
  const notComposited = new Set<string>();
  // An animation's trace is an async begin naming it and instants carrying the compositor's answer, by one id.
  const animationId = (event: TraceEvent) => `${event.pid}:${event.id ?? event.id2?.local ?? ""}`;
  const animationNames = new Map<string, string>();
  for (const event of events)
    if (event.name === "Animation" && typeof event.args?.data?.name === "string" && event.args.data.name)
      animationNames.set(animationId(event), event.args.data.name as string);
  for (const event of events) {
    if (!renderers.has(event.pid)) continue;
    const ms = (event.dur ?? 0) / 1000;
    if (event.name === "DrawFrame") frames += 1;
    if (event.name === "Animation" && event.args?.data) {
      const data = event.args.data as { compositeFailed?: number; unsupportedProperties?: string[] };
      if (data.compositeFailed)
        notComposited.add(
          `${animationNames.get(animationId(event)) || "?"}: compositeFailed ${data.compositeFailed}${data.unsupportedProperties?.length ? ` (${data.unsupportedProperties.join(", ")})` : ""}`,
        );
    }
    if (!main(event)) continue;
    if (event.name === "BeginMainThreadFrame") mainFrames += 1;
    else if (event.name === "Paint" && event.ph === "X") {
      paints += 1;
      paintMs += ms;
      const clip = event.args?.data?.clip as number[] | undefined;
      // An unbounded cull rect (about 2^24 px a side) says nothing of the area drawn: left out.
      if (clip?.length === 8 && clip.every((value) => Math.abs(value) < 1e6)) {
        const xs = [clip[0]!, clip[2]!, clip[4]!, clip[6]!];
        const ys = [clip[1]!, clip[3]!, clip[5]!, clip[7]!];
        const area = (Math.max(...xs) - Math.min(...xs)) * (Math.max(...ys) - Math.min(...ys));
        paintArea += area;
        maxPaintArea = Math.max(maxPaintArea, area);
      }
    } else if (event.name === "Layout" && event.ph === "X") layoutMs += ms;
    else if (event.name === "UpdateLayoutTree" && event.ph === "X") styleMs += ms;
    else if (event.name === "RunTask" && event.ph === "X") taskMs += ms;
  }
  return {
    seconds,
    framesPerS: frames / seconds,
    mainFramesPerS: mainFrames / seconds,
    paintsPerS: paints / seconds,
    paintMsPerS: paintMs / seconds,
    layoutMsPerS: layoutMs / seconds,
    styleMsPerS: styleMs / seconds,
    taskMsPerS: taskMs / seconds,
    maxPaintArea,
    paintAreaPerS: paintArea / seconds,
    notComposited: [...notComposited],
    animations,
    frameSources,
    startedPerS,
  };
}

/// One line of a window, and a line per running animation.
export function describePaintWindow(label: string, window: PaintWindow): string {
  const head =
    `  ${label}: ${window.framesPerS.toFixed(1)} frames/s, ${window.mainFramesPerS.toFixed(1)} main frames/s, ` +
    `${window.paintsPerS.toFixed(1)} paints/s (${window.paintMsPerS.toFixed(2)} ms/s, largest ${Math.round(window.maxPaintArea)} px², ` +
    `${Math.round(window.paintAreaPerS)} px²/s); layout ${window.layoutMsPerS.toFixed(2)} ms/s, style ${window.styleMsPerS.toFixed(2)} ms/s, ` +
    `main tasks ${window.taskMsPerS.toFixed(1)} ms/s`;
  const lines = window.animations.map(
    (animation) =>
      `    animation ${animation.name} on ${animation.target}: ${animation.properties.join(", ") || "-"}` +
      `${animation.compositable ? "" : " (not compositor-only)"}${animation.onScreen ? "" : " (off screen)"}`,
  );
  for (const reason of window.notComposited) lines.push(`    trace: not composited ${reason}`);
  for (const [site, perS] of window.frameSources.slice(0, 8))
    lines.push(`    frames ${perS.toFixed(1)}/s from ${site}`);
  for (const [what, perS] of window.startedPerS.slice(0, 8)) lines.push(`    started ${perS.toFixed(1)}/s: ${what}`);
  return [head, ...lines].join("\n");
}
