import { expect, test } from "bun:test";
import { commandText, composerCommandRoute } from "./commandRouting";

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
  expect(composerCommandRoute("!   ")).toBeNull();
});
