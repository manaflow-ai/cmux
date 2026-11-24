// The composer's Resume control (Composer.tsx `canResume`) is offered only on an empty prompt, so a
// resume in flight never blocks typing: the first typed letter turns the slot back into Send, and
// Return sends or queues that draft as it would anyway. Leo, 2026-11-24 11:57Z, on input grayed out
// while a session reattaches; the input-block report (check-connection-notices.py --input-block)
// lists the Resume button's `disabled={resuming}`, which guards only its own request.
import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import { canResumeFromComposer } from "./resumeControl";

const stopped = {
  sessionId: "s1",
  connection: "live",
  origin: "local",
  isWorking: false,
  queue: [],
  summary: { sessionId: "s1" },
} as unknown as AcpmuxSnapshot;

const idle = {
  offered: true,
  blank: true,
  attachments: 0,
  pending: 0,
  shell: false,
  running: false,
  readOnly: false,
  blocked: false,
  dictating: false,
};

test("an empty prompt on a stopped session offers Resume", () => {
  expect(canResumeFromComposer(stopped, idle)).toBe(true);
});

test("a draft typed while the session resumes takes the slot back for Send", () => {
  expect(canResumeFromComposer(stopped, { ...idle, blank: false })).toBe(false);
  expect(canResumeFromComposer(stopped, { ...idle, attachments: 1 })).toBe(false);
});

test("Resume is not offered until the link is up", () => {
  for (const connection of ["connecting", "connecting:reattach", "disconnected"]) {
    expect(canResumeFromComposer({ ...stopped, connection } as AcpmuxSnapshot, idle)).toBe(false);
  }
});
