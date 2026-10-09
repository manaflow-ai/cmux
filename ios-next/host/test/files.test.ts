import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { sanitizeFileName } from "../src/providers/files.ts";
import { connectedCore, tempDir } from "./helpers.ts";

describe("sanitizeFileName", () => {
  it("keeps one safe path component", () => {
    expect(sanitizeFileName("../../etc/passwd")).toBe("passwd");
    expect(sanitizeFileName("a\\b\\c.png")).toBe("c.png");
    expect(sanitizeFileName(".hidden")).toBe("hidden");
    expect(sanitizeFileName("..")).toBe("upload");
    expect(sanitizeFileName("x\u0000y\nz.txt")).toBe("xyz.txt");
    expect(sanitizeFileName('a:b*c?"<>|.jpg')).toBe("a_b_c_____.jpg");
    const long = sanitizeFileName("n".repeat(300) + ".jpeg");
    expect(long.length).toBe(120);
    expect(long.endsWith(".jpeg")).toBe(true);
  });
});

describe("fs.upload", () => {
  it("writes the file under uploads/<uuid>/<name> and returns its absolute path", async () => {
    const root = join(tempDir(), "uploads");
    const { client, core } = await connectedCore({ files: { root } });
    const data = Buffer.from("hello photo");
    const { path } = await client.request("fs.upload", {
      name: "../IMG 0001.png", mimeType: "image/png", dataBase64: data.toString("base64"),
    });
    expect(path.startsWith(root + "/")).toBe(true);
    expect(path.endsWith("/IMG 0001.png")).toBe(true);
    expect(path.split("/").length).toBe(root.split("/").length + 2);
    expect(readFileSync(path).toString()).toBe("hello photo");
    expect(statSync(path).mode & 0o777).toBe(0o600);
    expect(core.info().capabilities).toContain("fs.v1");
    // Two uploads with one name never collide.
    const second = await client.request("fs.upload", { name: "IMG 0001.png", dataBase64: data.toString("base64") });
    expect(second.path).not.toBe(path);
    core.shutdown();
  });

  it("rejects oversized and malformed uploads", async () => {
    const root = join(tempDir(), "uploads");
    const { client, core } = await connectedCore({ files: { root, maxBytes: 8 } });
    await expect(client.request("fs.upload", { name: "big.bin", dataBase64: Buffer.alloc(64).toString("base64") }))
      .rejects.toMatchObject({ code: "bad_request" });
    await expect(client.request("fs.upload", { name: "x", dataBase64: "not base64!" }))
      .rejects.toMatchObject({ code: "bad_request" });
    await expect(client.request("fs.upload", { name: "", dataBase64: "" })).rejects.toMatchObject({ code: "bad_request" });
    expect(existsSync(root)).toBe(false);
    core.shutdown();
  });
});
