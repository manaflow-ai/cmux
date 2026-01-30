'use strict';

module.exports = exports = install;

exports.usage = 'Attempts to install pre-built binary for module';

const fs = require('fs');
const path = require('path');
const log = require('./util/log.js');
const existsAsync = fs.exists || path.exists;
const versioning = require('./util/versioning.js');
const napi = require('./util/napi.js');
const s3_setup = require('./util/s3_setup.js');
const url = require('url');
// for fetching binaries
const fetch = require('node-fetch');
const tar = require('tar');

let npgVersion = 'unknown';
try {
  // Read own package.json to get the current node-pre-pyp version.
  const ownPackageJSON = fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8');
  npgVersion = JSON.parse(ownPackageJSON).version;
} catch (e) {
  // do nothing
}

function place_binary_authenticated(opts, targetDir, callback) {
  log.info('install', 'Attempting authenticated S3 download');

  // Check if AWS credentials are available
  if (!process.env.AWS_ACCESS_KEY_ID || !process.env.AWS_SECRET_ACCESS_KEY) {
    const err = new Error('Binary is private but AWS credentials not found. Please configure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables, or use --fallback-to-build to compile from source.');
    err.statusCode = 403;
    return callback(err);
  }

  try {
    const config = s3_setup.detect(opts);
    const s3 = s3_setup.get_s3(config);
    const key_name = url.resolve(config.prefix, opts.package_name);

    log.info('install', 'Downloading from S3:', config.bucket, key_name);

    const s3_opts = {
      Bucket: config.bucket,
      Key: key_name
    };

    s3.getObject(s3_opts, (err, data) => {
      if (err) {
        log.error('install', 'Authenticated S3 download failed:', err.message);
        return callback(err);
      }

      log.info('install', 'Authenticated download successful, extracting...');

      const { Readable } = require('stream');
      const dataStream = Readable.from(data.Body);

      let extractions = 0;
      const countExtractions = (entry) => {
        extractions += 1;
        log.info('install', `unpacking ${entry.path}`);
      };

      dataStream.pipe(extract(targetDir, countExtractions))
        .on('error', (e) => {
          callback(e);
        })
        .on('close', () => {
          log.info('install', `extracted file count: ${extractions}`);
          callback();
        });
    });
  } catch (e) {
    if (e.code === 'MODULE_NOT_FOUND' && e.message.includes('aws-sdk')) {
      const err = new Error('Binary is private and requires aws-sdk for authenticated download. Please run: npm install aws-sdk');
      err.statusCode = 403;
      return callback(err);
    }
    log.error('install', 'Error setting up authenticated download:', e.message);
    callback(e);
  }
}

function place_binary(uri, targetDir, opts, callback) {
  log.log('GET', uri);

  // Try getting version info from the currently running npm.
  const envVersionInfo = process.env.npm_config_user_agent ||
        'node ' + process.version;

  const sanitized = uri.replace('+', '%2B');
  const requestOpts = {
    uri: sanitized,
    headers: {
      'User-Agent': 'node-pre-gyp (v' + npgVersion + ', ' + envVersionInfo + ')'
    },
    follow_max: 10
  };

  if (opts.cafile) {
    try {
      requestOpts.ca = fs.readFileSync(opts.cafile);
    } catch (e) {
      return callback(e);
    }
  } else if (opts.ca) {
    requestOpts.ca = opts.ca;
  }

  const proxyUrl = opts.proxy ||
                    process.env.http_proxy ||
                    process.env.HTTP_PROXY ||
                    process.env.npm_config_proxy;
  let agent;
  if (proxyUrl) {
    const { HttpsProxyAgent } = require('https-proxy-agent');
    agent = new HttpsProxyAgent(proxyUrl);
    log.log('download', `proxy agent configured using: "${proxyUrl}"`);
  }

  fetch(sanitized, { agent })
    .then((res) => {
      if (!res.ok) {
        // If we get 403 Forbidden, the binary might be private - try authenticated download
        if (res.status === 403) {
          log.info('install', 'Received 403 Forbidden - attempting authenticated download');
          // Call place_binary_authenticated and return a special marker
          // to prevent the promise chain from calling callback again
          place_binary_authenticated(opts, targetDir, callback);
          return { authenticated: true };
        }
        throw new Error(`response status ${res.status} ${res.statusText} on ${sanitized}`);
      }
      const dataStream = res.body;

      return new Promise((resolve, reject) => {
        let extractions = 0;
        const countExtractions = (entry) => {
          extractions += 1;
          log.info('install', `unpacking ${entry.path}`);
        };

        dataStream.pipe(extract(targetDir, countExtractions))
          .on('error', (e) => {
            reject(e);
          });
        dataStream.on('end', () => {
          resolve(`extracted file count: ${extractions}`);
        });
        dataStream.on('error', (e) => {
          reject(e);
        });
      });
    })
    .then((text) => {
      if (text && text.authenticated) {
        return; // Don't call callback - place_binary_authenticated will handle it
      }
      log.info(text);
      callback();
    })
    .catch((e) => {
      log.error(`install ${e.message}`);
      callback(e);
    });
}

function extract(to, onentry) {
  return tar.extract({
    cwd: to,
    strip: 1,
    onentry
  });
}

