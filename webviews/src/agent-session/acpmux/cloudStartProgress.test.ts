// l10n-allow-file: test fixture prompts and host words, not shipped UI.
import { expect, test } from "bun:test";
import { cloudStartBegun, cloudStartEnded, cloudStartPushed } from "./cloudStartProgress";

const begun = () => cloudStartBegun("k-1", "fix the build", "/Users/me/src/paint/");

test("a start shows the message and the folder by its name", () => {
  expect(begun()).toEqual({ key: "k-1", task: "fix the build", state: "starting", folder: "paint" });
  expect(cloudStartBegun("k", "t", undefined)).toEqual({ key: "k", task: "t", state: "starting" });
});

test("the host's push fills the card, field by field, each checked", () => {
  const pushed = cloudStartPushed(begun(), {
    key: "k-1",
    step: "folder",
    folder: "paint-app",
    machine: "  paint   machine ",
    size: "4 CPU, 16 GB",
    secrets: 3,
    network: "limited",
    token: "never shown",
  });
  expect(pushed).toEqual({
    key: "k-1",
    task: "fix the build",
    state: "starting",
    folder: "paint-app",
    step: "folder",
    machine: "paint machine",
    size: "4 CPU, 16 GB",
    secrets: 3,
    network: "limited",
  });
  const odd = cloudStartPushed(begun(), { key: "k-1", step: "done", secrets: -1, network: "open", machine: 7 });
  expect(odd).toEqual(begun());
  expect(cloudStartPushed(begun(), { key: "k-1", machine: "x".repeat(100) })?.machine).toHaveLength(64);
  expect(cloudStartPushed(begun(), { key: "k-1", folder: "/Users/me/src" })?.folder).toBe("paint");
});

test("a step never goes back, and another start's push or a push after a failure changes nothing", () => {
  const opening = cloudStartPushed(begun(), { key: "k-1", step: "opening" });
  expect(cloudStartPushed(opening, { key: "k-1", step: "machine" })?.step).toBe("opening");
  expect(cloudStartPushed(begun(), { key: "k-2", step: "folder" })).toEqual(begun());
  const failed = cloudStartEnded(begun(), "k-1", { ok: false, code: "cloud_start_failed", message: "No machine" });
  expect(cloudStartPushed(failed, { key: "k-1", step: "folder" })).toBe(failed);
  expect(cloudStartPushed(undefined, { key: "k-1" })).toBeUndefined();
  expect(cloudStartPushed(begun(), null)).toEqual(begun());
});

test("the start's answer: an opened chat clears the card, a failure keeps it with the host's words", () => {
  expect(cloudStartEnded(begun(), "k-1", { ok: true })).toBeUndefined();
  expect(
    cloudStartEnded(begun(), "k-1", { ok: false, code: "cloud_start_failed", message: "No machine\nfree" }),
  ).toEqual({ ...begun(), state: "failed", message: "No machine free" });
  expect(cloudStartEnded(begun(), "k-1", { ok: false, code: "unavailable" })).toEqual({ ...begun(), state: "failed" });
  expect(cloudStartEnded(begun(), "k-2", { ok: true })).toEqual(begun());
  expect(cloudStartEnded(undefined, "k-1", { ok: true })).toBeUndefined();
});

test("a start with no project carries home, and the agent's name for the opening step", () => {
  expect(cloudStartBegun("k", "hi", undefined, "Claude Code", true)).toEqual({
    key: "k",
    task: "hi",
    state: "starting",
    agent: "Claude Code",
    home: true,
  });
  expect(cloudStartBegun("k", "hi", "/Users/me/paint").home).toBeUndefined();
});
