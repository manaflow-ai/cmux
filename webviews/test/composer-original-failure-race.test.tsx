// l10n-allow-file: synthetic file names and host errors for a behavioral regression.
// An image's original that fails between a commit and that commit's passive effects keeps its Retry
// (composer/attachmentIntakeModel.ts, the cleanup effect's `everDrawn` guard, which each commit's
// layout phase fills, never a render; #40892, review F1).
//
// The cleanup effect drops the original's file and failure of a chip no longer in the strip. It runs
// after its commit's paint, so a second image read meanwhile (staged, its original failed) is in no
// render's `attachments` yet: without the guard the effect took it for one that left and dropped its
// Retry. The race is made deterministic here: the second image is pasted and fully decoded, but its
// intake waits on the host's answer of where its file is (`localPaths`), which both its staging and
// its upload wait on. A commit that changes the strip answers it from its layout phase and holds the
// frame past React's scheduler slice, so the scheduler yields before that commit's passive effects.
// From that answer on everything is a microtask (the decode is done, the upload's answer is ready),
// so the image's staging and its failed original land in that yield, ahead of the cleanup effect.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useEffect, useImperativeHandle, useLayoutEffect, type Ref } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import {
  useAttachmentIntake,
  type AttachmentIntakeOptions,
} from "../src/agent-session/acpmux/composer/attachmentIntakeModel";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "createImageBitmap",
  "OffscreenCanvas",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
/// Each picture the canvas encoded (a preview, a thumbnail): an image's read is done once its own are.
let encoded = 0;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    // The engine's image decoder and canvas, which jsdom lacks (composer/imageWork.ts).
    createImageBitmap: async () => ({ width: 40, height: 30, close() {} }),
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        encoded++;
        return new Blob(["pixels"], { type });
      }
    },
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const png = (name: string) => new File(["png"], name, { type: "image/png" });

type Intake = ReturnType<typeof useAttachmentIntake>;
function Harness({
  options,
  handle,
  committed,
}: {
  options: AttachmentIntakeOptions;
  handle: Ref<Intake>;
  /// Runs in each commit's layout phase: before that commit's passive effects (the cleanup effect).
  committed: (attachments: readonly ComposerAttachment[]) => void;
}) {
  const intake = useAttachmentIntake(options);
  useImperativeHandle(handle, () => intake);
  useLayoutEffect(() => committed(intake.attachments));
  // After the intake's own effects (hook order): what each commit's passive phase saw.
  useEffect(() => {
    trace.push(`passive ${intake.attachments.map((chip) => chip.name).join(",")}`);
  });
  return null;
}

const trace: string[] = [];

/// One macrotask (outside act, React's own scheduler runs each render and its passive effects then).
const turn = () => new Promise((resolve) => setTimeout(resolve, 0));
/// Yields until `check` holds.
async function until(check: () => boolean, inAct = false) {
  for (let at = 0; at < 2000 && !check(); at++) await (inAct ? act(turn) : turn());
  expect(check()).toBe(true);
}

test("an original that fails before its chip's first render keeps its Retry", async () => {
  const answers: UploadResult[] = [{ paths: ["/remote/first.png"] }, { error: "The disk is full." }];
  // The host's answer of where the pasted file is: held until the strip's commit. It knows no path
  // (an empty list), so the file uploads.
  let answerPaths: (() => void) | undefined;
  const options: AttachmentIntakeOptions = {
    allowImages: true,
    pasteTarget: () => undefined,
    upload: async () => answers.shift(),
    localPaths: () => new Promise((resolve) => (answerPaths = () => resolve([]))),
  };
  const handle: { current: Intake | null } = { current: null };
  let armed = false;
  let started = false;
  const committed = (attachments: readonly ComposerAttachment[]) => {
    if (!armed) return;
    armed = false;
    started = true;
    trace.push(`layout ${attachments.map((chip) => chip.name).join(",")}`);
    // The host answers, and this frame runs past the scheduler's slice (5 ms), so it yields before this
    // commit's passive effects: the image's staging and its failed original land first.
    answerPaths?.();
    const until = performance.now() + 20;
    while (performance.now() < until);
  };
  root = createRoot(host);
  act(() => root!.render(<Harness options={options} handle={handle} committed={committed} />));
  await act(() => handle.current!.attach([png("first.png")], true));
  await until(() => handle.current!.attachments[0]?.originalPath === "/remote/first.png", true);
  expect(handle.current!.attachments.map((chip) => chip.name)).toEqual(["first.png"]);
  const perImage = encoded;

  // A change to the strip, rendered by React's scheduler (not act, which would flush its effects at
  // once): its commit's layout phase starts the second image, its passive effects run after.
  scope.IS_REACT_ACT_ENVIRONMENT = false;
  void handle.current!.attach([png("second.png")], true, "paste");
  // It is not staged: it waits on the host's answer. Its preview may wait on that answer too, so the
  // test waits only for the question, not for the preview. The answer is given from the strip's
  // commit below, and from it on the preview, the staging and the failed upload are all microtasks
  // (the decode and the upload are faked with no timers), so they still land before that commit's
  // passive effects.
  await until(() => answerPaths !== undefined);
  expect(handle.current!.attachments.map((chip) => chip.name)).toEqual(["first.png"]);
  trace.length = 0;
  armed = true;
  handle.current!.setAttachments((chips) => chips.map((chip) => ({ ...chip })));
  // Settled: the commit that draws both chips has run its passive effects (the cleanup effect too).
  await until(() => trace.includes("passive first.png,second.png"));
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  await act(async () => {});

  expect(started).toBe(true);
  // The second image was read in full: its preview and thumbnail were made.
  expect(encoded).toBeGreaterThanOrEqual(2 * perImage);
  // The race: the strip's commit saw only the first image, its passive effects ran after the second
  // was staged with its original failed (the decode it waited on went on in that commit's layout).
  // (An earlier render's passive effects may land before the armed layout; what counts is the one after.)
  const layout = trace.indexOf("layout first.png");
  expect(layout).toBeGreaterThan(-1);
  expect(trace.slice(layout, layout + 2)).toEqual(["layout first.png", "passive first.png"]);
  const second = handle.current!.attachments.find((chip) => chip.name === "second.png");
  expect(second).toBeDefined();
  // Its original failed while no render had staged it: the failure and its file stay, so Retry shows
  // and uploads it again.
  expect(handle.current!.originalFailures[second!.id]).toBe("The disk is full.");
  answers.push({ paths: ["/remote/second.png"] });
  act(() => handle.current!.retry(second!.id));
  await until(
    () => handle.current!.attachments.find((chip) => chip.id === second!.id)?.originalPath === "/remote/second.png",
    true,
  );
  expect(handle.current!.attachments.find((chip) => chip.id === second!.id)?.originalPath).toBe("/remote/second.png");
  expect(handle.current!.originalFailures).toEqual({});
});
