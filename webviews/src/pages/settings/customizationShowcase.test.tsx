import { afterAll, afterEach, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import showcase from "./customizeShowcase.json";
import { LOCALES } from "../../../scripts/pages/gen-strings.mjs";
import { installDom } from "./testDom";
import { SHOWCASE_REF, templateInstallCommand } from "./components/CustomizeExamplesCard";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage } = await import("./testing");

let page: Awaited<ReturnType<typeof renderPage>> | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const template = showcase.samples[0]!;
const repoRoot = join(import.meta.dir, "../../../..");
const rawBase = `https://raw.githubusercontent.com/manaflow-ai/cmux/${SHOWCASE_REF}/`;

function writeExecutable(path: string, source: string): void {
  writeFileSync(path, source);
  chmodSync(path, 0o755);
}

function shellFixture(failSecondDownload = false, tamperManifest = false) {
  const root = mkdtempSync(join(tmpdir(), "cmux-customization-test-"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  const curlLog = join(root, "curl.log");
  const curlCount = join(root, "curl.count");
  const cmuxLog = join(root, "cmux.log");
  const home = join(root, "home");
  const customize = join(home, ".config", "cmux", "customize");
  mkdirSync(customize, { recursive: true });
  writeFileSync(join(customize, "main.js"), "keep customize source");
  writeFileSync(join(customize, "cmux-app.json"), "keep customize manifest");
  writeFileSync(join(root, "sentinel.txt"), "keep me");
  writeExecutable(
    join(bin, "curl"),
    `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$CURL_LOG"
count=0
if [ -f "$CURL_COUNT" ]; then count=$(cat "$CURL_COUNT"); fi
count=$((count + 1))
printf '%s' "$count" > "$CURL_COUNT"
if [ "${failSecondDownload ? "1" : "0"}" = 1 ] && [ "$count" -eq 2 ]; then exit 22; fi
out=""
url=""
previous=""
for arg in "$@"; do
  if [ "$previous" = "-o" ]; then out="$arg"; fi
  case "$arg" in https://*) url="$arg";; esac
  previous="$arg"
done
[ -n "$out" ]
case "$url" in
  "$RAW_BASE"*) cat "$REPO_ROOT/\${url#"$RAW_BASE"}" > "$out" ;;
  *) exit 23 ;;
esac
if [ "$TAMPER_MANIFEST" = 1 ]; then case "$out" in *cmux-app.json) printf ' ' >> "$out" ;; esac; fi
`,
  );
  writeExecutable(
    join(bin, "cmux"),
    `#!/bin/sh
printf '%s|%s\\n' "$PWD" "$*" >> "$CMUX_LOG"
`,
  );
  const env = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH ?? ""}`,
    CURL_LOG: curlLog,
    CURL_COUNT: curlCount,
    CMUX_LOG: cmuxLog,
    HOME: home,
    RAW_BASE: rawBase,
    REPO_ROOT: repoRoot,
    TAMPER_MANIFEST: tamperManifest ? "1" : "0",
  };
  return { root, env, curlLog, cmuxLog, customize };
}

function runCommand(command: string, fixture: ReturnType<typeof shellFixture>) {
  return Bun.spawnSync(["/bin/sh", "-c", command], {
    cwd: fixture.root,
    env: fixture.env,
    stdout: "pipe",
    stderr: "pipe",
  });
}

test("template install command writes both files in an exclusive folder and runs cmux ext dev there", () => {
  const fixture = shellFixture();
  try {
    const command = templateInstallCommand(template);
    expect(command).toContain(`mktemp -d './cmux-example-${template.id}.XXXXXX'`);
    expect(runCommand(command, fixture).exitCode).toBe(0);
    expect(runCommand(command, fixture).exitCode).toBe(0);
    expect(readFileSync(join(fixture.root, "sentinel.txt"), "utf8")).toBe("keep me");

    const folders = readdirSync(fixture.root).filter((name) => name.startsWith(`cmux-example-${template.id}.`));
    expect(folders).toHaveLength(2);
    for (const folder of folders) {
      const exampleDir = join(fixture.root, folder);
      expect(readFileSync(join(exampleDir, "main.js"), "utf8")).toBe(
        readFileSync(join(repoRoot, template.file), "utf8"),
      );
      expect(readFileSync(join(exampleDir, "cmux-app.json"), "utf8")).toBe(
        readFileSync(join(repoRoot, template.manifest), "utf8"),
      );
    }
    const cmuxCalls = readFileSync(fixture.cmuxLog, "utf8").trim().split("\n");
    const orderedFolders = cmuxCalls.map((call) => basename(call.split("|", 1)[0]!));
    expect(new Set(orderedFolders)).toEqual(new Set(folders));
    const curlCalls = readFileSync(fixture.curlLog, "utf8").trim().split("\n");
    expect(curlCalls).toHaveLength(4);
    expect(curlCalls[0]).toContain(`${rawBase}${template.file}`);
    expect(curlCalls[0]).toContain(`-o ./${orderedFolders[0]}/main.js`);
    expect(curlCalls[1]).toContain(`${rawBase}${template.manifest}`);
    expect(curlCalls[1]).toContain(`-o ./${orderedFolders[0]}/cmux-app.json`);
    expect(curlCalls[2]).toContain(`-o ./${orderedFolders[1]}/main.js`);
    expect(curlCalls[3]).toContain(`-o ./${orderedFolders[1]}/cmux-app.json`);
    expect(cmuxCalls).toEqual(orderedFolders.map((folder) => `${join(fixture.root, folder)}|ext dev`));
    expect(readFileSync(join(fixture.customize, "main.js"), "utf8")).toBe("keep customize source");
    expect(readFileSync(join(fixture.customize, "cmux-app.json"), "utf8")).toBe("keep customize manifest");
  } finally {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("template install command does not start cmux when the manifest download fails", () => {
  const fixture = shellFixture(true);
  try {
    const result = runCommand(templateInstallCommand(template), fixture);
    expect(result.exitCode).not.toBe(0);
    expect(readFileSync(join(fixture.root, "sentinel.txt"), "utf8")).toBe("keep me");
    expect(readFileSync(join(fixture.customize, "main.js"), "utf8")).toBe("keep customize source");
    expect(readFileSync(join(fixture.customize, "cmux-app.json"), "utf8")).toBe("keep customize manifest");
    expect(existsSync(fixture.cmuxLog)).toBe(false);
  } finally {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("template install command refuses a download that does not match the catalog's sha256", () => {
  const fixture = shellFixture(false, true);
  try {
    const result = runCommand(templateInstallCommand(template), fixture);
    expect(result.exitCode).not.toBe(0);
    expect(existsSync(fixture.cmuxLog)).toBe(false);
    expect(readFileSync(join(fixture.customize, "cmux-app.json"), "utf8")).toBe("keep customize manifest");
  } finally {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("the catalog pins a full commit and every example's sha256 matches the reviewed file", () => {
  expect(SHOWCASE_REF).toMatch(/^[0-9a-f]{40}$/);
  for (const sample of showcase.samples) {
    for (const part of ["file", "manifest"] as const) {
      const digest = new Bun.CryptoHasher("sha256").update(readFileSync(join(repoRoot, sample[part]))).digest("hex");
      expect(sample.sha256[part]).toBe(digest);
    }
  }
});

test("Customize > Examples copies the exact generated command for the first template", async () => {
  page = await renderPage({ path: "/settings/customize" });
  const button = [...page.container.querySelectorAll<HTMLButtonElement>("button")].find(
    (candidate) => candidate.textContent === "Copy install command",
  );
  expect(button).toBeDefined();
  await click(button!);
  expect(ops(page.provider, "cmux.app.clipboard.write")).toContainEqual({
    text: templateInstallCommand(template),
  });
});

test("Customize > Examples draws each description as one line of at most 60 characters, in every language", async () => {
  const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const long: string[] = [];
  for (const locale of LOCALES as string[]) {
    page = await renderPage({ path: "/settings/customize", locale });
    const lines = [...page.container.querySelectorAll<HTMLElement>('[data-card="customization-examples"] .row-help')];
    expect(lines.length).toBe(showcase.samples.length + 1);
    for (const line of lines) {
      const text = line.textContent?.trim() ?? "";
      if (text.includes("\n") || [...graphemes.segment(text)].length > 60) long.push(`${locale}: ${text}`);
    }
    page.unmount();
    page = null;
  }
  expect(long).toEqual([]);
});
