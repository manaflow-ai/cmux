import { describe, expect, it, vi } from "vitest";
import {
  beginTerminalSelection,
  clampTerminalSelection,
  releaseTerminalSelection,
} from "../src/lib/terminalSelection";

function fixture() {
  const shell = document.createElement("main");
  shell.className = "app-shell";
  const first = document.createElement("div");
  const second = document.createElement("div");
  first.className = "render-terminal-host";
  second.className = "render-terminal-host";
  shell.append(first, second);
  return { shell, first, second };
}

describe("terminal selection ownership", () => {
  it("keeps exactly one terminal selectable and clears the previous range", () => {
    const { shell, first, second } = fixture();
    const selection = { removeAllRanges: vi.fn() } as unknown as Selection;

    beginTerminalSelection(first, selection);
    beginTerminalSelection(second, selection);

    expect(shell).toHaveClass("terminal-selection-active");
    expect(first).not.toHaveClass("terminal-selection-owner");
    expect(second).toHaveClass("terminal-selection-owner");
    expect(selection.removeAllRanges).toHaveBeenCalledTimes(2);
  });

  it("releases the shell only when its owner unmounts", () => {
    const { shell, first, second } = fixture();
    const selection = { removeAllRanges: vi.fn() } as unknown as Selection;
    beginTerminalSelection(first, selection);

    releaseTerminalSelection(second);
    expect(shell).toHaveClass("terminal-selection-active");
    releaseTerminalSelection(first);
    expect(shell).not.toHaveClass("terminal-selection-active");
  });

  it("clamps a cross-pane range to the originating terminal", () => {
    const { shell, first, second } = fixture();
    const firstGrid = document.createElement("div");
    const secondGrid = document.createElement("div");
    firstGrid.className = "render-grid";
    secondGrid.className = "render-grid";
    firstGrid.textContent = "first terminal";
    secondGrid.textContent = "second terminal";
    first.append(firstGrid);
    second.append(secondGrid);
    document.body.append(shell);
    const selection = window.getSelection()!;
    beginTerminalSelection(first, selection);
    selection.setBaseAndExtent(firstGrid.firstChild!, 6, secondGrid.firstChild!, 6);

    clampTerminalSelection(first, selection);

    expect(selection.toString()).toBe("terminal");
    expect(first.contains(selection.focusNode)).toBe(true);
    shell.remove();
  });
});
