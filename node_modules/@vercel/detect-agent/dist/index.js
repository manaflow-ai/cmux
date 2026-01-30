"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
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
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var src_exports = {};
__export(src_exports, {
  KNOWN_AGENTS: () => KNOWN_AGENTS,
  determineAgent: () => determineAgent
});
module.exports = __toCommonJS(src_exports);
var import_promises = require("node:fs/promises");
var import_node_fs = require("node:fs");
const DEVIN_LOCAL_PATH = "/opt/.devin";
const CURSOR = "cursor";
const CURSOR_CLI = "cursor-cli";
const CLAUDE = "claude";
const DEVIN = "devin";
const REPLIT = "replit";
const GEMINI = "gemini";
const CODEX = "codex";
const AUGMENT_CLI = "augment-cli";
const OPENCODE = "opencode";
const KNOWN_AGENTS = {
  CURSOR,
  CURSOR_CLI,
  CLAUDE,
  DEVIN,
  REPLIT,
  GEMINI,
  CODEX,
  AUGMENT_CLI,
  OPENCODE
};
async function determineAgent() {
  if (process.env.AI_AGENT) {
    const name = process.env.AI_AGENT.trim();
    if (name) {
      return {
        isAgent: true,
        agent: { name }
      };
    }
  }
  if (process.env.CURSOR_TRACE_ID) {
    return { isAgent: true, agent: { name: CURSOR } };
  }
  if (process.env.CURSOR_AGENT) {
    return { isAgent: true, agent: { name: CURSOR_CLI } };
  }
  if (process.env.GEMINI_CLI) {
    return { isAgent: true, agent: { name: GEMINI } };
  }
  if (process.env.CODEX_SANDBOX) {
    return { isAgent: true, agent: { name: CODEX } };
  }
  if (process.env.AUGMENT_AGENT) {
    return { isAgent: true, agent: { name: AUGMENT_CLI } };
  }
  if (process.env.OPENCODE_CLIENT) {
    return { isAgent: true, agent: { name: OPENCODE } };
  }
  if (process.env.CLAUDECODE || process.env.CLAUDE_CODE) {
    return { isAgent: true, agent: { name: CLAUDE } };
  }
  if (process.env.REPL_ID) {
    return { isAgent: true, agent: { name: REPLIT } };
  }
  try {
    await (0, import_promises.access)(DEVIN_LOCAL_PATH, import_node_fs.constants.F_OK);
    return { isAgent: true, agent: { name: DEVIN } };
  } catch (error) {
  }
  return { isAgent: false, agent: void 0 };
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  KNOWN_AGENTS,
  determineAgent
});
