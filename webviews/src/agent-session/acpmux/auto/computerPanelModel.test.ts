import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import {
  awakeRow,
  clockText,
  durationText,
  historyLine,
  shapeText,
  sizeRow,
  sleepRow,
  survivesLine,
} from "./computerPanelModel";
import { SURVIVES_COLUMNS, SURVIVES_EVENTS, SURVIVES_ROWS } from "./survivesTable";

const t = translatorFor("en");
const T = Date.UTC(2026, 10, 24, 14, 2);
const f = { t, locale: "en-US", timeZone: "UTC" };

test("durations read as hours and minutes", () => {
  expect(durationText(0, t)).toBe("0 min");
  expect(durationText(45, t)).toBe("45 min");
  expect(durationText(60, t)).toBe("1 h");
  expect(durationText(85, t)).toBe("1 h 25 min");
});

test("size and sleep rows show a pin only when pinned", () => {
  const shape = { vcpu: 2, memory_gib: 4 };
  expect(shapeText(shape, t)).toBe("2 vCPU · 4 GB");
  expect(sizeRow({ size: { mode: "auto" }, shape, home: "cloud" }, t)).toEqual({
    pinned: false,
    text: "Auto · now 2 vCPU · 4 GB, grows as it works",
  });
  expect(sizeRow({ size: { mode: "auto" }, home: "this_mac" }, t).text).toBe("Auto · no cloud computer yet");
  expect(sizeRow({ size: { mode: "pinned", vcpu: 4, memory_gib: 8 }, shape, home: "cloud" }, t)).toEqual({
    pinned: true,
    text: "Pinned at 4 vCPU · 8 GB",
  });
  expect(sleepRow({ mode: "auto" }, f).pinned).toBe(false);
  expect(sleepRow({ mode: "keep_awake" }, f)).toEqual({ pinned: true, text: "Keep awake until you say" });
  expect(sleepRow({ mode: "keep_awake", until_ms: T }, f).text).toBe("Keep awake until 02:02 PM");
});

test("local time is free; cloud shows minutes today", () => {
  expect(awakeRow({ home: "this_mac" }, t)).toBe("on your Mac · free");
  expect(awakeRow({ home: "cloud", minutes_awake_today: 85 }, t)).toBe("1 h 25 min awake today");
  expect(awakeRow({ home: "cloud" }, t)).toBe("No cloud time today");
});

test("a history line is a time and one sentence; the id is apart", () => {
  expect(clockText(T, f)).toBe("02:02 PM");
  const line = historyLine(
    { at_ms: T, change: "resized_up", reason: "grew_for_memory", command: "cargo build", vm_id: "vm-1" },
    f,
  );
  expect(line).toEqual({ time: "02:02 PM", text: "Made bigger: cargo build needed more memory.", vmId: "vm-1" });
  expect(historyLine({ at_ms: T, change: "moved_to_cloud", reason: "lid_closed" }, f).vmId).toBeUndefined();
});

test("the survives table covers every event and column, and promises only kept", () => {
  expect(SURVIVES_ROWS.map((r) => r.event)).toEqual([...SURVIVES_EVENTS]);
  for (const row of SURVIVES_ROWS) for (const c of SURVIVES_COLUMNS) expect(row.cells[c]).toBeDefined();
  const move = SURVIVES_ROWS.find((r) => r.event === "move");
  expect(move?.cells.processes.value).toBe("restarted");
  expect(SURVIVES_ROWS.find((r) => r.event === "cloud_lost")?.cells.chat.value).toBe("lost");
  expect(survivesLine(move as NonNullable<typeof move>, t)).toContain(
    "Running processes Restarted (Dev servers start again.)",
  );
});

test("no copy names a vendor", () => {
  const text = SURVIVES_ROWS.map((r) => survivesLine(r, t)).join(" ");
  expect(text).not.toMatch(/freestyle|criu|aws|ec2/i);
});
