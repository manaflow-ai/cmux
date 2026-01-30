"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getNodeMajorVersion = getNodeMajorVersion;
/**
 * Gets the major version of the current Node.js runtime
 * @returns The major version number (e.g., 22 for Node.js v22.16.0)
 */
function getNodeMajorVersion() {
    return parseInt(process.versions.node.split('.')[0], 10);
}
