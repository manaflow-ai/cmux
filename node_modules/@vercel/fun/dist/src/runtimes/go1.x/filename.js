"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getOutputFile = void 0;
function getOutputFile() {
    const ext = process.platform === 'win32' ? '.exe' : '';
    return `bootstrap${ext}`;
}
exports.getOutputFile = getOutputFile;
//# sourceMappingURL=filename.js.map