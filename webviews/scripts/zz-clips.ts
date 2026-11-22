// Temporary: records fuzz seeds' clips for one look (PR evidence); not committed.
import { openRecorder, recordLook } from "./fold-variants-record";
import { fuzzSpec, SPLITS } from "../test/browser/fold-fuzz.scenario";
const [out, looks, seeds] = process.argv.slice(2);
const recorder = await openRecorder();
for (const seed of seeds!.split(",").map(Number))
  for (const look of looks!.split(",")) {
    const { width, height } = SPLITS[fuzzSpec(seed).split];
    const made = await recordLook(recorder.browser, recorder.port, { look, scenario: `fuzz:${seed}`, width, height, out: out!, name: `seed-${seed}-${look}`, ffmpeg: "/usr/bin/ffmpeg" }).catch((e: unknown) => (console.error(seed, look, String(e).split("\n")[0]), undefined));
    console.log(seed, look, made?.clip ?? "no clip");
  }
await recorder.close();
