// Lucas 2026-10-19: Files and Thread details side by side looked wrong. Until both live in one right
// sidebar, the chat shows one: the viewer (Files, a file, Changes) hides Thread details while open,
// and the Thread details button then closes the viewer and shows the details.
import { expect, test } from "bun:test";
import { viewerOrDetails } from "../src/agent-session/acpmux/chatViewerPanels";

const card = (shown: boolean, log: string[]) => ({
  shown,
  toggle: () => log.push("toggle"),
  show: () => log.push("show"),
});

test("with no viewer open, Thread details is its own card", () => {
  const log: string[] = [];
  const base = card(true, log);
  expect(viewerOrDetails(base, false, () => log.push("closeViewer"))).toBe(base);
});

test("an open viewer hides Thread details, and its button closes the viewer to show them", () => {
  const log: string[] = [];
  const shown = viewerOrDetails(card(true, log), true, () => log.push("closeViewer"));
  expect(shown.shown).toBe(false);
  shown.toggle();
  expect(log).toEqual(["closeViewer", "show"]);
});