function extract_from_local(from, targetDir, callback) {
  if (!fs.existsSync(from)) {
    return callback(new Error('Cannot find file ' + from));
  }
  log.info('Found local file to extract from ' + from);

  // extract helpers
  let extractCount = 0;
  function countExtractions(entry) {
    extractCount += 1;
    log.info('install', 'unpacking ' + entry.path);
  }
  function afterExtract(err) {
    if (err) return callback(err);
    if (extractCount === 0) {
      return callback(new Error('There was a fatal problem while extracting the tarball'));
    }
    log.info('tarball', 'done parsing tarball');
    callback();
  }

  fs.createReadStream(from).pipe(extract(targetDir, countExtractions))
    .on('close', afterExtract)
    .on('error', afterExtract);
}

function do_build(gyp, argv, callback) {
  const args = ['rebuild'].concat(argv);
  gyp.todo.push({ name: 'build', args: args });
  process.nextTick(callback);
}

function print_fallback_error(err, opts, package_json) {
  const fallback_message = ' (falling back to source compile with node-gyp)';
  let full_message = '';
  if (err.statusCode !== undefined) {
    // If we got a network response it but failed to download
    // it means remote binaries are not available, so let's try to help
    // the user/developer with the info to debug why
    full_message = 'Pre-built binaries not found for ' + package_json.name + '@' + package_json.version;
    full_message += ' and ' + opts.runtime + '@' + (opts.target || process.versions.node) + ' (' + opts.node_abi + ' ABI, ' + opts.libc + ')';
    full_message += fallback_message;
    log.warn('Tried to download(' + err.statusCode + '): ' + opts.hosted_tarball);
    log.warn(full_message);
    log.error(err.message);
  } else {
    // If we do not have a statusCode that means an unexpected error
    // happened and prevented an http response, so we output the exact error
    full_message = 'Pre-built binaries not installable for ' + package_json.name + '@' + package_json.version;
    full_message += ' and ' + opts.runtime + '@' + (opts.target || process.versions.node) + ' (' + opts.node_abi + ' ABI, ' + opts.libc + ')';
    full_message += fallback_message;
    log.warn(full_message);
    log.warn('Hit error ' + err.message);
  }
}

//
// install
//
function install(gyp, argv, callback) {
  const package_json = gyp.package_json;
  const napi_build_version = napi.get_napi_build_version_from_command_args(argv);
  const source_build = gyp.opts['build-from-source'] || gyp.opts.build_from_source;
  const update_binary = gyp.opts['update-binary'] || gyp.opts.update_binary;
  const should_do_source_build = source_build === package_json.name || (source_build === true || source_build === 'true');
  if (should_do_source_build) {
    log.info('build', 'requesting source compile');
    return do_build(gyp, argv, callback);
  } else {
    const fallback_to_build = gyp.opts['fallback-to-build'] || gyp.opts.fallback_to_build;
    let should_do_fallback_build = fallback_to_build === package_json.name || (fallback_to_build === true || fallback_to_build === 'true');
    // but allow override from npm
    if (process.env.npm_config_argv) {
      const cooked = JSON.parse(process.env.npm_config_argv).cooked;
      const match = cooked.indexOf('--fallback-to-build');
      if (match > -1 && cooked.length > match && cooked[match + 1] === 'false') {
        should_do_fallback_build = false;
        log.info('install', 'Build fallback disabled via npm flag: --fallback-to-build=false');
      }
    }
    let opts;
    try {
      opts = versioning.evaluate(package_json, gyp.opts, napi_build_version);
    } catch (err) {
      return callback(err);
    }

    opts.ca = gyp.opts.ca;
    opts.cafile = gyp.opts.cafile;

    const from = opts.hosted_tarball;
    const to = opts.module_path;
    const binary_module = path.join(to, opts.module_name + '.node');
    existsAsync(binary_module, (found) => {
      if (!update_binary) {
        if (found) {
          console.log('[' + package_json.name + '] Success: "' + binary_module + '" already installed');
          console.log('Pass --update-binary to reinstall or --build-from-source to recompile');
          return callback();
        }
        log.info('check', 'checked for "' + binary_module + '" (not found)');
      }

      fs.promises.mkdir(to, { recursive: true }).then(() => {
        const fileName = from.startsWith('file://') && from.slice('file://'.length);
        if (fileName) {
          extract_from_local(fileName, to, after_place);
        } else {
          place_binary(from, to, opts, after_place);
        }
      }).catch((err) => {
        after_place(err);
      });

      function after_place(err) {
        if (err && should_do_fallback_build) {
          print_fallback_error(err, opts, package_json);
          return do_build(gyp, argv, callback);
        } else if (err) {
          return callback(err);
        } else {
          console.log('[' + package_json.name + '] Success: "' + binary_module + '" is installed via remote');
          return callback();
        }
      }
    });
  }
}

// setting an environment variable: node_pre_gyp_mock_s3 to any value
// enables intercepting outgoing http requests to s3 (using nock) and
// serving them from a mocked S3 file system (using mock-aws-s3)
if (process.env.node_pre_gyp_mock_s3) {
  require('./mock/http')();
}
