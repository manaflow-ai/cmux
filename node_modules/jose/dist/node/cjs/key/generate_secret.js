"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.generateSecret = generateSecret;
const generate_js_1 = require("../runtime/generate.js");
async function generateSecret(alg, options) {
    return (0, generate_js_1.generateSecret)(alg, options);
}
