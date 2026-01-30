var chai = require('chai'),
  assert = chai.assert.equal,
	eventsIntercept = require('../lib/events-intercept'),
	events = require('events');

describe('patched event emitters', function () {
  describe('with no intercepts', function () {
    it('returns true if an event had handlers', function () {
      var ee = new events.EventEmitter();
      eventsIntercept.patch(ee);

      ee.on('foo', function () {});

      assert(ee.emit('foo'), true, "emit('foo') is true");
    });

    it('returns false if an event had no handlers', function () {
      var ee = new events.EventEmitter();
      eventsIntercept.patch(ee);
      ee.on('foo', function () {});

      assert(ee.emit('bar'), false, "emit('bar') is false");
    });
  });

  describe('with the event intercepted', function () {
    it('returns true if an event had handlers', function () {
      var ee = new events.EventEmitter();
      eventsIntercept.patch(ee);
      
      var intercepted = false;
      var handled = false;
      
      ee.on('foo', function () { handled = true; });
      ee.intercept('foo', function (next) { intercepted = true; return next(); });

      assert(ee.emit('foo'), true, "emit('foo') returns true");
      assert(intercepted, true, "interceptor was invoked");
      assert(handled, true, "handler was invoked");
    });

    it('returns false if an event had no handlers', function () {
      var ee = new events.EventEmitter();
      eventsIntercept.patch(ee);

      var intercepted = false;
      
      ee.intercept('bar', function (next) { intercepted = true; return next(); });

      assert(ee.emit('bar'), false, "emit('bar') returns false");
      assert(intercepted, true, "interceptor was called");
    });
  });
});

describe('events-intercept event emitters', function () {
  it('returns true if an event had handlers', function () {
    var ee = new eventsIntercept.EventEmitter();
    ee.on('foo', function () {});

    assert(ee.emit('foo'), true, "emit('foo') is true");
  });

  it('returns false if an event had no handlers', function () {
    var ee = new eventsIntercept.EventEmitter();
    eventsIntercept.patch(ee);
    ee.on('foo', function () {});

    assert(ee.emit('bar'), false, "emit('bar') is false");
  });

  describe('with the event intercepted', function () {
    it('returns true if an event had handlers', function () {
      var ee = new eventsIntercept.EventEmitter();
      
      var intercepted = false;
      var handled = false;
      
      ee.on('foo', function () { handled = true; });
      ee.intercept('foo', function (next) { intercepted = true; return next(); });

      assert(ee.emit('foo'), true, "emit('foo') returns true");
      assert(intercepted, true, "interceptor was invoked");
      assert(handled, true, "handler was invoked");
    });
  });
});
