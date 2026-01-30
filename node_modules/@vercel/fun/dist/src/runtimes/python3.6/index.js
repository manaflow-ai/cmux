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
Object.defineProperty(exports, "__esModule", { value: true });
exports.init = void 0;
const install_python_1 = require("../../install-python");
const runtimes_1 = require("../../runtimes");
function init({ cacheDir }) {
    return __awaiter(this, void 0, void 0, function* () {
        yield Promise.all([
            (0, runtimes_1.initializeRuntime)(runtimes_1.runtimes.python),
            (0, install_python_1.installPython)(cacheDir, '3.6.8')
        ]);
    });
}
exports.init = init;
//# sourceMappingURL=index.js.map