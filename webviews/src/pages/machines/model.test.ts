// The Machines section's layout (ported from the Swift MachineSectionLayoutTests,
// MachineSectionViewTests and JoinedMachineRowsTests' caption checks): every style keeps every
// machine, this Mac comes first with no header, the kinds follow in one fixed order, ready machines
// sort first, and each row's words.
import { describe, expect, test } from "bun:test";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import {
  KIND_ICON,
  groups,
  healthHelp,
  isLinked,
  joinedCaption,
  platformText,
  sectionItems,
  shownLines,
  stateText,
  stepText,
} from "./model";
import { sampleRows } from "./mockProvider";
import type { MachineRow, MachineSectionStyle, MachineServerState } from "./types";

const strings = createStrings(table, ["en"]);
const t = strings.t;

const local: MachineRow = {
  id: "local",
  name: "This Mac",
  kind: "local",
  isLocal: true,
  isConnected: true,
  isConnecting: false,
};
const machine = (id: string, kind: MachineRow["kind"], extra: Partial<MachineRow> = {}): MachineRow => ({
  id,
  name: id,
  kind,
  isLocal: false,
  isConnected: false,
  isConnecting: false,
  ...extra,
});
/** Out of kind order on purpose: grouping must not depend on the registry's order. */
const rows: MachineRow[] = [
  local,
  machine("s1", "server", { isConnected: true }),
  machine("h1", "ssh", { isConnected: true }),
  machine("c1", "cloud", { isConnected: true }),
  machine("c2", "cloud", { isConnecting: true }),
];
const styles: MachineSectionStyle[] = ["compact", "grouped", "flat"];

describe("groups", () => {
  test("grouped styles put this Mac first, then Cloud, SSH and Servers under headers", () => {
    for (const style of ["compact", "grouped"] as const) {
      const shown = groups(rows, style);
      expect(shown.map((group) => group.kind)).toEqual([undefined, "cloud", "ssh", "server"]);
      expect(shown.map((group) => group.rows.map((row) => row.id))).toEqual([["local"], ["c1", "c2"], ["h1"], ["s1"]]);
      expect(new Set(shown.map((group) => group.id)).size).toBe(shown.length);
    }
  });

  test("a kind with no machine has no group", () => {
    expect(groups([local], "compact").map((group) => group.kind)).toEqual([undefined]);
    expect(groups([], "compact")).toEqual([]);
    expect(groups([], "flat")).toEqual([]);
  });

  test("the flat style is one untitled list", () => {
    const shown = groups(rows, "flat");
    expect(shown).toHaveLength(1);
    expect(shown[0]!.kind).toBeUndefined();
    expect(shown[0]!.rows.map((row) => row.id)).toEqual(["local", "s1", "h1", "c1", "c2"]);
  });

  test("every style keeps every machine", () => {
    for (const style of styles) expect(groups(rows, style).flatMap((group) => group.rows)).toHaveLength(rows.length);
  });

  // Leo, 2026-10-31: "ready machines first, then paused, then offline", each rank in the registry's order.
  test("ready machines come first, then connecting, paused and offline ones", () => {
    const cloud = (id: string, extra: Partial<MachineRow> = {}) => machine(id, "cloud", extra);
    const given = [
      cloud("off1"),
      cloud("off2"),
      cloud("paused1", { serverState: "paused" }),
      cloud("ready1", { isConnected: true }),
      cloud("failed1", { serverState: "failed" }),
      cloud("paused2", { serverState: "paused" }),
      cloud("resuming1", { serverState: "resuming", isConnecting: true }),
      cloud("ready2", { isConnected: true }),
    ];
    const order = ["ready1", "ready2", "resuming1", "paused1", "paused2", "off1", "off2", "failed1"];
    for (const style of ["compact", "grouped"] as const) {
      expect(groups([...given, local], style).map((group) => group.rows.map((row) => row.id))).toEqual([
        ["local"],
        order,
      ]);
    }
    expect(groups([...given, local], "flat")[0]!.rows.map((row) => row.id)).toEqual(["local", ...order]);
  });

  test("each kind has its own icon", () => {
    expect(new Set(Object.values(KIND_ICON)).size).toBe(Object.keys(KIND_ICON).length);
  });
});

