"use strict";
/**
 * Subclassing `Error` in TypeScript:
 * https://stackoverflow.com/a/41102306/376773
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.LambdaError = void 0;
class LambdaError extends Error {
    constructor(data = {}) {
        super(data.errorMessage || 'Unspecified runtime initialization error');
        Object.setPrototypeOf(this, LambdaError.prototype);
        Object.defineProperty(this, 'name', {
            value: data.errorType || this.constructor.name
        });
        if (Array.isArray(data.stackTrace)) {
            this.stack = [
                `${this.name}: ${this.message}`,
                ...data.stackTrace
            ].join('\n');
        }
        else if (typeof data.stackTrace === 'string') {
            this.stack = data.stackTrace;
        }
    }
}
exports.LambdaError = LambdaError;
//# sourceMappingURL=errors.js.map