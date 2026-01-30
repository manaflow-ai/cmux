"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_path_1 = require("node:path");
const node_child_process_1 = require("node:child_process");
// `PYTHONPATH` is *not* a restricted env var, so only set the
// default one if the user did not provide one of their own
if (!process.env.PYTHONPATH) {
    process.env.PYTHONPATH = process.env.LAMBDA_RUNTIME_DIR;
}
const bootstrap = (0, node_path_1.join)(__dirname, 'bootstrap.py');
(0, node_child_process_1.spawn)('python', [bootstrap], { stdio: 'inherit' });
//# sourceMappingURL=bootstrap.js.map