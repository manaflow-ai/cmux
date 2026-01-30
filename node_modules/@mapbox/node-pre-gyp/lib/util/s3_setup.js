'use strict';

module.exports = exports;

const url = require('url');

module.exports.detect = function(opts) {
  const config = {};

  const to = opts.hosted_path;
  const uri = url.parse(to);

  if (opts.bucket && opts.region) {
    // use user defined settings for host, region, bucket
    config.endpoint = opts.host;
    config.bucket = opts.bucket;
    config.region = opts.region;
    config.s3ForcePathStyle = opts.s3ForcePathStyle;

    // if using s3ForcePathStyle the bucket is part of the http object path
    // but not the S3 key prefix path.
    // remove it
    const bucketPath = config.s3ForcePathStyle ? `/${config.bucket}/` : '/';
    config.prefix = (!uri.pathname || uri.pathname === bucketPath) ? '' : uri.pathname.replace(bucketPath, '');
  } else {
    // auto detect region and bucket from url
    // only virtual-hosted–style access can be auto detected
    // the uri will have the following format:
    // https://bucket-name.s3.Region.amazonaws.com/key-name (dash Region)
    // or in some legacy region of this format:
    // https://bucket-name.s3-Region.amazonaws.com/key-name (dot Region)
    const parts = uri.hostname.split('.s3');

    // there is nothing before the .s3
    // not a valid s3 virtual host bucket url
    if (parts.length === 1) {
      throw new Error('Could not parse s3 bucket name from virtual host url.');
    }

    // everything before .s3 is the bucket
    config.bucket = parts[0];

    // from everything that comes after the s3
    // first char is connecting dot or dash
    // everything up to the domain should be the region name
    const region = parts[1].slice(1).split('.')[0];
    // if user provided url does not include region, default to us-east-1.
    if (region === 'amazonaws') {
      config.region = 'us-east-1';
    } else {
      config.region = region;
    }

    config.prefix = (!uri.pathname || uri.pathname === '/') ? '' : uri.pathname.replace('/', '');
  }

  return config;
};

module.exports.get_s3 = function(config) {
  // setting an environment variable: node_pre_gyp_mock_s3 to any value
  // enables intercepting outgoing http requests to s3 (using nock) and
  // serving them from a mocked S3 file system (using mock-aws-s3)
  if (process.env.node_pre_gyp_mock_s3) {
    return require('../mock/s3')();
  }

  // if not mocking then setup real s3.
  const AWS = require('aws-sdk');

  AWS.config.update(config);
  const s3 = new AWS.S3();

  // need to change if additional options need to be specified.
  return {
    listObjects(params, callback) {
      return s3.listObjects(params, callback);
    },
    headObject(params, callback) {
      return s3.headObject(params, callback);
    },
    deleteObject(params, callback) {
      return s3.deleteObject(params, callback);
    },
    putObject(params, callback) {
      return s3.putObject(params, callback);
    },
    getObject(params, callback) {
      return s3.getObject(params, callback);
    }
  };
};
