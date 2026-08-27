import { describe, expect, it } from "vitest";
import { syncCanvasBackground } from "../src/lib/canvasTheme";

describe("canvas theme", () => {
  it("promotes the active render surface background to the app canvas", () => {
    const shell = document.createElement("main");
    shell.className = "app-shell";
    const host = document.createElement("div");
    shell.append(host);

    syncCanvasBackground(host, "#272822", true);

    expect(shell.style.getPropertyValue("--terminal-background")).toBe("#272822");
  });

  it("does not let an inactive pane replace the app canvas", () => {
    const shell = document.createElement("main");
    shell.className = "app-shell";
    shell.style.setProperty("--terminal-background", "#272822");
    const host = document.createElement("div");
    shell.append(host);

    syncCanvasBackground(host, "#000000", false);

    expect(shell.style.getPropertyValue("--terminal-background")).toBe("#272822");
  });
});
