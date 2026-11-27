import { describe, expect, test } from "bun:test";
import { existsSync, statSync } from "node:fs";
import path from "node:path";
import {
  GAI_CONF,
  NET_BASELINE_DIR,
  netBaselineBakeCommand,
  netBaselineFiles,
  netBaselineProblems,
  netBaselineSmokeCommand,
  SYN_RETRY_MS,
  SYN_RETRY_PATH,
  SYN_RETRY_UNIT,
} from "../scripts/cmux-vm-image/net-baseline";

// What a Freestyle clone prints with every piece live (6.1 guest kernel, tcp_bbr built in).
const LIVE = ["syn-retry=attached 200", "syn-retry-mark=200", "bbr-baked=yes", "cc=bbr", "gai=ipv6-first"].join("\n");

describe("netBaselineFiles", () => {
  test("every source file is in the tree, and the SYN retry program is executable", () => {
    for (const name of ["syn_retry.py", "vm-net-syn-retry.service", "gai.conf", "60-vm-net-bbr.conf", "vm-net-bbr.modules"]) {
      expect(existsSync(path.join(NET_BASELINE_DIR, name))).toBe(true);
    }
    expect(statSync(path.join(NET_BASELINE_DIR, "syn_retry.py")).mode & 0o111).not.toBe(0);
    const program = netBaselineFiles().find((f) => f.path === SYN_RETRY_PATH);
    expect(program?.mode).toBe(0o755);
  });

  test("the unit attaches the program the bake writes, at SYN_RETRY_MS", () => {
    const unit = netBaselineFiles().find((f) => f.path.endsWith(SYN_RETRY_UNIT));
    expect(unit?.text).toContain(`ExecStart=/usr/bin/python3 -I ${SYN_RETRY_PATH} attach ${SYN_RETRY_MS}`);
    expect(unit?.text).toContain("WantedBy=multi-user.target");
  });

  test("gai.conf gives a ULA source the label of ::/0 and writes glibc's whole table", () => {
    const gai = netBaselineFiles().find((f) => f.path === GAI_CONF)?.text ?? "";
    expect(gai).toMatch(/^label fc00::\/7 1$/m);
    // Any label line replaces glibc's default table, so the rest of it must be written out too.
    for (const line of ["label ::1/128 0", "label ::/0 1", "label ::ffff:0:0/96 4", "precedence ::/0 40", "precedence ::ffff:0:0/96 10"]) {
      expect(gai).toContain(line);
    }
  });
});

describe("netBaselineBakeCommand", () => {
  test("BBR goes in only where the kernel has it, and a SYN retry that does not take fails the bake", () => {
    const cmd = netBaselineBakeCommand();
    expect(cmd).toContain("modprobe tcp_bbr");
    expect(cmd).toContain("bbr=off (kernel");
    expect(cmd).toContain(`= ${SYN_RETRY_MS} || {`);
    expect(cmd).toContain(`systemctl enable ${SYN_RETRY_UNIT}`);
  });

  test("the smoke reads each piece", () => {
    const cmd = netBaselineSmokeCommand();
    for (const key of ["syn-retry=", "bbr-baked=", "cc=", "gai="]) expect(cmd).toContain(key);
  });
});

describe("netBaselineProblems", () => {
  test("a clone with every piece live passes", () => {
    expect(netBaselineProblems(LIVE)).toEqual([]);
  });

  test("a clone where the program is not attached fails and says what that costs", () => {
    const problems = netBaselineProblems(LIVE.replace("syn-retry=attached 200", "syn-retry=not attached"));
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("not attached");
    expect(problems[0]).toContain("1 s");
  });

  test("a kernel without tcp_bbr is fine when the bake left BBR out", () => {
    expect(netBaselineProblems(LIVE.replace("bbr-baked=yes", "bbr-baked=no").replace("cc=bbr", "cc=cubic"))).toEqual([]);
  });

  test("BBR baked but cubic running fails", () => {
    expect(netBaselineProblems(LIVE.replace("cc=bbr", "cc=cubic"))[0]).toContain("cubic");
  });

  test("no IPv6-first gai.conf fails, and empty output names every piece", () => {
    expect(netBaselineProblems(LIVE.replace("gai=ipv6-first", "gai=default"))[0]).toContain(GAI_CONF);
    expect(netBaselineProblems("")).toHaveLength(2);
  });
});
