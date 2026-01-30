"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_path_1 = require("node:path");
const node_child_process_1 = require("node:child_process");
const pythonBin = (0, node_path_1.join)(__dirname, 'bin', 'python');
const bootstrap = (0, node_path_1.join)(__dirname, '..', 'python', 'bootstrap.py');
(0, node_child_process_1.spawn)(pythonBin, [bootstrap], { stdio: 'inherit' });
//# sourceMappingURL=bootstrap.js.map