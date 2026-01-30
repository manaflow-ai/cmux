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
exports.installPython = exports.generatePythonTarballUrl = void 0;
const tar_1 = require("tar");
const node_fetch_1 = __importDefault(require("node-fetch"));
const debug_1 = __importDefault(require("debug"));
const node_zlib_1 = require("node:zlib");
const debug = (0, debug_1.default)('@vercel/fun:install-python');
function generatePythonTarballUrl(version, platform = process.platform, arch = process.arch) {
    return `https://python-binaries.zeit.sh/python-${version}-${platform}-${arch}.tar.gz`;
}
exports.generatePythonTarballUrl = generatePythonTarballUrl;
function installPython(dest, version, platform = process.platform, arch = process.arch) {
    return __awaiter(this, void 0, void 0, function* () {
        // For Apple M1 use the x64 binaries
        if (platform === 'darwin' && arch === 'arm64') {
            arch = 'x64';
        }
        const tarballUrl = generatePythonTarballUrl(version, platform, arch);
        debug('Downloading Python %s tarball %o', version, tarballUrl);
        const res = yield (0, node_fetch_1.default)(tarballUrl);
        if (!res.ok) {
            throw new Error(`HTTP request ${tarballUrl} failed: ${res.status}`);
        }
        return new Promise((resolve, reject) => {
            debug('Extracting Python %s tarball to %o', version, dest);
            res.body
                .pipe((0, node_zlib_1.createGunzip)())
                .pipe((0, tar_1.extract)({ strip: 1, C: dest }))
                .on('error', reject)
                .on('end', resolve);
        });
    });
}
exports.installPython = installPython;
//# sourceMappingURL=install-python.js.map