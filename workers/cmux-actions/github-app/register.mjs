#!/usr/bin/env node
// Registers the "cmux Actions (experiment)" GitHub App from manifest.json with
// GitHub's manifest flow. Run once, by an owner of the manaflow-ai org, from a
// trusted checkout:
//
//   node workers/cmux-actions/github-app/register.mjs
//
// It serves an auto-submitting form on 127.0.0.1, GitHub redirects back with a
// one-time code, and the code is exchanged for the App credentials. The
// credentials (App id, private key, webhook secret, client secret) are written
// to ~/.secrets/cmux-actions-github-app.json with mode 0600 and never printed.
// After registration, install the App on manaflow-ai/cmux only ("Only select
// repositories"). No dependencies; Node 18 or newer.

import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ORG = "manaflow-ai";
const PORT = 17421;
const OUTPUT = join(homedir(), ".secrets", "cmux-actions-github-app.json");

const manifestPath = join(dirname(fileURLToPath(import.meta.url)), "manifest.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (manifest.redirect_url !== `http://127.0.0.1:${PORT}/callback`) {
  throw new Error(`manifest.json redirect_url must be http://127.0.0.1:${PORT}/callback`);
}
if (existsSync(OUTPUT)) {
  throw new Error(`${OUTPUT} already exists; refusing to overwrite App credentials`);
}

const state = randomBytes(24).toString("hex");
const registerUrl = `https://github.com/organizations/${ORG}/settings/apps/new?state=${state}`;

const escapeHtml = (text) =>
  text.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

const formPage = `<!doctype html>
<meta charset="utf-8">
<title>Register cmux Actions (experiment)</title>
<form id="register" method="post" action="${escapeHtml(registerUrl)}">
  <input type="hidden" name="manifest" value="${escapeHtml(JSON.stringify(manifest))}">
  <button type="submit">Register the GitHub App on ${ORG}</button>
</form>
<script>document.getElementById("register").submit();</script>`;

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${PORT}`);
  if (url.pathname === "/") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(formPage);
    return;
  }
  if (url.pathname !== "/callback") {
    response.writeHead(404).end();
    return;
  }
  const code = url.searchParams.get("code");
  if (url.searchParams.get("state") !== state || code === null || !/^[A-Za-z0-9_-]{1,200}$/.test(code)) {
    response.writeHead(400).end("state or code mismatch");
    return;
  }
  try {
    const conversion = await fetch(`https://api.github.com/app-manifests/${code}/conversions`, {
      method: "POST",
      headers: { accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28" },
    });
    if (!conversion.ok) throw new Error(`conversion failed with HTTP ${conversion.status}`);
    const app = await conversion.json();
    mkdirSync(dirname(OUTPUT), { recursive: true, mode: 0o700 });
    writeFileSync(OUTPUT, JSON.stringify(app, null, 2), { mode: 0o600, flag: "wx" });
    const installUrl = `https://github.com/apps/${app.slug}/installations/new`;
    console.log(`App id: ${app.id}`);
    console.log(`App slug: ${app.slug}`);
    console.log(`Credentials written to ${OUTPUT} (mode 0600)`);
    console.log(`Install on manaflow-ai/cmux only: ${installUrl}`);
    response.writeHead(302, { location: installUrl }).end();
  } catch (error) {
    console.error(String(error instanceof Error ? error.message : error));
    response.writeHead(500).end("registration failed; see the terminal");
  } finally {
    server.close();
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Open http://127.0.0.1:${PORT}/ in a browser signed in as a ${ORG} owner.`);
  console.log(`It posts manifest.json to ${registerUrl.split("?")[0]}.`);
});
