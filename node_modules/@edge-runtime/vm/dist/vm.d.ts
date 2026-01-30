/// <reference types="node" />
import type { CreateContextOptions } from 'vm';
export interface VMOptions<T> {
    /**
     * Provide code generation options to the Node.js VM.
     * If you don't provide any option, code generation will be disabled.
     */
    codeGeneration?: CreateContextOptions['codeGeneration'];
    /**
     * Allows to extend the VMContext. Note that it must return a contextified
     * object so ideally it should return the same reference it receives.
     */
    extend?: (context: VMContext) => VMContext & T;
}
/**
 * A raw VM with a context that can be extended on instantiation. Implements
 * a realm-like interface where one can evaluate code or require CommonJS
 * modules in multiple ways.
 */
export declare class VM<T extends Record<string | number, any>> {
    readonly context: VMContext & T;
    constructor(options?: VMOptions<T>);
    /**
     * Allows to run arbitrary code within the VM.
     */
    evaluate<T = any>(code: string): T;
}
export interface VMContext {
    Array: typeof Array;
    ArrayBuffer: typeof ArrayBuffer;
    Atomics: typeof Atomics;
    BigInt: typeof BigInt;
    BigInt64Array: typeof BigInt64Array;
    BigUint64Array: typeof BigUint64Array;
    Boolean: typeof Boolean;
    DataView: typeof DataView;
    Date: typeof Date;
    decodeURI: typeof decodeURI;
    decodeURIComponent: typeof decodeURIComponent;
    encodeURI: typeof encodeURI;
    encodeURIComponent: typeof encodeURIComponent;
    Error: typeof Error;
    EvalError: typeof EvalError;
    Float32Array: typeof Float32Array;
    Float64Array: typeof Float64Array;
    Function: typeof Function;
    Infinity: typeof Infinity;
    Int8Array: typeof Int8Array;
    Int16Array: typeof Int16Array;
    Int32Array: typeof Int32Array;
    Intl: typeof Intl;
    isFinite: typeof isFinite;
    isNaN: typeof isNaN;
    JSON: typeof JSON;
    Map: typeof Map;
    Math: typeof Math;
    Number: typeof Number;
    Object: typeof Object;
    parseFloat: typeof parseFloat;
    parseInt: typeof parseInt;
    Promise: typeof Promise;
    Proxy: typeof Proxy;
    RangeError: typeof RangeError;
    ReferenceError: typeof ReferenceError;
    Reflect: typeof Reflect;
    RegExp: typeof RegExp;
    Set: typeof Set;
    SharedArrayBuffer: typeof SharedArrayBuffer;
    String: typeof String;
    Symbol: typeof Symbol;
    SyntaxError: typeof SyntaxError;
    TypeError: typeof TypeError;
    Uint8Array: typeof Uint8Array;
    Uint8ClampedArray: typeof Uint8ClampedArray;
    Uint16Array: typeof Uint16Array;
    Uint32Array: typeof Uint32Array;
    URIError: typeof URIError;
    WeakMap: typeof WeakMap;
    WeakSet: typeof WeakSet;
    WebAssembly: typeof WebAssembly;
    [key: string | number]: any;
}
