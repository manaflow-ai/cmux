import { expect, test } from "bun:test";
import {
  commandText,
  ComposerCommandSubmissionGate,
  composerCommandRoute,
} from "./commandRouting";

test("explicit bang routes any non-empty command", () => {
  expect(composerCommandRoute("!git status")).toBe("explicit");
  expect(commandText("!git status")).toBe("git status");
});

test("high-confidence shell commands auto-route", () => {
  expect(composerCommandRoute("cd projects")).toBe("detected");
  expect(composerCommandRoute("pwd")).toBe("detected");
  expect(composerCommandRoute("./scripts/check.sh")).toBe("detected");
  expect(composerCommandRoute("git status")).toBeNull();
});

test("ordinary prose stays with the provider", () => {
  expect(composerCommandRoute("help me understand git branches")).toBeNull();
  expect(composerCommandRoute(". I need help with this")).toBeNull();
  expect(composerCommandRoute(".. can you inspect the parent directory?")).toBeNull();
  expect(composerCommandRoute("~ means home on Unix")).toBeNull();
  expect(composerCommandRoute("!   ")).toBeNull();
});

test("shell path prefixes remain high-confidence routes", () => {
  expect(composerCommandRoute("./scripts/check.sh")).toBe("detected");
  expect(composerCommandRoute("../scripts/check.sh")).toBe("detected");
  expect(composerCommandRoute("~/bin/check")).toBe("detected");
  expect(composerCommandRoute("/usr/bin/env")).toBe("detected");
});

test("command gate rejects duplicate submissions and preserves later drafts", () => {
  const gate = new ComposerCommandSubmissionGate();

  expect(gate.begin(4)).toBe(true);
  expect(gate.isPending).toBe(true);
  expect(gate.begin(4)).toBe(false);
  expect(gate.complete(4, 5)).toBe(false);
  expect(gate.isPending).toBe(false);

  expect(gate.begin(6)).toBe(true);
  expect(gate.complete(6, 6)).toBe(true);
  expect(gate.isPending).toBe(false);
});

test("command gate ignores stale completions and releases failures", () => {
  const gate = new ComposerCommandSubmissionGate();

  expect(gate.begin(10)).toBe(true);
  expect(gate.complete(9, 10)).toBe(false);
  expect(gate.isPending).toBe(true);
  expect(gate.fail(9)).toBe(false);
  expect(gate.fail(10)).toBe(true);
  expect(gate.isPending).toBe(false);
});
