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
var node_version_exports = {};
__export(node_version_exports, {
  BUN_VERSIONS: () => BUN_VERSIONS,
  NODE_VERSIONS: () => NODE_VERSIONS,
  getAvailableNodeVersions: () => getAvailableNodeVersions,
  getDiscontinuedNodeVersions: () => getDiscontinuedNodeVersions,
  getLatestNodeVersion: () => getLatestNodeVersion,
  getNodeVersionByMajor: () => getNodeVersionByMajor,
  getSupportedBunVersion: () => getSupportedBunVersion,
  getSupportedNodeVersion: () => getSupportedNodeVersion,
  isBunVersion: () => isBunVersion
});
module.exports = __toCommonJS(node_version_exports);
var import_fs = require("fs");
var import_semver = require("semver");
var import_types = require("../types");
var import_errors = require("../errors");
var import_debug = __toESM(require("../debug"));
const NODE_VERSIONS = [
  new import_types.NodeVersion({
    major: 24,
    range: "24.x",
    runtime: "nodejs24.x"
  }),
  new import_types.NodeVersion({
    major: 22,
    range: "22.x",
    runtime: "nodejs22.x"
  }),
  new import_types.NodeVersion({
    major: 20,
    range: "20.x",
    runtime: "nodejs20.x"
  }),
  new import_types.NodeVersion({
    major: 18,
    range: "18.x",
    runtime: "nodejs18.x",
    discontinueDate: /* @__PURE__ */ new Date("2025-09-01")
  }),
  new import_types.NodeVersion({
    major: 16,
    range: "16.x",
    runtime: "nodejs16.x",
    discontinueDate: /* @__PURE__ */ new Date("2025-02-03")
  }),
  new import_types.NodeVersion({
    major: 14,
    range: "14.x",
    runtime: "nodejs14.x",
    discontinueDate: /* @__PURE__ */ new Date("2023-08-15")
  }),
  new import_types.NodeVersion({
    major: 12,
    range: "12.x",
    runtime: "nodejs12.x",
    discontinueDate: /* @__PURE__ */ new Date("2022-10-03")
  }),
  new import_types.NodeVersion({
    major: 10,
    range: "10.x",
    runtime: "nodejs10.x",
    discontinueDate: /* @__PURE__ */ new Date("2021-04-20")
  }),
  new import_types.NodeVersion({
    major: 8,
    range: "8.10.x",
    runtime: "nodejs8.10",
    discontinueDate: /* @__PURE__ */ new Date("2020-01-06")
  })
];
const BUN_VERSIONS = [
  new import_types.BunVersion({
    major: 1,
    range: "1.x",
    runtime: "bun1.x"
  })
];
function getNodeVersionByMajor(major) {
  return getOptions().find((v) => v.major === major);
}
function getOptions() {
  return NODE_VERSIONS;
}
function isNodeVersionAvailable(version) {
  const stat = (0, import_fs.statSync)(`/node${version.major}`, { throwIfNoEntry: false });
  return stat?.isDirectory() ?? false;
}
function getAvailableNodeVersions() {
  return getOptions().filter((v) => v.major >= 18).filter(isNodeVersionAvailable).map((n) => n.major);
}
function getHint(isAuto = false, availableVersions) {
  const { major, range } = getLatestNodeVersion(availableVersions);
  return isAuto ? `Please set Node.js Version to ${range} in your Project Settings to use Node.js ${major}.` : `Please set "engines": { "node": "${range}" } in your \`package.json\` file to use Node.js ${major}.`;
}
function getLatestNodeVersion(availableVersions) {
  const all = getOptions();
  if (availableVersions) {
    for (const version of all) {
      for (const major of availableVersions) {
        if (version.major === major) {
          return version;
        }
      }
    }
  }
  return all[0];
}
function getDiscontinuedNodeVersions() {
  return getOptions().filter((version) => {
    return version.state === "discontinued";
  });
}
async function getSupportedNodeVersion(engineRange, isAuto = false, availableVersions) {
  let selection;
  if (engineRange) {
    const found = (0, import_semver.validRange)(engineRange) && getOptions().some((o) => {
      selection = o;
      return (0, import_semver.intersects)(o.range, engineRange) && (availableVersions?.length ? availableVersions.includes(o.major) : true);
    });
    if (!found) {
      throw new import_errors.NowBuildError({
        code: "BUILD_UTILS_NODE_VERSION_INVALID",
        link: "https://vercel.link/node-version",
        message: `Found invalid or discontinued Node.js Version: "${engineRange}". ${getHint(
          isAuto,
          availableVersions
        )}`
      });
    }
  }
  if (!selection) {
    selection = getLatestNodeVersion(availableVersions);
  }
  if (selection.state === "discontinued") {
    const intro = `Node.js Version "${selection.range}" is discontinued and must be upgraded.`;
    throw new import_errors.NowBuildError({
      code: "BUILD_UTILS_NODE_VERSION_DISCONTINUED",
      link: "https://vercel.link/node-version",
      message: `${intro} ${getHint(isAuto)}`
    });
  }
  (0, import_debug.default)(`Selected Node.js ${selection.range}`);
  if (selection.state === "deprecated") {
    const d = selection.formattedDate;
    if (d) {
      console.warn(
        `Error: Node.js version ${selection.range} is deprecated. Deployments created on or after ${d} will fail to build. ${getHint(
          isAuto
        )}`
      );
    } else {
      console.warn(
        `Error: Node.js version ${selection.range} is deprecated. ${getHint(
          isAuto
        )}`
      );
    }
  }
  return selection;
}
function getSupportedBunVersion(engineRange) {
  if ((0, import_semver.validRange)(engineRange)) {
    const selected = BUN_VERSIONS.find((version) => {
      return (0, import_semver.intersects)(version.range, engineRange);
    });
    if (selected) {
      return new import_types.BunVersion({
        major: selected.major,
        range: selected.range,
        runtime: selected.runtime
      });
    }
  }
  throw new import_errors.NowBuildError({
    message: `Found invalid Bun Version: "${engineRange}".`,
    code: "BUILD_UTILS_BUN_VERSION_INVALID"
  });
}
function isBunVersion(version) {
  return version.runtime.startsWith("bun");
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  BUN_VERSIONS,
  NODE_VERSIONS,
  getAvailableNodeVersions,
  getDiscontinuedNodeVersions,
  getLatestNodeVersion,
  getNodeVersionByMajor,
  getSupportedBunVersion,
  getSupportedNodeVersion,
  isBunVersion
});
