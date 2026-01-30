"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.VM = void 0;
const vm_1 = require("vm");
/**
 * A raw VM with a context that can be extended on instantiation. Implements
 * a realm-like interface where one can evaluate code or require CommonJS
 * modules in multiple ways.
 */
class VM {
    constructor(options = {}) {
        var _a, _b, _c;
        const context = (0, vm_1.createContext)({}, {
            name: 'Edge Runtime',
            codeGeneration: (_a = options.codeGeneration) !== null && _a !== void 0 ? _a : {
                strings: false,
                wasm: true,
            },
        });
        this.context = (_c = (_b = options.extend) === null || _b === void 0 ? void 0 : _b.call(options, context)) !== null && _c !== void 0 ? _c : context;
    }
    /**
     * Allows to run arbitrary code within the VM.
     */
    evaluate(code) {
        return (0, vm_1.runInContext)(code, this.context);
    }
}
exports.VM = VM;
//# sourceMappingURL=vm.js.map