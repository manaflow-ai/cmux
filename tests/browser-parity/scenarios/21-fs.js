// node:fs, node:path, node:os and Buffer: Node semantics, the same modules
// through import(), and files limited to the session and temp directories.
const cleanUp = () => {
  for (const f of ["note.txt", "renamed.txt", "copy.txt", "p.txt"]) fs.rmSync(f, { force: true });
  fs.rmSync("dir", { recursive: true, force: true });
};
cleanUp();
fs.writeFileSync("note.txt", "hello");
fs.appendFileSync("note.txt", " world");
emit("read", fs.readFileSync("note.txt", "utf8"));
emit("read-buffer", Buffer.isBuffer(fs.readFileSync("note.txt")));
fs.mkdirSync("dir/sub", { recursive: true });
fs.writeFileSync("dir/sub/x.json", JSON.stringify({ a: 1 }));
emit("readdir", fs.readdirSync("dir"));
emit("readdir-types", fs.readdirSync("dir", { withFileTypes: true }).map((d) => [d.name, d.isDirectory()]));
emit("stat", [fs.statSync("note.txt").size, fs.statSync("dir").isDirectory()]);
emit("exists", [fs.existsSync("note.txt"), fs.existsSync("nope.txt")]);
fs.renameSync("note.txt", "renamed.txt");
fs.copyFileSync("renamed.txt", "copy.txt");
emit("rename-copy", [fs.existsSync("note.txt"), fs.readFileSync("copy.txt", "utf8")]);
emit("cwd", path.isAbsolute(path.resolve(".")) && fs.existsSync(path.join(path.resolve("."), "copy.txt")));
await fs.promises.writeFile("p.txt", "promised");
emit("promises", await fs.promises.readFile("p.txt", "utf8"));
const fsm = await import("node:fs");
const pm = await import("node:path");
const om = await import("node:os");
emit("import-same", [fsm.readFileSync === fs.readFileSync, pm.join === path.join, om.tmpdir === os.tmpdir, fsm.default.readFileSync === fs.readFileSync]);
emit("import-promises", (await import("node:fs/promises")).readFile === fs.promises.readFile);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "parity-"));
fs.writeFileSync(path.join(tmp, "t.txt"), "temp ok");
emit("temp", fs.readFileSync(path.join(tmp, "t.txt"), "utf8"));
fs.rmSync(tmp, { recursive: true, force: true });
emit("temp-removed", fs.existsSync(tmp));
emit("path", [path.join("a", "..", "b", "c.txt"), path.basename("/x/y.js", ".js"), path.extname("f.tar.gz"), path.isAbsolute(path.resolve("q"))]);
emit("buffer", [Buffer.from("héllo").toString("base64"), Buffer.from("aGk=", "base64").toString(), Buffer.concat([Buffer.from("a"), Buffer.from("b")]).toString("hex")]);
try {
  fs.readFileSync("missing.txt");
} catch (e) {
  emit("enoent", e.code);
}
try {
  fs.readFileSync("/etc/hosts", "utf8");
  emitCmux("outside", "read");
} catch (e) {
  emitCmux("outside", e.code);
}
try {
  fs.writeFileSync("/cmux-parity-denied.txt", "x");
  emitCmux("outside-write", "written");
} catch (e) {
  emitCmux("outside-write", e.code);
}
cleanUp();
