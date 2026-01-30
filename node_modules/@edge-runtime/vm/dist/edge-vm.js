"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.EdgeVM = void 0;
const load_1 = require("@edge-runtime/primitives/load");
const vm_1 = require("vm");
const vm_2 = require("./vm");
/**
 * Store handlers that the user defined from code so that we can invoke them
 * from the Node.js realm.
 */
let unhandledRejectionHandlers;
let uncaughtExceptionHandlers;
class EdgeVM extends vm_2.VM {
    constructor(options) {
        super({
            ...options,
            extend: (context) => {
                return (options === null || options === void 0 ? void 0 : options.extend)
                    ? options.extend(addPrimitives(context))
                    : addPrimitives(context);
            },
        });
        Object.defineProperty(this.context, '__onUnhandledRejectionHandlers', {
            set: registerUnhandledRejectionHandlers,
            configurable: false,
            enumerable: false,
        });
        Object.defineProperty(this, '__rejectionHandlers', {
            get: () => unhandledRejectionHandlers,
            configurable: false,
            enumerable: false,
        });
        Object.defineProperty(this.context, '__onErrorHandlers', {
            set: registerUncaughtExceptionHandlers,
            configurable: false,
            enumerable: false,
        });
        Object.defineProperty(this, '__errorHandlers', {
            get: () => uncaughtExceptionHandlers,
            configurable: false,
            enumerable: false,
        });
        this.evaluate(getDefineEventListenersCode());
        this.dispatchFetch = this.evaluate(getDispatchFetchCode());
        for (const name of transferableConstructors) {
            patchInstanceOf(name, this.context);
        }
        if (options === null || options === void 0 ? void 0 : options.initialCode) {
            this.evaluate(options.initialCode);
        }
    }
}
exports.EdgeVM = EdgeVM;
/**
 * Transferable constructors are the constructors that we expect to be
 * "shared" between the realms.
 *
 * When a user creates an instance of one of these constructors, we want
 * to make sure that the `instanceof` operator works as expected:
 *
 * * If the instance was created in the Node.js realm, then `instanceof`
 *   should return true when used in the EdgeVM realm.
 * * If the instance was created in the EdgeVM realm, then `instanceof`
 *   should return true when used in the EdgeVM realm.
 *
 * For example, the return value from `new TextEncoder().encode("hello")` is a
 * Uint8Array. Since `TextEncoder` implementation is coming from the Node.js realm,
 * therefore the following will be false, which doesn't fit the expectation of the user:
 * ```ts
 * new TextEncoder().encode("hello") instanceof Uint8Array
 * ```
 *
 * This is because the `Uint8Array` in the `vm` context is not the same
 * as the one in the Node.js realm.
 *
 * Patching the constructors in the `vm` is done by the {@link patchInstanceOf}
 * function, and this is the list of constructors that need to be patched.
 *
 * These constructors are also being injected as "globals" when the VM is
 * constructed, by passing them as arguments to the {@link loadPrimitives}
 * function.
 */
const transferableConstructors = [
    'Object',
    'Array',
    'RegExp',
    'Uint8Array',
    'ArrayBuffer',
    'Error',
    'SyntaxError',
    'TypeError',
];
function patchInstanceOf(item, ctx) {
    // @ts-ignore
    ctx[Symbol.for(`node:${item}`)] = eval(item);
    return (0, vm_1.runInContext)(`
      globalThis.${item} = new Proxy(${item}, {
        get(target, prop, receiver) {
          if (prop === Symbol.hasInstance && receiver === globalThis.${item}) {
            const nodeTarget = globalThis[Symbol.for('node:${item}')];
            if (nodeTarget) {
              return function(instance) {
                return instance instanceof target || instance instanceof nodeTarget;
              };
            } else {
              throw new Error('node target must exist')
            }
          }

          return Reflect.get(target, prop, receiver);
        }
      })
    `, ctx);
}
/**
 * Register system-level handlers to make sure that we report to the user
 * whenever there is an unhandled rejection or exception before the process crashes.
 * Do it on demand so we don't swallow rejections/errors for no reason.
 */
function registerUnhandledRejectionHandlers(handlers) {
    if (!unhandledRejectionHandlers) {
        process.on('unhandledRejection', function invokeRejectionHandlers(reason, promise) {
            unhandledRejectionHandlers.forEach((handler) => handler({ reason, promise }));
        });
    }
    unhandledRejectionHandlers = handlers;
}
function registerUncaughtExceptionHandlers(handlers) {
    if (!uncaughtExceptionHandlers) {
        process.on('uncaughtException', function invokeErrorHandlers(error) {
            uncaughtExceptionHandlers.forEach((handler) => handler(error));
        });
    }
    uncaughtExceptionHandlers = handlers;
}
/**
 * Generates polyfills for addEventListener and removeEventListener. It keeps
 * all listeners in hidden property __listeners. It will also call a hook
 * `__onUnhandledRejectionHandler` and `__onErrorHandler` when unhandled rejection
 * events are added or removed and prevent from having more than one FetchEvent
 * handler.
 */
