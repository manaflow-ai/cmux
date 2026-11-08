// The glass host is a self-contained package (README.md): its web half imports nothing outside this
// folder, and its Swift half (Packages/Shared/GlassHost) imports only Apple frameworks and depends on no
// other package. This fails when either reaches into cmux.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const WEB = import.meta.dir;
const SWIFT = join(WEB, "../../../Packages/Shared/GlassHost");
const APPLE = new Set([
  "AppKit",
  "Foundation",
  "CoreGraphics",
  "QuartzCore",
  "Testing",
  "XCTest",
  "GlassHost",
  "PackageDescription",
]);

function files(dir: string, ext: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? files(path, ext) : path.endsWith(ext) ? [path] : [];
  });
}

test("the web half imports nothing outside its folder but test tooling", () => {
  const outside: string[] = [];
  for (const file of [...files(WEB, ".ts"), ...files(WEB, ".tsx")]) {
    const text = readFileSync(file, "utf8");
    for (const match of text.matchAll(
      /(?:import|export)[^"']*?from\s*["']([^"']+)["']|import\s*\(\s*["']([^"']+)["']/g,
    )) {
      const spec = match[1] ?? match[2] ?? "";
      const tooling = file.endsWith(".test.ts") && ["bun:test", "jsdom", "node:fs", "node:path"].includes(spec);
      const local = spec.startsWith("./");
      // The gallery page lives here but loads through the app's gallery format and a fixture image.
      const gallery = file.endsWith(".gallery.tsx") && (spec === "react" || spec.startsWith("../gallery/"));
      // The React binding's one import, a peer dependency.
      const peer = file.endsWith("/react.ts") && spec === "react";
      if (!tooling && !local && !gallery && !peer) outside.push(`${relative(WEB, file)}: ${spec}`);
    }
  }
  expect(outside).toEqual([]);
});

test("the Swift half imports only Apple frameworks and has no package dependencies", () => {
  const imports: string[] = [];
  for (const file of files(SWIFT, ".swift")) {
    for (const match of readFileSync(file, "utf8").matchAll(/^\s*(?:public |package |@testable )?import\s+(\w+)/gm))
      if (!APPLE.has(match[1]!)) imports.push(`${relative(SWIFT, file)}: ${match[1]}`);
  }
  expect(imports).toEqual([]);
  expect(readFileSync(join(SWIFT, "Package.swift"), "utf8")).not.toContain(".package(");
});
