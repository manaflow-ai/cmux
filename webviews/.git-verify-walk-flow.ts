import { chromium } from 'playwright';
import { readFile } from 'node:fs/promises';
const root='/home/cmux/.wt/checkouts/cmux/lane--intro-walk-four-screens-carry/webviews/dist/gallery';
const contentTypes:any={'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.css':'text/css','.json':'application/json','.svg':'image/svg+xml','.png':'image/png','.woff2':'font/woff2'};
const server=Bun.serve({port:0,async fetch(req){const u=new URL(req.url);const p=decodeURIComponent(u.pathname).replace(/^\/+/, '')||'index.html'; try{return new Response(await readFile(`${root}/${p}`),{headers:{'content-type':contentTypes[p.slice(p.lastIndexOf('.'))]??'application/octet-stream'}})}catch{return new Response('not found',{status:404})}}});
const browser=await chromium.launch({headless:true, executablePath:process.env.CMUX_CHROME_HEADLESS_SHELL});
const page=await browser.newPage({viewport:{width:640,height:520}, colorScheme:'light'});
page.on('console',m=>console.log('CONSOLE',m.type(),m.text())); page.on('pageerror',e=>console.log('PAGEERROR',e.stack||e.message)); page.on('requestfailed',r=>console.log('REQFAIL',r.url(),r.failure()?.errorText));
const u=`http://127.0.0.1:${server.port}/frame.html?entry=pages.onboarding&variant=intro-walk-look&locale=en&theme=Apple%20System%20Colors%20Light`;

try {
  await page.goto(u);
  for (const [index, screen] of ["look", "work", "trust", "tune"].entries()) {
    await page.locator(".onb-make[data-screen='" + screen + "']").waitFor({state:"visible",timeout:8000});
    console.log(screen, await page.locator("h1").innerText());
    if (index < 3) await page.locator("footer [data-primary]").click();
  }
  await page.getByRole('button', {name:/Back/i}).click();
  await page.locator(".onb-make[data-screen='trust']").waitFor({state:"visible",timeout:8000});
  console.log('Back: trust');
} finally { await browser.close(); server.stop(); }
