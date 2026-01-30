"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_path_1 = require("node:path");
const node_child_process_1 = require("node:child_process");
const nodeBin = (0, node_path_1.join)(__dirname, 'bin', 'node');
const bootstrap = (0, node_path_1.join)(__dirname, '..', 'nodejs', 'bootstrap.js');
(0, node_child_process_1.spawn)(nodeBin, [bootstrap], { stdio: 'inherit' });
//# sourceMappingURL=bootstrap.js.map