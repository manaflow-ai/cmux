// l10n-allow-file: test fixtures (raw error text the pane must never show).
// Audit 2026-11-12 (Leo: "we want good error states. We don't want busted errors."): each pane
// surface that printed a caught error's own text says what happened in plain words instead, with
// the pane's own reason only when it words one. plainErrors.test.ts is the scan over every source;
// these pin the words each surface says.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { createNoticeQueue } from "../../ui/NoticeStack";
import { HandoffClient } from "./handoff/client";
import { HANDOFF_OPS } from "./handoff/protocol";
import { translate } from "./i18n";
import { paneNotices } from "./paneToasts";
import { shareFailureText } from "./share/ShareControl";
import { knownRefusalText, switchFailedText } from "./transportErrors";
import { failedAsk } from "./useFolderTrustAsk";

const RAW = "peer_unreachable: box (reconnecting, last seen 10s ago: WebSocket protocol error)";

const warn = console.warn;
beforeEach(() => {
  console.warn = () => undefined;
});
afterEach(() => {
  console.warn = warn;
});

test("a failure toast is drawn as an error; other feedback stays a plain toast", () => {
  const toasts = createNoticeQueue();
  const notices = paneNotices({ transcript: () => undefined, toasts });
  notices.failed(translate("watch.takeOverFailed"));
  notices.transient(translate("notice.forkNothingYet"));
  expect(toasts.snapshot().map((entry) => [entry.spec.message, entry.spec.kind])).toEqual([
    [translate("watch.takeOverFailed"), "error"],
    [translate("notice.forkNothingYet"), undefined],
  ]);
});

test("only the pane's own words count as a reason", () => {
  expect(knownRefusalText(new Error(RAW))).toBeUndefined();
  expect(knownRefusalText(new Error("Failed to fetch"))).toBeUndefined();
  expect(knownRefusalText("Error: socket hang up")).toBeUndefined();
  expect(knownRefusalText({ code: "transport.gesture_required" })).toBe(translate("transport.gestureRequired"));
  expect(knownRefusalText({ reason: "trust.pending" })).toBe(translate("error.trustPending"));
  expect(knownRefusalText({ reason: "remote.session_cancel_ownership" })).toBe(translate("error.stopOwnerOnly"));
  // acpmux's reason is worded; its own message (written for the agent or the CLI) is not.
  expect(knownRefusalText(Object.assign(new Error(RAW), { reason: "subsessions.width_limit" }))).toBe(
    translate("error.subsessionsFull"),
  );
  expect(knownRefusalText(Object.assign(new Error(RAW), { reason: "remote.cwd_outside_roots" }))).toBe(
    translate("error.cwdOutsideRoots"),
  );
  expect(knownRefusalText(Object.assign(new Error(RAW), { reason: "subsessions.unworded" }))).toBeUndefined();
});

test("a refused mode or model pick never prints the agent's text or a bare ?", () => {
  expect(switchFailedText("mode", "plan", new Error(RAW))).toBe(translate("switch.modeFailedPlain", { mode: "plan" }));
  expect(switchFailedText("mode", "plan", new Error(""))).toBe(translate("switch.modeFailedPlain", { mode: "plan" }));
  expect(switchFailedText("model", "opus", new Error(RAW))).toBe(
    translate("switch.modelFailedPlain", { model: "opus" }),
  );
  // A refusal the pane words keeps its reason.
  expect(switchFailedText("mode", "bypass", { code: "transport.full_access_off" })).toBe(
    translate("switch.modeFailed", { mode: "bypass", reason: translate("transport.fullAccessOff") }),
  );
  expect(switchFailedText("mode", "plan", new Error(RAW))).not.toContain("?");
});

test("a trust answer that did not save shows no host text under Couldn't save that", () => {
  expect(failedAsk("/w", new Error(RAW))).toEqual({ cwd: "/w", state: "failed" });
  expect(failedAsk("/w", { reason: "trust.untrusted" })).toEqual({
    cwd: "/w",
    state: "failed",
    reason: translate("error.trustUntrusted"),
  });
});

test("a share refusal with an unknown code says That didn't finish. Try again.", () => {
  expect(shareFailureText(new Error("share: 500 Internal Server Error"))).toBe(translate("share.error.generic"));
  expect(shareFailureText({ code: "share.weird", message: "raw server words" })).toBe(translate("share.error.generic"));
  expect(shareFailureText({ code: "share.needs_sign_in" })).toBe(translate("share.error.signIn"));
});

test("a handoff request that failed shows the plain line, never the daemon's message", async () => {
  const client = new HandoffClient(
    async (method) => {
      if (method === HANDOFF_OPS.get) return null;
      throw new Error(RAW);
    },
    () => undefined,
  );
  client.select("s1");
  await client.refresh();
  await client.prepare("codex").catch(() => undefined);
  expect(client.state.error).toBe(translate("handoff.error.prepare"));
});
