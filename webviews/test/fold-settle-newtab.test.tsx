// l10n-allow-file: test fixture chat titles, not shipped UI.
// The New Tab page's folds move as one state transition on the settle (Leo, 2026-11-07: "they dont
// overshoot but they decelerate at the end. i think that might be the key"): a chat's children open
// and close with their box's height and opacity, and a project's chats in All chats fold into their
// header while the rows under it slide up (and back out of it), every drawn row on the same curve.
// Nothing is drawn after the motion ends, and under Reduce Motion the fold is one frame. The list's
// own rows still arrive and leave at once (listMotion.ts): only the fold moves.
import { expect, test } from "bun:test";
import { act } from "react";
import { MOTION_SETTLE, MOTION_SETTLE_MS } from "../src/motion/scale.generated";
import { AllChatsList } from "../src/agent-session/acpmux/newtab/AllChatsList";
import { ChatCards } from "../src/agent-session/acpmux/newtab/ChatCards";
import type { ChatCard } from "../src/agent-session/acpmux/newtab/screenModel";
import { click, expectSettle, fold, reduceMotion, render, useFoldPage } from "./foldSettleHarness";

useFoldPage();

const card = (sessionId: string, title: string, children?: ChatCard[]): ChatCard =>
  ({ sessionId, title, harness: "claude", age: "1m", state: "idle", children }) as unknown as ChatCard;

const cards = [card("p", "Parent", [card("c1", "Child one"), card("c2", "Child two")]), card("q", "Other")];

function cardsPage() {
  render(<ChatCards cards={cards} variant="list" onOpen={() => {}} />);
}
const childrenToggle = () => fold.container.querySelector<HTMLButtonElement>(".nt-card-children-toggle")!;
const children = () => fold.container.querySelector(".nt-card-children");

test("a chat's children open and close with their box's height and opacity on the settle", () => {
  cardsPage();
  expect(children()).toBeNull();
  click(childrenToggle());
  expect(children()).not.toBeNull();
  const opening = fold.animations.find((animation) => animation.target.contains(children()));
  expectSettle(opening);
  expect(opening!.keyframes[0]).toEqual({ height: "0px", opacity: 0 });
  opening!.finish();

  click(childrenToggle());
  expect(childrenToggle().getAttribute("aria-expanded")).toBe("false");
  const closing = fold.animations.at(-1)!;
  expectSettle(closing);
  expect(closing.keyframes.at(-1)).toEqual({ height: "0px", opacity: 0 });
  // Drawn while the box closes over them, gone on the frame it ends, and nothing after.
  expect(children()).not.toBeNull();
  const count = fold.animations.length;
  closing.finish();
  expect(children()).toBeNull();
  expect(fold.animations.length).toBe(count);
});

test("a chat's children open and close in one frame under Reduce Motion", () => {
  reduceMotion();
  cardsPage();
  click(childrenToggle());
  expect(children()).not.toBeNull();
  click(childrenToggle());
  expect(children()).toBeNull();
  expect(fold.animations.filter((animation) => "height" in animation.keyframes[0]!)).toEqual([]);
});

// All chats, Projects: JSDOM lays nothing out, so a row's box is where its virtual place puts it
// (its inline translateY), 30px tall, and the list's other boxes are the page's height.
const ROW = 30;
function layOut() {
  const proto = window.HTMLElement.prototype;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const place = /translateY\((-?[\d.]+)px\)/.exec(this.style.transform)?.[1];
    const top = place === undefined ? 0 : Number(place);
    const height = place === undefined ? 800 : ROW;
    return { x: 0, y: top, top, left: 0, right: 600, bottom: top + height, width: 600, height, toJSON() {} } as DOMRect;
  };
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
}
const chat = (key: string, title: string, cwd: string, updatedAt: number) => ({
  key,
  harness: "claude",
  title,
  cwd,
  updatedAt,
});
const chats = [
  chat("a", "Retry uploads", "/Users/me/src/uploader", 9),
  chat("b", "Fix the sidebar", "/Users/me/src/cmux", 8),
  chat("d", "Cover retry with tests", "/Users/me/src/uploader", 6),
];
const titles = (selector: string) =>
  [...fold.container.querySelectorAll(`${selector} .nt-all-title`)].map((node) => node.textContent);
/// The list's rows, not the drawn copies of rows a fold hid (listMotion.ts).
const ROWS = ".nt-all-item:not([data-list-ghost])";
const GHOST = "[data-list-ghost]";
const button = (name: string) =>
  [...fold.container.querySelectorAll("button")].find((element) => element.textContent?.trim() === name)!;
