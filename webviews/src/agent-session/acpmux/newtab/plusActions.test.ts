import { expect, test } from "bun:test";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { newTabCommandDraft, newTabPlusEntries } from "./plusActions";
import type { Translate } from "../i18n";

const snapshot = noChat([], {
  summary: {
    sessionId: "deferred",
    harness: "claude",
    cwd: "/project",
    peer: "build",
    modes: { currentModeId: "default", availableModes: [{ id: "default" }, { id: "plan" }] },
  },
  commands: [
    { name: "review", source: "skill", description: "Review" },
    { name: "goal", description: "Goal" },
  ],
});
const options = {
  snapshot,
  target: { harness: "claude", cwd: "/project", peer: "build" },
  translate: ((key: string) => key) as Translate,
  capture: true,
  project: true,
  mode: true,
};
const ids = (value = options) => newTabPlusEntries(value).map((entry) => entry.id);

test("New Tab reuses the registry's capability rows and native harness mode ids", () => {
  expect(ids()).toEqual([
    "add.files",
    "add.screenshot",
    "add.window",
    "add.project",
    "add.mode.plan",
    "add.goal",
    "add.skill.review",
  ]);
  const planning = newTabPlusEntries({
    ...options,
    snapshot: {
      ...snapshot,
      summary: {
        ...snapshot.summary!,
        modes: { currentModeId: "plan", availableModes: [{ id: "native-build" }, { id: "plan" }] },
      },
    },
  });
  expect(planning.find((entry) => entry.id === "add.mode.native-build")?.name).toBe("picker.build");
});

test("New Tab cannot reuse commands or modes from another machine, folder or harness", () => {
  for (const target of [
    { ...options.target, harness: "codex" },
    { ...options.target, peer: "other" },
    { ...options.target, cwd: "/other" },
  ]) {
    const entries = ids({ ...options, target });
    expect(entries.some((id) => /^add\.(goal|skill|mode)/.test(id))).toBe(false);
  }
  expect(ids({ ...options, snapshot: noChat([], { commands: snapshot.commands }) })).toEqual([
    "add.files",
    "add.screenshot",
    "add.window",
    "add.project",
  ]);
});

test("unsupported capture and mode capabilities stay absent", () => {
  const entries = ids({ ...options, capture: false, project: false, mode: false });
  expect(entries).toEqual(["add.files", "add.goal", "add.skill.review"]);
  expect(
    ids({
      ...options,
      snapshot: {
        ...snapshot,
        summary: { ...snapshot.summary!, promptCapabilities: { image: false } },
      },
    }),
  ).not.toContain("add.screenshot");
});

test("skill and goal arguments keep every character and inline attachment position", () => {
  const draft = "before \uFFFCfile%3A1\uFFFC after\n\nlast paragraph";
  expect(newTabCommandDraft({ name: "review", description: "" }, draft)).toBe(`/review ${draft}`);
});
