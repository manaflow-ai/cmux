import { test, expect, chromium } from '@playwright/test';

test.describe('vite app', () => {
  let browser;
  let context;
  let page;

  test.beforeAll(async () => {
    const proxyUrl = process.env.PROXY_URL;
    if (!proxyUrl) throw new Error('PROXY_URL env var not set');
    
    browser = await chromium.launch({
      proxy: { server: proxyUrl },
      args: [
        '--ignore-certificate-errors',
        '--proxy-bypass-list=<-loopback>', // Ensure localhost goes through proxy
      ]
    });
  });

  test.afterAll(async () => {
    await browser.close();
  });

  test('should load vite app via HTTP', async () => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    
    const targetUrl = 'http://localhost:5173';
    console.log(`Navigating to ${targetUrl}`);
    
    // Capture console logs to check for the "Blocked script" error
    page.on('console', msg => console.log(`[Browser Console] ${msg.text()}`));
    page.on('pageerror', err => console.log(`[Browser Error] ${err.message}`));
    page.on('requestfailed', req => console.log(`[Request Failed] ${req.url()} - ${req.failure()?.errorText}`));
    page.on('response', res => {
        if (res.status() >= 400) {
            console.log(`[Response Error] ${res.url()} - ${res.status()}`);
        }
    });

    await page.goto(targetUrl);
    
    // Title seems to be 'app' (directory name) in newer create-vite defaults
    await expect(page).toHaveTitle(/app|Vite/);
    
    // Wait for React to hydrate
    const button = page.locator('button');
    await expect(button).toBeVisible({ timeout: 10000 });
    await button.click();
    await expect(button).toContainText('count is 1');
    
    await context.close();
  });

  test('should load vite app via HTTPS', async () => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    
    const targetUrl = 'https://localhost:5173';
    console.log(`Navigating to ${targetUrl}`);
    
    page.on('console', msg => console.log(`[Browser Console] ${msg.text()}`));
    page.on('response', res => {
        if (res.status() >= 400) {
            console.log(`[Response Error] ${res.url()} - ${res.status()}`);
        }
    });

    await page.goto(targetUrl);
    
    await expect(page).toHaveTitle(/app|Vite/);
    const button = page.locator('button');
    await expect(button).toBeVisible({ timeout: 10000 });
    await button.click();
    await expect(button).toContainText('count is 1');
    
    await context.close();
  });
});
