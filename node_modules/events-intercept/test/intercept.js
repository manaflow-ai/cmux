var chai = require('chai'),
	expect = chai.expect,
	sinon = require('sinon'),
	eventsIntercept = require('../lib/events-intercept'),
	events = require('events'),
	emitterFactories;

chai.use(require('sinon-chai'));
chai.config.includeStack = true;

emitterFactories = {
	"events-intercept EventEmitter": function() {return new eventsIntercept.EventEmitter()},
	"patched classic EventEmitter": function() {
		var classicEmitter = new events.EventEmitter();
		eventsIntercept.patch(classicEmitter);
		return classicEmitter;
	}
}

for (description in emitterFactories) {

	var emitterFactory = emitterFactories[description];
	
	(function(emitterFactory) {

		describe(description, function() {
			it('intercepts an event with a single interceptor', function(done) {
				var emitter = emitterFactory(),
					handler,
					interceptor;

				handler = function(arg) {
					expect(interceptor).to.have.been.called.once;
					expect(arg).to.equal('newValue');
					done();
				};

				interceptor = sinon.spy(function(arg, done) {
					expect(arg).to.equal('value');
					done(null, 'newValue');
				});


				emitter
				.intercept('test', interceptor)
				.on('test', handler)
				.emit('test', 'value');
			});

			it('intercepts an event with a multiple interceptors', function(done) {
				var emitter = emitterFactory(),
					handler,
					interceptor1,
					interceptor2,
					interceptor3;

				handler = function(arg) {
					expect(interceptor1).to.have.been.called.once;
					expect(interceptor2).to.have.been.called.once;
					expect(interceptor3).to.have.been.called.once;
					expect(arg).to.equal('finalValue');
					done();
				};
				
				interceptor1 = sinon.spy(function(arg, done) {
					expect(arg).to.equal('value');
					done(null, 'secondValue', 'anotherValue');
				});

				interceptor2 = sinon.spy(function(arg, arg2, done) {
					expect(arg).to.equal('secondValue');
					expect(arg2).to.equal('anotherValue');
					done(null, 'thirdValue');
				});

				interceptor3 = sinon.spy(function(arg, done) {
					expect(arg).to.equal('thirdValue');
					done(null, 'finalValue');
				});


				emitter
				.on('test', handler)
				.intercept('test', interceptor1)
				.intercept('test', interceptor2)
				.intercept('test', interceptor3)
				.emit('test', 'value');
			});

			it('warns once for 11+ interceptors (by default)', function(done) {
				var emitter = emitterFactory(),
					handler,
					interceptors = [],
					i;

				for (i=0; i < 12; i++) {
					interceptors[i] = sinon.spy(function(done) {
						done();
					});
				}

				handler = function(arg) {
					for (i=0; i < 12; i++) {
						expect(interceptors[i]).to.have.been.called.once;
					}
					expect(console.error).to.have.been.called.once;
					expect(console.trace).to.have.been.called.once;
					console.error.restore();
					console.trace.restore();
					done()
				}

				sinon.stub(console, "error");
				sinon.stub(console, "trace");

				emitter
				.on('test', handler);
				for (i=0; i < 12; i++) {
					emitter.intercept('test', interceptors[i]);
				}
				emitter.emit('test');
			});

			it('allows for setting the maxInterceptors', function(done) {
				var emitter = emitterFactory(),
					handler,
					interceptors = [],
					i;

				for (i=0; i < 6; i++) {
					interceptors[i] = sinon.spy(function(done) {
						done();
					});
				}

				handler = function(arg) {
					for (i=0; i < 6; i++) {
						expect(interceptors[i]).to.have.been.called.once;
					}
					expect(console.error).to.have.been.called.once;
					expect(console.trace).to.have.been.called.once;
					console.error.restore();
					console.trace.restore();
					done()
				}

				sinon.stub(console, "error");
				sinon.stub(console, "trace");

				emitter
				.setMaxInterceptors(5)
				.on('test', handler);
				for (i=0; i < 6; i++) {
					emitter.intercept('test', interceptors[i]);
				}
				emitter.emit('test');
			});

			it('throws for invalid maxInterceptors', function() {
				var emitter = emitterFactory();

				expect(function() {
					emitter.setMaxInterceptors('not a number');
				}).to.throw(Error);
			});

			it('triggers an error when an interceptor passes one', function(done) {
				var emitter = emitterFactory(),
					handler = sinon.spy(),
					interceptor,
					errorHandler;

				interceptor = sinon.spy(function(arg, done) {
					expect(arg).to.equal('value')
					done(new Error('test error'));
				});

				errorHandler = function(err) {
					expect(interceptor).to.have.been.called.once;
					expect(handler).to.not.have.been.called;
					expect(err.message).to.equal('test error');
					done();
				};


				emitter
				.on('test', handler)
				.intercept('test', interceptor)
				.on('error', errorHandler)
				.emit('test', 'value');
			});

			it('allows interceptors to trigger other events', function(done) {
				var emitter = emitterFactory(),
					handler = sinon.spy(),
					interceptor,
					errorHandler;

				interceptor = sinon.spy(function(arg, done) {
					expect(arg).to.equal('value')
					this.emit('newTest', 'newValue')
				});

				newHandler = (function(arg) {
					expect(arg).to.equal('newValue');
					expect(interceptor).to.have.been.called.once;
					expect(handler).to.not.have.been.called;
					done();
				});

				emitter
				.on('test', handler)
				.on('newTest', newHandler)
				.intercept('test', interceptor)
				.emit('test', 'value');
			});

			// it('can monkey patch standard EventEmitters', function(done) {
			// 	var emitter = new events.EventEmitter(),
			// 		handler,
			// 		interceptor;

			// 	handler = function(arg) {
			// 		expect(interceptor).to.have.been.called.once;
			// 		expect(arg).to.equal('newValue');
			// 		done();
			// 	};

			// 	interceptor = sinon.spy(function(arg, done) {
			// 		expect(arg).to.equal('value');
			// 		done(null, 'newValue');
			// 	});

			// 	eventsIntercept.patch(emitter);
				
			// 	emitter
			// 	.on('test', handler)
			// 	.intercept('test', interceptor)
			// 	.emit('test', 'value');
			// });

			it('behaves as before for events without interceptors', function(done) {
				var emitter = emitterFactory(),
					handler;

				handler = function(arg) {
					expect(arg).to.equal('value');
					done();
				};
				
				emitter
				.on('test', handler)
				.emit('test', 'value');
			});

			it('throws for interceptors that are not functions', function() {
				var emitter = emitterFactory(),
					interceptCall;

				interceptCall = function() {
					emitter.intercept('test', 'not a function');
				};

				expect(interceptCall).to.throw(Error);
			});

			it('emits newInterceptor for new interceptors', function(done) {
				var emitter = emitterFactory(),
					interceptor = function() {},
					newInterceptorCall;

				newInterceptorCall = function(event, _interceptor) {
					expect(event).to.equal('test');
					expect(_interceptor).to.equal(interceptor);
					done()
				}

				emitter
				.on('newInterceptor', newInterceptorCall)
				.intercept('test', interceptor);
			});

			it('lists all interceptors', function() {
				var emitter = emitterFactory(),
					interceptor1 = function() {},
					interceptor2 = function() {};

				expect(emitter.interceptors('test'), '0').to.deep.equal([]);

				emitter.intercept('test', interceptor1);
				expect(emitter.interceptors('test'), '1').to.deep.equal([interceptor1]);

				emitter.intercept('test', interceptor2);
				expect(emitter.interceptors('test'), '2').to.deep.equal([interceptor1, interceptor2]);
			});

			it('removes an interceptor', function() {
				var emitter = emitterFactory(),
					interceptor1 = function() {},
					interceptor2 = function() {},
					notAnInterceptor = function() {};

				emitter
				.intercept('test', interceptor1)
				.intercept('test', interceptor2);
				expect(emitter.interceptors('test'), '2').to.deep.equal([interceptor1, interceptor2]);

				emitter.removeInterceptor('test', interceptor1);
				expect(emitter.interceptors('test'), '1').to.deep.equal([interceptor2]);

				emitter.removeInterceptor('test', notAnInterceptor);
				expect(emitter.interceptors('test'), '0').to.deep.equal([interceptor2]);

				emitter.removeInterceptor('test', interceptor2);
				expect(emitter.interceptors('test'), '0').to.deep.equal([]);
			});

			it('removes all interceptors', function() {
				var emitter = emitterFactory(),
					interceptor1 = function() {},
					interceptor2 = function() {},
					removeHandler = sinon.spy()
					removeInterceptor = sinon.spy();

				emitter
				.intercept('removeInterceptor', removeInterceptor)
				.on('removeInterceptor', removeHandler)
				.intercept('test', interceptor1)
				.intercept('test', interceptor2)
				.removeAllInterceptors()
				.removeAllInterceptors();

				expect(removeHandler).to.have.been.called.twice;
				expect(removeInterceptor).to.have.been.called.once;
				expect(emitter.interceptors('test')).to.deep.equal([]);

			});

			it('removes specific interceptors', function() {
				var emitter = emitterFactory(),
					interceptor1 = function() {},
					interceptor2 = function() {},
					removeHandler = sinon.spy();

				emitter
				.on('removeInterceptor', removeHandler)
				.intercept('test', interceptor1)
				.intercept('anotherTest', interceptor2)
				.removeAllInterceptors('test')
				.removeAllInterceptors('notAnEvent');

				expect(removeHandler).to.have.been.called.once;
				expect(emitter.interceptors('anotherTest')).to.deep.equal([interceptor2]);

			});

			it('throws for removing interceptors that are not functions', function() {
				var emitter = emitterFactory(),
					interceptCall;

				interceptCall = function() {
					emitter.removeInterceptor('test', 'not a function');
				};

				expect(interceptCall).to.throw(Error);
			});

			it('emits removeInterceptor for removed interceptors', function(done) {
				var emitter = emitterFactory(),
					interceptor = function() {},
					removeInterceptorCall;

				removeInterceptorCall = function(event, _interceptor) {
					expect(event).to.equal('test');
					expect(_interceptor).to.equal(interceptor);
					done()
				}

				emitter
				.on('removeInterceptor', removeInterceptorCall)
				.intercept('test', interceptor)
				.removeInterceptor('test', interceptor);
			});

			it("doesn't do anything for removeInterceptor with no interceptor", function() {
				var emitter = emitterFactory(),
					interceptor = function() {},
					removeInterceptorCall = sinon.spy();

				emitter
				.on('removeInterceptor', removeInterceptorCall)
				.removeInterceptor('test', interceptor);

				expect(removeInterceptorCall).to.not.have.been.called;
			});

			it('calls an interceptor even if there is no handler', function(done) {
				var emitter = emitterFactory(),
					interceptor;

				interceptor = function(arg, interceptorDone) {
					expect(arg).to.equal('value');
					interceptorDone();
					done();
				}

				emitter
				.intercept('test', interceptor)
				.emit('test', 'value')
			});

			it('emits newListener and removeListener even if there are no handlers', function() {
				var emitter = emitterFactory(),
					newListenerInterceptor,
					removeListenerInterceptor,
					handler = sinon.spy();

				newListenerInterceptor = sinon.spy(function(event, interceptor, done) {
					expect(event).to.equal('test');
					expect(interceptor).to.equal(handler);
					done()
				});

				removeListenerInterceptor = sinon.spy(function(event, interceptor, done) {
					expect(event).to.equal('test');
					expect(interceptor).to.equal(handler);
					done()
				});

				emitter
				.intercept('newListener', newListenerInterceptor)
				.intercept('removeListener', removeListenerInterceptor)
				.on('test', handler)
				.removeListener('test', handler);

				expect(emitter.listeners('newListener')).to.be.empty;
				expect(emitter.listeners('removeListener')).to.be.empty;
				expect(handler).to.not.have.been.called;
				expect(newListenerInterceptor).to.have.been.called.once;
				expect(removeListenerInterceptor).to.have.been.called.once;
		})

			it('emits newListener and removeListener if there are handlers', function(done) {
				var emitter = emitterFactory(),
					newListenerInterceptor,
					removeListenerInterceptor,
					newListenerHandler = sinon.spy(),
					removeListenerHandler = sinon.spy(),
					handler = sinon.spy();

				newListenerInterceptor = function(event, interceptor, done) {
					expect(event).to.equal('test');
					expect(interceptor).to.equal(handler);
					done()
				}

				removeListenerInterceptor = function(event, interceptor, done) {
					expect(event).to.equal('test');
					expect(interceptor).to.equal(handler);
					done()
				}

				emitter
				.on('removeListener', removeListenerHandler)
				.on('newListener', newListenerHandler)
				.intercept('newListener', newListenerInterceptor)
				.intercept('removeListener', removeListenerInterceptor)
				.on('test', handler)
				.removeListener('test', handler);

				expect(handler).to.not.have.been.called;
				expect(emitter.listeners('newListener')).to.deep.equal([newListenerHandler]);
				expect(emitter.listeners('removeListener')).to.deep.equal([removeListenerHandler]);
				expect(emitter.listeners('test')).to.deep.equal([]);
				expect(newListenerHandler).to.have.been.called.once;
				expect(removeListenerHandler).to.have.been.called.once;

				done()


			})

		});
	})(emitterFactory);
}