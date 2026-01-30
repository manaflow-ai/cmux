import { n as __toESM, t as require_binding } from "./binding-QUhP-0wQ.mjs";
import { l as locate, n as error, s as logParseError, t as augmentCodeLocation, u as getCodeFrame } from "./logs-Up1RAnkl.mjs";

//#region ../../node_modules/.pnpm/oxc-parser@0.107.0/node_modules/oxc-parser/src-js/wrap.js
function wrap$1(result) {
	let program, module, comments, errors;
	return {
		get program() {
			if (!program) program = jsonParseAst(result.program);
			return program;
		},
		get module() {
			if (!module) module = result.module;
			return module;
		},
		get comments() {
			if (!comments) comments = result.comments;
			return comments;
		},
		get errors() {
			if (!errors) errors = result.errors;
			return errors;
		}
	};
}
function jsonParseAst(programJson) {
	const { node: program, fixes } = JSON.parse(programJson);
	for (const fixPath of fixes) applyFix(program, fixPath);
	return program;
}
function applyFix(program, fixPath) {
	let node = program;
	for (const key of fixPath) node = node[key];
	if (node.bigint) node.value = BigInt(node.bigint);
	else try {
		node.value = RegExp(node.regex.pattern, node.regex.flags);
	} catch {}
}

//#endregion
//#region src/utils/parse.ts
var import_binding = /* @__PURE__ */ __toESM(require_binding(), 1);
/**
* Parse asynchronously.
*
* Note: This function can be slower than `parseSync` due to the overhead of spawning a thread.
*/
async function parse(filename, sourceText, options) {
	return wrap$1(await (0, import_binding.parse)(filename, sourceText, options));
}
/** Parse synchronously. */
function parseSync(filename, sourceText, options) {
	return wrap$1((0, import_binding.parseSync)(filename, sourceText, options));
}

//#endregion
//#region src/parse-ast-index.ts
function wrap(result, filename, sourceText) {
	if (result.errors.length > 0) return normalizeParseError(filename, sourceText, result.errors);
	return result.program;
}
function normalizeParseError(filename, sourceText, errors) {
	let message = `Parse failed with ${errors.length} error${errors.length < 2 ? "" : "s"}:\n`;
	const pos = errors[0]?.labels?.[0]?.start;
	for (let i = 0; i < errors.length; i++) {
		if (i >= 5) {
			message += "\n...";
			break;
		}
		const e = errors[i];
		message += e.message + "\n" + e.labels.map((label) => {
			const location = locate(sourceText, label.start, { offsetLine: 1 });
			if (!location) return;
			return getCodeFrame(sourceText, location.line, location.column);
		}).filter(Boolean).join("\n");
	}
	const log = logParseError(message, filename, pos);
	if (pos !== void 0 && filename) augmentCodeLocation(log, pos, sourceText, filename);
	return error(log);
}
const defaultParserOptions = {
	lang: "js",
	preserveParens: false
};
function parseAst(sourceText, options, filename) {
	return wrap(parseSync(filename ?? "file.js", sourceText, {
		...defaultParserOptions,
		...options
	}), filename, sourceText);
}
async function parseAstAsync(sourceText, options, filename) {
	return wrap(await parse(filename ?? "file.js", sourceText, {
		...defaultParserOptions,
		...options
	}), filename, sourceText);
}

//#endregion
export { parseSync as i, parseAstAsync as n, parse as r, parseAst as t };