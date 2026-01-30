"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isJWK = isJWK;
exports.isPrivateJWK = isPrivateJWK;
exports.isPublicJWK = isPublicJWK;
exports.isSecretJWK = isSecretJWK;
const is_object_js_1 = require("./is_object.js");
function isJWK(key) {
    return (0, is_object_js_1.default)(key) && typeof key.kty === 'string';
}
function isPrivateJWK(key) {
    return key.kty !== 'oct' && typeof key.d === 'string';
}
function isPublicJWK(key) {
    return key.kty !== 'oct' && typeof key.d === 'undefined';
}
function isSecretJWK(key) {
    return isJWK(key) && key.kty === 'oct' && typeof key.k === 'string';
}
