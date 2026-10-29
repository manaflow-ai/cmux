// Behavioral harness for the React Grab bridge scripts.
//
// Extracts the real JavaScript templates from
// Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Scripting/ReactGrabBridgeScripts.swift
// (between the begin/end markers) and runs them in a simulated two-world
// WebKit environment: the page world (site scripts, react-grab library) and
// the cmux isolated content world (relay + native message handler). The two
// worlds share a window message bus, mirroring how window.postMessage data is
// structured-cloned across content worlds, while JS globals stay per-world.
//
// Run: node --test tests/react_grab_bridge.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const bridgeScriptsSwiftPath = join(
  repoRoot,
  'Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Scripting/ReactGrabBridgeScripts.swift',
);
const reactGrabSwiftPath = join(repoRoot, 'Sources/Panels/ReactGrab.swift');

function loadSources() {
  const bridgeSwift = readFileSync(bridgeScriptsSwiftPath, 'utf8');
  const reactGrabSwift = readFileSync(reactGrabSwiftPath, 'utf8');

  const handlerMatch = reactGrabSwift.match(
    /let reactGrabMessageHandlerName = "([A-Za-z0-9_]+)"/,
  );
  assert.ok(handlerMatch, 'handler name not found in ReactGrab.swift');
  const handlerName = handlerMatch[1];

  const maxMatch = bridgeSwift.match(
    /static let maxContentLength(?::\s*Int)?\s*=\s*([0-9_]+)/,
  );
  assert.ok(maxMatch, 'maxContentLength not found in ReactGrabBridgeScripts.swift');
  const maxContentLength = Number.parseInt(maxMatch[1].replaceAll('_', ''), 10);

  const extract = (beginMarker, endMarker) => {
    const begin = bridgeSwift.indexOf(beginMarker);
    const end = bridgeSwift.indexOf(endMarker);
    assert.ok(begin !== -1, `missing marker ${beginMarker}`);
    assert.ok(end !== -1 && end > begin, `missing marker ${endMarker}`);
    return bridgeSwift.slice(begin + beginMarker.length, end);
  };

  const relayTemplate = extract(
    '// cmux-react-grab-relay-begin',
    '// cmux-react-grab-relay-end',
  );
  const tokenSyncTemplate = extract(
    '// cmux-react-grab-token-sync-begin',
    '// cmux-react-grab-token-sync-end',
  );
  const pageBridgeTemplate = extract(
    '// cmux-react-grab-page-bridge-begin',
    '// cmux-react-grab-page-bridge-end',
  );

  const relaySource = relayTemplate
    .replaceAll('__CMUX_RG_HANDLER__', handlerName)
    .replaceAll('__CMUX_RG_MAX_CONTENT_LENGTH__', String(maxContentLength));
  const tokenSyncSource = (token) =>
    tokenSyncTemplate.replaceAll(
      '__CMUX_RG_TOKEN_LITERAL__',
      token === null ? 'null' : `'${token}'`,
    );

  return {
    handlerName,
    maxContentLength,
    relaySource,
    tokenSyncSource,
    pageBridgeTemplate,
  };
}

function makeEventTargetWindow() {
  const listeners = [];
  const win = {
    __listenerErrors: [],
    addEventListener(type, fn, options) {
      listeners.push({ type, fn, once: Boolean(options && options.once) });
    },
    removeEventListener(type, fn) {
      const index = listeners.findIndex(
        (entry) => entry.type === type && entry.fn === fn,
      );
      if (index !== -1) listeners.splice(index, 1);
    },
    __dispatch(type, event) {
      const snapshot = listeners.filter((entry) => entry.type === type);
      for (const entry of snapshot) {
        if (entry.once) {
          const index = listeners.indexOf(entry);
          if (index !== -1) listeners.splice(index, 1);
        }
        // DOM semantics: one listener throwing does not stop dispatch.
        try {
          entry.fn(event);
        } catch (error) {
          win.__listenerErrors.push(error);
        }
      }
    },
  };
  return win;
}