function getDefineEventListenersCode() {
    return `
    Object.defineProperty(self, '__listeners', {
      configurable: false,
      enumerable: false,
      value: {},
      writable: true,
    })

    function __conditionallyUpdatesHandlerList(eventType) {
      if (eventType === 'unhandledrejection') {
        self.__onUnhandledRejectionHandlers = self.__listeners[eventType];
      } else if (eventType === 'error') {
        self.__onErrorHandlers = self.__listeners[eventType];
      }
    }

    function addEventListener(type, handler) {
      const eventType = type.toLowerCase();
      if (eventType === 'fetch' && self.__listeners.fetch) {
        throw new TypeError('You can register just one "fetch" event listener');
      }

      self.__listeners[eventType] = self.__listeners[eventType] || [];
      self.__listeners[eventType].push(handler);
      __conditionallyUpdatesHandlerList(eventType);
    }

    function removeEventListener(type, handler) {
      const eventType = type.toLowerCase();
      if (self.__listeners[eventType]) {
        self.__listeners[eventType] = self.__listeners[eventType].filter(item => {
          return item !== handler;
        });

        if (self.__listeners[eventType].length === 0) {
          delete self.__listeners[eventType];
        }
      }
      __conditionallyUpdatesHandlerList(eventType);
    }
  `;
}
/**
 * Generates the code to dispatch a FetchEvent invoking the handlers defined
 * for such events. In case there is no event handler defined it will throw
 * an error.
 */
function getDispatchFetchCode() {
    return `(async function dispatchFetch(input, init) {
    const request = new Request(input, init);
    const event = new FetchEvent(request);
    if (!self.__listeners.fetch) {
      throw new Error("No fetch event listeners found");
    }

    const getResponse = ({ response, error }) => {
     if (error || !response || !(response instanceof Response)) {
        console.error(error ? error.toString() : 'The event listener did not respond')
        response = new Response(null, {
          statusText: 'Internal Server Error',
          status: 500
        })
      }

      response.waitUntil = () => Promise.all(event.awaiting);

      if (response.status < 300 || response.status >= 400 ) {
        response.headers.delete('content-encoding');
        response.headers.delete('transform-encoding');
        response.headers.delete('content-length');
      }

      return response;
    }

    try {
      await self.__listeners.fetch[0].call(event, event)
    } catch (error) {
      return getResponse({ error })
    }

    return Promise.resolve(event.response)
      .then(response => getResponse({ response }))
      .catch(error => getResponse({ error }))
  })`;
}
function addPrimitives(context) {
    defineProperty(context, 'self', { enumerable: true, value: context });
    defineProperty(context, 'globalThis', { value: context });
    defineProperty(context, 'Symbol', { value: Symbol });
    defineProperty(context, 'clearInterval', { value: clearInterval });
    defineProperty(context, 'clearTimeout', { value: clearTimeout });
    defineProperty(context, 'queueMicrotask', { value: queueMicrotask });
    defineProperty(context, 'EdgeRuntime', { value: 'edge-runtime' });
    const transferables = getTransferablePrimitivesFromContext(context);
    defineProperties(context, {
        exports: (0, load_1.load)({
            ...transferables,
            WeakRef: (0, vm_1.runInContext)(`WeakRef`, context),
        }),
        enumerable: ['crypto'],
        nonenumerable: [
            // Crypto
            'Crypto',
            'CryptoKey',
            'SubtleCrypto',
            // Fetch APIs
            'fetch',
            'File',
            'FormData',
            'Headers',
            'Request',
            'Response',
            'WebSocket',
            // Structured Clone
            'structuredClone',
            // Blob
            'Blob',
            // URL
            'URL',
            'URLSearchParams',
            'URLPattern',
            // AbortController
            'AbortController',
            'AbortSignal',
            'DOMException',
            // Streams
            'ReadableStream',
            'ReadableStreamBYOBReader',
            'ReadableStreamDefaultReader',
            'TextDecoderStream',
            'TextEncoderStream',
            'TransformStream',
            'WritableStream',
            'WritableStreamDefaultWriter',
            // Encoding
            'atob',
            'btoa',
            'TextEncoder',
            'TextDecoder',
            // Events
            'Event',
            'EventTarget',
            'FetchEvent',
            'PromiseRejectionEvent',
            // Console
            'console',
            // Performance
            'performance',
            // Timers
            'setTimeout',
            'setInterval',
        ],
    });
    return context;
}
function defineProperty(obj, prop, attrs) {
    var _a, _b, _c;
    Object.defineProperty(obj, prop, {
        configurable: (_a = attrs.configurable) !== null && _a !== void 0 ? _a : false,
        enumerable: (_b = attrs.enumerable) !== null && _b !== void 0 ? _b : false,
        value: attrs.value,
        writable: (_c = attrs.writable) !== null && _c !== void 0 ? _c : true,
    });
}
function defineProperties(context, options) {
    var _a, _b;
    for (const property of (_a = options.enumerable) !== null && _a !== void 0 ? _a : []) {
        if (!options.exports[property]) {
            throw new Error(`Attempt to export a nullable value for "${property}"`);
        }
        defineProperty(context, property, {
            enumerable: true,
            value: options.exports[property],
        });
    }
    for (const property of (_b = options.nonenumerable) !== null && _b !== void 0 ? _b : []) {
        if (!options.exports[property]) {
            throw new Error(`Attempt to export a nullable value for "${property}"`);
        }
        defineProperty(context, property, {
            value: options.exports[property],
        });
    }
}
/**
 * Create an object that contains all the {@link transferableConstructors}
 * implemented in the provided context.
 */
function getTransferablePrimitivesFromContext(context) {
    const keys = transferableConstructors.join(',');
    const stringifedObject = `({${keys}})`;
    return (0, vm_1.runInContext)(stringifedObject, context);
}
//# sourceMappingURL=edge-vm.js.map