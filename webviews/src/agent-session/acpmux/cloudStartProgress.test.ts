// l10n-allow-file: test fixture prompts and host words, not shipped UI.
import { expect, test } from "bun:test";
import type { CloudStartAsk } from "./cloudStartProgress";
import {
  cloudRefusalText,
  cloudStartAsk,
  cloudStartBegun,
  cloudStartEnded,
  cloudStartPushed,
  cloudStartSignedIn,
  cloudFolderTooBig,
  folderSizeText,
} from "./cloudStartProgress";

const begun = () => cloudStartBegun("k-1", "fix the build", "/Users/me/src/paint/");

test("a start shows the message and the folder by its name", () => {
  expect(begun()).toEqual({ key: "k-1", task: "fix the build", state: "starting", folder: "paint" });
  expect(cloudStartBegun("k", "t", undefined)).toEqual({ key: "k", task: "t", state: "starting" });
});

test("a start waiting on its browser sign-in is marked until it signs in or ends", () => {
  const waiting = cloudStartBegun("k-1", "fix the build", "/Users/me/src/paint/", undefined, undefined, true);
  expect(waiting).toEqual({ ...begun(), signingIn: true });
  // Signed in: the same start goes on, no longer waiting.
  expect(cloudStartSignedIn(waiting, "k-1")).toEqual(begun());
  // Another start's sign-in, or a start that never waited, is unchanged.
  expect(cloudStartSignedIn(waiting, "k-2")).toBe(waiting);
  expect(cloudStartSignedIn(begun(), "k-1")).toEqual(begun());
  // A sign-in that failed or timed out ends the wait: the card offers sign in again.
  const ended = cloudStartEnded(waiting, "k-1", { ok: false, code: "not_signed_in", message: "Sign-in timed out." });
  expect(ended?.state).toBe("failed");
  expect(ended?.code).toBe("not_signed_in");
  expect(ended?.signingIn).toBeUndefined();
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
  ).toEqual({ ...begun(), state: "failed", code: "cloud_start_failed", message: "No machine free" });
  expect(cloudStartEnded(begun(), "k-1", { ok: false, code: "unavailable" })).toEqual({
    ...begun(),
    state: "failed",
    code: "unavailable",
  });
  expect(
    cloudStartEnded(begun(), "k-1", { ok: false, code: "cloud_plan_required", message: "Upgrade to use Cloud" }),
  ).toEqual({ ...begun(), state: "failed", code: "cloud_plan_required", message: "Upgrade to use Cloud" });
  expect(cloudStartEnded(begun(), "k-2", { ok: true })).toEqual(begun());
  expect(cloudStartEnded(undefined, "k-1", { ok: true })).toBeUndefined();
});

test("a chat opened during sign-in keeps its specific recovery message", () => {
  expect(
    cloudStartEnded(begun(), "k-1", {
      ok: false,
      code: "cloud_chat_already_started",
      message: "A chat opened while you were signing in. This prompt was not sent to Cloud.",
    }),
  ).toEqual({
    ...begun(),
    state: "failed",
    code: "cloud_chat_already_started",
    message: "A chat opened while you were signing in. This prompt was not sent to Cloud.",
  });
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
    code: "transport.path_outside_roots",
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
    code: "cloud_folder_missing",
    message: "This folder no longer exists; pick another one to send to Cloud.",
    refusedHere: true,
  });
  expect(ended("cloud_folder_home", "cloud_folder_home")?.message).toBe(
    "Cloud doesn't copy your home folder or a folder above it; pick another folder.",
  );
  const secret = ended("cloud_folder_secret", "~/.ssh");
  expect(secret?.message).toBe("Cloud never copies ~/.ssh, which holds keys or credentials; pick another folder.");
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
    code: "cloud_attachments",
    message: attachment,
    refusedHere: true,
  });
  for (const code of ["unsupported", "unavailable_now", "sandbox_busy", "sandbox_spent"]) {
    const ended = cloudStartEnded(begun(), "k-1", { ok: false, code, message: code });
    expect(ended?.refusedHere).toBe(true);
    expect(ended?.message).not.toBe(code);
  }
});

// Leo 2026-11-10: "Cloud isn't available for this chat" said no reason and offered nothing.
test("the host's not-now refusal says a chat is starting in this tab and how to use Cloud instead", () => {
  const text = cloudRefusalText("unavailable_now");
  expect(text).toBe("A chat is already starting in this tab. Open a new chat to start one in Cloud.");
  expect(text).not.toContain("isn't available");
});

const question: CloudStartAsk = {
  id: "ask-1",
  kind: "codexDevice",
  title: "Sign in to Codex",
  lines: ["Enter this one-time code: WXYZ-1234"],
  buttons: [
    { id: "cancel", title: "Cancel", role: "cancel" },
    { id: "signedIn", title: "I signed in", role: "default" },
  ],
  code: "WXYZ-1234",
  link: { url: "https://auth.openai.com/codex/device", title: "Open sign-in" },
};

test("the host's question shows in the card and leaves it when the host takes it away", () => {
  const asked = cloudStartPushed(begun(), { key: "k-1", ask: question });
  expect(asked?.ask).toEqual(question);
  expect(cloudStartPushed(asked, { key: "k-1", step: "folder" })?.ask).toEqual(question);
  expect(cloudStartPushed(asked, { key: "k-1", ask: null })).toEqual(begun());
  // Another start's question, or one after the start failed, shows nothing.
  expect(cloudStartPushed(begun(), { key: "k-2", ask: question })).toEqual(begun());
  const failed = cloudStartEnded(begun(), "k-1", { ok: false, code: "cloud_start_failed", message: "x" });
  expect(cloudStartPushed(failed, { key: "k-1", ask: question })?.ask).toBeUndefined();
});

