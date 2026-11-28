// l10n-allow-file: test fixture tasks and commands, not shipped UI.
import { describe, expect, test } from "bun:test";
import { crownGroups, formatCrownBadge } from "./crownModel";
import type { TrayCard } from "./trayAttention";
import type { Subagent } from "./subagentFold";
import type { BackgroundCommand } from "../session-info/processes";

const now = Date.now();
const agentCard = (id: string, finished = false, overrides: Partial<Subagent> = {}): TrayCard => ({
  finished,
  item: {
    kind: "agent",
    id,
    depth: 0,
    agent: {
      id,
      parent: null,
      name: id,
      task: `Task ${id}`,
      state: finished ? "completed" : "running",
      startedAt: now - 30_000,
      ...(finished ? { endedAt: now - 2_000 } : {}),
      ...overrides,
    },
  },
});

const commandCard = (id: string, finished = false, overrides: Partial<BackgroundCommand> = {}): TrayCard => ({
  finished,
  item: {
    kind: "command",
    id,
    command: {
      id,
      command: `bun test ${id}`,
      state: finished ? "completed" : "running",
      startedAt: now - 15_000,
      ...(finished ? { endedAt: now - 1_000 } : {}),
      ...overrides,
    },
  },
});

describe("crownModel", () => {
  test("formatCrownBadge caps counts at 9+", () => {
    expect(formatCrownBadge(1)).toBe("1");
    expect(formatCrownBadge(9)).toBe("9");
    expect(formatCrownBadge(10)).toBe("9+");
    expect(formatCrownBadge(24)).toBe("9+");
  });

  test("splits subagents and commands into separate groups and flattens them without dividers", () => {
    const a1 = agentCard("a1");
    const a2 = agentCard("a2", true);
    const c1 = commandCard("c1");
    const g = crownGroups([a1, c1, a2]);

    expect(g.isSingle).toBe(false);
    expect(g.hasVisibleWork).toBe(true);
    expect(g.agents).toEqual([a1, a2]);
    expect(g.commands).toEqual([c1]);
    expect(g.agentsRunning).toBe(1);
    expect(g.commandsRunning).toBe(1);
    expect(g.leadAgent).toBe(a1);
    expect(g.leadCommand).toBe(c1);
    expect(g.lead).toBe(a1);
    expect(g.flatList).toEqual([a1, a2, c1]);
    expect(g.anyRunning).toBe(true);
  });

  test("single-item state sets isSingle=true", () => {
    const lone = agentCard("a1", true);
    const g = crownGroups([lone]);
    expect(g.isSingle).toBe(true);
    expect(g.anyRunning).toBe(false);
    expect(g.lead).toBe(lone);
  });

  test("prefers running command as lead when all subagents are finished", () => {
    const aDone = agentCard("a1", true);
    const cRun = commandCard("c1", false);
    const g = crownGroups([cRun, aDone]);
    expect(g.lead).toBe(cRun);
    expect(g.leadAgent).toBe(aDone);
    expect(g.leadCommand).toBe(cRun);
    expect(g.agentsRunning).toBe(0);
    expect(g.commandsRunning).toBe(1);
  });

  test("hides tray when only finished silent turns exist and excludes them beside live work", () => {
    const silent: TrayCard = {
      finished: true,
      item: {
        kind: "turn",
        id: "t1",
        turn: {
          id: "t1",
          startedAt: now - 5_000,
          endedAt: now - 1_000,
          steps: [],
        },
      },
    };
    expect(crownGroups([silent]).hasVisibleWork).toBe(false);
    expect(crownGroups([]).hasVisibleWork).toBe(false);

    const a1 = agentCard("a1", false);
    const mixed = crownGroups([a1, silent]);
    expect(mixed.isSingle).toBe(true);
    expect(mixed.commands).toEqual([]);
    expect(mixed.flatList).toEqual([a1]);
  });

  test("picks the longest-running active item as lead so newly joined items do not thrash the title", () => {
    const newer = agentCard("a-new", false, { startedAt: now - 5_000 });
    const older = agentCard("a-old", false, { startedAt: now - 90_000 });
    const g = crownGroups([newer, older]);
    expect(g.leadAgent).toBe(older);
    expect(g.lead).toBe(older);
  });
});
