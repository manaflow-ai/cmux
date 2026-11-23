import { describe, expect, test } from "bun:test";
import { commandWorkLabel } from "./commandWorkLabel";

describe("commandWorkLabel", () => {
  test("names a setup substitution, then the program that does the work", () => {
    expect(commandWorkLabel("SHA=$(git rev-parse HEAD); cmux-ci run --ref $SHA --script x.sh")).toBe(
      "git rev-parse HEAD · cmux-ci run",
    );
  });

  test("a polling loop names its work once, never the shell grammar, pauses or log lines", () => {
    // Leo, 2026-11-21, on a tray row reading "pgrep · head · ps · until · do sleep 15 · done · sleep 70 · echo me…".
    const loop =
      'until [ -z "$(pgrep -f worker.sh | head -1)" ] && [ -z "$(ps -o pid= -p 4242)" ]; do sleep 15; done; sleep 70; echo measured';
    expect(commandWorkLabel(loop)).toBe("pgrep · head · ps");
  });

  test("more than three operations end in an ellipsis", () => {
    expect(
      commandWorkLabel('while [ -n "$(pgrep x)" ]; do sleep 5; done; git fetch origin; git status; finish-up now'),
    ).toBe("pgrep x · git fetch origin · git status …");
  });

  test("a note written to a file is still named", () => {
    expect(commandWorkLabel('echo "$(date)" > stamp.txt')).toBe("date · echo");
  });
});
