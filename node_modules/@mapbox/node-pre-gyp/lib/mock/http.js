'use strict';

module.exports = exports = http_mock;

const fs = require('fs');
const path = require('path');
const nock = require('nock');
const os = require('os');

const log = require('../util/log.js');
log.heading = 'node-pre-gyp'; // differentiate node-pre-gyp's logs from npm's

function http_mock() {
  log.warn('mocking http requests to s3');

  const basePath = `${os.tmpdir()}/mock`;

  nock(new RegExp('([a-z0-9]+[.])*s3[.]us-east-1[.]amazonaws[.]com'))
    .persist()
    .get(() => true) //a function that always returns true is a catch all for nock
    .reply(
      (uri) => {
        const bucket = 'npg-mock-bucket';
        const mockDir = uri.indexOf(bucket) === -1 ? `${basePath}/${bucket}` : basePath;
        const filepath = path.join(mockDir, uri.replace(new RegExp('%2B', 'g'), '+'));

        try {
          fs.accessSync(filepath, fs.constants.R_OK);
        } catch (e) {
          return [404, 'not found\n'];
        }

        // mock s3 functions write to disk
        // return what is read from it.
        return [200, fs.createReadStream(filepath)];
      }
    );
}
