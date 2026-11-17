import { describe, expect, it } from "bun:test";
import fs from "node:fs";
import path from "node:path";

/// A bench number is only worth reading when it comes from the code a user runs. Every bench here
/// used to serve its page from a Vite dev server, so React's **development** bundle ran: a CDP
/// profile of the transcript resize drag at 100k rows put about a third of main-thread self time in
/// three of its commit-phase instrumentation functions, which do not exist in the production bundle
/// (bench/support/benchPage.ts). So one helper serves the page, a build by default, and a file that
/// serves its own dev server has to say why.
const bench = path.resolve(import.meta.dir, "..", "bench");
const list = JSON.parse(fs.readFileSync(path.join(bench, "dev-server-benches.json"), "utf8")) as {
  allowed: Record<string, string>;
};

// `.tsx` too: bench/daemon-gate-relink.bench.tsx and its neighbours are benches, and a scan that
// only read `.ts` would let a new one serve a dev server with nothing here noticing.
function sourceFiles(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(full);
    return entry.isFile() && /\.tsx?$/.test(entry.name) ? [full] : [];
  });
}

const support = path.resolve(import.meta.dir, "support");
const rel = (file: string) => `bench/${path.relative(bench, file).split(path.sep).join("/")}`;
// `net.createServer()` (a port probe, test/support/frames120.ts) is not a dev server.
const servesItsOwn = (text: string) => /(?<!net\.)\bcreateServer\b/.test(text);
/// Calls it, not merely mentions it: a file that names `requireProductionReact` in a comment and
/// never calls it checks nothing.
const checksTheBundle = (text: string) => /\brequireProductionReact\(/.test(text);

describe("webviews benches serve the build", () => {
  const files = sourceFiles(bench).map((file) => ({ name: rel(file), text: fs.readFileSync(file, "utf8") }));

  it("has benches to check", () => {
    expect(files.length).toBeGreaterThan(5);
  });

  it("serves a dev server only from the helper or a listed file", () => {
    const own = files.filter((file) => servesItsOwn(file.text)).map((file) => file.name);
    const unlisted = own.filter((name) => !(name in list.allowed));
    expect(unlisted).toEqual([]);
  });

  it("keeps every listed file that opens a page labelling which React it measured", () => {
    for (const name of Object.keys(list.allowed)) {
      const file = files.find((each) => each.name === name);
      expect(file, `${name} is listed but gone: drop it from dev-server-benches.json`).toBeTruthy();
      // A file that only serves (bench/composer-arms.ts serves the pane for composer-typing) is
      // checked by whoever opens the page; one that opens its own page checks it itself.
      if (!/page\.goto\(/.test(file!.text)) continue;
      expect(
        checksTheBundle(file!.text),
        `${name} must call requireProductionReact so a dev bundle cannot pass unlabelled`,
      ).toBe(true);
    }
  });

  it("lists nothing that no longer serves its own server", () => {
    const own = new Set(files.filter((file) => servesItsOwn(file.text)).map((file) => file.name));
    const stale = Object.keys(list.allowed).filter((name) => !own.has(name));
    expect(stale, "these no longer serve a dev server: drop them from dev-server-benches.json").toEqual([]);
  });

  it("every bench that takes its page from the helper checks which React it loaded", () => {
    const helped = files.filter(
      (file) => /serveBenchPage\(/.test(file.text) && file.name !== "bench/support/benchPage.ts",
    );
    expect(helped.length).toBeGreaterThan(0);
    const unchecked = helped.filter((file) => !checksTheBundle(file.text)).map((file) => file.name);
    expect(unchecked).toEqual([]);
  });

  // The helper is not the only way to a dev page: test/support modules of their own create Vite dev
  // servers (papercutChat's pane, galleryControlSurfaces, transcriptDragFlows), and a bench reaching
  // one of those serves a development bundle without ever naming `createServer`. Each such module
  // has a production switch (`production: {...}` for the papercut pane), so a bench that opens a page
  // through one says which it wants.
  it("asks for production from the dev-server helpers outside bench/ too", () => {
    const helpers = sourceFiles(support)
      .filter((file) => servesItsOwn(fs.readFileSync(file, "utf8")))
      .map((file) => path.basename(file).replace(/\.tsx?$/, ""));
    expect(helpers.length).toBeGreaterThan(0);
    const reaching = files.filter((file) =>
      helpers.some((helper) => new RegExp(`from "[^"]*/${helper}"`).test(file.text)),
    );
    expect(reaching.length).toBeGreaterThan(0);
    const silent = reaching
      .filter((file) => !/\bproduction\b/.test(file.text) && !checksTheBundle(file.text))
      .filter((file) => !(file.name in list.allowed))
      // A fixture that only builds events for a bench opens no page of its own.
      .filter((file) => /\.bench\.tsx?$/.test(file.name))
      .map((file) => file.name);
    expect(
      silent,
      "these open a page through a dev-server helper without asking for production: pass production, call" +
        " requireProductionReact, or list the file in dev-server-benches.json with a reason",
    ).toEqual([]);
  });
});
