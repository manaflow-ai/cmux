import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runLocal } from "./runner";

test("workflow captures surround a trusted action and persist only AX digests", async () => {
  const root = await mkdtemp(join(tmpdir(), "cmux-workflow-evidence-"));
  const old = process.env.CMUX_GALLERY_WORKFLOW_EVIDENCE;
  process.env.CMUX_GALLERY_WORKFLOW_EVIDENCE = "1";
  try {
    await writeFile(join(root, "gallery-frame-fixture.js"), "// fixture stage marker\n");
    await writeFile(join(root, "frame.html"), `<!doctype html><body><button>Before</button><script src="gallery-frame-fixture.js"></script><script>
      (async () => {
        const root = document.documentElement;
        root.dataset.galleryEntry = 'fixture'; root.dataset.galleryVariant = 'click';
        root.dataset.galleryRevision = '${"a".repeat(40)}';
        document.querySelector('button').onclick = event => event.target.textContent = 'After';
        await window.cmuxGalleryBeforeStep({step: 'click'});
        const box = document.querySelector('button').getBoundingClientRect();
        await window.cmuxGalleryInput({kind: 'click', x: box.x + box.width / 2, y: box.y + box.height / 2});
        await window.cmuxGalleryStep({index: 0, step: 'click'});
        window.cmuxGalleryPlayReport = {status: 'pass', steps: [{step: 'click', action: 'click', status: 'pass', problems: [], settleMs: 1, layoutShift: 0, longFrames: [], frameSource: 'raf'}]};
        root.dataset.galleryReady = '1';
      })();
    </script></body>`);
    const manifest = join(root, "manifest.json");
    await writeFile(manifest, JSON.stringify([{ id: "fixture", path_or_url: "frame.html" }]));
    const results = await runLocal({ manifest, galleryDir: root, outputDir: join(root, "output"), threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 });
    const evidence = results[0]!.workflowEvidence as {
      beforeSteps: { screenshot: string; axDigest: { sha256: string; count: number } }[];
      afterSteps: { screenshot: string; axDigest: { sha256: string; count: number } }[];
      timingIncludesEvidenceCapture: boolean;
    };
    expect(results[0]!.ready).toBe("1");
    expect(evidence.beforeSteps).toHaveLength(1);
    expect(evidence.afterSteps).toHaveLength(1);
    expect(evidence.beforeSteps[0]!.axDigest.sha256).not.toBe(evidence.afterSteps[0]!.axDigest.sha256);
    expect(evidence.afterSteps[0]!.axDigest.count).toBeGreaterThan(0);
    expect(JSON.stringify(evidence)).not.toContain("Before");
    expect(JSON.stringify(evidence)).not.toContain("After");
    for (const frame of [...evidence.beforeSteps, ...evidence.afterSteps]) {
      expect((await readFile(join(root, "output", frame.screenshot))).subarray(1, 4).toString()).toBe("PNG");
    }
    expect(evidence.timingIncludesEvidenceCapture).toBe(false);
  } finally {
    if (old === undefined) delete process.env.CMUX_GALLERY_WORKFLOW_EVIDENCE;
    else process.env.CMUX_GALLERY_WORKFLOW_EVIDENCE = old;
    await rm(root, { recursive: true, force: true });
  }
});
