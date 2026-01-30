"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getStringFromStrOrFunc = exports.escapeChar = exports.escapeForWithinString = void 0;
const newlineRegex = /(\r?\n)/g;
/** @internal */
function escapeForWithinString(str, quoteKind) {
    return escapeChar(str, quoteKind).replace(newlineRegex, "\\$1");
}
exports.escapeForWithinString = escapeForWithinString;
/** @internal */
function escapeChar(str, char) {
    if (char.length !== 1)
        throw new Error(`Specified char must be one character long.`);
    let result = "";
    for (let i = 0; i < str.length; i++) {
        if (str[i] === char)
            result += "\\";
        result += str[i];
    }
    return result;
}
exports.escapeChar = escapeChar;
/** @internal */
function getStringFromStrOrFunc(strOrFunc) {
    return strOrFunc instanceof Function ? strOrFunc() : strOrFunc;
}
exports.getStringFromStrOrFunc = getStringFromStrOrFunc;
