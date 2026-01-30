(function () {

  var events = require('events');
  var util = require('util');

  function intercept(type, interceptor) {
    var m;

    if (typeof interceptor !== 'function') {
      throw new TypeError('interceptor must be a function');
    }

    this.emit('newInterceptor', type, interceptor);

    if (!this._interceptors[type]) {
      this._interceptors[type] = [interceptor];
    } else {
      this._interceptors[type].push(interceptor);
    }

    // Check for listener leak
    if (!this._interceptors[type].warned) {
      if (typeof this._maxInterceptors !== 'undefined') {
        m = this._maxInterceptors;
      } else {
        m = EventEmitter.defaultMaxInterceptors;
      }

      if (m && m > 0 && this._interceptors[type].length > m) {
        this._interceptors[type].warned = true;
        console.error('(node) warning: possible events-intercept EventEmitter memory ' +
          'leak detected. %d interceptors added. ' +
          'Use emitter.setMaxInterceptors(n) to increase limit.',
          this._interceptors[type].length);
        console.trace();
      }
    }

    return this;
  }

  function emitFactory(superCall) {
    return function (type) {
      var completed,
        interceptor,
        _this = this;

      function next(err) {
        var trueArgs;
        if (err) {
          _this.emit('error', err);
        } else if (completed === interceptor.length) {
          return superCall.apply(_this, [type].concat(Array.prototype.slice.call(arguments).slice(1)));
        } else {
          trueArgs = Array.prototype.slice.call(arguments).slice(1).concat([next]);
          completed += 1;
          return interceptor[completed - 1].apply(_this, trueArgs);
        }
      }

      if (!_this._interceptors) {
        _this._interceptors = {};
      }

      interceptor = _this._interceptors[type];

      if (!interceptor) {

        //Just pass through
        return superCall.apply(_this, arguments);

      } else {

        completed = 0;
        return next.apply(_this, [null].concat(Array.prototype.slice.call(arguments).slice(1)));

      }
    };
  }

  function interceptors(type) {
    var ret;

    if (!this._interceptors || !this._interceptors[type]) {
      ret = [];
    } else {
      ret = this._interceptors[type].slice();
    }

    return ret;
  }

  function removeInterceptor(type, interceptor) {
    var list, position, length, i;

    if (typeof interceptor !== 'function') {
      throw new TypeError('interceptor must be a function');
    }

    if (!this._interceptors || !this._interceptors[type]) {
      return this;
    }

    list = this._interceptors[type];
    length = list.length;
    position = -1;

    for (i = length - 1; i >= 0; i--) {
      if (list[i] === interceptor) {
        position = i;
        break;
      }
    }

    if (position < 0) {
      return this;
    }

    if (length === 1) {
      delete this._interceptors[type];
    } else {
      list.splice(position, 1);
    }

    this.emit('removeInterceptor', type, interceptor);

    return this;
  }

  function listenersFactory(superCall) {
    return function (type) {
      var superListeners = superCall.call(this, type);
      var fakeFunctionIndex;
      var tempSuperListeners = superListeners.slice();
      if (type === 'newListener' || type === 'removeListener') {
        fakeFunctionIndex = superListeners.indexOf(fakeFunction);
        if (fakeFunctionIndex !== -1) {
          tempSuperListeners.splice(fakeFunctionIndex, 1);
        }
        return tempSuperListeners;
      }
      return superListeners;
    };
  }

  function fakeFunction() {}

  function fixListeners(emitter) {
    emitter.on('newListener', fakeFunction);
    emitter.on('removeListener', fakeFunction);
  }

  function setMaxInterceptors(n) {
    if (typeof n !== 'number' || n < 0 || isNaN(n)) {
      throw new TypeError('n must be a positive number');
    }
    this._maxInterceptors = n;
    return this;
  }

  function removeAllInterceptors(type) {
    var key, theseInterceptors, length, i;

    if (!this._interceptors || Object.getOwnPropertyNames(this._interceptors).length === 0) {
      return this;
    }

    if (arguments.length === 0) {

      for (key in this._interceptors) {
        if (this._interceptors.hasOwnProperty(key) && key !== 'removeInterceptor') {
          this.removeAllInterceptors(key);
        }
      }
      this.removeAllInterceptors('removeInterceptor');
      this._interceptors = {};

    } else if (this._interceptors[type]) {
      theseInterceptors = this._interceptors[type];
      length = theseInterceptors.length;

      // LIFO order
      for (i = length - 1; i >= 0; i--) {
        this.removeInterceptor(type, theseInterceptors[i]);
      }

      delete this._interceptors[type];
    }

    return this;
  }

  function EventEmitter() {
    events.EventEmitter.call(this);
    fixListeners(this);
  }

  util.inherits(EventEmitter, events.EventEmitter);

  EventEmitter.prototype.intercept = intercept;
  EventEmitter.prototype.emit = emitFactory(EventEmitter.super_.prototype.emit);
  EventEmitter.prototype.interceptors = interceptors;
  EventEmitter.prototype.removeInterceptor = removeInterceptor;
  EventEmitter.prototype.removeAllInterceptors = removeAllInterceptors;
  EventEmitter.prototype.setMaxInterceptors = setMaxInterceptors;
  EventEmitter.prototype.listeners = listenersFactory(EventEmitter.super_.prototype.listeners);
  EventEmitter.defaultMaxInterceptors = 10;

  function monkeyPatch(emitter) {
    var oldEmit = emitter.emit;
    var oldListeners = emitter.listeners;

    emitter.emit = emitFactory(oldEmit);
    emitter.intercept = intercept;
    emitter.interceptors = interceptors;
    emitter.removeInterceptor = removeInterceptor;
    emitter.removeAllInterceptors = removeAllInterceptors;
    emitter.setMaxInterceptors = setMaxInterceptors;
    emitter.listeners = listenersFactory(oldListeners);
    fixListeners(emitter);
  }

  module.exports = {
    EventEmitter: EventEmitter,
    patch: monkeyPatch
  };

})();
