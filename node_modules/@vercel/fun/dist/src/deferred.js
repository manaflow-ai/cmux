"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createDeferred = void 0;
function createDeferred() {
    let r;
    let j;
    const promise = new Promise((resolve, reject) => {
        r = resolve;
        j = reject;
    });
    return { promise, resolve: r, reject: j };
}
exports.createDeferred = createDeferred;
//# sourceMappingURL=deferred.js.map