test("a malformed question changes nothing, and a field it can't trust is left out", () => {
  const asked = cloudStartPushed(begun(), { key: "k-1", ask: question });
  for (const bad of [
    { ...question, kind: "password" },
    { ...question, id: "" },
    { ...question, title: "" },
    { ...question, buttons: [] },
    { ...question, buttons: [{ id: "", title: "X", role: "default" }] },
    "ask",
  ]) {
    expect(cloudStartAsk(bad)).toBeUndefined();
    expect(cloudStartPushed(asked, { key: "k-1", ask: bad })?.ask).toEqual(question);
  }
  // A page that is not https is never linked; an unknown role draws as a plain button; at most four.
  expect(cloudStartAsk({ ...question, link: { url: "javascript:alert(1)", title: "Open" } })?.link).toBeUndefined();
  expect(cloudStartAsk({ ...question, buttons: [{ id: "x", title: "X", role: "danger" }] })?.buttons).toEqual([
    { id: "x", title: "X", role: "normal" },
  ]);
  const many = Array.from({ length: 6 }, (_, i) => ({ id: `b${i}`, title: "B", role: "normal" }));
  expect(cloudStartAsk({ ...question, buttons: many })?.buttons).toHaveLength(4);
});

test("a failed start drops its question and says whether Retry can help", () => {
  const asked = cloudStartPushed(begun(), { key: "k-1", ask: question });
  const retry = cloudStartEnded(asked, "k-1", {
    ok: false,
    code: "cloud_start_failed",
    message: "Slow",
    retryable: true,
  });
  expect(retry).toEqual({ ...begun(), state: "failed", code: "cloud_start_failed", message: "Slow", retryable: true });
  const final = cloudStartEnded(asked, "k-1", { ok: false, code: "cloud_start_failed", message: "No" });
  expect(final?.retryable).toBeUndefined();
  expect(final?.ask).toBeUndefined();
});

test("a start the team's spending cap or the member's budget refused is worded by the pane, with no Retry", () => {
  const cap = cloudStartEnded(begun(), "k-1", {
    ok: false,
    code: "cloud_start_failed",
    message: "this team has spent 503.10 USD of its 500.00 USD spending cap; an admin can raise it",
    retryable: true,
  });
  expect(cap).toMatchObject({ state: "failed", code: "cloud_spend_cap" });
  expect(cap?.retryable).toBeUndefined();
  expect(cap?.message).toContain("team admin");
  const budget = cloudStartEnded(begun(), "k-1", {
    ok: false,
    code: "cloud_start_failed",
    message: "you have spent 50.20 USD of your 50.00 USD monthly budget; a team admin can raise it",
  });
  expect(budget).toMatchObject({ state: "failed", code: "cloud_member_budget" });
  // Any other failure keeps the host's words.
  expect(
    cloudStartEnded(begun(), "k-1", {
      ok: false,
      code: "cloud_start_failed",
      message: "the machine stopped answering",
    }),
  ).toMatchObject({ code: "cloud_start_failed", message: "the machine stopped answering" });
});

test("a folder too big to copy says why with its size, offers no Retry and marks no step failed (Leo, 2026-11-10)", () => {
  const gib = 1024 ** 3;
  const details = {
    folder: "~/Projects",
    bytes: 20.1 * gib,
    files: 323_831,
    repos: [
      { name: "cmux", path: "/Users/me/Projects/cmux" },
      { name: "work/api", path: "/Users/me/Projects/work/api" },
      { name: "relative", path: "not/absolute" },
      { name: "", path: "/Users/me/Projects/empty" },
    ],
    more: false,
  };
  const ended = cloudStartEnded(begun(), "k-1", {
    ok: false,
    code: "cloud_folder_too_big",
    message: "~/Projects is too big to copy to a Cloud machine",
    retryable: true,
    details,
  });
  expect(ended?.state).toBe("failed");
  expect(ended?.code).toBe("cloud_folder_too_big");
  expect(ended?.retryable).toBeUndefined();
  expect(ended?.refusedHere).toBe(true);
  // Only well-formed repositories with absolute paths are offered.
  expect(ended?.tooBig).toEqual({
    folder: "~/Projects",
    repos: [
      { name: "cmux", path: "/Users/me/Projects/cmux" },
      { name: "work/api", path: "/Users/me/Projects/work/api" },
    ],
    more: false,
  });
  expect(ended?.message).toBe(
    "~/Projects is too big to copy to a Cloud machine (at least 20.1 GB in 323,831 files). It holds repositories of its own: pick one to start in, or start without a folder.",
  );
  // No repository inside: the limit is named, and another folder is the way on.
  const plain = cloudStartEnded(begun(), "k-1", {
    ok: false,
    code: "cloud_folder_too_big",
    details: { ...details, folder: "~/Downloads", repos: [] },
  });
  expect(plain?.message).toBe(
    "~/Downloads is too big to copy to a Cloud machine (at least 20.1 GB in 323,831 files; a copy sends at most 20 GB or 500,000 files). Pick a smaller folder, or start without a folder.",
  );
});

test("a too-big folder's size reads as the copy's limit words it", () => {
  expect(folderSizeText(20.1 * 1024 ** 3)).toBe("20.1 GB");
  expect(folderSizeText(20 * 1024 ** 3)).toBe("20 GB");
  expect(folderSizeText(632 * 1024 ** 3)).toBe("632 GB");
  expect(folderSizeText(300 * 1024 ** 2)).toBe("300 MB");
  // Malformed details still say why, with no repository to offer.
  expect(cloudFolderTooBig(undefined).tooBig).toEqual({ folder: "~", repos: [], more: false });
});
