"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_path_1 = require("node:path");
const node_child_process_1 = require("node:child_process");
// Delegate out to the provided `executable` file within the lambda
const executable = (0, node_path_1.join)(process.env.LAMBDA_TASK_ROOT, 'executable');
(0, node_child_process_1.spawn)(executable, [], { stdio: 'inherit' });
//# sourceMappingURL=bootstrap.js.map