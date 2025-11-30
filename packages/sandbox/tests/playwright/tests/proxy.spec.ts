import { test, expect, chromium } from '@playwright/test';

test('proxy should tunnel traffic to sandbox', async () => {
  const proxyUrl = process.env.PROXY_URL;
  if (!proxyUrl) throw new Error('PROXY_URL env var not set');

  console.log(`Launching browser with proxy: ${proxyUrl}`);

  const browser = await chromium.launch({
    proxy: {
      server: proxyUrl,
    },
    args: ['--ignore-certificate-errors']
  });
  
  try {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();

    const targetUrl = process.env.TARGET_URL || 'http://localhost:8000';
    
    console.log(`Navigating to ${targetUrl}`);
    
    const response = await page.goto(targetUrl);
    if (!response) throw new Error('No response');

    expect(response.status()).toBe(200);
    
    // Python http.server defaults to listing the directory
    const text = await page.textContent('body');
    console.log('Page content preview:', text?.substring(0, 100));
    expect(text).toContain('Directory listing');
  } finally {
    await browser.close();
  }
});

test('proxy should support websockets', async () => {
  const proxyUrl = process.env.PROXY_URL;
  const wsTargetUrl = process.env.WS_TARGET_URL || 'ws://localhost:8765';
  
  if (!proxyUrl) throw new Error('PROXY_URL env var not set');

  const browser = await chromium.launch({
    proxy: { server: proxyUrl },
    args: ['--ignore-certificate-errors']
  });
  
  try {
    const page = await browser.newPage({ ignoreHTTPSErrors: true });
    
    // We navigate to a data url to have a context
    await page.goto('data:text/html,<html><body>ws test</body></html>');
    
    const result = await page.evaluate((url) => {
        return new Promise((resolve, reject) => {
            const ws = new WebSocket(url);
            ws.onopen = () => {
                console.log('ws open');
                ws.send('ping');
            };
            ws.onmessage = (msg) => {
                console.log('ws msg', msg.data);
                resolve(msg.data);
            };
            ws.onerror = (e) => reject('ws error');
            // Timeout safety
            setTimeout(() => reject('timeout'), 5000);
        });
    }, wsTargetUrl);
    
    expect(result).toBe('ping');
  } finally {
    await browser.close();
  }
});
