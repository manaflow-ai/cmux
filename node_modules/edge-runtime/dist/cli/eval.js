"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.inlineEval = void 0;
const edge_runtime_1 = require("../edge-runtime");
const inlineEval = async (script) => {
    const runtime = new edge_runtime_1.EdgeRuntime();
    const result = await runtime.evaluate(script);
    return result;
};
exports.inlineEval = inlineEval;
//# sourceMappingURL=eval.js.map