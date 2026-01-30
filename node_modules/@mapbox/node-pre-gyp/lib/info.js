'use strict';

module.exports = exports = info;

exports.usage = 'Lists all published binaries (requires aws-sdk)';

const log = require('./util/log.js');
const versioning = require('./util/versioning.js');
const s3_setup = require('./util/s3_setup.js');

function info(gyp, argv, callback) {
  const package_json = gyp.package_json;
  const opts = versioning.evaluate(package_json, gyp.opts);
  const config = s3_setup.detect(opts);
  const s3 = s3_setup.get_s3(config);
  const s3_opts = {
    Bucket: config.bucket,
    Prefix: config.prefix
  };
  s3.listObjects(s3_opts, (err, meta) => {
    if (err && err.code === 'NotFound') {
      return callback(new Error('[' + package_json.name + '] Not found: https://' + opts.hosted_path));
    } else if (err) {
      return callback(err);
    } else {
      log.verbose(JSON.stringify(meta, null, 1));
      if (meta && meta.Contents.length) {
        meta.Contents.forEach((obj) => {
          console.log(obj.Key);
        });
      } else {
        console.error('[' + package_json.name + '] Not found: No objects at https://' + opts.hosted_path);
      }
      return callback();
    }
  });
}
