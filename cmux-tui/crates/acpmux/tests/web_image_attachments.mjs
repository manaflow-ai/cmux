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
function harness({ fail = '', decodeFails = false, onChunk = null, promptReply = null } = {}) {
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
      if (method === '_acpmux/file_put_chunk') { uploads.get(params.uploadId).push(Buffer.from(params.data, 'base64')); onChunk?.(input); }
      if (method === 'session/prompt') {
        if (!onChunk) assert.equal(input.value, 'keep this draft', 'draft cleared before server acceptance');
        accept?.(params);
        if (promptReply) return promptReply;
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
  Buffer.from('89504e470d0a1a0a', 'hex').copy(original);
  original.writeUInt32BE(20000, 16); original.writeUInt32BE(10000, 20);
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
  assert.equal(h.decoded[0].resizeWidth, 1024); assert.equal(h.decoded[0].resizeHeight, 512);
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


test('acceptance frees the composer before turn completion; later failure keeps accepted originals', async () => {
  let rejectTurn, accepted;
  const turn = new Promise((_, reject) => { rejectTurn = reject; });
  const receipt = new Promise(resolve => { accepted = resolve; });
  const h = harness({ promptReply: turn });
  h.context.file = file(Buffer.from('image'));
  await h.run('readImage(file).then(image => promptImages.push(image))');
  h.onPrompt(params => {
    h.context.acceptedId = params._meta.acpmux.promptId;
    h.run('promptAccepts.get(acceptedId)()');
    accepted();
  });
  const sending = h.run('send(false)');
  await receipt;
  assert.equal(h.input.value, '');
  assert.equal(h.run('sendingPrompt'), false);
  rejectTurn(Error('agent failed after acceptance'));
  await sending;
  assert.equal(h.calls.filter(c => c.method === '_acpmux/file_put_cancel').length, 0);
});

test('edits and a second send during upload do not replace or duplicate the submitted draft', async () => {
  const h = harness({ onChunk: input => { input.value = 'new text'; } });
  h.context.file = file(Buffer.alloc(2 * 1024 * 1024));
  await h.run('readImage(file).then(image => promptImages.push(image))');
  await Promise.all([h.run('send(false)'), h.run('send(false)')]);
  assert.equal(h.calls.filter(c => c.method === 'session/prompt').length, 1);
  assert.equal(h.input.value, 'new text');
});


test('very tall images bound both decoder dimensions', async () => {
  const h = harness();
  const bytes = Buffer.alloc(128);
  Buffer.from('89504e470d0a1a0a', 'hex').copy(bytes);
  bytes.writeUInt32BE(10, 16); bytes.writeUInt32BE(100000, 20);
  h.context.file = file(bytes);
  await h.run('readImage(file)');
  assert.equal(h.decoded[0].resizeWidth, 1);
  assert.equal(h.decoded[0].resizeHeight, 1024);
});

const eventCode = page.slice(page.indexOf('  function applyEventInner('), page.indexOf('  const pendingPermission'));
function eventHarness(options) {
  const h = harness(options);
  vm.runInContext(eventCode, h.context);
  h.event = (kind, msg) => { h.context.ev = { dir: 'mux', kind, msg, at: Date.now() }; h.run("applyEventInner(state.transcripts.get('peer/session-1'), ev)"); };
  h.rows = () => h.run("state.transcripts.get('peer/session-1').items.filter(x => x.type === 'user')");
  h.run("state.transcripts.set('peer/session-1', newTranscript())");
  return h;
}

test('sending works where crypto.randomUUID is missing (plain HTTP origins)', async () => {
  const h = harness();
  h.context.crypto = { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = (i * 37 + 11) & 255; return a; } };
  h.input.value = 'hello';
  await h.run('send(false)');
  const prompt = h.calls.find(c => c.method === 'session/prompt');
  assert.ok(prompt, 'the prompt never reached the server');
  assert.match(prompt.params._meta.acpmux.promptId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(h.run('sendingPrompt'), false, 'the composer stays locked');
});

test('a queued event before acceptance leaves one row, which the prompt start replaces', async () => {
  const h = eventHarness();
  h.run("state.transcripts.get('peer/session-1').status = 'running'");
  h.onPrompt(params => {
    h.event('queued', { text: 'keep this draft', promptId: params._meta.acpmux.promptId });
    h.context.acceptedId = params._meta.acpmux.promptId;
    h.run('promptAccepts.get(acceptedId)()');
  });
  await h.run('send(false)');
  assert.equal(h.rows().length, 1, 'acceptance added a second row');
  h.event('user_message', { text: 'keep this draft', promptId: h.context.acceptedId });
  const rows = h.rows();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].queued, undefined, 'a row stays queued forever');
});

