// One jump control (jumpControl.ts, design/transcript-overlays.md; Leo, 2026-11-10: "There's also no
// point doubling up on this"). Jump up was a second disc stacked on Jump to latest (#40326) that a
// lookup of the bare `.acpmux-jump-latest` class could find instead; it is now the same disc turned
// up (`data-jump="up"`, with `.acpmux-jump-up` while it is). So the transcript renders one button with
// that class, and no source draws a Jump up of its own.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const transcript = fs.readFileSync(path.join(root, "src/agent-session/acpmux/VirtualTranscript.tsx"), "utf8");
const shell = fs.readFileSync(path.join(root, "src/agent-session/acpmux/transcript/transcriptShell.tsx"), "utf8");
const buttons = fs.readFileSync(path.join(root, "src/agent-session/acpmux/transcript/JumpButtons.tsx"), "utf8");

test("the transcript draws one jump control, and no Jump up of its own", () => {
  for (const source of [transcript, shell, buttons]) {
    expect(source).not.toMatch(/export function JumpUp\b/);
    expect(source).not.toMatch(/<JumpUp\b/);
  }
  // The extracted shell mounts the shared control once; its two directions share one button.
  expect(shell.match(/<JumpToLatestMemo\b/g)?.length).toBe(1);
  // The one button carries the disc's class; Jump up is its `up` state.
  expect(buttons.match(/"ui-glass acpmux-jump-latest"/g)?.length).toBe(1);
  expect(buttons).toMatch(/data-jump=\{up \? "up" : "latest"\}/);
});

test("its CSS stacks no second disc over Jump to latest", () => {
  const css = fs.readFileSync(path.join(root, "src/agent-session/acpmux/jumpPair.css"), "utf8");
  expect(css).not.toMatch(/\.acpmux-jump-up[^{]*\{[^}]*bottom:/);
});
