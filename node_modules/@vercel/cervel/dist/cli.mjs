import { parseArgs } from "node:util";
import { createRequire } from "module";
import { existsSync } from "fs";
import { readFile, rm, writeFile } from "fs/promises";
import { extname, join } from "path";
import { build } from "rolldown";
import { spawn } from "child_process";
import execa from "execa";

//#region src/rolldown.ts
/**
* Escapes special regex characters in a string to treat it as a literal pattern.
*/
function escapeRegExp(string) {
	return string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
const rolldown = async (args) => {
	const baseDir = args.repoRootPath || args.workPath;
	const entrypointPath = join(args.workPath, args.entrypoint);
	const shouldAddSourcemapSupport = false;
	const extension = extname(args.entrypoint);
	const extensionMap = {
		".ts": {
			format: "auto",
			extension: "js"
		},
		".mts": {
			format: "esm",
			extension: "mjs"
		},
		".cts": {
			format: "cjs",
			extension: "cjs"
		},
		".cjs": {
			format: "cjs",
			extension: "cjs"
		},
		".js": {
			format: "auto",
			extension: "js"
		},
		".mjs": {
			format: "esm",
			extension: "mjs"
		}
	};
	const extensionInfo = extensionMap[extension] || extensionMap[".js"];
	let resolvedFormat = extensionInfo.format === "auto" ? void 0 : extensionInfo.format;
	const resolvedExtension = extensionInfo.extension;
	const packageJsonPath = join(args.workPath, "package.json");
	const external = [];
	let pkg = {};
	if (existsSync(packageJsonPath)) {
		const source = await readFile(packageJsonPath, "utf8");
		try {
			pkg = JSON.parse(source.toString());
		} catch (_e) {
			pkg = {};
		}
		if (extensionInfo.format === "auto") if (pkg.type === "module") resolvedFormat = "esm";
		else resolvedFormat = "cjs";
		for (const dependency of Object.keys(pkg.dependencies || {})) external.push(dependency);
		for (const dependency of Object.keys(pkg.devDependencies || {})) external.push(dependency);
		for (const dependency of Object.keys(pkg.peerDependencies || {})) external.push(dependency);
		for (const dependency of Object.keys(pkg.optionalDependencies || {})) external.push(dependency);
	}
	const relativeOutputDir = args.out;
	const outputDir = join(baseDir, relativeOutputDir);
	const out = await build({
		input: entrypointPath,
		cwd: baseDir,
		platform: "node",
		tsconfig: true,
		external: external.map((pkg$1) => /* @__PURE__ */ new RegExp(`^${escapeRegExp(pkg$1)}`)),
		output: {
			cleanDir: true,
			dir: outputDir,
			format: resolvedFormat,
			entryFileNames: `[name].${resolvedExtension}`,
			preserveModules: true,
			sourcemap: false
		}
	});
	let handler = null;
	for (const entry of out.output) if (entry.type === "chunk") {
		if (entry.isEntry) handler = entry.fileName;
	}
	if (typeof handler !== "string") throw new Error(`Unable to resolve module for ${args.entrypoint}`);
	const cleanup = async () => {
		await rm(outputDir, {
			recursive: true,
			force: true
		});
	};
	return {
		result: {
			pkg,
			shouldAddSourcemapSupport,
			handler,
			outputDir
		},
		cleanup
	};
};

//#endregion
//#region src/utils.ts
const noColor = globalThis.process?.env?.NO_COLOR === "1" || globalThis.process?.env?.TERM === "dumb";
const resets = {
	1: 22,
	31: 39,
	32: 39,
	33: 39,
	34: 39,
	35: 39,
	36: 39,
	90: 39
};
const _c = (c) => (text) => {
	if (noColor) return text;
	return `\u001B[${c}m${text}\u001B[${resets[c] ?? 0}m`;
};
const Colors = {
	bold: _c(1),
	red: _c(31),
	green: _c(32),
	yellow: _c(33),
	blue: _c(34),
	magenta: _c(35),
	cyan: _c(36),
	gray: _c(90),
	url: (title, url) => noColor ? `[${title}](${url})` : `\u001B]8;;${url}\u001B\\${title}\u001B]8;;\u001B\\`
};

//#endregion
//#region src/typescript.ts
const require_ = createRequire(import.meta.url);
const typescript = (args) => {
	const extension = extname(args.entrypoint);
	if (![
		".ts",
		".mts",
		".cts"
	].includes(extension)) return;
	const tscPath = resolveTscPath(args);
	if (!tscPath) {
		console.log(Colors.gray(`${Colors.bold(Colors.cyan("✓"))} Typecheck skipped ${Colors.gray("(TypeScript not found)")}`));
		return null;
	}
	return doTypeCheck(args, tscPath);
};
async function doTypeCheck(args, tscPath) {
	let stdout = "";
	let stderr = "";
	/**
	* This might be subject to change.
	* - if no tscPath, skip typecheck
	* - if tsconfig, provide the tsconfig path
	* - else provide the entrypoint path
	*/
	const tscArgs = [
		tscPath,
		"--noEmit",
		"--pretty",
		"--allowJs",
		"--esModuleInterop",
		"--skipLibCheck"
	];
	const tsconfig = await findNearestTsconfig(args.workPath);
	if (tsconfig) tscArgs.push("--project", tsconfig);
	else tscArgs.push(args.entrypoint);
	const child = spawn(process.execPath, tscArgs, {
		cwd: args.workPath,
		stdio: [
			"ignore",
			"pipe",
			"pipe"
		]
	});
	child.stdout?.on("data", (data) => {
		stdout += data.toString();
	});
	child.stderr?.on("data", (data) => {
		stderr += data.toString();
	});
	await new Promise((resolve, reject) => {
		child.on("close", (code) => {
			if (code === 0) {
				console.log(Colors.gray(`${Colors.bold(Colors.cyan("✓"))} Typecheck complete`));
				resolve();
			} else {
				const output = stdout || stderr;
				if (output) {
					console.error("\nTypeScript type check failed:\n");
					console.error(output);
				}
				reject(/* @__PURE__ */ new Error("TypeScript type check failed"));
			}
		});
		child.on("error", (err) => {
			reject(err);
		});
	});
}
const resolveTscPath = (args) => {
	try {
		return require_.resolve("typescript/bin/tsc", { paths: [args.workPath] });
	} catch (e) {
		return null;
	}
};
const findNearestTsconfig = async (workPath) => {
	const tsconfigPath = join(workPath, "tsconfig.json");
	if (existsSync(tsconfigPath)) return tsconfigPath;
	if (workPath === "/") return;
	return findNearestTsconfig(join(workPath, ".."));
};

//#endregion
//#region src/find-entrypoint.ts
const frameworks = [
	"express",
	"hono",
	"elysia",
	"fastify",
	"@nestjs/core",
	"h3"
];
const entrypointFilenames = [
	"app",
	"index",
	"server",
	"main"
];
const entrypointExtensions = [
	"js",
	"cjs",
	"mjs",
	"ts",
	"cts",
	"mts"
];
const entrypoints = entrypointFilenames.flatMap((filename) => entrypointExtensions.map((extension) => `${filename}.${extension}`));
const createFrameworkRegex = (framework) => new RegExp(`(?:from|require|import)\\s*(?:\\(\\s*)?["']${framework}["']\\s*(?:\\))?`, "g");
const findEntrypoint = async (cwd, options) => {
	if (options?.ignoreRegex ?? false) {
		for (const entrypoint of entrypoints) if (existsSync(join(cwd, entrypoint))) return entrypoint;
		for (const entrypoint of entrypoints) if (existsSync(join(cwd, "src", entrypoint))) return join("src", entrypoint);
		throw new Error("No entrypoint file found");
	}
	const packageJson = await readFile(join(cwd, "package.json"), "utf-8");
	const packageJsonObject = JSON.parse(packageJson);
	const framework = frameworks.find((framework$1) => packageJsonObject.dependencies?.[framework$1]);
	if (!framework) {
		for (const entrypoint of entrypoints) {
			const entrypointPath = join(cwd, entrypoint);
			try {
				await readFile(entrypointPath, "utf-8");
				return entrypoint;
			} catch (e) {
				continue;
			}
		}
		throw new Error("No entrypoint or framework found");
	}
	const regex = createFrameworkRegex(framework);
	for (const entrypoint of entrypoints) {
		const entrypointPath = join(cwd, entrypoint);
		try {
			const content = await readFile(entrypointPath, "utf-8");
			if (regex.test(content)) return entrypoint;
		} catch (e) {
			continue;
		}
	}
	for (const entrypoint of entrypoints) {
		const entrypointPath = join(cwd, "src", entrypoint);
		try {
			const content = await readFile(entrypointPath, "utf-8");
			if (regex.test(content)) return join("src", entrypoint);
		} catch (e) {
			continue;
		}
	}
	throw new Error("No entrypoint found");
};

//#endregion
//#region src/index.ts
const require = createRequire(import.meta.url);
const build$1 = async (args) => {
	const entrypoint = args.entrypoint || await findEntrypoint(args.cwd);
	const tsPromise = typescript({
		...args,
		entrypoint,
		workPath: args.cwd
	});
	const rolldownResult = await rolldown({
		...args,
		entrypoint,
		workPath: args.cwd,
		repoRootPath: args.cwd,
		out: args.out
	});
	await writeFile(join(args.cwd, args.out, ".cervel.json"), JSON.stringify({ handler: rolldownResult.result.handler }, null, 2));
	console.log(Colors.gray(`${Colors.bold(Colors.cyan("✓"))} Build complete`));
	const typecheckComplete = true;
	const result = tsPromise ? await Promise.race([tsPromise.then(() => typecheckComplete), Promise.resolve(false)]) : true;
	if (tsPromise && !result) console.log(Colors.gray(`${Colors.bold(Colors.gray("*"))} Waiting for typecheck...`));
	return {
		rolldownResult: rolldownResult.result,
		tsPromise
	};
};
const serve = async (args) => {
	const entrypoint = await findEntrypoint(args.cwd);
	const srvxBin = join(require.resolve("srvx"), "..", "..", "..", "bin", "srvx.mjs");
	const tsxBin = require.resolve("tsx");
	const restArgs = Object.entries(args.rest).filter(([, value]) => value !== void 0 && value !== false).map(([key, value]) => typeof value === "boolean" ? `--${key}` : `--${key}=${value}`);
	if (!args.rest.import) restArgs.push("--import", tsxBin);
	await execa("npx", [
		srvxBin,
		...restArgs,
		entrypoint
	], {
		cwd: args.cwd,
		stdio: "inherit"
	});
};
const srvxOptions = {
	help: {
		type: "boolean",
		short: "h"
	},
	version: {
		type: "boolean",
		short: "v"
	},
	prod: { type: "boolean" },
	port: {
		type: "string",
		short: "p"
	},
	host: {
		type: "string",
		short: "H"
	},
	static: {
		type: "string",
		short: "s"
	},
	import: { type: "string" },
	tls: { type: "boolean" },
	cert: { type: "string" },
	key: { type: "string" }
};

//#endregion
//#region src/cli.ts
const main = async () => {
	const options = parseArgs$1(process.argv.slice(2));
	const { cwd, out,...rest } = options.values;
	const [command, entrypoint] = options.positionals;
	if (command === "build") {
		const { tsPromise } = await build$1({
			cwd,
			out,
			entrypoint
		});
		await tsPromise;
	} else await serve({
		cwd,
		rest
	});
};
function parseArgs$1(args) {
	const { values, positionals } = parseArgs({
		args,
		allowPositionals: true,
		options: {
			cwd: {
				type: "string",
				default: process.cwd()
			},
			out: {
				type: "string",
				default: "dist"
			},
			...srvxOptions
		}
	});
	return {
		values,
		positionals
	};
}

//#endregion
export { main };