function makeHarness(handlerName) {
  const nativeMessages = [];
  let nativeFailuresRemaining = 0;
  const pageWindow = makeEventTargetWindow();
  const isolatedWindow = makeEventTargetWindow();

  // window.postMessage to the same window: listeners in every content world
  // observe the message with an independent structured clone, and in each
  // world event.source is that world's own window proxy for the same window.
  const deliverSameWindow = (data) => {
    pageWindow.__dispatch('message', {
      source: pageWindow,
      data: structuredClone(data),
    });
    isolatedWindow.__dispatch('message', {
      source: isolatedWindow,
      data: structuredClone(data),
    });
  };
  pageWindow.postMessage = (data) => deliverSameWindow(data);
  isolatedWindow.postMessage = (data) => deliverSameWindow(data);

  // Only the isolated content world can see the native script-message handler.
  isolatedWindow.webkit = {
    messageHandlers: {
      [handlerName]: {
        postMessage(message) {
          if (nativeFailuresRemaining > 0) {
            nativeFailuresRemaining -= 1;
            throw new Error('simulated native handler failure');
          }
          nativeMessages.push(structuredClone(message));
        },
      },
    },
  };

  return {
    pageWindow,
    isolatedWindow,
    nativeMessages,
    failNextNativePost() {
      nativeFailuresRemaining += 1;
    },
    // A message whose source is another frame's window (e.g. an embedded
    // iframe posting into its parent): source !== window in every world.
    dispatchForeignSource(data) {
      const foreignWindow = {};
      pageWindow.__dispatch('message', {
        source: foreignWindow,
        data: structuredClone(data),
      });
      isolatedWindow.__dispatch('message', {
        source: foreignWindow,
        data: structuredClone(data),
      });
    },
  };
}

function runInWorld(source, windowObject) {
  return vm.runInNewContext(source, { window: windowObject });
}

function makeFakeGrabAPI() {
  const api = {
    plugins: [],
    activateCount: 0,
    registerPlugin(plugin) {
      api.plugins.push(plugin);
    },
    activate() {
      api.activateCount += 1;
    },
  };
  return api;
}

function postCopyFromPage(harness, content) {
  harness.pageWindow.postMessage({
    __cmuxReactGrab: true,
    type: 'copySuccess',
    content,
  });
}

const sources = loadSources();

test('relay installs once per document and hides its surface from enumeration', () => {
  const harness = makeHarness(sources.handlerName);
  assert.equal(runInWorld(sources.relaySource, harness.isolatedWindow), true);
  // Idempotent: a second evaluation must not add a second message listener.
  assert.equal(runInWorld(sources.relaySource, harness.isolatedWindow), true);

  const descriptor = Object.getOwnPropertyDescriptor(
    harness.isolatedWindow,
    '__cmuxReactGrabRelay',
  );
  assert.ok(descriptor, 'relay anchor missing');
  assert.equal(descriptor.enumerable, false);
  assert.equal(descriptor.writable, false);
  assert.equal(descriptor.configurable, false);

  assert.equal(
    runInWorld(sources.tokenSyncSource('tok-single'), harness.isolatedWindow),
    true,
  );
  postCopyFromPage(harness, 'once');
  assert.equal(
    harness.nativeMessages.filter((m) => m.type === 'copySuccess').length,
    1,
    'duplicate relay listener delivered the one-shot token twice',
  );
});

test('page bridge source carries no native handler or token plumbing', () => {
  assert.ok(
    !sources.pageBridgeTemplate.includes('messageHandlers'),
    'page bridge must not reference script message handlers',
  );
  assert.ok(
    !sources.pageBridgeTemplate.includes('webkit'),
    'page bridge must not reference window.webkit',
  );
  assert.ok(
    !sources.pageBridgeTemplate.toLowerCase().includes('token'),
    'page bridge must not carry token plumbing',
  );
});

test('page bridge never touches window.webkit at runtime', () => {
  const harness = makeHarness(sources.handlerName);
  const accessedProperties = [];
  const trapped = new Proxy(harness.pageWindow, {
    get(target, property, receiver) {
      accessedProperties.push(property);
      return Reflect.get(target, property, receiver);
    },
  });
  trapped.__REACT_GRAB__ = makeFakeGrabAPI();
  runInWorld(sources.pageBridgeTemplate, trapped);
  const hooks = harness.pageWindow.__REACT_GRAB__.plugins[0].hooks;
  hooks.onCopySuccess([], 'anything');
  assert.ok(
    !accessedProperties.includes('webkit'),
    'page bridge read window.webkit',
  );
});

test('token sync reports absence of the relay and arms it when present', () => {
  const harness = makeHarness(sources.handlerName);
  assert.equal(
    runInWorld(sources.tokenSyncSource('tok-early'), harness.isolatedWindow),
    false,
    'sync must fail while no relay is installed',
  );
  assert.equal(runInWorld(sources.relaySource, harness.isolatedWindow), true);
  assert.equal(
    runInWorld(sources.tokenSyncSource('tok-1'), harness.isolatedWindow),
    true,
  );
});

test('unarmed copySuccess is rejected', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  postCopyFromPage(harness, 'echo injected');
  assert.deepEqual(harness.nativeMessages, []);
});

test('disarming via a null token sync revokes a previously armed relay', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-armed'), harness.isolatedWindow);
  assert.equal(
    runInWorld(sources.tokenSyncSource(null), harness.isolatedWindow),
    true,
  );
  postCopyFromPage(harness, 'echo injected');
  assert.deepEqual(harness.nativeMessages, []);
});

