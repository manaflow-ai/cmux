"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.installNode = exports.generateNodeTarballUrl = void 0;
const tar_1 = require("tar");
const promisepipe_1 = __importDefault(require("promisepipe"));
const node_fetch_1 = __importDefault(require("node-fetch"));
const debug_1 = __importDefault(require("debug"));
const node_zlib_1 = require("node:zlib");
const node_path_1 = require("node:path");
const node_fs_1 = require("node:fs");
const semver_1 = require("semver");
const unzip_1 = require("./unzip");
const debug = (0, debug_1.default)('@vercel/fun:install-node');
function generateNodeTarballUrl(version, platform = process.platform, arch = process.arch) {
    if (!version.startsWith('v')) {
        version = `v${version}`;
    }
    let ext;
    let plat = platform;
    if (platform === 'win32') {
        ext = 'zip';
        plat = 'win';
    }
    else {
        ext = 'tar.gz';
    }
    return `https://nodejs.org/dist/${version}/node-${version}-${plat}-${arch}.${ext}`;
}
exports.generateNodeTarballUrl = generateNodeTarballUrl;
function installNode(dest, version, platform = process.platform, arch = process.arch) {
    return __awaiter(this, void 0, void 0, function* () {
        // For Apple M1, use the x64 binaries for v14 or less,
        // since there are no arm64 binaries for these versions
        if (platform === 'darwin' &&
            arch === 'arm64' &&
            (0, semver_1.satisfies)(version, '<= 14')) {
            arch = 'x64';
        }
        const tarballUrl = generateNodeTarballUrl(version, platform, arch);
        debug('Downloading Node.js %s tarball %o', version, tarballUrl);
        const res = yield (0, node_fetch_1.default)(tarballUrl);
        if (!res.ok) {
            throw new Error(`HTTP request failed: ${res.status}`);
        }
        if (platform === 'win32') {
            // Put it in the `bin` dir for consistency with the tarballs
            const finalDest = (0, node_path_1.join)(dest, 'bin');
            const zipName = (0, node_path_1.basename)(tarballUrl);
            const zipPath = (0, node_path_1.join)(dest, zipName);
            debug('Saving Node.js %s zip file to %o', version, zipPath);
            yield (0, promisepipe_1.default)(res.body, (0, node_fs_1.createWriteStream)(zipPath));
            debug('Extracting Node.js %s zip file to %o', version, finalDest);
            const zipFile = yield (0, unzip_1.zipFromFile)(zipPath);
            yield (0, unzip_1.unzip)(zipFile, finalDest, { strip: 1 });
        }
        else {
            debug('Extracting Node.js %s tarball to %o', version, dest);
            yield (0, promisepipe_1.default)(res.body, (0, node_zlib_1.createGunzip)(), (0, tar_1.extract)({ strip: 1, C: dest }));
        }
    });
}
exports.installNode = installNode;
//# sourceMappingURL=install-node.js.map