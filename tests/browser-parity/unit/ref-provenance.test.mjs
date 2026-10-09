// A Page remembers which frame each ref prefix names and which document
// issued each ref (runtime-core.js, Page._checkRef). A page that keeps
// adding and removing iframes, or a session that keeps taking snapshots,
// must not make that memory grow without end; a ref whose record was
// dropped fails stale and never resolves to an element of another document.
//
//   node --test tests/browser-parity/unit/ref-provenance.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime } from "../lib/dev-driver.mjs";

const ns = loadRuntime();
const { Page } = ns.core;

// A driver whose page agent answers `refState` as a document where every
// ref number names a live element (the worst case for a forgotten ref):
// only the document check the runtime passes can refuse it.
function fakePage(state) {
  const session = {
    async call(method, params) {
      if (method === "frames.list") return [{ frameId: "main", url: "https://a.example/" }, ...state.children.map((id) => ({ frameId: id, parentFrameId: "main", url: "https://b.example/" }))];
      if (method === "frame.evaluate") {
        const [name, , , doc] = params.args;
        if (name === "refState") {
          if (typeof doc === "string" && doc !== state.doc) return { live: false, foreignDoc: true, max: 0, doc: state.doc };
          return { live: true, max: 0, doc: state.doc };
        }
      }
      throw new Error(`unexpected driver call ${method}`);
    },
  };
  return new Page(session, "t1");
}

// Entries a provenance map holds, whether it keeps one map per frame or one in all.
const entries = (map) => [...map.values()].reduce((n, v) => n + (v instanceof Map ? v.size : 1), 0);

test("ref documents: the record of issued refs is bounded, and a dropped ref fails stale", async () => {
  const state = { doc: "docA", children: [] };
  const page = fakePage(state);
  const issued = 600000;
  for (let i = 1; i <= issued; i += 1000) page._noteRefDocs(page._mainFrame, "docA", Array.from({ length: 1000 }, (_, k) => `e${i + k}`));
  assert.ok(entries(page._refDocs) < issued, `all ${issued} ref records were kept`);
  // The newest ref still resolves in its own document.
  assert.equal(await page._checkRef(`e${issued}`), page._mainFrame);
  // The oldest ref's record is gone: it fails stale, also though the page
  // agent shows an element under its number.
  await assert.rejects(page._checkRef("e1"), /stale/);
  // In another document neither resolves.
  state.doc = "docB";
  await assert.rejects(page._checkRef(`e${issued}`), /stale/);
  await assert.rejects(page._checkRef("e1"), /stale/);
});

test("frame prefixes: detached frames are not kept without bound, and their refs never resolve", async () => {
  const state = { doc: "docA", children: [] };
  const page = fakePage(state);
  const churn = 5000;
  const prefixes = [];
  for (let i = 0; i < churn; i++) {
    state.children = [`c${i}`];
    await page._refreshFrames();
    const frame = page._frames.get(`c${i}`);
    prefixes.push(page._prefixFor(frame));
    page._noteRefDocs(frame, "docA", ["e1"]);
  }
  await page._refreshFrames();
  assert.ok(page._prefixFrames.size < churn, `all ${churn} frame prefixes were kept`);
  assert.ok(entries(page._refDocs) < churn, `the ref records of all ${churn} frames were kept`);
  // The live frame's ref resolves; refs of detached frames, the newest and
  // the oldest, never do.
  assert.equal(await page._checkRef(`${prefixes.at(-1)}e1`), page._frames.get(`c${churn - 1}`));
  await assert.rejects(page._checkRef(`${prefixes.at(-2)}e1`), /stale/);
  await assert.rejects(page._checkRef(`${prefixes[0]}e1`), /stale|does not exist/);
});
