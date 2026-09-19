import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import nextConfig from "../next.config";

async function checkProductionTypes(projectDir: string) {
  await nextConfig.compiler!.runAfterProductionCompile!({
    projectDir,
    distDir: join(projectDir, ".next"),
  });
}

let fixture: string | undefined;
afterEach(() => { if (fixture) rmSync(fixture, { recursive: true, force: true }); });

function project(page: string) {
  fixture = mkdtempSync(join(tmpdir(), "cmux-production-types-"));
  mkdirSync(join(fixture, "app"));
  symlinkSync(fileURLToPath(new URL("../node_modules", import.meta.url)), join(fixture, "node_modules"));
  writeFileSync(join(fixture, "package.json"), JSON.stringify({ private: true, dependencies: { next: "16.3.4", react: "19.2.3" } }));
  writeFileSync(join(fixture, "tsconfig.json"), JSON.stringify({ compilerOptions: { strict: true, skipLibCheck: true, jsx: "react-jsx", module: "esnext", moduleResolution: "bundler", target: "es2017", noEmit: true, esModuleInterop: true }, include: ["next-env.d.ts", "app/**/*.tsx", "app/**/*.ts", ".next/types/**/*.ts"] }));
  writeFileSync(join(fixture, "tsconfig.next.json"), JSON.stringify({ extends: "./tsconfig.json" }));
  writeFileSync(join(fixture, "app", "layout.tsx"), "export default function Layout({ children }: { children: React.ReactNode }) { return <html><body>{children}</body></html>; }");
  writeFileSync(join(fixture, "app", "page.tsx"), page);
  return fixture;
}

test("production hook accepts valid types on a fresh clone", async () => {
  const dir = project("export default function Page() { return <p>Valid</p>; }");
  expect(nextConfig.compiler?.runAfterProductionCompile).toBeDefined();
  await checkProductionTypes(dir);
});

test("production hook rejects an application type error", async () => {
  const dir = project("const value: string = 42; export default function Page() { return <p>{value}</p>; }");
  await expect(checkProductionTypes(dir)).rejects.toThrow();
});

test("production hook checks Next-generated route parameter contracts", async () => {
  const dir = project("export default function Page() { return <p>Valid</p>; }");
  mkdirSync(join(dir, "app", "api", "[id]"), { recursive: true });
  writeFileSync(join(dir, "app", "api", "[id]", "route.ts"), "export async function GET(request: Request, { params }: { params: string }) { return Response.json({ params }); }");
  await expect(checkProductionTypes(dir)).rejects.toThrow();
});
