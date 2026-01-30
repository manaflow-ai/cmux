#`events-intercept`

[![Build Status](https://travis-ci.org/brandonhorst/events-intercept.svg?branch=master)](https://travis-ci.org/brandonhorst/events-intercept)
[![Coverage Status](https://coveralls.io/repos/brandonhorst/events-intercept/badge.png?branch=master)](https://coveralls.io/r/brandonhorst/events-intercept?branch=master)

The node [EventEmitter](http://nodejs.org/api/events.html) is very powerful. However, at times it could be valuable to intercept events before they reach their handlers, to modify the data, or emit other events. That's a job for `event-intercept`.

##Installation

```sh
npm install events-intercept
```

##Standalone Usage

The module contains a constructor, `EventEmitter`, which inherits from the standard node `events.EventEmitter`.

	var EventEmitter = require('events-intercept').EventEmitter;
	var emitter = new EventEmitter();

In our application, we have an object that will emit a `data` event, and pass it a single argument.

	emitter.emit('data', 'myData')

It is very easy to listen for this event and handle it

	emitter.on('data', function(arg) {
		console.log(arg);
	}); //logs 'myData'

However, we want to intercept that event and modify the data. We can do that by setting an `interceptor` with `intercept(event, interceptor)`. It is passed all arguments that would be passed to the emitter, as well as a standard node callback. In this case, let's just add a prefix on to the data.

	emitter.intercept('data', function(arg, done) {
		return done(null, 'intercepted ' + arg);
	});

This code will be executed before the handler, and the new argument will be passed on to the handler appropriately.

	emitter.emit('data', 'some other data');
	//logs 'intercepted some other data'

If multiple interceptors are added to a single event, they will be called in the order that they are added, like [async.waterfall](https://github.com/caolan/async#waterfall).

Here's that sample code all together. Of course, `intercept` supports proper function chaining.

	var eventsIntercept = require('events-intercept');
	var emitter = new eventsIntercept.EventEmitter();

	emitter
	.on('data', function(arg) {
		console.log(arg);
	}).intercept('data', function(arg, done) {
		return done(null, 'intercepted ' + arg);
	}).emit('data', 'myData');
	//logs 'intercepted myData'

Please see `test/intercept.js` for more complete samples.

##Calling Separate Events

There may be times when you want to intercept one event and call another. Luckily, all `intercept` handlers are called with the `EventEmitter` as the `this` context, so you can `emit` events yourself.

	emitter.intercept('data', function(done) {
		this
		.emit('otherData')
		.emit('thirdData');
		return done(null);
	});
	//emits 'data', 'otherData', and 'thirdData'

Remember, `emit`ting an event that you are `intercept`ing will cause a loop, so be careful.

In fact, an `intercept`or do not need to call the callback at all, which means that the event that was `intercept`ed will never be called at all.


	emitter.intercept('data', function(done) {
		this
		.emit('otherData')
		.emit('thirdData');
	});
	//emits 'otherData' and 'thirdData' but not 'data'

##Utilities

`events-intercept` supports all of the useful utilities that the standard `EventEmitter` supports:

* `interceptors(type)` returns an array of all interceptors (functions) for the given type.
* `removeInterceptor(type, interceptor)` removes an interceptor of a given type. You must pass in the interceptor function.
* `removeAllInterceptors(type)` removes all interceptors for a given type.
* `removeAllInterceptors()` removes all interceptors. Will remove the `removeInterceptor` event last, so they will all get triggered.
* the EventEmitter will throw a warning if more than 10 interceptors are added to a single event, as this could represent a memory leak. `setMaxInterceptors(n)` allows you to change that. Set it to 0 for no limit.

All of these are demonstrated in the tests.

##Patching

Of course, many EventEmitters that you have the pleasure of using will not have the foresight to use `event-intercept`. Thankfully, Javascript is awesome, it's possible to monkey patch the interception capabilities onto an existing object. Just call

	var events = require('events');
	var eventsIntercept = require('events-intercept');

	var emitter = new events.EventEmitter();

	eventsIntercept.patch(emitter)

	emitter
	.on('data', function(arg) {
		console.log(arg);
	}).intercept('data', function(arg, done) {
		return done(null, 'intercepted ' + arg);
	}).emit('data', 'myData');
	//logs 'intercepted myData'

Now, you should be able to call `intercept` on the standard `EventEmitter`.

This is also shown in `test/intercept.js`.
