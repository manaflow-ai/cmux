'use strict';

module.exports = exports = s3_mock;

const AWSMock = require('mock-aws-s3');
const os = require('os');

const log = require('../util/log.js');
log.heading = 'node-pre-gyp'; // differentiate node-pre-gyp's logs from npm's

function s3_mock() {
  log.warn('mocking s3 operations');

  AWSMock.config.basePath = `${os.tmpdir()}/mock`;

  const s3 = AWSMock.S3();

  // wrapped callback maker. fs calls return code of ENOENT but AWS.S3 returns
  // NotFound.
  const wcb = (fn) => (err, ...args) => {
    if (err && err.code === 'ENOENT') {
      err.code = 'NotFound';
    }
    return fn(err, ...args);
  };

  return {
    listObjects(params, callback) {
      return s3.listObjects(params, wcb(callback));
    },
    headObject(params, callback) {
      return s3.headObject(params, wcb(callback));
    },
    deleteObject(params, callback) {
      return s3.deleteObject(params, wcb(callback));
    },
    putObject(params, callback) {
      return s3.putObject(params, wcb(callback));
    },
    getObject(params, callback) {
      return s3.getObject(params, wcb(callback));
    }
  };
}
