"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var python_exports = {};
__export(python_exports, {
  isPythonEntrypoint: () => isPythonEntrypoint,
  runStdlibPyScript: () => runStdlibPyScript
});
module.exports = __toCommonJS(python_exports);
var import_fs = __toESM(require("fs"));
var import_path = require("path");
var import_execa = __toESM(require("execa"));
var import_debug = __toESM(require("./debug"));
const isWin = process.platform === "win32";
async function runStdlibPyScript(options) {
  const { scriptName, pythonPath, args = [], cwd } = options;
  const scriptPath = (0, import_path.join)(__dirname, "..", "lib", "python", `${scriptName}.py`);
  if (!import_fs.default.existsSync(scriptPath)) {
    throw new Error(`Python script not found: ${scriptPath}`);
  }
  const pythonCmd = pythonPath ?? (isWin ? "python" : "python3");
  (0, import_debug.default)(
    `Running stdlib Python script: ${pythonCmd} ${scriptPath} ${args.join(" ")}`
  );
  try {
    const result = await (0, import_execa.default)(pythonCmd, [scriptPath, ...args], { cwd });
    return { exitCode: 0, stdout: result.stdout, stderr: result.stderr };
  } catch (err) {
    const execaErr = err;
    return {
      exitCode: execaErr.exitCode ?? 1,
      stdout: execaErr.stdout ?? "",
      stderr: execaErr.stderr ?? ""
    };
  }
}
async function isPythonEntrypoint(file) {
  try {
    const fsPath = file.fsPath;
    if (!fsPath)
      return false;
    const content = await import_fs.default.promises.readFile(fsPath, "utf-8");
    if (!content.includes("app") && !content.includes("handler") && !content.includes("Handler")) {
      return false;
    }
    const result = await runStdlibPyScript({
      scriptName: "ast_parser",
      args: [fsPath]
    });
    return result.exitCode === 0;
  } catch (err) {
    (0, import_debug.default)(`Failed to check Python entrypoint: ${err}`);
    return false;
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  isPythonEntrypoint,
  runStdlibPyScript
});
