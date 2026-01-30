"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_path_1 = require("node:path");
const node_child_process_1 = require("node:child_process");
const filename_1 = require("./filename");
const out = (0, filename_1.getOutputFile)();
const bootstrap = (0, node_path_1.join)(__dirname, out);
(0, node_child_process_1.spawn)(bootstrap, [], { stdio: 'inherit' });
//# sourceMappingURL=bootstrap.js.map