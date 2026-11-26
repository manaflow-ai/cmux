import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { SEND_ICONS } from "../composer/sendMenuModel";
import { forkMenuRows } from "../header/forkMenu";
import { FORK_ICON } from "./forkIcon";

const repoRoot = fileURLToPath(new URL("../../../../../", import.meta.url));
const webSrc = join(repoRoot, "webviews/src");
const read = (path: string) => readFileSync(join(repoRoot, path), "utf8");

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === "node_modules" ? [] : sources(path);
    return /\.(ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name) ? [path] : [];
  });
}

// Leo 2026-11-09: "and this fork symbol is so bad". Every surface that offers or marks a fork draws the one glyph.
describe("the fork glyph", () => {
  test("is the pack's agent.fork", () => {
    expect(FORK_ICON).toBe("agent.fork");
  });

  // Leo 2026-11-22: "dont get cute about it; let's just do claude and codex's symbol for branching/forking
  // chats". The split arrow: no git nodes, a stem running on up and right, a detached arm down and right.
  test("is the split arrow, not a git mark", () => {
    const pack = JSON.parse(read("webviews/src/agent-session/acpmux/icons/cmuxIcons.json")) as {
      icons: Record<string, { line: { d: string; op: string }[]; solid: { d: string; op: string }[] }>;
    };
    const fork = pack.icons[FORK_ICON];
    const arrow = "M3.5 12L11.5 12L20.5 3M15.5 3L20.5 3L20.5 8M14.5 15L20.5 21M20.5 16L20.5 21L15.5 21";
    for (const layers of [fork.line, fork.solid]) {
      expect(layers.map((layer) => [layer.op, layer.d])).toEqual([["stroke", arrow]]);
    }
  });

  test("the web surfaces name it through FORK_ICON, never a literal or another glyph", () => {
    const literal = sources(webSrc)
      .filter((path) => !path.endsWith("icons/forkIcon.ts") && read(relative(repoRoot, path)).includes('"agent.fork"'))
      .map((path) => relative(webSrc, path));
    expect(literal).toEqual([]);
    for (const path of [
      "agent-session/acpmux/conversation/icons.tsx",
      "agent-session/acpmux/ModelPicker.tsx",
      "agent-session/acpmux/composer/sendMenuModel.ts",
      "agent-session/acpmux/header/forkMenu.ts",
    ]) {
      expect(read(`webviews/src/${path}`)).toContain("FORK_ICON");
    }
    expect(read("webviews/src/agent-session/acpmux/conversation/icons.tsx")).toContain(
      "TurnFork = ({ size = 14 }: CvIconProps = {}) => <Icon name={FORK_ICON}",
    );
    expect(SEND_ICONS.side).toBe(FORK_ICON);
    const rows = forkMenuRows(
      1,
      () => undefined,
      (key) => key,
    );
    expect(rows.map((row) => (row === "separator" ? row : row.icon))).toEqual([FORK_ICON, FORK_ICON]);
  });

  // The app names SF arrow.branch for every fork row and the catalog draws the pack's fork in its place
  // (NSImage.packOverride: the palette, hand-built menus). Nothing else may name arrow.branch.
  test("the app's fork rows name the one symbol the catalog draws as the fork", () => {
    const symbol = "arrow.branch";
    const catalog = JSON.parse(read("Packages/macOS/CmuxNext/Sources/CmuxNextIcons/Resources/icon-catalog.json")) as {
      icons: { name: string; sf?: string; overrides?: string[] }[];
    };
    expect(catalog.icons.filter((icon) => icon.overrides?.includes(symbol)).map((icon) => icon.name)).toEqual([
      FORK_ICON,
    ]);
    expect(catalog.icons.find((icon) => icon.name === FORK_ICON)?.sf).toBe(symbol);
    // Catalog-built right-click rows draw the override too (ActionRegistry.symbolOverride, which the App passes).
    expect(read("Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift")).toContain(
      "warmingOn: mainWork, symbolOverride: NSImage.packOverride)",
    );
    expect(read("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneContextMenu.swift")).toContain(
      `AgentPaneMenuStrings.forkFromHere, symbol: "${symbol}"`,
    );
    expect(read("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentForkMenu.swift")).toContain(
      `AgentPaneContextMenu.icon("${symbol}")`,
    );
    const actions = (
      JSON.parse(read("plans/cmux-next/action-catalog.json")) as { actions: { id: string; symbol: string }[] }
    ).actions;
    expect(actions.filter((action) => action.symbol === symbol).map((action) => action.id)).toEqual([
      "palette.forkAgentConversation",
      "palette.cloud.fork",
    ]);
    for (const [path, id] of [
      ["cmux-tui/crates/cmux-action-catalog/src/catalog/agent.rs", "palette.forkAgentConversation"],
      ["cmux-tui/crates/cmux-action-catalog/src/catalog/cloud.rs", "palette.cloud.fork"],
    ]) {
      const rest = read(path).slice(read(path).indexOf(`id: "${id}",`));
      expect(rest.slice(0, rest.indexOf("},\n    Action {"))).toContain(`symbol: "${symbol}"`);
    }
  });
});
