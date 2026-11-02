const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { once } = require('node:events');

const modulePath = path.resolve(__dirname, '../Resources/claude-attach-observer.cjs');
// On the unfixed base, native sockets have no attachment observer.
const install = fs.existsSync(modulePath)
  ? require(modulePath).installObserver : () => () => {};

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
