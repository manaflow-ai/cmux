import { describe, expect, test } from "bun:test";
import { terminalInputSurfaceIdsForScene } from "../app/share/[shareId]/ShareWorkspaceConnection";
import type { WorkspaceScene } from "../services/share/protocol";
import {
  MAX_TERMINAL_INPUT_BYTES,
  terminalCommandForKeyboardEvent,
  terminalCommandsFromText,
  terminalInputPayload,
  validTerminalInputCommand,
} from "../services/share/terminalInput";

const surfaceA = "72C552A7-8F75-4DF3-AC47-3750D01D0C18";
const hiddenA = "3C819442-134F-486E-8CB8-D408FA65A549";
const surfaceB = "8489FC65-5D32-4012-8200-6FC9DAB557B5";

const keyboard = (key: string, overrides: Partial<{
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  isComposing: boolean;
}> = {}) => ({
  key,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  metaKey: false,
  isComposing: false,
  ...overrides,
});

describe("shared terminal input", () => {
  test("maps navigation and Ctrl chords without claiming printable or IME input", () => {
    expect(terminalCommandForKeyboardEvent(keyboard("Enter"))).toEqual({ kind: "key", data: "enter" });
    expect(terminalCommandForKeyboardEvent(keyboard("Tab", { shiftKey: true }))).toEqual({ kind: "key", data: "shift-tab" });
    expect(terminalCommandForKeyboardEvent(keyboard("ArrowLeft"))).toEqual({ kind: "key", data: "left" });
    expect(terminalCommandForKeyboardEvent(keyboard("Delete"))).toEqual({ kind: "key", data: "delete" });
    expect(terminalCommandForKeyboardEvent(keyboard("C", { ctrlKey: true }))).toEqual({ kind: "key", data: "ctrl-c" });
    expect(terminalCommandForKeyboardEvent(keyboard("V", { ctrlKey: true, shiftKey: true }))).toBeNull();
    expect(terminalCommandForKeyboardEvent(keyboard("x"))).toBeNull();
    expect(terminalCommandForKeyboardEvent(keyboard("v", { metaKey: true }))).toBeNull();
    expect(terminalCommandForKeyboardEvent(keyboard("Process", { isComposing: true }))).toBeNull();
  });

  test("splits paste controls into bounded semantic input", () => {
    const commands = terminalCommandsFromText(`echo one\r\necho two\t${"🙂".repeat(MAX_TERMINAL_INPUT_BYTES / 4 + 1)}`);
    expect(commands.slice(0, 4)).toEqual([
      { kind: "text", data: "echo one" },
      { kind: "key", data: "enter" },
      { kind: "text", data: "echo two" },
      { kind: "key", data: "tab" },
    ]);
    expect(commands.every(validTerminalInputCommand)).toBe(true);
    expect(commands.filter((command) => command.kind === "text").every((command) =>
      new TextEncoder().encode(command.data).byteLength <= MAX_TERMINAL_INPUT_BYTES)).toBe(true);
  });

  test("binds input to an exact surface and authoritative layout revision", () => {
    expect(terminalInputPayload(surfaceA, 14, { kind: "key", data: "ctrl-d" })).toEqual({
      surfaceId: surfaceA,
      layoutRevision: 14,
      kind: "key",
      data: "ctrl-d",
    });
    expect(terminalInputPayload("terminal", 14, { kind: "key", data: "enter" })).toBeNull();
    expect(terminalInputPayload(surfaceA, -1, { kind: "key", data: "enter" })).toBeNull();
  });

  test("authorizes only the selected terminal in each split", () => {
    const scene: WorkspaceScene = {
      workspaceId: "workspace",
      workspaceTitle: "Workspace",
      layoutRevision: 4,
      width: 1_000,
      height: 700,
      panes: [
        {
          id: "left",
          frame: { x: 0, y: 0, width: 500, height: 700 },
          selectedSurfaceId: surfaceA,
          surfaces: [
            { id: hiddenA, title: "Hidden", kind: "terminal" },
            { id: surfaceA, title: "Left", kind: "textbox", docId: surfaceA },
          ],
        },
        {
          id: "right",
          frame: { x: 500, y: 0, width: 500, height: 700 },
          selectedSurfaceId: surfaceB,
          surfaces: [{ id: surfaceB, title: "Right", kind: "terminal" }],
        },
      ],
    };

    expect([...terminalInputSurfaceIdsForScene(scene)]).toEqual([surfaceA, surfaceB]);
    expect(terminalInputSurfaceIdsForScene(scene).has(hiddenA)).toBe(false);
  });
});
