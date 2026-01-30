#!/usr/bin/env node
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const path_1 = require("path");
const graceful_fs_1 = require("graceful-fs");
const { copyFile, mkdir, rm } = graceful_fs_1.promises;
const node_file_trace_1 = require("./node-file-trace");
function printStack(file, reasons, stdout, cwd) {
    stdout.push(file);
    const reason = reasons.get(file);
    if (!reason ||
        !reason.parents ||
        (reason.type.length === 1 &&
            reason.type.includes('initial') &&
            reason.parents.size === 0)) {
        return;
    }
    for (let parent of reason.parents) {
        printStack(parent, reasons, stdout, cwd);
    }
}
async function cli(action = process.argv[2], entrypoint = process.argv[3], exitpoint = process.argv[4], outputDir = 'dist', cwd = process.cwd()) {
    const opts = {
        ts: true,
        base: cwd,
        mixedModules: true,
        log: action == 'print' || action == 'build',
    };
    const { fileList, esmFileList, warnings, reasons } = await (0, node_file_trace_1.nodeFileTrace)([entrypoint], opts);
    const allFiles = [...fileList].concat([...esmFileList]).sort();
    const stdout = [];
    if (action === 'print') {
        stdout.push('FILELIST:');
        stdout.push(...allFiles);
        stdout.push('\n');
        if (warnings.size > 0) {
            stdout.push('WARNINGS:');
            for (var warning of warnings) {
                stdout.push(warning.toString());
            }
        }
    }
    else if (action === 'build') {
        await rm((0, path_1.join)(cwd, outputDir), { recursive: true, force: true });
        for (const f of allFiles) {
            const src = (0, path_1.join)(cwd, f);
            const dest = (0, path_1.join)(cwd, outputDir, f);
            const dir = (0, path_1.dirname)(dest);
            await mkdir(dir, { recursive: true });
            await copyFile(src, dest);
        }
    }
    else if (action === 'size') {
        const isSymbolicLink = (m) => (m & 61440) === 40960;
        let bytes = 0;
        for (const f of allFiles) {
            const lstat = (0, graceful_fs_1.lstatSync)(f);
            if (isSymbolicLink(lstat.mode)) {
                bytes += lstat.size;
            }
            else {
                const stat = (0, graceful_fs_1.statSync)(f);
                bytes += stat.size;
            }
        }
        stdout.push(`${bytes} bytes total`);
    }
    else if (action === 'why') {
        if (!exitpoint) {
            throw new Error('Expected additional argument for "why" action');
        }
        const normalizedExitPoint = ((0, path_1.isAbsolute)(exitpoint) ? (0, path_1.relative)(cwd, exitpoint) : exitpoint).replace(/[/\\]/g, path_1.sep);
        printStack(normalizedExitPoint, reasons, stdout, cwd);
    }
    else {
        stdout.push(`△ nft ${require('../package.json').version}`);
        stdout.push('');
        stdout.push('Usage:');
        stdout.push('');
        stdout.push(`  $ nft [command] <file>`);
        stdout.push('');
        stdout.push('Commands:');
        stdout.push('');
        stdout.push('  build [entrypoint]        trace and copy to the dist directory');
        stdout.push('  print [entrypoint]        trace and print to stdout');
        stdout.push('   size [entrypoint]        trace and print size in bytes');
        stdout.push('    why [entrypoint] [file] trace and print stack why file was included');
    }
    return stdout.join('\n');
}
if (require.main === module) {
    cli().then(console.log).catch(console.error);
}
module.exports = cli;
