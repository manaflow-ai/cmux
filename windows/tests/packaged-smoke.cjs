// Verify the distributable with its packaged, in-process runtime and native PTY.
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const assert = require('node:assert/strict');
const { WebSocket } = require('ws');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  const lease = net.createServer();
  await new Promise(resolve => lease.listen(0, '127.0.0.1', resolve));
  const port = lease.address().port;
  await new Promise(resolve => lease.close(resolve));
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'cmux-packaged-test-'));
  const binary = path.resolve(__dirname, '../release/win-unpacked/cmux.exe');
  const env = {...process.env, APPDATA:profile, CMUX_WINDOWS_PIPE:`\\\\.\\pipe\\cmux-packaged-test-${process.pid}`};
  delete env.ELECTRON_RUN_AS_NODE;
  const child = spawn(binary, [`--user-data-dir=${path.join(profile,'electron')}`, `--remote-debugging-port=${port}`, '--remote-debugging-address=127.0.0.1'], {env, windowsHide:true, stdio:'ignore'});
  const exited = new Promise(resolve => child.once('exit', resolve));
  let socket;
  try {
    let target;
    for (let i=0; i<200; i++) {
      try {
        const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
        target = targets.find(t=>t.type==='page' && t.url.startsWith('http://127.0.0.1:'));
        if (target) break;
      } catch {}
      if (child.exitCode !== null) throw new Error(`Packaged app exited early: ${child.exitCode}`);
      await delay(100);
    }
    assert(target, 'Packaged renderer must start');
    socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve,reject)=>{socket.once('open',resolve);socket.once('error',reject);});
    const pending = new Map();
    let id=0;
    socket.on('message', raw=>{
      const response=JSON.parse(raw);
      if (!response.id) return;
      const waiter=pending.get(response.id);
      if (!waiter) return;
      pending.delete(response.id);
      clearTimeout(waiter.timer);
      response.error ? waiter.reject(new Error(response.error.message)) : waiter.resolve(response.result);
    });
    function call(method,params={}) {
      return new Promise((resolve,reject)=>{
        const requestId=++id;
        const timer=setTimeout(()=>{pending.delete(requestId);reject(new Error(`CDP timeout: ${method}`));},15000);
        pending.set(requestId,{resolve,reject,timer});
        socket.send(JSON.stringify({id:requestId,method,params}));
      });
    }
    async function evaluate(expression) {
      const result=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
      if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
      return result.result.value;
    }
    async function api(route,body,method='POST') {
      return evaluate(`(async()=>{
        const token=new URL(location.href).searchParams.get('token');
        const response=await fetch(${JSON.stringify(route)}+'?token='+encodeURIComponent(token),{
          method:${JSON.stringify(method)}, headers:{'Content-Type':'application/json'},
          ${body===undefined?'':`body:JSON.stringify(${JSON.stringify(body)}),`}
        });
        if(!response.ok) throw new Error('API status '+response.status);
        return response.json();
      })()`);
    }
    let loaded=false;
    for(let i=0;i<150;i++) {
      try { loaded=await evaluate("location.protocol==='http:' && document.readyState==='complete' && !!document.querySelector('.workspace-row') && !!new URL(location.href).searchParams.get('token')"); } catch {}
      if(loaded) break;
      await delay(100);
    }
    assert(loaded,'Packaged renderer must finish loading');
    const state=await api('/api/state',undefined,'GET');
    assert.equal(state.ptyAvailable,true,'Packaged native ConPTY must load');
    await api('/api/workspaces',{title:'Packaged verification',cwd:path.resolve(__dirname,'../..')});
    let ready=false;
    for(let i=0;i<150;i++) {
      ready=await evaluate("!!document.querySelector('.xterm-screen') && (document.querySelector('.xterm-screen').textContent.includes('❯') || document.querySelector('.xterm-screen').textContent.includes('>'))");
      if(ready) break;
      await delay(100);
    }
    assert(ready,'Packaged terminal must reach a shell prompt');
    await api('/api/input',{text:"Write-Output ('CMUX_PACKAGED_' + 'VERIFIED')\r"});
    let rendered=false;
    for(let i=0;i<100;i++) {
      rendered=await evaluate("document.querySelector('.xterm-screen').textContent.includes('CMUX_PACKAGED_VERIFIED')");
      if(rendered) break;
      await delay(100);
    }
    assert(rendered,'Packaged ConPTY must execute a command and render its output');
    const screenshot=await call('Page.captureScreenshot',{format:'png'});
    fs.mkdirSync(path.resolve(__dirname,'../test-output'),{recursive:true});
    fs.writeFileSync(path.resolve(__dirname,'../test-output/packaged.png'),Buffer.from(screenshot.data,'base64'));
    await evaluate('window.cmuxNative.closeWindow()');
    await Promise.race([exited,delay(10000).then(()=>{throw new Error('Packaged app did not close');})]);
    console.log('PASS packaged cmux.exe: native ConPTY, workspace creation, command execution, rendered output, clean close');
  } finally {
    socket?.close();
    if(child.exitCode===null) {
      child.kill();
      await Promise.race([exited,delay(5000)]);
    }
    const resolved=path.resolve(profile);
    if(path.dirname(resolved)===path.resolve(os.tmpdir()) && path.basename(resolved).startsWith('cmux-packaged-test-')) {
      try { fs.rmSync(resolved,{recursive:true,force:true,maxRetries:5,retryDelay:200}); }
      catch { console.error(`Test profile retained for diagnosis: ${profile}`); }
    }
  }
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
