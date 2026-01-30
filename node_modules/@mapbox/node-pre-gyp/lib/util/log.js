'use strict';

const { createConsola } = require('consola/basic');

// match the default behavior of npm and node-gyp  where stdout is reserved for output that is expected
// to be used programmatically (usually json)
const log = createConsola({ stdout: process.stderr });

module.exports = exports = log;
