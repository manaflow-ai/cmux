const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { once } = require('node:events');
const { spawnSync } = require('node:child_process');

const modulePath = path.resolve(__dirname, '../Resources/claude-attach-observer.cjs');
// On the unfixed base, native sockets have no attachment observer.
const observerModule = fs.existsSync(modulePath) ? require(modulePath) : {};
const install = observerModule.installObserver ?? (() => () => {});
const createReportQueue = observerModule.createReportQueue ?? (() => ({ report: () => {}, flush: () => {} }));

async function exchange(t, response, { oversized = false, unrelated = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cmux-attach-test-'));
  const socketPath = path.join(root, 'control.sock');
  const events = [];
  const restore = install({ report: value => events.push(value), acceptsPath: p => !unrelated && p === socketPath });
  const request = { proto: 1, op: 'attach', short: 'aabbccdd',
    attachId: '11111111-1111-4111-8111-111111111111', auth: 'SECRET_DO_NOT_COPY' };
  let received = '';
  const server = net.createServer(socket => {
    socket.on('data', data => {
      received += data;
      if (!received.endsWith('\n')) return;
      socket.write(response.slice(0, 7));
      setImmediate(() => socket.end(response.slice(7)));
    });
  });
  t.after(() => { restore(); server.close(); fs.rmSync(root, { recursive: true, force: true }); });
  server.listen(socketPath); await once(server, 'listening');
  const client = net.createConnection(socketPath);
  let reply = '';
  client.on('data', data => { reply += data; });
  const closed = once(client, 'close');
  await once(client, 'connect');
  const line = oversized ? 'x'.repeat(70000) + '\n' : JSON.stringify(request) + '\n';
  client.write(line.slice(0, 11));
  assert.equal(events.length, 0, 'a request alone is not an acknowledged attachment');
  client.write(line.slice(11));
  await closed;
  assert.equal(received, line, 'observer must not change outgoing bytes');
  assert.equal(reply, response, 'observer must not change reply or terminal output');
  return events;
}

test('acknowledged attach and close report one lease without authentication or terminal output', async t => {
  const events = await exchange(t, '{"ok":true,"op":"attach"}\nPRIVATE TERMINAL OUTPUT');
  assert.deepEqual(events.map(e => e.action), ['attached', 'detached']);
  assert.equal(events[0].attach_id, events[1].attach_id);
  assert.equal(events[0].job_id, 'aabbccdd');
  assert.ok(!JSON.stringify(events).includes('SECRET'));
  assert.ok(!JSON.stringify(events).includes('PRIVATE TERMINAL'));
});
test('failed attach creates no lease', async t => {
  assert.deepEqual(await exchange(t, '{"ok":false,"op":"attach"}\n'), []);
});
test('unrelated socket is never observed', async t => {
  assert.deepEqual(await exchange(t, '{"ok":true,"op":"attach"}\n', { unrelated: true }), []);
});
test('oversized protocol line fails closed without modifying transport', async t => {
  assert.deepEqual(await exchange(t, '{"ok":true,"op":"attach"}\n', { oversized: true }), []);
});
test('two overlapping attachments keep independent leases', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cmux-attach-concurrent-'));
  const socketPath = path.join(root, 'control.sock');
  const events = [];
  const restore = install({ report: value => events.push(value), acceptsPath: p => p === socketPath });
  const server = net.createServer(socket => {
    socket.on('data', data => {
      if (data.toString().includes('\n')) socket.write('{"ok":true,"op":"attach"}\n');
    });
  });
  t.after(() => { restore(); server.close(); fs.rmSync(root, { recursive: true, force: true }); });
  server.listen(socketPath); await once(server, 'listening');
  const idA = '11111111-1111-4111-8111-111111111111';
  const idB = '22222222-2222-4222-8222-222222222222';
  const clientA = net.createConnection(socketPath);
  const clientB = net.createConnection(socketPath);
  clientA.on('data', () => {}); clientB.on('data', () => {});
  await once(clientA, 'connect'); await once(clientB, 'connect');
  clientA.write(JSON.stringify({ proto: 1, op: 'attach', short: 'aaaaaaaa', attachId: idA }) + '\n');
  clientB.write(JSON.stringify({ proto: 1, op: 'attach', short: 'bbbbbbbb', attachId: idB }) + '\n');
  const waitFor = async predicate => {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error('observer event did not arrive before the deadline');
  };
  await waitFor(() => events.filter(e => e.action === 'attached').length === 2);
  assert.deepEqual(events.filter(e => e.action === 'attached').map(e => e.attach_id).sort(), [idA, idB].sort());
  const closedA = once(clientA, 'close');
  clientA.destroy(); await closedA;
  await waitFor(() => events.some(e => e.action === 'detached' && e.attach_id === idA));
  assert.ok(!events.some(e => e.action === 'detached' && e.attach_id === idB),
    'the remaining attachment keeps its lease');
  const closedB = once(clientB, 'close');
  clientB.destroy(); await closedB;
  await waitFor(() => events.some(e => e.action === 'detached' && e.attach_id === idB));
});

