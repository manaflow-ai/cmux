// Translates every wallpaper under cmux-tui/crates/cmux-wallpaper/wallpapers to GLSL ES 3.00
// with naga, the translator the app's Rust uses, and writes wallpapers.js for the gallery.
//
//   NAGA=/path/to/naga SCENE_FRAMES=/path/to/scene_frames node design/live-wallpapers-gallery/build.mjs [id]
//
// `naga` comes from `cargo install naga-cli` (the version cmux-wallpaper's Cargo.toml pins).
//
// A motion scene (a manifest naming `scene` or `lottie`, plans/cmux-next/motion-scenes.md) has no
// program of its own: Rust packs its uniforms. `scene_frames` is cmux-wallpaper's example
// (`cargo build -p cmux-wallpaper --example scene_frames`; the default path is cmux-tui's
// target/debug/examples). It prints the scene engine's GLSL (translated by build.rs) and, for each
// variant and theme, the packed Frame and Scene floats of the still, and for the first card a
// sequence of SCENE_SECONDS (default one loop) at SCENE_FPS (default 15), at the card's rendered
// size. A scene card therefore stands for a 480 x 270 point window at backing scale 2 times the
// manifest's scale, whatever ?size says; live, a card without a sequence shows its still.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
// The gallery's themes, so a scene is packed with the colors its cards use.
import { THEMES } from "./runner.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const crate = path.join(here, "../../cmux-tui/crates/cmux-wallpaper");
const naga = process.env.NAGA ?? "naga";
const sceneFrames = process.env.SCENE_FRAMES ?? path.join(here, "../../cmux-tui/target/debug/examples/scene_frames");
const sceneFps = Number(process.env.SCENE_FPS ?? 15);
// Optional: only these ids (comma separated), e.g. while iterating on one scene.
const only = process.argv[2]?.split(",");
const prelude = fs.readFileSync(path.join(crate, "src/prelude.wgsl"), "utf8");
const epilogue = fs.readFileSync(path.join(crate, "src/epilogue.wgsl"), "utf8");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "wallpapers-"));

// The card: 480 x 270 points at backing 2 (index.html's default).
const CARD = [480, 270];
const DPR = 2;

// Rust's floats, trimmed to what a uniform needs, so the module stays small.
const trim = (a) => a.map((v) => Math.round(v * 1e4) / 1e4);

function scene(dir, manifest) {
  const scale = manifest.scale ?? 1;
  const size = CARD.map((v) => Math.max(1, Math.round(v * DPR * scale)));
  const variants = manifest.variants?.length ? manifest.variants : [{ name: "Default" }];
  const still = (v) => v.still ?? manifest.still ?? { time: 0, pointer: [0.6, 0.4] };
  const runs = {};
  let glsl = "";
  let loop = 10;
  const frames = (v, theme, extra) => {
    const t = THEMES[theme];
    const args = [dir, "--size", `${size[0]}x${size[1]}`, "--backing", String(DPR * scale), "--theme", `${t.ink},${t.paper}`];
    if (v.accent) args.push("--accent", v.accent);
    return JSON.parse(execFileSync(sceneFrames, [...args, ...extra], { maxBuffer: 1 << 30 }).toString());
  };
  const pack = (f) => ({ t: f.t, frame: trim(f.frame), scene: trim(f.scene) });
  // The card that gets a sequence: SCENE_CARD ("Variant|theme"), else the first.
  const seqCard = process.env.SCENE_CARD;
  let first = true;
  for (const v of variants) {
    for (const theme of v.themes ?? ["dark", "light"]) {
      // The still: every 1/60 s up to its time, so physics has run as in the app; the last frame.
      const s = still(v);
      const [px, py] = s.pointer ?? [0.6, 0.4];
      const t = Number(s.time ?? 0);
      const st = frames(v, theme, ["--fps", "60", "--duration", String(t + 1 / 60), "--last", "1", "--pointer", `0:${px}:${py}:0`]);
      glsl = st.glsl;
      loop = st.loop;
      // One sequence, for one card only (SCENE_SECONDS, default one loop, at SCENE_FPS);
      // every other card shows its still, which keeps the module small.
      let seq = [];
      const card = `${v.name}|${theme}`;
      if (seqCard ? card === seqCard : first) {
        const seconds = Number(process.env.SCENE_SECONDS ?? loop);
        seq = frames(v, theme, ["--fps", String(sceneFps), "--duration", String(seconds)]).frames.map(pack);
        first = false;
      }
      runs[`${v.name}|${theme}`] = { size, fps: sceneFps, still: pack(st.frames.at(-1)), frames: seq };
    }
  }
  return { glsl, scene: { loop, runs } };
}

const root = path.join(crate, "wallpapers");
const out = [];
for (const id of fs.readdirSync(root).sort()) {
  if (only && !only.includes(id)) continue;
  const dir = path.join(root, id);
  const manifestPath = path.join(dir, "wallpaper.json");
  if (!fs.existsSync(manifestPath)) continue;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (manifest.scene || manifest.lottie) {
    try {
      out.push({ id, manifest, ...scene(dir, manifest) });
      console.log(`${id}: ok (scene)`);
    } catch (e) {
      console.error(`${id}: ${e.stderr?.toString() ?? e.message}`);
      process.exitCode = 1;
    }
    continue;
  }
  const source = fs.readFileSync(path.join(dir, manifest.shader ?? "wallpaper.wgsl"), "utf8");
  const wgsl = path.join(tmp, `${id}.wgsl`);
  const frag = path.join(tmp, `${id}.frag`);
  fs.writeFileSync(wgsl, `${prelude}\n${source}\n${epilogue}`);
  try {
    execFileSync(naga, [wgsl, frag, "--shader-stage", "frag", "--entry-point", "fs_main", "--profile", "es300"], { stdio: "pipe" });
  } catch (e) {
    console.error(`${id}: ${e.stderr?.toString() ?? e.message}`);
    process.exitCode = 1;
    continue;
  }
  out.push({ id, manifest, glsl: fs.readFileSync(frag, "utf8") });
  console.log(`${id}: ok`);
}
fs.rmSync(tmp, { recursive: true, force: true });
fs.writeFileSync(path.join(here, "wallpapers.js"), `// Generated by build.mjs; do not edit.\nexport const WALLPAPERS = ${JSON.stringify(out)};\n`);
