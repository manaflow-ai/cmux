import { n as __toESM, t as require_binding } from "./shared/binding-QUhP-0wQ.mjs";
import { n as onExit, t as watch } from "./shared/watch-CN4zUkzW.mjs";
import { y as VERSION } from "./shared/normalize-string-or-regex-DbyImenn.mjs";
import "./shared/rolldown-build-ciWo5RN-.mjs";
import "./shared/bindingify-input-options-CJ8NjPpl.mjs";
import "./shared/parse-ast-index-Dxd6PXtU.mjs";
import { t as rolldown } from "./shared/rolldown-BR9L9ovo.mjs";
import { t as defineConfig } from "./shared/define-config-BF4P-Pum.mjs";
import { isMainThread } from "node:worker_threads";

//#region src/setup.ts
var import_binding = /* @__PURE__ */ __toESM(require_binding(), 1);
if (isMainThread) {
	const subscriberGuard = (0, import_binding.initTraceSubscriber)();
	onExit(() => {
		subscriberGuard?.close();
	});
}

//#endregion
//#region src/api/build.ts
async function build(options) {
	if (Array.isArray(options)) return Promise.all(options.map((opts) => build(opts)));
	else {
		const { output, write = true, ...inputOptions } = options;
		const build$1 = await rolldown(inputOptions);
		try {
			if (write) return await build$1.write(output);
			else return await build$1.generate(output);
		} finally {
			await build$1.close();
		}
	}
}

//#endregion
var BindingMagicString = import_binding.BindingMagicString;
export { BindingMagicString, VERSION, build, defineConfig, rolldown, watch };