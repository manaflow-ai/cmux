"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.help = void 0;
const picocolors_1 = require("picocolors");
const flags = {
    eval: 'Evaluate an input script',
    help: 'Display this message.',
    listen: 'Run as HTTP server.',
    port: 'Specify a port to use.',
    repl: 'Start an interactive session.',
};
const help = () => `
  edge-runtime ${(0, picocolors_1.dim)('[<flags>] [input]')}

  ${(0, picocolors_1.dim)('Flags:')}

${getSectionSummary(flags)}
`;
exports.help = help;
function getPadLength(options) {
    const lengths = Object.keys(options).map((key) => key.length);
    return Math.max.apply(null, lengths) + 1;
}
function getSectionSummary(options) {
    const summaryPadLength = getPadLength(options);
    const summary = Object.entries(options)
        .map(([key, description]) => `    --${key.padEnd(summaryPadLength)} ${(0, picocolors_1.dim)(description)}`)
        .join('\n');
    return `${summary}`;
}
//# sourceMappingURL=help.js.map