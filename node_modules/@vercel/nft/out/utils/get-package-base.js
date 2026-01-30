"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getPackageBase = getPackageBase;
exports.getPackageName = getPackageName;
// returns the base-level package folder based on detecting "node_modules"
// package name boundaries
const pkgNameRegEx = /^(@[^\\\/]+[\\\/])?[^\\\/]+/;
function getPackageBase(id) {
    const pkgIndex = id.lastIndexOf('node_modules');
    if (pkgIndex !== -1 &&
        (id[pkgIndex - 1] === '/' || id[pkgIndex - 1] === '\\') &&
        (id[pkgIndex + 12] === '/' || id[pkgIndex + 12] === '\\')) {
        const pkgNameMatch = id.slice(pkgIndex + 13).match(pkgNameRegEx);
        if (pkgNameMatch)
            return id.slice(0, pkgIndex + 13 + pkgNameMatch[0].length);
    }
    return undefined;
}
function getPackageName(id) {
    const pkgIndex = id.lastIndexOf('node_modules');
    if (pkgIndex !== -1 &&
        (id[pkgIndex - 1] === '/' || id[pkgIndex - 1] === '\\') &&
        (id[pkgIndex + 12] === '/' || id[pkgIndex + 12] === '\\')) {
        const pkgNameMatch = id.slice(pkgIndex + 13).match(pkgNameRegEx);
        if (pkgNameMatch && pkgNameMatch.length > 0) {
            return pkgNameMatch[0].replace(/\\/g, '/');
        }
    }
    return undefined;
}
