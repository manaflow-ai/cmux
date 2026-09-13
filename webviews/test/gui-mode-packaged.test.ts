import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { GuiModeContext } from "../src/gui-mode/bridge";
import { guiModeFallbackProviders } from "./fixtures/guiModeProviders";

const repoRoot = resolve(import.meta.dir, "../..");
const context: GuiModeContext = {
  page: "home",
  prompt: "",
  selectedProviderId: "codex",
  providers: guiModeFallbackProviders,
  copy: {
    homeTitle: "Packaged GUI Mode",
    taskTitle: "GUI Task",
    promptPlaceholder: "Describe a task",
    submit: "Submit",
    submitting: "Submitting",
    cancel: "Cancel",
    cancellationUnconfirmed: "Could not confirm cancellation. Try Cancel again before submitting another task.",
    providerLabel: "Agent",
    providerSearchPlaceholder: "Search agents",
    noProvidersFound: "No agents found",
    runtimeLabel: "Runtime",
    setupCommandLabel: "Setup",
    taskCommandLabel: "Launch",
    taskPromptLabel: "Prompt",
    errorMessage: "Could not create the GUI workspace.",
  },
};

test("packaged GUI boots its real script and displays the native composer context", () => {
  const fixture = mkdtempSync(join(tmpdir(), "cmux-gui-package-"));
  const assetRoot = join(fixture, "markdown-viewer");
  const appRoot = join(assetRoot, "webviews-app");
  try {
    cpSync(join(repoRoot, "Resources/markdown-viewer/webviews-app"), appRoot, { recursive: true });
    execFileSync("sh", [join(repoRoot, "scripts/compress-markdown-viewer-assets.sh"), assetRoot]);
    // Use Node for JSDOM's file dispatcher; Bun's undici shim cannot load file URLs.
    const result = JSON.parse(execFileSync("node", [
      join(import.meta.dir, "fixtures/boot-gui-mode.mjs"),
      join(appRoot, "gui-mode.html"),
    ], { input: JSON.stringify(context), encoding: "utf8", timeout: 8000 }));
    expect(result.errors).toEqual([]);
    expect(result.requests).toContain("app.context");
    expect(result.title).toBe(context.copy.homeTitle);
    expect(result.hasEditor).toBe(true);
    expect(result.selectedProvider).toBe("codex");
    expect(result.submitDisabled).toBe(true);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
