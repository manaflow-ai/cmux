"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.default = handleSpecialCases;
const path_1 = require("path");
const resolve_dependency_1 = __importDefault(require("../resolve-dependency"));
const get_package_base_1 = require("./get-package-base");
const graceful_fs_1 = require("graceful-fs");
const specialCases = {
    '@generated/photon'({ id, emitAssetDirectory }) {
        if (id.endsWith('@generated/photon/index.js')) {
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), 'runtime/'));
        }
    },
    '@serialport/bindings-cpp'({ id, emitAssetDirectory }) {
        if (id.endsWith('@serialport/bindings-cpp/dist/index.js')) {
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), '..', 'build', 'Release'));
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), '..', 'prebuilds'));
        }
    },
    argon2({ id, emitAssetDirectory }) {
        if (id.endsWith('argon2/argon2.js')) {
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), 'build', 'Release'));
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), 'prebuilds'));
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), 'lib', 'binding'));
        }
    },
    bull({ id, emitAssetDirectory }) {
        if (id.endsWith('bull/lib/commands/index.js')) {
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id)));
        }
    },
    camaro({ id, emitAsset }) {
        if (id.endsWith('camaro/dist/camaro.js')) {
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), 'camaro.wasm'));
        }
    },
    esbuild({ id, emitAssetDirectory }) {
        if (id.endsWith('esbuild/lib/main.js')) {
            const file = (0, path_1.resolve)(id, '..', '..', 'package.json');
            const pkg = JSON.parse((0, graceful_fs_1.readFileSync)(file, 'utf8'));
            for (const dep of Object.keys(pkg.optionalDependencies || {})) {
                const dir = (0, path_1.resolve)(id, '..', '..', '..', dep);
                emitAssetDirectory(dir);
            }
        }
    },
    'ffmpeg-static'({ id, emitAsset }) {
        if (id.endsWith('ffmpeg-static/index.js')) {
            const bin = require(id);
            emitAsset(bin);
        }
    },
    'google-gax'({ id, ast, emitAssetDirectory }) {
        if (id.endsWith('google-gax/build/src/grpc.js')) {
            // const googleProtoFilesDir = path.normalize(google_proto_files_1.getProtoPath('..'));
            // ->
            // const googleProtoFilesDir = resolve(__dirname, '../../../google-proto-files');
            for (const statement of ast.body) {
                if (statement.type === 'VariableDeclaration' &&
                    statement.declarations[0].id.type === 'Identifier' &&
                    statement.declarations[0].id.name === 'googleProtoFilesDir') {
                    emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), '../../../google-proto-files'));
                }
            }
        }
    },
    oracledb({ id, ast, emitAsset }) {
        if (id.endsWith('oracledb/lib/oracledb.js')) {
            for (const statement of ast.body) {
                if (statement.type === 'ForStatement' &&
                    'body' in statement.body &&
                    statement.body.body &&
                    Array.isArray(statement.body.body) &&
                    statement.body.body[0] &&
                    statement.body.body[0].type === 'TryStatement' &&
                    statement.body.body[0].block.body[0] &&
                    statement.body.body[0].block.body[0].type === 'ExpressionStatement' &&
                    statement.body.body[0].block.body[0].expression.type ===
                        'AssignmentExpression' &&
                    statement.body.body[0].block.body[0].expression.operator === '=' &&
                    statement.body.body[0].block.body[0].expression.left.type ===
                        'Identifier' &&
                    statement.body.body[0].block.body[0].expression.left.name ===
                        'oracledbCLib' &&
                    statement.body.body[0].block.body[0].expression.right.type ===
                        'CallExpression' &&
                    statement.body.body[0].block.body[0].expression.right.callee.type ===
                        'Identifier' &&
                    statement.body.body[0].block.body[0].expression.right.callee.name ===
                        'require' &&
                    statement.body.body[0].block.body[0].expression.right.arguments
                        .length === 1 &&
                    statement.body.body[0].block.body[0].expression.right.arguments[0]
                        .type === 'MemberExpression' &&
                    statement.body.body[0].block.body[0].expression.right.arguments[0]
                        .computed === true &&
                    statement.body.body[0].block.body[0].expression.right.arguments[0]
                        .object.type === 'Identifier' &&
                    statement.body.body[0].block.body[0].expression.right.arguments[0]
                        .object.name === 'binaryLocations' &&
                    statement.body.body[0].block.body[0].expression.right.arguments[0]
                        .property.type === 'Identifier' &&
                    statement.body.body[0].block.body[0].expression.right.arguments[0]
                        .property.name === 'i') {
                    statement.body.body[0].block.body[0].expression.right.arguments = [
                        { type: 'Literal', value: '_' },
                    ];
                    const version = global._unit
                        ? '3.0.0'
                        : JSON.parse((0, graceful_fs_1.readFileSync)(id.slice(0, -15) + 'package.json', 'utf8')).version;
                    const useVersion = Number(version.slice(0, version.indexOf('.'))) >= 4;
                    const binaryName = 'oracledb-' +
                        (useVersion ? version : 'abi' + process.versions.modules) +
                        '-' +
                        process.platform +
                        '-' +
                        process.arch +
                        '.node';
                    emitAsset((0, path_1.resolve)(id, '../../build/Release/' + binaryName));
                }
            }
        }
    },
    'phantomjs-prebuilt'({ id, emitAssetDirectory }) {
        if (id.endsWith('phantomjs-prebuilt/lib/phantomjs.js')) {
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), '..', 'bin'));
        }
    },
    'remark-prism'({ id, emitAssetDirectory }) {
        const file = 'remark-prism/src/highlight.js';
        if (id.endsWith(file)) {
            try {
                const node_modules = id.slice(0, -file.length);
                emitAssetDirectory((0, path_1.resolve)(node_modules, 'prismjs', 'components'));
            }
            catch (e) {
                // fail silently
            }
        }
    },
    semver({ id, emitAsset }) {
        if (id.endsWith('semver/index.js')) {
            // See https://github.com/npm/node-semver/blob/master/CHANGELOG.md#710
            emitAsset((0, path_1.resolve)(id.replace('index.js', 'preload.js')));
        }
    },
    sharp: async ({ id, emitAssetDirectory, job }) => {
        if (id.endsWith('sharp/lib/index.js')) {
            const file = (0, path_1.resolve)(id, '..', '..', 'package.json');
            const pkg = JSON.parse((0, graceful_fs_1.readFileSync)(file, 'utf8'));
            for (const dep of Object.keys(pkg.optionalDependencies || {})) {
                const dir = (0, path_1.resolve)(id, '..', '..', '..', dep);
                emitAssetDirectory(dir);
                try {
                    const file = (0, path_1.resolve)(dir, 'package.json');
                    const pkg = JSON.parse((0, graceful_fs_1.readFileSync)(file, 'utf8'));
                    for (const innerDep of Object.keys(pkg.optionalDependencies || {})) {
                        const innerDir = (0, path_1.resolve)(await job.realpath(dir), '..', '..', innerDep);
                        emitAssetDirectory(innerDir);
                    }
                }
                catch (err) {
                    if (err && err.code !== 'ENOENT') {
                        console.error(`Error reading "sharp" dependencies from "${dir}/package.json"'`);
                        throw err;
                    }
                }
            }
        }
    },
    shiki({ id, emitAssetDirectory }) {
        if (id.endsWith('/dist/index.js')) {
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), '..', 'languages'));
            emitAssetDirectory((0, path_1.resolve)((0, path_1.dirname)(id), '..', 'themes'));
        }
    },
    'socket.io': async function ({ id, ast, job }) {
        if (id.endsWith('socket.io/lib/index.js')) {
            async function replaceResolvePathStatement(statement) {
                if (statement.type === 'ExpressionStatement' &&
                    statement.expression.type === 'AssignmentExpression' &&
                    statement.expression.operator === '=' &&
                    statement.expression.right.type === 'CallExpression' &&
                    statement.expression.right.callee.type === 'Identifier' &&
                    statement.expression.right.callee.name === 'read' &&
                    statement.expression.right.arguments.length >= 1 &&
                    statement.expression.right.arguments[0].type === 'CallExpression' &&
                    statement.expression.right.arguments[0].callee.type ===
                        'Identifier' &&
                    statement.expression.right.arguments[0].callee.name ===
                        'resolvePath' &&
                    statement.expression.right.arguments[0].arguments.length === 1 &&
                    statement.expression.right.arguments[0].arguments[0].type ===
                        'Literal') {
                    const arg = statement.expression.right.arguments[0].arguments[0].value;
                    let resolved;
                    try {
                        const dep = await (0, resolve_dependency_1.default)(String(arg), id, job);
                        if (typeof dep === 'string') {
                            resolved = dep;
                        }
                        else {
                            return undefined;
                        }
                    }
                    catch (e) {
                        return undefined;
                    }
                    // The asset relocator will then pick up the AST rewriting from here
                    const relResolved = '/' + (0, path_1.relative)((0, path_1.dirname)(id), resolved);
                    statement.expression.right.arguments[0] = {
                        type: 'BinaryExpression',
                        // @ts-ignore Its okay if start is undefined
                        start: statement.expression.right.arguments[0].start,
                        // @ts-ignore Its okay if end is undefined
                        end: statement.expression.right.arguments[0].end,
                        operator: '+',
                        left: {
                            type: 'Identifier',
                            name: '__dirname',
                        },
                        right: {
                            type: 'Literal',
                            value: relResolved,
                            raw: JSON.stringify(relResolved),
                        },
                    };
                }
                return undefined;
            }
            for (const statement of ast.body) {
                if (statement.type === 'ExpressionStatement' &&
                    statement.expression.type === 'AssignmentExpression' &&
                    statement.expression.operator === '=' &&
                    statement.expression.left.type === 'MemberExpression' &&
                    statement.expression.left.object.type === 'MemberExpression' &&
                    statement.expression.left.object.object.type === 'Identifier' &&
                    statement.expression.left.object.object.name === 'Server' &&
                    statement.expression.left.object.property.type === 'Identifier' &&
                    statement.expression.left.object.property.name === 'prototype' &&
                    statement.expression.left.property.type === 'Identifier' &&
                    statement.expression.left.property.name === 'serveClient' &&
                    statement.expression.right.type === 'FunctionExpression') {
                    for (const node of statement.expression.right.body.body) {
                        if (node.type === 'IfStatement' &&
                            node.consequent &&
                            'body' in node.consequent &&
                            node.consequent.body) {
                            const ifBody = node.consequent.body;
                            let replaced = false;
                            if (Array.isArray(ifBody) &&
                                ifBody[0] &&
                                ifBody[0].type === 'ExpressionStatement') {
                                replaced = await replaceResolvePathStatement(ifBody[0]);
                            }
                            if (Array.isArray(ifBody) &&
                                ifBody[1] &&
                                ifBody[1].type === 'TryStatement' &&
                                ifBody[1].block.body &&
                                ifBody[1].block.body[0]) {
                                replaced =
                                    (await replaceResolvePathStatement(ifBody[1].block.body[0])) || replaced;
                            }
                            return;
                        }
                    }
                }
            }
        }
    },
    typescript({ id, emitAssetDirectory }) {
        if (id.endsWith('typescript/lib/tsc.js')) {
            emitAssetDirectory((0, path_1.resolve)(id, '../'));
        }
    },
    'uglify-es'({ id, emitAsset }) {
        if (id.endsWith('uglify-es/tools/node.js')) {
            emitAsset((0, path_1.resolve)(id, '../../lib/utils.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/ast.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/parse.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/transform.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/scope.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/output.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/compress.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/sourcemap.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/mozilla-ast.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/propmangle.js'));
            emitAsset((0, path_1.resolve)(id, '../../lib/minify.js'));
            emitAsset((0, path_1.resolve)(id, '../exports.js'));
        }
    },
    'uglify-js'({ id, emitAsset, emitAssetDirectory }) {
        if (id.endsWith('uglify-js/tools/node.js')) {
            emitAssetDirectory((0, path_1.resolve)(id, '../../lib'));
            emitAsset((0, path_1.resolve)(id, '../exports.js'));
        }
    },
    'playwright-core'({ id, emitAsset }) {
        if (id.endsWith('playwright-core/index.js')) {
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), 'browsers.json'));
        }
    },
    'geo-tz'({ id, emitAsset }) {
        if (id.endsWith('geo-tz/dist/geo-tz.js')) {
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), '../data/geo.dat'));
        }
    },
    pixelmatch({ id, emitDependency }) {
        if (id.endsWith('pixelmatch/index.js')) {
            emitDependency((0, path_1.resolve)((0, path_1.dirname)(id), 'bin/pixelmatch'));
        }
    },
    'geoip-lite'({ id, emitAsset }) {
        if (id.endsWith('geoip-lite/lib/geoip.js')) {
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), '../data/geoip-city.dat'));
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), '../data/geoip-city6.dat'));
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), '../data/geoip-city-names.dat'));
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), '../data/geoip-country.dat'));
            emitAsset((0, path_1.resolve)((0, path_1.dirname)(id), '../data/geoip-country6.dat'));
        }
    },
};
async function handleSpecialCases({ id, ast, emitDependency, emitAsset, emitAssetDirectory, job, }) {
    const pkgName = (0, get_package_base_1.getPackageName)(id);
    const specialCase = specialCases[pkgName || ''];
    id = id.replace(/\\/g, '/');
    if (specialCase)
        await specialCase({
            id,
            ast,
            emitDependency,
            emitAsset,
            emitAssetDirectory,
            job,
        });
}
