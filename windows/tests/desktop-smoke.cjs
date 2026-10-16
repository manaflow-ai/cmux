// Run with: npx electron tests/desktop-smoke.cjs
// Exercises the real desktop, renderer and ConPTY in a disposable profile.
const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const http = require('node:http');

const profile = process.env.CMUX_DESKTOP_TEST_PROFILE || fs.mkdtempSync(path.join(os.tmpdir(), 'cmux-desktop-test-'));
process.env.APPDATA = profile;
process.env.CMUX_WINDOWS_PIPE = `\\\\.\\pipe\\cmux-desktop-test-${process.pid}`;
app.setPath('userData', path.join(profile, 'electron'));
const output = path.resolve(__dirname, '..', 'test-output');
fs.mkdirSync(output, { recursive: true });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let failed = false;
const errors = [];
const repository = path.resolve(__dirname,'../..');
const chromeSource = fs.readFileSync(path.join(repository,'Sources/WindowChromeMetrics.swift'),'utf8');
const sessionSource = fs.readFileSync(path.join(repository,'Sources/SessionPersistence.swift'),'utf8');
const expectedChrome = Number(chromeSource.match(/sharedChromeBarHeight: CGFloat = (\d+)/)[1]);
const expectedSidebar = Number(sessionSource.match(/defaultSidebarWidth: Double = (\d+)/)[1]);
const fixture = http.createServer((_request, response) => {
  response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
  response.end('<!doctype html><title>Browser verification</title><h1>CMUX_BROWSER_VERIFIED</h1>');
});
fixture.listen(0, '127.0.0.1');
const deadline = setTimeout(() => { console.error('Desktop test timed out'); process.exit(1); }, 60000);

