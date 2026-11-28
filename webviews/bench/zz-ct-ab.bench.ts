// l10n-allow-file: PROBE ONLY (lane/composer-typing-webkit-l0-wrap), never lands. Interleaved WebKit L0/L3 arms of
// composer-typing.bench.ts on one exclusive worker, so every arm reads the same host in the same window.
/// <reference types="bun" />
import path from "node:path";
import fs from "node:fs";
import os from "node:os";
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ct-ab-"));
const style = (css: string) =>
  `(() => { const add = () => { const s = document.createElement("style"); s.textContent = ${JSON.stringify(css)}; (document.head || document.documentElement).appendChild(s); }; if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", add); else add(); })();`;
const intervals = `(() => { const t = []; let last = 0; const on = () => { const tick = (n) => { if (last) t.push(n - last); last = n; requestAnimationFrame(tick); }; requestAnimationFrame(tick); }; window.__probeOn = on; window.__probe = () => { const a = [...t].sort((x, y) => x - y); const q = (p) => a.length ? +a[Math.floor(p * (a.length - 1))].toFixed(1) : null; return { n: a.length, p10: q(0.1), p50: q(0.5), p90: q(0.9), p99: q(0.99) }; }; })();`;
const PROBES: Record<string, string> = {
  base: "window.__probe = () => null;",
  minimal: `(() => { const pin = () => document.documentElement && document.documentElement.setAttribute("data-chat-motion", "minimal"); pin(); document.addEventListener("readystatechange", pin); window.__probe = () => document.documentElement.getAttribute("data-chat-motion"); })();`,
  layer: style(".acpmux-thread{will-change:translate}") + "window.__probe = () => null;",
  noanim:
    style("*,*::before,*::after{animation:none!important;transition:none!important}") + "window.__probe = () => null;",
  raf: intervals + "window.__probeOn();",
};
const ARMS = (process.env.CT_AB_ARMS ?? "base,minimal,layer,noanim,raf").split(",");
const ROUNDS = Number(process.env.CT_AB_ROUNDS ?? 3);
const DEADLINE = Date.now() + Number(process.env.CT_AB_BUDGET_S ?? 2700) * 1000;
const files = Object.fromEntries(
  ARMS.map((a) => {
    const f = path.join(dir, `${a}.js`);
    fs.writeFileSync(f, PROBES[a]!);
    return [a, f];
  }),
);
const bench = path.join(import.meta.dir, "composer-typing.bench.ts");
const floor = path.join(import.meta.dir, "zz-ct-floor.ts");
const out: any[] = [];
// Host readings around each arm: the VM's steal and iowait share (/proc/stat), its load and the top CPU users.
const cpu = () => fs.readFileSync("/proc/stat", "utf8").split("\n")[0]!.trim().split(/\s+/).slice(1).map(Number);
const host = (a: number[], b: number[]) => {
  const d = b.map((v, i) => v - a[i]!);
  const all = d.reduce((x, y) => x + y, 0) || 1;
  return {
    busy: +(((all - d[3]! - d[4]!) / all) * 100).toFixed(1),
    iowait: +((d[4]! / all) * 100).toFixed(1),
    steal: +((d[7]! / all) * 100).toFixed(2),
    load: fs.readFileSync("/proc/loadavg", "utf8").split(" ").slice(0, 3).join(" "),
  };
};
const top = () =>
  Bun.spawnSync(["sh", "-c", "ps -eo pcpu,comm --sort=-pcpu | sed -n 2,7p | tr -s ' ' | paste -sd ','"])
    .stdout.toString()
    .trim();
console.log(`CT-HOST start nproc=${os.cpus().length} ${JSON.stringify(host(cpu(), cpu()))} top=${top()}`);
for (let round = 0; round < ROUNDS && Date.now() < DEADLINE; round++) {
  const order = round % 2 ? [...ARMS].reverse() : ARMS;
  for (const arm of order) {
    if (Date.now() > DEADLINE) break;
    const args = [
      "bun",
      bench,
      "--mode",
      "L0,L3",
      "--engines",
      "webkit",
      "--lengths",
      "60",
      "--keys",
      "500",
      "--gap",
      "20",
      "--repeat",
      "1",
      "--probe",
      files[arm]!,
    ];
    const t0 = Date.now();
    const c0 = cpu();
    const p = Bun.spawnSync(args, {
      cwd: path.resolve(import.meta.dir, ".."),
      stdout: "pipe",
      stderr: "pipe",
      timeout: 600_000,
    });
    const text = p.stdout.toString();
    console.log(`CT-HOST ${arm} r${round} ${JSON.stringify(host(c0, cpu()))} top=${top()}`);
    const probes = text
      .split("\n")
      .filter((l) => l.startsWith("PROBE "))
      .map((l) => JSON.parse(l.slice(6)));
    const line = text
      .split("\n")
      .reverse()
      .find((l) => l.startsWith("COMPOSER-TYPING "));
    if (!line) {
      console.log(
        `CT-AB-FAIL ${arm} r${round} exit ${p.exitCode}\n${text.slice(-3000)}\n${p.stderr.toString().slice(-3000)}`,
      );
      continue;
    }
    for (const r of JSON.parse(line.slice(16)) as any[]) {
      const row = {
        arm,
        round,
        mode: r.mode,
        valid: r.valid,
        p95: r.to_paint_p95,
        p99: r.to_paint_p99,
        f95: r.to_frame_p95,
        f99: r.to_frame_p99,
        work95: r.to_work_p95,
        refresh: r.display_refresh_ms,
        missed: r.keys_missed_refresh,
        sharing: r.keys_sharing_frame,
        late95: r.driver_late_p95_ms,
        b95: r.budget_p95_ms,
        b99: r.budget_p99_ms,
        probe: probes.find((x) => x.mode === r.mode)?.probe,
        s: Math.round((Date.now() - t0) / 1000),
      };
      out.push(row);
      console.log(`CT-AB ${JSON.stringify(row)}`);
    }
    for (const fl of round === 0 && arm === order[0] ? ["", "raf"] : arm === "base" ? [""] : []) {
      const f = Bun.spawnSync(["bun", floor, fl], {
        cwd: path.resolve(import.meta.dir, ".."),
        stdout: "pipe",
        stderr: "pipe",
        timeout: 120_000,
      });
      console.log(
        `CT-FLOOR ${fl || "plain"} r${round} ${f.stdout.toString().trim()} ${f.exitCode ? f.stderr.toString().slice(-500) : ""}`,
      );
    }
  }
}
for (const mode of ["L0", "L3"])
  for (const arm of ARMS) {
    const rows = out.filter((r) => r.mode === mode && r.arm === arm);
    const med = (k: string) => {
      const a = rows
        .map((r) => r[k])
        .filter((v) => typeof v === "number")
        .sort((x, y) => x - y);
      return a.length ? a[Math.floor(a.length / 2)] : null;
    };
    console.log(
      `CT-AB-SUMMARY ${mode} ${arm} n=${rows.length} p95=${rows.map((r) => r.p95).join("/")} (med ${med("p95")}) p99=${rows.map((r) => r.p99).join("/")} (med ${med("p99")}) refresh=${med("refresh")}`,
    );
  }