const uploader = () => fold.container.querySelector<HTMLButtonElement>(".nt-all-group")!;

async function projectsPage() {
  layOut();
  render(<AllChatsList load={async () => ({ chats, ready: true })} onOpen={() => {}} />);
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  click(button("Projects"));
  expect(titles(ROWS)).toEqual(["Retry uploads", "Cover retry with tests", "Fix the sidebar"]);
  fold.animations = [];
}

test("a project folds its chats into its header and the rows under it rise with them, on the settle", async () => {
  await projectsPage();
  click(uploader());
  expect(uploader().getAttribute("aria-expanded")).toBe("false");
  // The list itself drops them at once; what was drawn of them folds into the header as ghosts.
  expect(titles(ROWS)).toEqual(["Fix the sidebar"]);
  expect(titles(GHOST)).toEqual(["Retry uploads", "Cover retry with tests"]);
  for (const ghost of fold.container.querySelectorAll(GHOST)) {
    expect(ghost.getAttribute("aria-hidden")).toBe("true");
    expect(ghost.hasAttribute("inert")).toBe(true);
  }
  expect(fold.animations.length).toBeGreaterThan(0);
  for (const animation of fold.animations) {
    expect(animation.options.duration).toBe(MOTION_SETTLE_MS);
    expect(animation.options.easing).toBe(MOTION_SETTLE);
  }
  // The cmux header and its chat slide up from where they were drawn.
  const rose = fold.animations.filter((animation) => !animation.target.closest(GHOST));
  expect(rose.length).toBe(2);
  for (const animation of rose) expect(animation.keyframes[0]!.translate).toBe("0 60px");
  // The ghosts fade out into the header.
  const ghosts = fold.animations.filter((animation) => animation.target.closest(GHOST));
  expect(ghosts.length).toBe(2);
  for (const animation of ghosts) expect(animation.keyframes.at(-1)!.opacity).toBe(0);
  // When the motion ends the ghosts go, and nothing else is drawn or runs.
  const count = fold.animations.length;
  for (const animation of fold.animations.slice()) animation.finish();
  expect(fold.container.querySelector(GHOST)).toBeNull();
  expect(fold.animations.length).toBe(count);
});

test("a project opens its chats out of its header, fading in, as the rows under it slide down", async () => {
  await projectsPage();
  click(uploader());
  for (const animation of fold.animations.slice()) animation.finish();
  fold.animations = [];
  click(uploader());
  expect(titles(ROWS)).toEqual(["Retry uploads", "Cover retry with tests", "Fix the sidebar"]);
  const arrived = fold.animations.filter((animation) => animation.keyframes[0]!.opacity === 0);
  expect(arrived.length).toBe(2);
  for (const animation of fold.animations) {
    expect(animation.options.duration).toBe(MOTION_SETTLE_MS);
    expect(animation.options.easing).toBe(MOTION_SETTLE);
  }
  for (const animation of fold.animations.slice()) animation.finish();
  expect(fold.container.querySelector(GHOST)).toBeNull();
});

test("a project reopened mid-fold brings its chats back from where their ghosts are drawn", async () => {
  await projectsPage();
  click(uploader());
  // Cut short halfway: the ghost of the first chat is drawn half faded (JSDOM runs no animation).
  const ghost = [...fold.container.querySelectorAll<HTMLElement>(GHOST)].find((node) =>
    node.textContent?.includes("Retry uploads"),
  )!;
  ghost.style.opacity = "0.5";
  fold.animations = [];
  click(uploader());
  expect(fold.container.querySelector(GHOST)).toBeNull();
  const back = fold.animations.filter(
    (animation) => animation.target.querySelector(".nt-all-title")?.textContent === "Retry uploads",
  );
  expect(back.length).toBe(1);
  expect(back[0]!.keyframes[0]!.opacity).toBe(0.5);
  expect(back[0]!.keyframes.at(-1)!.opacity).toBe(1);
});

test("a project folds and opens in one frame under Reduce Motion", async () => {
  reduceMotion();
  await projectsPage();
  click(uploader());
  expect(titles(ROWS)).toEqual(["Fix the sidebar"]);
  expect(fold.container.querySelector(GHOST)).toBeNull();
  click(uploader());
  expect(titles(ROWS)).toEqual(["Retry uploads", "Cover retry with tests", "Fix the sidebar"]);
  expect(fold.animations).toEqual([]);
});
