// l10n-allow-file: test fixture prompts and host words, not shipped UI.
import { expect, test } from "bun:test";
import { cloudRefusalText, cloudStartBegun, cloudStartEnded, cloudStartPushed } from "./cloudStartProgress";

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

// The Swift bridge nests seed_* timestamps under clone; they must not start
// the machine or harness clocks, including on failed and cached copies.
test("forwarded copy timestamps stay on the clone row", () => {
  for (const [state, phase] of [
    ["done", "complete"],
    ["done", "cached"],
    ["failed", "copy"],
  ] as const) {
    const pushed = cloudStartPushed(begun(), {
      key: "k-1",
      step: "folder",
      clone: { state, phase, startedAt: 1000, finishedAt: 3500 },
    });
    expect(pushed?.clone).toEqual({ state, phase, startedAt: 1000, finishedAt: 3500 });
    expect(pushed?.machineStartedAt).toBeUndefined();
    expect(pushed?.harnessStartedAt).toBeUndefined();
  }
});

test("a copy's files and bytes, its fallback and an https install link reach the clone row", () => {
  const pushed = cloudStartPushed(begun(), {
    key: "k-1",
    step: "folder",
    clone: {
      state: "running",
      phase: "copy",
      fallback: "seed.needs_github",
      install_url: "https://github.com/apps/cmux/installations/new",
      progress: { received_bytes: 10, bytes_total: 20, files_done: 1, files_total: 2 },
    },
  });
  expect(pushed?.clone).toEqual({
    state: "running",
    phase: "copy",
    fallback: "seed.needs_github",
    installUrl: "https://github.com/apps/cmux/installations/new",
    progress: { receivedBytes: 10, bytesTotal: 20, filesDone: 1, filesTotal: 2 },
  });
  // The final answer keeps why the seed copied; it does not repeat it.
  const ended = cloudStartPushed(pushed, { key: "k-1", step: "folder", clone: { state: "done", phase: "complete" } });
  expect(ended?.clone).toEqual({
    state: "done",
    phase: "complete",
    fallback: "seed.needs_github",
    installUrl: "https://github.com/apps/cmux/installations/new",
  });
  const unsafe = cloudStartPushed(begun(), {
    key: "k-1",
    step: "folder",
    clone: { state: "running", install_url: "javascript:alert(1)" },
  });
  expect(unsafe?.clone?.installUrl).toBeUndefined();
});

test("forwards the environment id and setup ran or cached state", () => {
  const ran = cloudStartPushed(begun(), {
    key: "k-1",
    step: "folder",
    environmentId: "denv_0123456789abcdef01234567",
    setup: { state: "done", started_at: 1000, finished_at: 3500 },
  });
  expect(ran?.environmentId).toBe("denv_0123456789abcdef01234567");
  expect(ran?.setup).toEqual({ state: "done", startedAt: 1000, finishedAt: 3500 });

  const cached = cloudStartPushed(begun(), {
    key: "k-1",
    setup: { state: "done", status: "ready" },
  });
  expect(cached?.setup).toEqual({ state: "done", status: "ready" });
});

test("a start this Mac's pane refused says why by its code, never the generic connection refusal", () => {
  const generic = "The app refused the agent connection.";
  const outside = cloudStartEnded(begun(), "k-1", {
    ok: false,
    code: "transport.path_outside_roots",
    message: generic,
  });
  expect(outside).toEqual({
    ...begun(),
    state: "failed",
    message: "This folder isn't open in this tab; pick it to send it to Cloud.",
    refusedHere: true,
  });
  const gesture = cloudStartEnded(begun(), "k-1", { ok: false, code: "transport.gesture_required", message: generic });
  expect(gesture?.message).toBe(cloudRefusalText("transport.gesture_required"));
  expect(gesture?.message).not.toBe(generic);
  expect(gesture?.refusedHere).toBe(true);
  // The App's own failure keeps the host's words and its checklist step.
  expect(
    cloudStartEnded(begun(), "k-1", { ok: false, code: "cloud_start_failed", message: "No machine" })?.refusedHere,
  ).toBeUndefined();
});

test("a gone, home or credential folder each says why, naming the credential folder (cmux#35005, cmux#35006)", () => {
  const ended = (code: string, message: string) => cloudStartEnded(begun(), "k-1", { ok: false, code, message });
  expect(ended("cloud_folder_missing", "cloud_folder_missing")).toEqual({
    ...begun(),
    state: "failed",
    message: "This folder no longer exists; pick another one to send to Cloud.",
    refusedHere: true,
  });
  expect(ended("cloud_folder_home", "cloud_folder_home")?.message).toBe(
    "Cloud doesn't copy your home folder or a folder above it; pick a project folder.",
  );
  const secret = ended("cloud_folder_secret", "~/.ssh");
  expect(secret?.message).toBe("Cloud never copies ~/.ssh, which holds keys or credentials; pick a project folder.");
  expect(secret?.refusedHere).toBe(true);
  for (const code of ["cloud_folder_missing", "cloud_folder_home", "cloud_folder_secret"])
    expect(ended(code, "x")?.message).not.toBe(cloudRefusalText("transport.path_outside_roots"));
});

test("the pane's other refusals before Cloud (attachments, a busy pane) mark no step failed, as Swift counts them", () => {
  const attachment =
    "This attachment needs a local file. Run this chat on This Mac, or paste an image or text to send it to Cloud.";
  expect(cloudStartEnded(begun(), "k-1", { ok: false, code: "cloud_attachments", message: attachment })).toEqual({
    ...begun(),
    state: "failed",
    message: attachment,
    refusedHere: true,
  });
  for (const code of ["unsupported", "unavailable_now", "sandbox_busy", "sandbox_spent"]) {
    const ended = cloudStartEnded(begun(), "k-1", { ok: false, code, message: code });
    expect(ended?.refusedHere).toBe(true);
    expect(ended?.message).not.toBe(code);
  }
});
