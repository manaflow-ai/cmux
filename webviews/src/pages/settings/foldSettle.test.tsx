// l10n-allow-file: test fixture names, not shipped UI.
// Every fold in Settings opens and closes as one motion on the settle (Leo, 2026-11-07: "they dont
// overshoot but they decelerate at the end. i think that might be the key"): a browser profile's
// form, a team's details, Agent integrations, an environment's build log and Density's exact sizes.
// The body's height moves over --cmux-motion-settle on --cmux-ease-settle (opacity with it), a
// closing body stays drawn until it has folded away and nothing mounts after, and under Reduce
// Motion the end state applies in one frame (session-info/foldMotion.ts).
import { act } from "react";
import { afterAll, beforeEach, expect, test } from "bun:test";
import { MOTION_SETTLE, MOTION_SETTLE_MS } from "../../motion/scale.generated";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");

type Animated = { target: HTMLElement; keyframes: Keyframe[]; options: KeyframeAnimationOptions; finish: () => void };
let animations: Animated[] = [];

beforeEach(() => {
  animations = [];
  delete document.documentElement.dataset.cmuxMotion;
  const proto = window.HTMLElement.prototype as unknown as Record<string, unknown>;
  // JSDOM lays out nothing: a box is 20px per element it draws, nothing past a closed <details>' summary.
  Object.defineProperty(proto, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      if (this.closest("details:not([open]) > :not(summary)")) return 0;
      return this.querySelectorAll("*").length * 20 + (this.textContent ? 20 : 0);
    },
  });
  proto.animate = function (this: HTMLElement, keyframes: Keyframe[], options: KeyframeAnimationOptions) {
    const animation = {
      onfinish: null as null | (() => void),
      oncancel: null as null | (() => void),
      cancel() {
        animation.oncancel?.();
      },
    };
    animations.push({ target: this, keyframes, options, finish: () => act(() => animation.onfinish?.()) });
    return animation;
  };
});

/// The fold the last toggle ran: the settle's duration and curve, over the body's height.
function expectSettle(animation: Animated | undefined, body: Element | null) {
  expect(animation).toBeDefined();
  expect(animation!.options.duration).toBe(MOTION_SETTLE_MS);
  expect(animation!.options.easing).toBe(MOTION_SETTLE);
  expect(animation!.keyframes.every((frame) => "height" in frame)).toBe(true);
  expect(body?.contains(animation!.target) || animation!.target.contains(body!)).toBe(true);
}

/// Opens with `toggle`, then closes: each a settle fold; the closing body stays until the fold ends,
/// then is gone, and nothing more runs.
async function foldsOnTheSettle(toggle: () => Element, body: () => Element | null, shown: () => boolean) {
  expect(shown()).toBe(false);
  await click(toggle());
  await settle();
  expect(shown()).toBe(true);
  expectSettle(animations.at(-1), body());
  expect(animations.at(-1)!.keyframes[0]).toMatchObject({ height: "0px", opacity: 0 });
  animations.at(-1)!.finish();
  const opened = animations.length;
  await click(toggle());
  await settle();
  expect(animations.length).toBe(opened + 1);
  const closing = animations.at(-1)!;
  expectSettle(closing, body());
  expect(closing.keyframes.at(-1)).toMatchObject({ height: "0px", opacity: 0 });
  // Drawn while it folds away.
  expect(shown()).toBe(true);
  closing.finish();
  await settle();
  expect(shown()).toBe(false);
  expect(animations.length).toBe(opened + 1);
}

const profileRow = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-profile="p-work"]')!;

test("a browser profile's form folds open and closed on the settle", async () => {
  const page = await renderPage({ path: "/settings/browser" });
  const row = profileRow(page.container);
  await foldsOnTheSettle(
    () => row.querySelector(".host-toggle")!,
    () => row.querySelector(".host-form"),
    () => row.querySelector(".host-form") !== null,
  );
  page.unmount();
});

test("opening another profile folds the open one away on the same frames", async () => {
  const page = await renderPage({ path: "/settings/browser" });
  const rows = [...page.container.querySelectorAll<HTMLElement>("[data-profile]")];
  expect(rows.length).toBeGreaterThan(1);
  const [first, second] = rows;
  await click(first!.querySelector(".host-toggle")!);
  await settle();
  animations.at(-1)!.finish();
  const before = animations.length;
  await click(second!.querySelector(".host-toggle")!);
  await settle();
  // One fold opens the second, one closes the first; the first stays drawn until its fold ends.
  expect(animations.length).toBe(before + 2);
  const closing = animations.slice(before).find((run) => first!.contains(run.target))!;
  expectSettle(closing, first!.querySelector(".host-form"));
  expect(first!.querySelector(".host-form")).not.toBeNull();
  closing.finish();
  await settle();
  expect(first!.querySelector(".host-form")).toBeNull();
  page.unmount();
});

test("a team's details fold open and closed on the settle", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await settle();
  const row = () => page.container.querySelector<HTMLElement>('[data-team="team-personal"]')!;
  await foldsOnTheSettle(
    () => row().querySelector('[data-team-button="team.details"]')!,
    () => row().querySelector("[data-team-detail]"),
    () => row().querySelector("[data-team-detail]") !== null,
  );
  page.unmount();
});

test("Agent integrations folds open and closed on the settle, and reads its status once", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const card = () => page.container.querySelector<HTMLElement>('[data-card="agentIntegrations"]')!;
  await foldsOnTheSettle(
    () => card().querySelector("summary")!,
    () => card().querySelector("details > :not(summary)"),
    () => card().querySelector("details")!.open,
  );
  expect(page.provider.log.filter((entry) => entry.op === "cmux.settings.integrations.state").length).toBe(1);
  page.unmount();
});

test("an environment's build log folds open and closed on the settle", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await settle();
  const log = () => page.container.querySelector<HTMLDetailsElement>("[data-environment-log]")!;
  await foldsOnTheSettle(
    () => log().querySelector("summary")!,
    () => log().querySelector(":scope > :not(summary)"),
    () => log().open,
  );
  page.unmount();
});

test("Density's exact sizes fold open and closed on the settle", async () => {
  const page = await renderPage({ path: "/settings/appearance?focus=appearance.density" });
  await settle();
  await click(page.container.querySelector('[data-density-action="duplicate"]')!);
  await settle();
  const exact = () => page.container.querySelector<HTMLDetailsElement>(".density-editor details")!;
  await foldsOnTheSettle(
    () => exact().querySelector("summary")!,
    () => exact().querySelector(":scope > :not(summary)"),
    () => exact().open,
  );
  page.unmount();
});

test("under Reduce Motion every Settings fold applies in one frame", async () => {
  document.documentElement.dataset.cmuxMotion = "reduced";
  const page = await renderPage({ path: "/settings/browser" });
  const row = profileRow(page.container);
  await click(row.querySelector(".host-toggle")!);
  expect(row.querySelector(".host-form")).not.toBeNull();
  await click(row.querySelector(".host-toggle")!);
  expect(row.querySelector(".host-form")).toBeNull();
  page.unmount();
  const accounts = await renderPage({ path: "/settings/accounts" });
  await settle();
  const log = accounts.container.querySelector<HTMLDetailsElement>("[data-environment-log]")!;
  await click(log.querySelector("summary")!);
  expect(log.open).toBe(true);
  await click(log.querySelector("summary")!);
  expect(log.open).toBe(false);
  accounts.unmount();
  expect(animations).toEqual([]);
});