test('two queued sends with the same text keep two rows whatever order their events arrive in', async () => {
  const h = eventHarness();
  h.run("state.transcripts.get('peer/session-1').status = 'running'");
  const ids = [];
  // A: accepted first, its queued event later. B: queued event first, then accepted.
  h.onPrompt(params => {
    const id = params._meta.acpmux.promptId; ids.push(id);
    h.context.acceptedId = id;
    if (ids.length === 1) { h.run('promptAccepts.get(acceptedId)()'); }
    else { h.event('queued', { text: 'keep this draft', promptId: id }); h.run('promptAccepts.get(acceptedId)()'); }
  });
  h.input.value = 'keep this draft';
  await h.run('send(false)');
  h.input.value = 'keep this draft';
  await h.run('send(false)');
  h.event('queued', { text: 'keep this draft', promptId: ids[0] });
  const rows = h.rows();
  assert.equal(rows.length, 2, 'two prompts collapsed into one row');
  assert.deepEqual(rows.map(r => r.promptId).sort(), [...ids].sort());
});

test('a dropped acceptance does not reopen a finished turn when the final response arrives', async () => {
  const h = eventHarness();
  h.context.refreshActivity = () => {};
  // The prompt_accepted notification is lost (server queue pressure); the whole turn runs
  // before session/prompt returns, so the final response is the first acceptance the page sees.
  h.onPrompt(params => {
    h.event('user_message', { text: 'keep this draft', promptId: params._meta.acpmux.promptId });
    h.event('status', { status: 'running' });
    h.event('status', { status: 'ready' });
  });
  await h.run('send(false)');
  const t = h.run("state.transcripts.get('peer/session-1')");
  assert.equal(t.status, 'ready', 'the finished chat shows Working forever');
  assert.equal(t.runningSince, 0);
  assert.equal(h.rows().length, 1);
  assert.equal(h.rows()[0].queued, undefined);
  assert.equal(h.run('sendingPrompt'), false);
});

test('a user_message before acceptance keeps the submitted image previews', async () => {
  const h = eventHarness();
  h.context.file = file(Buffer.from('image'));
  await h.run('readImage(file).then(image => promptImages.push(image))');
  h.onPrompt(params => {
    h.event('user_message', { text: 'keep this draft', promptId: params._meta.acpmux.promptId });
    h.context.acceptedId = params._meta.acpmux.promptId;
    h.run('promptAccepts.get(acceptedId)()');
  });
  await h.run('send(false)');
  const rows = h.rows();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].images?.length, 1, 'the accepted row lost its image previews');
});

test('a later upload failure cleans every earlier completed upload and retains all originals', async () => {
  const h = harness();
  h.context.files = [file(Buffer.from('first')), file(Buffer.from('second'))];
  await h.run('Promise.all(files.map(readImage)).then(images => promptImages.push(...images))');
  const call = h.context.call;
  let chunk = 0;
  h.context.call = async (method, params) => {
    if (method === '_acpmux/file_put_chunk' && ++chunk === 2) throw Error('second file failed');
    return call(method, params);
  };
  await h.run('send(false)');
  assert.equal(h.input.value, 'keep this draft');
  assert.equal(h.run('promptImages.length'), 2);
  assert.equal(h.calls.filter(c => c.method === '_acpmux/file_put_cancel').length, 2);
  assert.equal(h.calls.filter(c => c.method === 'session/prompt').length, 0);
});
