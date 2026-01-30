"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.exportSPKI = exportSPKI;
exports.exportPKCS8 = exportPKCS8;
exports.exportJWK = exportJWK;
const asn1_js_1 = require("../runtime/asn1.js");
const asn1_js_2 = require("../runtime/asn1.js");
const key_to_jwk_js_1 = require("../runtime/key_to_jwk.js");
async function exportSPKI(key) {
    return (0, asn1_js_1.toSPKI)(key);
}
async function exportPKCS8(key) {
    return (0, asn1_js_2.toPKCS8)(key);
}
async function exportJWK(key) {
    return (0, key_to_jwk_js_1.default)(key);
}
