import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { Blob } from 'node:buffer';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';

const page = fs.readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
const attachmentCode = page.slice(page.indexOf('  async function previewImage('), page.indexOf('  function startDraft('));
const sendCode = page.slice(page.indexOf('  async function send('), page.indexOf('  let toastEl'));
const stateCode = page.slice(page.indexOf('  // ---------- state'), page.indexOf('  function renderAttachments('));
function harness({ fail = '', decodeFails = false } = {}) {
  const input = { value: 'keep this draft', focus() {} };
  const calls = [], decoded = [], canvases = [], reads = [], uploads = new Map();
  let accept;
  const context = vm.createContext({
    console, Blob, Buffer, crypto: { randomUUID },
    $: () => input,
    loadProjectPrefs: () => ({}), renderAttachments() {}, autosize() {},
    createImageBitmap: async (_file, options) => {
      decoded.push(options);
      if (decodeFails) throw Error('decode failed');
      return { width: options?.resizeWidth || 50000, height: options?.resizeHeight || 50000, close() {} };
    },
    document: { createElement() {
      const canvas = { width: 0, height: 0, getContext: () => ({ drawImage() {}, fillRect() {}, fillText() {} }),
        toDataURL: () => 'data:image/png;base64,preview' };
      canvases.push(canvas); return canvas;
    } },
    FileReader: class {
      async readAsDataURL(blob) {
        reads.push(blob.size);
        this.result = 'data:application/octet-stream;base64,' + Buffer.from(await blob.arrayBuffer()).toString('base64');
        this.onload();
      }
    },
    call: async (method, params) => {
      const size = Buffer.byteLength(JSON.stringify({ method, params }));
      calls.push({ method, params, size });
      if (size > 15 * 1024 * 1024) throw Error('peer message exceeds 15 MiB');
      if (method === fail) throw Error('injected refusal');
      if (method === '_acpmux/file_put_begin') {
        const uploadId = randomUUID(); uploads.set(uploadId, []);
        return { uploadId, ownerToken: randomUUID() };
      }
      if (method === '_acpmux/file_put_chunk') uploads.get(params.uploadId).push(Buffer.from(params.data, 'base64'));
      if (method === 'session/prompt') {
        assert.equal(input.value, 'keep this draft', 'draft cleared before server acceptance');
        accept?.(params);
      }
      return {};
    },
    newTranscript: () => ({ items: [], status: '', dirty: new Set() }),
    touch() {}, scheduleRender() {}, toast() {}, openDirectory() {},
    draftMeta: () => ({}), upsertSession() {}, select() {},
  });
  vm.runInContext(stateCode + attachmentCode + sendCode, context);
  vm.runInContext("selected = 'peer/session-1';", context);
  return { context, input, calls, decoded, canvases, reads, uploads,
    run: (s) => vm.runInContext(s, context), onPrompt: (f) => { accept = f; } };
}
function file(bytes) { const f = new Blob([bytes], { type: 'image/png' }); f.name = 'original.png'; return f; }

// This same file is the pre-fix red and post-fix green command on the remote runner.
test('12 MiB original crosses peer boundary in bounded chunks and clears only after acceptance', async () => {
  const h = harness();
  const original = Buffer.alloc(12 * 1024 * 1024 + 37);
  for (let i = 0; i < original.length; i++) original[i] = i % 251;
  h.context.file = file(original);
  await h.run('readImage(file).then(image => promptImages.push(image))');
  await h.run('send(false)');
  const prompt = h.calls.find(c => c.method === 'session/prompt');
  assert.ok(prompt, 'no prompt reached peer');
  assert.ok(prompt.size < 1024 * 1024, 'original sent inline');
  assert.equal(h.uploads.size, 1);
  assert.deepEqual(Buffer.concat([...h.uploads.values()][0]), original, 'original bytes changed');
  assert.ok(h.calls.every(c => c.size < 1024 * 1024), 'transport frame unbounded');
  assert.ok(h.reads.every(size => size <= 512 * 1024), 'whole original read');
  assert.ok(h.decoded[0]?.resizeWidth <= 1024 && h.decoded[0]?.resizeHeight <= 1024, 'decode unbounded');
  assert.ok(h.canvases.every(c => c.width <= 1024 && c.height <= 1024));
  assert.equal(h.input.value, '');
});

test('upload or prompt refusal preserves text and original attachment for retry', async () => {
  for (const fail of ['_acpmux/file_put_chunk', 'session/prompt']) {
    const h = harness({ fail });
    h.context.file = file(Buffer.alloc(12 * 1024 * 1024));
    await h.run('readImage(file).then(image => promptImages.push(image))');
    await h.run('send(false)');
    assert.equal(h.input.value, 'keep this draft');
    assert.equal(h.run('promptImages.length'), 1);
    assert.equal(h.run('promptImages[0].file'), h.context.file);
    assert.ok(h.calls.some(c => c.method === '_acpmux/file_put_cancel'), 'failed upload not cleaned');
  }
});

test('failed decode returns bounded placeholder and retains original', async () => {
  const h = harness({ decodeFails: true });
  h.context.file = file(Buffer.alloc(12 * 1024 * 1024));
  const image = await h.run('readImage(file)');
  assert.equal(image.file, h.context.file);
  assert.equal(image.url, 'data:image/png;base64,preview');
  assert.ok(h.reads.every(n => n <= 512 * 1024));
});
