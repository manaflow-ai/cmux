"use strict";

const Pool = require("../lib/Pool");

/**
 * Generic class for handling creation of resources
 * for testing
 */
class ResourceFactory {
  constructor() {
    this.created = 0;
    this.destroyed = 0;
    this.bin = [];
  }

  create() {
    return Promise.resolve({ id: this.created++ });
  }

  validate() {
    return Promise.resolve(true);
  }

  destroy(resource) {
    this.destroyed++;
    this.bin.push(resource);
    return Promise.resolve();
  }
}
exports.ResourceFactory = ResourceFactory;

/**
 * drains and terminates the pool
 *
 * @param  {Pool} pool [description]
 * @return {Promise}      [description]
 */
exports.stopPool = function(pool) {
  return pool.drain().then(function() {
    return pool.clear();
  });
};
