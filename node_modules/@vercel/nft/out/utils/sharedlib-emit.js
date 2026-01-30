"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.sharedLibEmit = sharedLibEmit;
const os_1 = __importDefault(require("os"));
const path_1 = __importDefault(require("path"));
const glob_1 = require("glob");
const get_package_base_1 = require("./get-package-base");
let sharedlibGlob = '';
switch (os_1.default.platform()) {
    case 'darwin':
        sharedlibGlob = '/**/*.@(dylib|so?(.*))';
        break;
    case 'win32':
        sharedlibGlob = '/**/*.dll';
        break;
    default:
        sharedlibGlob = '/**/*.so?(.*)';
}
// helper for emitting the associated shared libraries when a binary is emitted
async function sharedLibEmit(p, job) {
    // console.log('Emitting shared libs for ' + path);
    const pkgPath = (0, get_package_base_1.getPackageBase)(p);
    if (!pkgPath)
        return;
    const files = await (0, glob_1.glob)(pkgPath.replaceAll(path_1.default.sep, path_1.default.posix.sep) + sharedlibGlob, {
        ignore: pkgPath.replaceAll(path_1.default.sep, path_1.default.posix.sep) + '/**/node_modules/**/*',
        dot: true,
    });
    await Promise.all(files.map((file) => job.emitFile(file, 'sharedlib', p)));
}