test('armed grab flow delivers content with the isolated-world token', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-A'), harness.isolatedWindow);

  harness.pageWindow.__REACT_GRAB__ = makeFakeGrabAPI();
  runInWorld(sources.pageBridgeTemplate, harness.pageWindow);
  const api = harness.pageWindow.__REACT_GRAB__;
  assert.equal(api.activateCount, 1, 'existing api must be activated');
  assert.equal(api.plugins.length, 1);

  api.plugins[0].hooks.onCopySuccess([], '<Button onClick={run} />');
  assert.deepEqual(harness.nativeMessages, [
    {
      type: 'copySuccess',
      content: '<Button onClick={run} />',
      token: 'tok-A',
    },
  ]);
});

test('delivery is one-shot until natively rearmed', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-A'), harness.isolatedWindow);
  postCopyFromPage(harness, 'first');
  postCopyFromPage(harness, 'second');
  assert.equal(harness.nativeMessages.length, 1);
  assert.equal(harness.nativeMessages[0].content, 'first');
});

test('rearming with a fresh token allows the next grab', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-A'), harness.isolatedWindow);
  postCopyFromPage(harness, 'first');
  runInWorld(sources.tokenSyncSource('tok-B'), harness.isolatedWindow);
  postCopyFromPage(harness, 'second');
  assert.equal(harness.nativeMessages.length, 2);
  assert.equal(harness.nativeMessages[1].token, 'tok-B');
  assert.equal(harness.nativeMessages[1].content, 'second');
});

test('messages from another frame are rejected and do not burn the arm', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-A'), harness.isolatedWindow);
  harness.dispatchForeignSource({
    __cmuxReactGrab: true,
    type: 'copySuccess',
    content: 'iframe payload',
  });
  assert.deepEqual(harness.nativeMessages, []);
  postCopyFromPage(harness, 'legit');
  assert.equal(harness.nativeMessages.length, 1);
  assert.equal(harness.nativeMessages[0].content, 'legit');
});

test('oversize content is refused and consumes the arm', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-A'), harness.isolatedWindow);
  postCopyFromPage(harness, 'x'.repeat(sources.maxContentLength + 1));
  assert.deepEqual(harness.nativeMessages, []);
  // The failed oversize attempt must have consumed the one-shot arm.
  postCopyFromPage(harness, 'after oversize');
  assert.deepEqual(harness.nativeMessages, []);
  // At-bound content passes after rearming.
  runInWorld(sources.tokenSyncSource('tok-B'), harness.isolatedWindow);
  const bounded = 'y'.repeat(sources.maxContentLength);
  postCopyFromPage(harness, bounded);
  assert.equal(harness.nativeMessages.length, 1);
  assert.equal(harness.nativeMessages[0].content.length, sources.maxContentLength);
});

test('line endings, control characters, and multibyte text pass through intact', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-A'), harness.isolatedWindow);
  const content = 'line1\nline2\r\n\tesc:\u001b[31m red \u0000 nul é 山 🙂';
  postCopyFromPage(harness, content);
  assert.equal(harness.nativeMessages.length, 1);
  assert.equal(harness.nativeMessages[0].content, content);
});

test('state changes relay without any token attached', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  harness.pageWindow.postMessage({
    __cmuxReactGrab: true,
    type: 'stateChange',
    isActive: 1,
  });
  assert.deepEqual(harness.nativeMessages, [
    { type: 'stateChange', isActive: true },
  ]);
  assert.ok(!('token' in harness.nativeMessages[0]));
});

test('bridge installs through react-grab:init and reactivates the api once', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.pageBridgeTemplate, harness.pageWindow);
  const api = makeFakeGrabAPI();
  harness.pageWindow.__dispatch('react-grab:init', { detail: api });
  assert.equal(api.plugins.length, 1);
  assert.equal(api.activateCount, 1);
  // A page re-dispatching init must not double-install the bridge.
  harness.pageWindow.__dispatch('react-grab:init', { detail: api });
  runInWorld(sources.pageBridgeTemplate, harness.pageWindow);
  assert.equal(api.plugins.length, 1);
});

test('copy ordering: the token is consumed before native delivery', () => {
  const harness = makeHarness(sources.handlerName);
  runInWorld(sources.relaySource, harness.isolatedWindow);
  runInWorld(sources.tokenSyncSource('tok-C'), harness.isolatedWindow);
  harness.failNextNativePost();
  postCopyFromPage(harness, 'first attempt');
  assert.equal(harness.isolatedWindow.__listenerErrors.length, 1);
  assert.deepEqual(harness.nativeMessages, []);
  // The token must not be replayable after the failed delivery.
  postCopyFromPage(harness, 'replay attempt');
  assert.deepEqual(harness.nativeMessages, []);
});
