import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { currentDiskRecord, DISK_BEGIN, DISK_END, DISK_RECORD_COMMAND, type DiskRecord, parseDiskOutput, renderDiskSection, replaceDiskSection } from "../scripts/cmux-vm-image/disk-record";

// The fresh image's disk record (disk-record.ts, RFD 0068 item 8). The guest half runs only in a bake; these feed
// the parser a captured sample: df and du as read on a fresh default VM on 2026-11-23 09:58Z, with a df -i line.

const SAMPLE = [
  "@@df",
  "Filesystem     Type 1M-blocks  Used Available Use% Mounted on",
  "/dev/vda       ext4     31950  5324     24973  18% /",
  "@@df-i",
  "Filesystem      Inodes  IUsed   IFree IUse% Mounted on",
  "/dev/vda       2048000 115897 1932103    6% /",
  "@@du",
  "1M\t/tmp",
  "3732M\t/usr",
  "2292M\t/usr/local",
  "561M\t/usr/lib",
  "1552M\t/opt/freestyle",
  "1552M\t/opt",
  "37M\t/var",
  "17M\t/var/log",
  "5324M\t/",
  "@@du-exit 0",
  "",
].join("\n");

const META = { image: "cmuxnp-dev-vmimg-ci-4242-1", measured_at: "2026-11-24T08:00:00.000Z", source: "bake" as const };

describe("DISK_RECORD_COMMAND", () => {
  test("one filesystem, depth 2, every tool under a timeout", () => {
    expect(DISK_RECORD_COMMAND).toContain("timeout 30 df -B1M -T /");
    expect(DISK_RECORD_COMMAND).toContain("timeout 30 df -i /");
    expect(DISK_RECORD_COMMAND).toContain("timeout 180 du -x -BM --max-depth=2 /");
  });
});

describe("parseDiskOutput", () => {
  test("reads df, inodes and du, largest first", () => {
    const r = parseDiskOutput(SAMPLE, META);
    expect(r.root).toEqual({ type: "ext4", total_mib: 31950, used_mib: 5324, available_mib: 24973, use_pct: 18 });
    expect(r.inodes).toEqual({ total: 2048000, used: 115897, free: 1932103, use_pct: 6 });
    expect(r.du_mib.slice(0, 4)).toEqual([
      { path: "/", mib: 5324 },
      { path: "/usr", mib: 3732 },
      { path: "/usr/local", mib: 2292 },
      { path: "/opt", mib: 1552 },
    ]);
    expect(r.du_mib.at(-1)).toEqual({ path: "/tmp", mib: 1 });
    expect(r).not.toHaveProperty("note");
  });

  test("a wrapped device name still parses", () => {
    const wrapped = SAMPLE.replace("/dev/vda       ext4", "/dev/mapper/a-very-long-volume-name\n               ext4");
    expect(parseDiskOutput(wrapped, META).root.used_mib).toBe(5324);
  });

  test("a du that timed out keeps what it printed and says so", () => {
    const r = parseDiskOutput(SAMPLE.replace("@@du-exit 0", "@@du-exit 124"), META);
    expect(r.du_mib.length).toBe(9);
    expect(r.note).toBe("du exited 124 (timed out; its list is partial)");
  });

  test("no df refuses; no df -i records inodes as not measured", () => {
    expect(() => parseDiskOutput("@@df\n@@du\n5324M\t/\n", META)).toThrow("df -B1M -T /: no output");
    expect(parseDiskOutput(SAMPLE.replace(/@@df-i\n[^@]*/, ""), META).inodes).toBeNull();
  });
});

describe("the doc section", () => {
  const record = parseDiskOutput(SAMPLE, META);

  test("renders the root filesystem and the du table between the markers", () => {
    const s = renderDiskSection(record);
    expect(s.startsWith(DISK_BEGIN)).toBe(true);
    expect(s.endsWith(DISK_END)).toBe(true);
    expect(s).toContain("by the bake of `cmuxnp-dev-vmimg-ci-4242-1`, after clean and before the snapshot");
    expect(s).toContain("| `/` | ext4 | 31,950 MiB | 5,324 MiB | 24,973 MiB | 18% | 115,897 of 2,048,000 (6%) |");
    expect(s).toContain("| `/usr/local` | 2,292 |");
  });

  test("the next run replaces the section and nothing else", () => {
    const doc = `# Title\n\nbefore\n\n${renderDiskSection(record)}\n\nafter\n`;
    const next = { ...record, root: { ...record.root, used_mib: 6000 } };
    const out = replaceDiskSection(doc, renderDiskSection(next));
    expect(out.startsWith("# Title\n\nbefore\n\n")).toBe(true);
    expect(out.endsWith("\n\nafter\n")).toBe(true);
    expect(out).toContain("6,000 MiB");
    expect(out).not.toContain("5,324 MiB");
    expect(out.split(DISK_BEGIN).length).toBe(2);
  });

  test("a doc without markers gets the section appended; broken markers refuse", () => {
    expect(replaceDiskSection("# T\n", "X")).toBe("# T\n\nX\n");
    expect(() => replaceDiskSection(`${DISK_END}\n${DISK_BEGIN}`, "X")).toThrow("markers are broken");
  });
});

describe("images/cmux-vm/fresh-disk.json", () => {
  const seed = JSON.parse(readFileSync(path.resolve(import.meta.dirname, "../../images/cmux-vm/fresh-disk.json"), "utf8")) as DiskRecord;

  test("is the hand-measured record, labelled as not by the bake", () => {
    expect(seed).toMatchObject({ schema: 1, image: null, source: "fresh-vm", measured_at: "2026-11-23 09:58Z", inodes: null });
    expect(seed.root).toEqual({ type: "ext4", total_mib: 31950, used_mib: 5324, available_mib: 24973, use_pct: 18 });
    expect(seed.du_mib[0]).toEqual({ path: "/", mib: 5324 });
    expect(renderDiskSection(seed)).toContain("on a fresh default VM, not by the bake");
  });

  test("the current dev image's bake record wins over it", () => {
    const baked = parseDiskOutput(SAMPLE, META);
    expect(currentDiskRecord({ snapshot_id: "sh-a", history: [{ snapshot_id: "sh-a", disk: baked }] }, seed)).toBe(baked);
    expect(currentDiskRecord({ snapshot_id: "sh-a", history: [{ snapshot_id: "sh-a" }, { snapshot_id: "sh-b", disk: baked }] }, seed)).toBe(seed);
  });
});
