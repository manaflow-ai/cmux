// The gallery runs WebTheme.bootstrapScript as the app does (dev-server/galleryHost.ts): it reads the
// Swift multi-line literal, so a Swift escape must come out as the character the app's script holds.
// The color transition's rgba parser (cx-3rf4z) wrote its regular expression with `\\`, one
// backslash in the app; the reader refused it and every gallery page answered 500.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";

const literal = (body: string) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "web-theme-"));
  const file = path.join(dir, "WebTheme.swift");
  fs.writeFileSync(file, `enum WebTheme {\n    static let bootstrapScript = """\n${body}\n    """\n}\n`);
  return file;
};

describe("readWebThemeBootstrap", () => {
  test("the app's script parses as JavaScript", () => {
    const script = readWebThemeBootstrap();
    expect(() => new vm.Script(script)).not.toThrow();
  });

  test("a Swift \\\\ is one backslash", () => {
    const script = readWebThemeBootstrap(literal(String.raw`    var rgba = /^rgba?\\(\\s*([\\d.]+)\\)$/;`));
    expect(script).toBe(String.raw`var rgba = /^rgba?\(\s*([\d.]+)\)$/;`);
    const rgba = vm.runInNewContext(`${script}; rgba`) as RegExp;
    expect(rgba.exec("rgb(12)")?.[1]).toBe("12");
  });

  test("any other escape or an interpolation still stops the reader", () => {
    for (const body of [
      String.raw`    var a = "\n";`,
      String.raw`    var a = "\"";`,
      String.raw`    var a = \(value);`,
    ])
      expect(() => readWebThemeBootstrap(literal(body))).toThrow(/Swift escapes/);
  });
});
