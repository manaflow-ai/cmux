var tap = require("tap");
var ResourceRequest = require("../lib/ResourceRequest");

tap.test("can be created", function(t) {
  var create = function() {
    var request = new ResourceRequest(undefined, Promise); // eslint-disable-line no-unused-vars
  };
  t.doesNotThrow(create);
  t.end();
});

tap.test("times out when created with a ttl", function(t) {
  var reject = function(err) {
    t.match(err, /ResourceRequest timed out/);
    t.end();
  };
  var resolve = function(r) {
    t.fail("should not resolve");
  };
  var request = new ResourceRequest(10, Promise); // eslint-disable-line no-unused-vars

  request.promise.then(resolve, reject);
});

tap.test("calls resolve when resolved", function(t) {
  var resource = {};
  var resolve = function(r) {
    t.equal(r, resource);
    t.end();
  };
  var reject = function(err) {
    t.error(err);
  };
  var request = new ResourceRequest(undefined, Promise);
  request.promise.then(resolve, reject);
  request.resolve(resource);
});

tap.test("removeTimeout removes the timeout", function(t) {
  var reject = function(err) {
    t.error(err);
  };
  var request = new ResourceRequest(10, Promise);
  request.promise.then(undefined, reject);
  request.removeTimeout();
  setTimeout(function() {
    t.end();
  }, 20);
});

tap.test("does nothing if resolved more than once", function(t) {
  var request = new ResourceRequest(undefined, Promise);
  t.doesNotThrow(function() {
    request.resolve({});
  });
  t.doesNotThrow(function() {
    request.resolve({});
  });
  t.end();
});