test('generated preload loads under Bun when the lane provides it', t => {
  const bun = spawnSync('bun', ['--version'], { encoding: 'utf8' });
  if (bun.error || bun.status !== 0) {
    t.skip('Bun is not installed; automated checks do not load the preload');
    return;
  }
  const result = spawnSync('bun', ['--preload', modulePath, '-e',
    'process.stdout.write("preload-ok")'], { encoding: 'utf8', timeout: 15000 });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'preload-ok');
});

test('a closed acknowledged connection records an authoritative closure', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cmux-attach-closed-'));
  const socketPath = path.join(root, 'control.sock');
  const closed = [];
  let attachedResolve;
  const attached = new Promise(resolve => { attachedResolve = resolve; });
  const restore = install({
    report: value => { if (value.action === 'attached') attachedResolve(); },
    acceptsPath: p => p === socketPath,
    onClosed: attachment => closed.push(attachment),
  });
  const server = net.createServer(socket => {
    socket.on('data', data => {
      if (data.toString().includes('\n')) socket.write('{"ok":true,"op":"attach"}\n');
    });
  });
  t.after(() => { restore(); server.close(); fs.rmSync(root, { recursive: true, force: true }); });
  server.listen(socketPath); await once(server, 'listening');
  const attachment = '33333333-3333-4333-8333-333333333333';
  const client = net.createConnection(socketPath);
  client.on('data', () => {});
  await once(client, 'connect');
  client.write(JSON.stringify({ proto: 1, op: 'attach', short: 'cccccccc', attachId: attachment }) + '\n');
  await Promise.race([attached, new Promise((_, reject) => setTimeout(() => reject(new Error('attach not acknowledged')), 5000))]);
  const closedEvent = once(client, 'close');
  client.destroy();
  await closedEvent;
  assert.deepEqual(closed, [attachment]);
});

test('a closed connection cancels its queued attach', () => {
  const calls = [];
  const queue = createReportQueue(value => {
    calls.push(value.action);
    return value.action === 'detached';
  }, { schedule: () => null, now: () => 0 });
  queue.report({ action: 'attached', attach_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', job_id: 'job', viewer_pid: 1 });
  queue.report({ action: 'detached', attach_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', job_id: 'job', viewer_pid: 1 });
  queue.flush();
  assert.deepEqual(calls, ['attached', 'detached'], 'the pending attach must not be retried after close');
});

test('preload restores Bun options and removes private context before children', () => {
  const result = spawnSync(process.execPath, ['--require', modulePath, '-e', `
    const assert=require('node:assert/strict');
    assert.equal(process.env.BUN_OPTIONS,'--smol');
    assert.equal(process.env.CMUX_CLAUDE_ATTACH_CONTEXT,undefined);
    assert.equal(process.env.CMUX_CLAUDE_ATTACH_ORIGINAL_BUN_OPTIONS,undefined);
    const child=require('node:child_process').spawnSync(process.execPath,['-e',
      'process.stdout.write(JSON.stringify({bun:process.env.BUN_OPTIONS,context:process.env.CMUX_CLAUDE_ATTACH_CONTEXT}))'],{encoding:'utf8'});
    assert.deepEqual(JSON.parse(child.stdout),{bun:'--smol'});
  `], { encoding:'utf8', env:{...process.env,
    BUN_OPTIONS:'--preload /private/module --smol',
    CMUX_CLAUDE_ATTACH_CONTEXT:JSON.stringify({cli:'/nonexistent-test-sink',environment:{}}),
    CMUX_CLAUDE_ATTACH_ORIGINAL_BUN_OPTIONS:'--smol',CMUX_CLAUDE_ATTACH_BUN_OPTIONS_PRESENT:'1'} });
  assert.equal(result.status,0,result.stderr);
});
