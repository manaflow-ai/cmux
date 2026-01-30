"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.createLogger = exports.format = void 0;
const format_1 = require("@edge-runtime/format");
const picocolors_1 = __importDefault(require("picocolors"));
const isEnabled = process.env.EDGE_RUNTIME_LOGGING !== undefined
    ? Boolean(process.env.EDGE_RUNTIME_LOGGING)
    : true;
exports.format = (0, format_1.createFormat)();
/**
 * Creates basic logger with colors that can be used from the CLI and the
 * server logs.
 */
function createLogger() {
    const logger = function (message, opts) {
        print(message, opts);
    };
    logger.info = logger;
    logger.error = (message, opts) => print(message, { color: 'red', ...opts });
    logger.debug = (message, opts) => print(message, { color: 'dim', ...opts });
    logger.warn = (message, opts) => print(message, { color: 'yellow', ...opts });
    logger.quotes = (str) => `\`${str}\``;
    return logger;
}
exports.createLogger = createLogger;
function print(message, { color = 'white', withHeader = true, withBreakline = false, } = {}) {
    if (!isEnabled)
        return;
    const colorize = picocolors_1.default[color];
    const header = withHeader ? `${colorize('ƒ')} ` : '';
    const separator = withBreakline ? '\n' : '';
    console.log(`${header}${separator}${colorize(message)}`);
}
//# sourceMappingURL=logger.js.map