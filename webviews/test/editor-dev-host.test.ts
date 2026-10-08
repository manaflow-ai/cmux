// The code editor's dev host (dev-server/editorHost.ts): the file rules the app's host follows too.
import { afterAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  EditorRefused,
  editorFiles,
  editorPreferences,
  readEditorFile,
  readEditorLook,
  saveEditorFile,
  withPreferences,
} from "../dev-server/editorHost";

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-editor-host-")));
const workspace = path.join(root, "workspace");
const outside = path.join(root, "outside");
fs.mkdirSync(workspace);
fs.mkdirSync(outside);
afterAll(() => fs.rmSync(root, { recursive: true, force: true }));

const write = (file: string, bytes: Uint8Array | string) => {
  fs.writeFileSync(file, bytes);
  return file;
};

describe("readEditorFile", () => {
  test("keeps a BOM and every line ending in the text", () => {
    const file = write(path.join(workspace, "bom.txt"), Buffer.from("﻿a\r\nb\rc", "utf8"));
    const content = readEditorFile(file, true)!;
    expect(content.text).toBe("﻿a\r\nb\rc");
    expect(content.readOnlyReason).toBeNull();
    expect(Buffer.from(content.text, "utf8").equals(fs.readFileSync(file))).toBe(true);
  });

  test("not UTF-8, binary, outside or unwritable: read only, with the reason", () => {
    const latin1 = write(path.join(workspace, "latin1.txt"), Buffer.from([0x63, 0x61, 0x66, 0xe9]));
    expect(readEditorFile(latin1, true)!.readOnlyReason).toBe("encoding");
    const binary = write(path.join(workspace, "bin.dat"), Buffer.from([1, 0, 2]));
    expect(readEditorFile(binary, true)!.readOnlyReason).toBe("binary");
    const text = write(path.join(outside, "a.txt"), "a");
    expect(readEditorFile(text, false)!.readOnlyReason).toBe("outside");
    const locked = write(path.join(workspace, "locked.txt"), "a");
    fs.chmodSync(locked, 0o444);
    expect(readEditorFile(locked, true)!.readOnlyReason).toBe("permission");
    expect(readEditorFile(path.join(workspace, "missing"), true)).toBeUndefined();
  });
});

describe("saveEditorFile", () => {
  test("writes the text's UTF-8 bytes when the base hash matches, keeping the mode", () => {
    const file = write(path.join(workspace, "save.sh"), "echo a\r\n");
    fs.chmodSync(file, 0o755);
    const base = readEditorFile(file, true)!.hash;
    const outcome = saveEditorFile(file, "﻿echo b\r\n", base, true);
    expect(outcome).toMatchObject({ ok: true, written: true });
    expect(fs.readFileSync(file).equals(Buffer.from("﻿echo b\r\n", "utf8"))).toBe(true);
    expect(fs.statSync(file).mode & 0o777).toBe(0o755);
  });

  test("bytes equal to the file are not written", () => {
    const file = write(path.join(workspace, "same.txt"), "same\n");
    const before = fs.statSync(file).mtimeMs;
    const content = readEditorFile(file, true)!;
    const outcome = saveEditorFile(file, "same\n", content.hash, true);
    expect(outcome).toEqual({ ok: true, hash: content.hash, written: false });
    expect(fs.statSync(file).mtimeMs).toBe(before);
  });

  test("a stale base hash is a conflict with the file's text; a deleted file says so", () => {
    const file = write(path.join(workspace, "conflict.txt"), "theirs");
    expect(saveEditorFile(file, "mine", "stale", true)).toEqual({
      ok: false,
      code: "cmux.editor.conflict",
      details: { hash: readEditorFile(file, true)!.hash, text: "theirs" },
    });
    expect(fs.readFileSync(file, "utf8")).toBe("theirs");
    fs.rmSync(file);
    expect(saveEditorFile(file, "mine", "stale", true)).toEqual({
      ok: false,
      code: "cmux.editor.conflict",
      details: { hash: null, deleted: true },
    });
  });

  test("read-only files are refused", () => {
    const file = write(path.join(outside, "ro.txt"), "a");
    expect(saveEditorFile(file, "b", readEditorFile(file, false)!.hash, false)).toEqual({
      ok: false,
      code: "cmux.editor.read_only",
    });
    const latin1 = write(path.join(workspace, "ro-latin1.txt"), Buffer.from([0xe9]));
    expect(saveEditorFile(latin1, "x", readEditorFile(latin1, true)!.hash, true)).toMatchObject({ ok: false });
    expect(fs.readFileSync(latin1).equals(Buffer.from([0xe9]))).toBe(true);
  });
});

describe("editorFiles", () => {
  const files = editorFiles({ workspaceRoots: [workspace], readableRoots: [outside] });

  test("opens regular files below the roots, writable only in the workspace", () => {
    const inside = write(path.join(workspace, "in.txt"), "a");
    const readable = write(path.join(outside, "out.txt"), "a");
    expect(files.resolve(inside)).toBe(inside);
    expect(files.inWorkspace(inside)).toBe(true);
    expect(files.inWorkspace(files.resolve(readable))).toBe(false);
  });

  test("refuses folders, missing files, relative paths and anything outside the roots", () => {
    const code = (requested: string) => {
      try {
        files.resolve(requested);
        return "opened";
      } catch (error) {
        return (error as EditorRefused).code;
      }
    };
    expect(code(workspace)).toBe("cmux.editor.not_file");
    expect(code(path.join(workspace, "nope"))).toBe("cmux.editor.not_found");
    expect(code("in.txt")).toBe("cmux.editor.not_found");
    expect(code("/etc/hosts")).toBe("cmux.editor.refused");
    const link = path.join(workspace, "escape");
    fs.symlinkSync("/etc/hosts", link);
    expect(code(link)).toBe("cmux.editor.refused");
  });
});

describe("preferences", () => {
  test("setPreference stores editor.* keys; the look merges them over cmux.json", () => {
    const prefs = editorPreferences(path.join(root, "state", "editor-preferences.json"));
    expect(prefs.set("editor.minimap.enabled", true)).toBe(true);
    expect(prefs.set("editor.wordWrap", "on")).toBe(true);
    expect(prefs.set("terminal.fontSize", 3)).toBe(false);
    const config = write(
      path.join(root, "cmux.json"),
      '{ // jsonc\n "editor": {"minimap": false, "tabSize": 2,}, "appearance": {"syntaxTheme": "nord"} }',
    );
    fs.mkdirSync(path.join(root, "editor"), { recursive: true });
    write(path.join(root, "editor", "theme.css"), ":root{--cmux-editor-ruler:red}");
    expect(readEditorLook(config, prefs.read())).toEqual({
      settings: { minimap: { enabled: true }, tabSize: 2, wordWrap: "on" },
      syntaxTheme: "nord",
      themeCSS: ":root{--cmux-editor-ruler:red}",
    });
    expect(withPreferences(undefined, { "editor.a.b": 1 })).toEqual({ a: { b: 1 } });
  });
});