describe("words", () => {
  test("a row's state follows its link and its server", () => {
    expect(stateText(machine("c", "cloud", { isConnecting: true }), strings)).toBe(t("machines.connecting"));
    expect(stateText(machine("c", "cloud", { isConnected: true }), strings)).toBe(t("machines.connected"));
    expect(stateText(machine("o", "ssh"), strings)).toBe(t("machines.offline"));
    const states: MachineServerState[] = ["paused", "resuming", "failed", "deleted"];
    const words = states.map((state) => stateText(machine("c", "cloud", { serverState: state }), strings));
    expect(words).toEqual(["Paused", "Resuming…", "Failed", "Deleted"]);
  });

  test("the status mark's tooltip names the step the last check flagged", () => {
    expect(healthHelp(local, strings)).toBeUndefined();
    expect(healthHelp(machine("h", "ssh", { health: "ok" }), strings)).toBe("Last check passed");
    expect(healthHelp(machine("h", "ssh", { health: "warning", healthStep: "update" }), strings)).toBe(
      "Last check: Keep it up to date needs attention",
    );
    expect(healthHelp(machine("h", "ssh", { health: "failing", healthStep: "signed-in" }), strings)).toBe(
      "Last check: Signed in to cmux failed",
    );
    // Every hyphenated step reads its camelCase key, not only signed-in (peer-back was shown raw).
    expect(stepText("peer-back", strings)).toBe(t("addMachine.step.peerBack"));
    expect(stepText("peer-back", strings)).not.toBe("peer-back");
    expect(stepText("some-new-step", strings)).toBe("some-new-step");
  });

  test("a joined machine's caption carries its state, platform and who made its line", () => {
    const online = {
      id: "m_1",
      name: "lane-vm-3",
      state: "online" as const,
      platform: "linux",
      mintedBy: "you@example.com",
    };
    expect(joinedCaption(online, undefined, strings)).toBe("Online · Linux · added by you@example.com");
    expect(joinedCaption({ ...online, state: "offline" }, undefined, strings)).toBe(
      "Offline · Linux · added by you@example.com",
    );
    expect(joinedCaption({ ...online, state: "revoked" }, undefined, strings).startsWith("Revoked")).toBe(true);
    expect(joinedCaption(online, "rotate", strings)).toContain("rotate");
    expect(joinedCaption(online, "revoke", strings)).toContain("revoke");
    expect(platformText("macos")).toBe("macOS");
    expect(platformText("freebsd")).toBe("freebsd");
  });

  test("a joined machine the app connects to keeps New Workspace; a mesh-only one has no link", () => {
    const joined = { id: "m_1", name: "lane-vm-3", state: "online" as const };
    expect(isLinked(machine("ssh-7", "ssh", { joined }))).toBe(true);
    expect(isLinked(machine("joined:m_1", "joined", { joined }))).toBe(false);
    expect(isLinked(machine("ssh-8", "ssh"))).toBe(true);
  });
});

describe("shown lines", () => {
  const four = [
    local,
    machine("atlas-web", "cloud", { isConnected: true }),
    machine("gpu-box", "cloud", { isConnecting: true }),
    machine("build-host", "ssh"),
  ];
  const snapshot = (style: MachineSectionStyle, given = four) => ({ rows: given, style, busy: [], failed: {} });

  test("each style shows its headers and states", () => {
    expect(shownLines(snapshot("compact"), strings)).toEqual([
      "This Mac",
      t("machines.group.cloud"),
      "atlas-web",
      "gpu-box",
      t("machines.group.ssh"),
      `build-host · ${t("machines.offline")}`,
      t("machines.addMachine"),
    ]);
    expect(shownLines(snapshot("flat"), strings)).toEqual([
      `This Mac · ${t("machines.connected")}`,
      `atlas-web · ${t("machines.connected")}`,
      `gpu-box · ${t("machines.connecting")}`,
      `build-host · ${t("machines.offline")}`,
      t("machines.addMachine"),
    ]);
  });

  test("a paused Cloud machine reads Paused, not a spinner", () => {
    const paused = machine("night-batch", "cloud", { serverState: "paused" });
    expect(shownLines(snapshot("compact", [...four, paused]), strings)).toContain(
      `night-batch · ${t("machines.paused")}`,
    );
  });

  test("joined machines sit in their link's group or under Joined, after the other kinds", () => {
    const linked = machine("h1", "ssh", {
      name: "lane-vm-3",
      isConnected: true,
      joined: { id: "m_1", name: "lane-vm-3", state: "online", mintedBy: "you@example.com" },
    });
    const mesh = machine("joined:m_2", "joined", {
      name: "gpu-west",
      joined: { id: "m_2", name: "gpu-west", state: "offline" },
    });
    const lines = shownLines(snapshot("compact", [local, mesh, linked]), strings);
    const ssh = lines.indexOf(t("machines.group.ssh"));
    const joined = lines.indexOf(t("machines.group.joined"));
    expect(lines[0]).toBe("This Mac");
    expect(ssh).toBeGreaterThan(0);
    expect(joined).toBeGreaterThan(ssh);
    expect(lines[ssh + 1]!.startsWith("lane-vm-3 · Online")).toBe(true);
    expect(lines[joined + 1]!.startsWith("gpu-west · Offline")).toBe(true);
  });

  test("Add Machine… ends the section, set apart only when machines sit in groups", () => {
    const grouped = sectionItems(snapshot("grouped", sampleRows), strings);
    expect(grouped.at(-1)).toEqual({ type: "add", key: "add", gap: true });
    expect(sectionItems(snapshot("flat", sampleRows), strings).at(-1)).toEqual({ type: "add", key: "add", gap: false });
  });
});