app.on('browser-window-created', (_event, win) => {
  win.webContents.on('console-message', details => {
    if (details?.level === 'error') errors.push(details.message);
  });
  win.webContents.once('did-finish-load', async () => {
    try {
      win.setSize(1280, 800);
      async function evaluate(expression) { return win.webContents.executeJavaScript(expression); }
      async function waitFor(expression) {
        for (let i = 0; i < 150; i++) {
          if (await evaluate(expression)) return;
          await delay(100);
        }
        throw new Error(`Timed out: ${expression}`);
      }
      async function api(route, body, method = 'POST') {
        return evaluate(`(async () => {
          const token = new URL(location.href).searchParams.get('token');
          const response = await fetch(${JSON.stringify(route)} + '?token=' + encodeURIComponent(token), {
            method: ${JSON.stringify(method)}, headers: {'Content-Type':'application/json'},
            ${body === undefined ? '' : `body: JSON.stringify(${JSON.stringify(body)}),`}
          });
          if (!response.ok) throw new Error('API status ' + response.status);
          return response.json();
        })()`);
      }
      await waitFor("document.querySelectorAll('.workspace-row').length > 0");
      const initial = await api('/api/state', undefined, 'GET');
      assert.equal(initial.ptyAvailable, true, 'Tests must use real ConPTY');
      if (process.argv.includes('--restore-session')) {
        const expected = JSON.parse(fs.readFileSync(path.join(profile, 'expected.json'), 'utf8'));
        assert(initial.workspaces.some(w=>w.id===expected.workspaceId && w.panels.length===4), 'Workspace and panels survive a full desktop restart');
        await waitFor("document.querySelectorAll('.pane .xterm').length === 3");
        assert.equal(await evaluate("document.querySelectorAll('.pane-tab').length"),4,'Per-split tab membership survives restart');
        assert.equal(await evaluate("document.getElementById('paneGrid').querySelectorAll('.pane-split').length"), expected.splitCount, 'Nested split tree survives restart');
        console.log('PASS desktop restart: workspace, panels, nested split layout');
        return;
      }
      const workspace = await api('/api/workspaces', { title: 'Windows verification', cwd: path.resolve(__dirname, '../..') });
      await waitFor("document.querySelector('.pane .xterm-helper-textarea') !== null");
      const state = await api('/api/state', undefined, 'GET');
      const active = state.workspaces.find(w => w.id === state.activeWorkspaceId);
      const terminal = active.panels.find(p => p.type === 'terminal');
      assert(terminal, 'New workspace must contain a terminal');
      // Deliver through the actual xterm input handler, then assert rendered output.
      await waitFor("document.querySelector('.xterm-screen').textContent.includes('❯') || document.querySelector('.xterm-screen').textContent.includes('>')");
      win.focus();
      win.webContents.focus();
      await evaluate("document.querySelector('.pane .xterm-helper-textarea').focus()");
      assert(await evaluate("document.activeElement.classList.contains('xterm-helper-textarea')"), 'Terminal must own keyboard focus');
      await win.webContents.insertText("Write-Output ('CMUX_DESKTOP_' + 'VERIFIED')");
      win.webContents.sendInputEvent({ type: 'keyDown', keyCode: 'Enter' });
      win.webContents.sendInputEvent({ type: 'keyUp', keyCode: 'Enter' });
      await waitFor("document.querySelector('.xterm-screen').textContent.includes('CMUX_DESKTOP_VERIFIED')");
      await evaluate("document.getElementById('splitRightButton').click()");
      await waitFor("document.querySelectorAll('.pane .xterm').length === 2");
      await evaluate("document.getElementById('splitDownButton').click()");
      await waitFor("document.querySelectorAll('.pane .xterm').length === 3");
      const originalPanelId = await evaluate("document.querySelector('.pane').dataset.panelId");
      await evaluate("document.querySelector('.pane .pane-new-tab').click()");
      await waitFor("document.querySelectorAll('.pane-tab').length === 4 && document.querySelectorAll('.pane').length === 3");
      await evaluate(`document.querySelector('[data-tab-panel-id="${originalPanelId}"]').click()`);
      await waitFor("document.querySelector('.xterm-screen').textContent.includes('CMUX_DESKTOP_VERIFIED')");
      const tabIds = await evaluate("[...document.querySelector('.pane .pane-tab-strip').children].map(n=>n.dataset.tabPanelId)");
      const newTabId = tabIds.find(id=>id!==originalPanelId);
      assert(newTabId, 'Split must contain two independently selectable tabs');
      await evaluate(`document.querySelector('[data-tab-panel-id="${newTabId}"]').click()`);
      await waitFor(`document.querySelector('.pane').dataset.panelId === '${newTabId}'`);
      await evaluate(`document.querySelector('[data-tab-panel-id="${newTabId}"] .pane-tab-close').click()`);
      await waitFor("document.querySelectorAll('.pane-tab').length === 3 && document.querySelectorAll('.pane').length === 3");
      assert.equal(await evaluate("document.querySelector('.pane').dataset.panelId"),originalPanelId,'Closing active tab preserves its split and selects surviving terminal');
      await evaluate("document.querySelector('.pane .pane-new-tab').click()");
      await waitFor("document.querySelectorAll('.pane-tab').length === 4 && document.querySelectorAll('.pane').length === 3");
      const metrics = await evaluate(`({
        titlebar: document.querySelector('.topbar').getBoundingClientRect().height,
        sidebar: document.querySelector('.sidebar').getBoundingClientRect().width,
        paneHeader: document.querySelector('.pane-header').getBoundingClientRect().height
        ,height: innerHeight, shell: document.getElementById('shell').getBoundingClientRect().height,
        gridBottom: document.getElementById('paneGrid').getBoundingClientRect().bottom,
        gridRows: getComputedStyle(document.querySelector('.main')).gridTemplateRows,
        mainHeight: document.querySelector('.main').getBoundingClientRect().height,
        gap: getComputedStyle(document.querySelector('.main')).gap,
        mainChildren: [...document.querySelector('.main').children].map(n=>({name:n.className,display:getComputedStyle(n).display,height:n.getBoundingClientRect().height})),
        classes: document.getElementById('shell').className
      })`);
      fs.writeFileSync(path.join(output, 'metrics.json'), JSON.stringify(metrics, null, 2));
      assert.equal(metrics.titlebar, expectedChrome, 'Match WindowChromeMetrics.appTitlebarHeight');
      assert.equal(metrics.sidebar, expectedSidebar, 'Match SessionPersistencePolicy.defaultSidebarWidth');
      assert.equal(metrics.paneHeader, expectedChrome, 'Match WindowChromeMetrics.bonsplitTabBarHeight');
      assert.equal(metrics.gridBottom, metrics.height, 'Terminal canvas must fill the window');
      await delay(700);
      fs.writeFileSync(path.join(output, 'desktop.png'), (await win.webContents.capturePage()).toPNG());
      await evaluate("document.getElementById('paletteButton').click()");
      await waitFor("document.getElementById('palette').getAttribute('aria-hidden') === 'false'");
      fs.writeFileSync(path.join(output, 'palette.png'), (await win.webContents.capturePage()).toPNG());
      win.webContents.sendInputEvent({type:'keyDown', keyCode:'Escape'});
      win.webContents.sendInputEvent({type:'keyUp', keyCode:'Escape'});
      const browser = await api('/api/panels', {workspaceId:workspace.id, type:'browser', url:`http://127.0.0.1:${fixture.address().port}/`});
      await waitFor("document.querySelector('webview') !== null");
      const { webContents } = require('electron');
      let guest;
      for (let attempt = 0; attempt < 100; attempt++) {
        guest = webContents.getAllWebContents().find(contents => contents.getType() === 'webview' && contents.getTitle() === 'Browser verification');
        if (guest) break;
        await delay(100);
      }
      assert(guest, 'Browser must load a real page');
      assert.equal(await guest.executeJavaScript('document.querySelector("h1").textContent'), 'CMUX_BROWSER_VERIFIED');
      assert.equal(guest.getLastWebPreferences().sandbox, true);
      assert.equal(guest.getLastWebPreferences().nodeIntegration, false);
      await delay(300);
      fs.writeFileSync(path.join(output, 'browser.png'), (await win.webContents.capturePage()).toPNG());
      await api(`/api/panels/${browser.id}`, undefined, 'DELETE');
      await api('/api/notify', {message:'Build finished'});
      await waitFor("document.getElementById('notificationsRailButton').dataset.count === '1'");
      await waitFor("document.querySelector('.workspace-summary').textContent !== undefined && [...document.querySelectorAll('.workspace-summary')].some(n=>n.textContent === 'Build finished')");
      await evaluate("document.getElementById('notificationsRailButton').click()");
      await waitFor("document.getElementById('shell').classList.contains('inspector-open')");
      await delay(250);
      fs.writeFileSync(path.join(output, 'notifications.png'), (await win.webContents.capturePage()).toPNG());
      await evaluate("document.getElementById('closeInspectorButton').click()");
      for (const [width, height] of [[640,480],[1280,800],[1920,1080]]) {
        win.setSize(width,height);
        await delay(350);
        assert(await evaluate("Math.abs(document.getElementById('paneGrid').getBoundingClientRect().bottom - innerHeight) < 1"), 'Canvas must fill every window size');
        assert(await evaluate("document.documentElement.scrollWidth === innerWidth"), 'No horizontal page overflow');
        assert(await evaluate("[...document.querySelectorAll('.pane')].every(n=>n.getBoundingClientRect().width > 0 && n.getBoundingClientRect().height > 28)"), 'Every split remains visible');
        fs.writeFileSync(path.join(output, `desktop-${width}.png`), (await win.webContents.capturePage()).toPNG());
      }
      const saved = JSON.parse(fs.readFileSync(path.join(profile, 'cmux-windows', 'session.json'), 'utf8'));
      assert(saved.workspaces.some(w=>w.id===workspace.id && w.panels.length===4), 'Persist workspace and terminal layout');
      fs.writeFileSync(path.join(profile, 'expected.json'), JSON.stringify({workspaceId:workspace.id, splitCount:await evaluate("document.getElementById('paneGrid').querySelectorAll('.pane-split').length")}));
      assert.equal(errors.length, 0, errors.join('\n'));
      console.log('PASS real desktop: ConPTY keyboard input/output, workspaces, nested splits, tab creation/switch/close, palette, sandboxed browser, notifications, persistence, three window sizes');
      console.log(`Screenshots: ${output}`);
    } catch (error) {
      failed = true;
      console.error(error.stack);
      console.error(await win.webContents.executeJavaScript("JSON.stringify({focus:document.activeElement.className, classes:document.getElementById('shell').className,main:getComputedStyle(document.querySelector('.main')).gridTemplateRows})"));
      fs.writeFileSync(path.join(output, 'failure.png'), (await win.webContents.capturePage()).toPNG());
    } finally {
      clearTimeout(deadline);
      fixture.close();
      // Normal quit invokes main.cjs's runtime/terminal cleanup.
      for (const window of BrowserWindow.getAllWindows()) window.destroy();
      app.quit();
    }
  });
});
app.on('will-quit', event => { if (failed) { event.preventDefault(); app.exit(1); } });
require('../src/main.cjs');
