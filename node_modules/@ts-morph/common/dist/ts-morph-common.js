'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

var ts = require('./typescript');
var minimatch = require('minimatch');
var fastGlob = require('fast-glob');
var fs$1 = require('fs');
var mkdirp = require('mkdirp');
var os = require('os');
var path$2 = require('path');

function _interopDefaultLegacy (e) { return e && typeof e === 'object' && 'default' in e ? e : { 'default': e }; }

function _interopNamespace(e) {
    if (e && e.__esModule) return e;
    var n = Object.create(null);
    if (e) {
        Object.keys(e).forEach(function (k) {
            if (k !== 'default') {
                var d = Object.getOwnPropertyDescriptor(e, k);
                Object.defineProperty(n, k, d.get ? d : {
                    enumerable: true,
                    get: function () { return e[k]; }
                });
            }
        });
    }
    n["default"] = e;
    return Object.freeze(n);
}

var ts__namespace = /*#__PURE__*/_interopNamespace(ts);
var minimatch__default = /*#__PURE__*/_interopDefaultLegacy(minimatch);
var fastGlob__default = /*#__PURE__*/_interopDefaultLegacy(fastGlob);
var fs__namespace = /*#__PURE__*/_interopNamespace(fs$1);
var mkdirp__default = /*#__PURE__*/_interopDefaultLegacy(mkdirp);
var os__namespace = /*#__PURE__*/_interopNamespace(os);
var path__namespace = /*#__PURE__*/_interopNamespace(path$2);

class KeyValueCache {
    constructor() {
        this.cacheItems = new Map();
    }
    getSize() {
        return this.cacheItems.size;
    }
    getValues() {
        return this.cacheItems.values();
    }
    getValuesAsArray() {
        return Array.from(this.getValues());
    }
    getKeys() {
        return this.cacheItems.keys();
    }
    getEntries() {
        return this.cacheItems.entries();
    }
    getOrCreate(key, createFunc) {
        let item = this.get(key);
        if (item == null) {
            item = createFunc();
            this.set(key, item);
        }
        return item;
    }
    has(key) {
        return this.cacheItems.has(key);
    }
    get(key) {
        return this.cacheItems.get(key);
    }
    set(key, value) {
        this.cacheItems.set(key, value);
    }
    replaceKey(key, newKey) {
        if (!this.cacheItems.has(key))
            throw new Error("Key not found.");
        const value = this.cacheItems.get(key);
        this.cacheItems.delete(key);
        this.cacheItems.set(newKey, value);
    }
    removeByKey(key) {
        this.cacheItems.delete(key);
    }
    clear() {
        this.cacheItems.clear();
    }
}

class ComparerToStoredComparer {
    constructor(comparer, storedValue) {
        this.comparer = comparer;
        this.storedValue = storedValue;
    }
    compareTo(value) {
        return this.comparer.compareTo(this.storedValue, value);
    }
}

class LocaleStringComparer {
    compareTo(a, b) {
        const comparisonResult = a.localeCompare(b, "en-us-u-kf-upper");
        if (comparisonResult < 0)
            return -1;
        else if (comparisonResult === 0)
            return 0;
        return 1;
    }
}
LocaleStringComparer.instance = new LocaleStringComparer();

class PropertyComparer {
    constructor(getProperty, comparer) {
        this.getProperty = getProperty;
        this.comparer = comparer;
    }
    compareTo(a, b) {
        return this.comparer.compareTo(this.getProperty(a), this.getProperty(b));
    }
}

class PropertyStoredComparer {
    constructor(getProperty, comparer) {
        this.getProperty = getProperty;
        this.comparer = comparer;
    }
    compareTo(value) {
        return this.comparer.compareTo(this.getProperty(value));
    }
}

class ArrayUtils {
    constructor() {
    }
    static isReadonlyArray(a) {
        return a instanceof Array;
    }
    static isNullOrEmpty(a) {
        return !(a instanceof Array) || a.length === 0;
    }
    static getUniqueItems(a) {
        return a.filter((item, index) => a.indexOf(item) === index);
    }
    static removeFirst(a, item) {
        const index = a.indexOf(item);
        if (index === -1)
            return false;
        a.splice(index, 1);
        return true;
    }
    static removeAll(a, isMatch) {
        const removedItems = [];
        for (let i = a.length - 1; i >= 0; i--) {
            if (isMatch(a[i])) {
                removedItems.push(a[i]);
                a.splice(i, 1);
            }
        }
        return removedItems;
    }
    static flatten(items) {
        return items.reduce((a, b) => a.concat(b), []);
    }
    static from(items) {
        const a = [];
        for (const item of items)
            a.push(item);
        return a;
    }
    static *toIterator(items) {
        for (const item of items)
            yield item;
    }
    static sortByProperty(items, getProp) {
        items.sort((a, b) => getProp(a) <= getProp(b) ? -1 : 1);
        return items;
    }
    static groupBy(items, getGroup) {
        const result = [];
        const groups = {};
        for (const item of items) {
            const group = getGroup(item).toString();
            if (groups[group] == null) {
                groups[group] = [];
                result.push(groups[group]);
            }
            groups[group].push(item);
        }
        return result;
    }
    static binaryInsertWithOverwrite(items, newItem, comparer) {
        let top = items.length - 1;
        let bottom = 0;
        while (bottom <= top) {
            const mid = Math.floor((top + bottom) / 2);
            if (comparer.compareTo(newItem, items[mid]) < 0)
                top = mid - 1;
            else
                bottom = mid + 1;
        }
        if (items[top] != null && comparer.compareTo(newItem, items[top]) === 0)
            items[top] = newItem;
        else
            items.splice(top + 1, 0, newItem);
    }
    static binarySearch(items, storedComparer) {
        let top = items.length - 1;
        let bottom = 0;
        while (bottom <= top) {
            const mid = Math.floor((top + bottom) / 2);
            const comparisonResult = storedComparer.compareTo(items[mid]);
            if (comparisonResult === 0)
                return mid;
            else if (comparisonResult < 0)
                top = mid - 1;
            else
                bottom = mid + 1;
        }
        return -1;
    }
    static containsSubArray(items, subArray) {
        let findIndex = 0;
        for (const item of items) {
            if (subArray[findIndex] === item) {
                findIndex++;
                if (findIndex === subArray.length)
                    return true;
            }
            else {
                findIndex = 0;
            }
        }
        return false;
    }
}

function deepClone(objToClone) {
    return clone(objToClone);
    function clone(obj) {
        const newObj = Object.create(obj.constructor.prototype);
        for (const propName of Object.keys(obj))
            newObj[propName] = cloneItem(obj[propName]);
        return newObj;
    }
    function cloneArray(array) {
        return array.map(cloneItem);
    }
    function cloneItem(item) {
        if (item instanceof Array)
            return cloneArray(item);
        else if (typeof item === "object")
            return item === null ? item : clone(item);
        return item;
    }
}

class EventContainer {
    constructor() {
        this.subscriptions = [];
    }
    subscribe(subscription) {
        const index = this.getIndex(subscription);
        if (index === -1)
            this.subscriptions.push(subscription);
    }
    unsubscribe(subscription) {
        const index = this.getIndex(subscription);
        if (index >= 0)
            this.subscriptions.splice(index, 1);
    }
    fire(arg) {
        for (const subscription of this.subscriptions)
            subscription(arg);
    }
    getIndex(subscription) {
        return this.subscriptions.indexOf(subscription);
    }
}

class IterableUtils {
    static find(items, condition) {
        for (const item of items) {
            if (condition(item))
                return item;
        }
        return undefined;
    }
}

class ObjectUtils {
    constructor() {
    }
    static clone(obj) {
        if (obj == null)
            return undefined;
        if (obj instanceof Array)
            return cloneArray(obj);
        return ObjectUtils.assign({}, obj);
        function cloneArray(a) {
            return a.map(item => ObjectUtils.clone(item));
        }
    }
    static assign(a, b, c) {
        if (Object.assign != null) {
            if (c == null)
                return Object.assign(a, b);
            else
                return Object.assign(a, b, c);
        }
        if (c == null)
            return this.es5Assign(a, b);
        else
            return this.es5Assign(a, b, c);
    }
    static es5Assign(a, b, c) {
        const to = Object(a);
        for (let index = 1; index < arguments.length; index++) {
            const nextSource = arguments[index];
            if (nextSource == null)
                continue;
            for (const nextKey in nextSource) {
                if (Object.prototype.hasOwnProperty.call(nextSource, nextKey))
                    to[nextKey] = nextSource[nextKey];
            }
        }
        return to;
    }
}

function matchFiles(path, extensions, excludes, includes, useCaseSensitiveFileNames, currentDirectory, depth, getEntries, realpath, directoryExists) {
    return ts__namespace.matchFiles.apply(this, arguments);
}
function getFileMatcherPatterns(path, excludes, includes, useCaseSensitiveFileNames, currentDirectory) {
    return ts__namespace.getFileMatcherPatterns.apply(this, arguments);
}
function getEmitModuleResolutionKind(compilerOptions) {
    return ts__namespace.getEmitModuleResolutionKind.apply(this, arguments);
}

function getSyntaxKindName(kind) {
    return getKindCache()[kind];
}
let kindCache = undefined;
function getKindCache() {
    if (kindCache != null)
        return kindCache;
    kindCache = {};
    for (const name of Object.keys(ts__namespace.SyntaxKind).filter(k => isNaN(parseInt(k, 10)))) {
        const value = ts__namespace.SyntaxKind[name];
        if (kindCache[value] == null)
            kindCache[value] = name;
    }
    return kindCache;
}

exports.errors = void 0;
(function (errors) {
    class BaseError extends Error {
        constructor(message) {
            super(message);
            this.message = message;
            this.message = message;
        }
    }
    errors.BaseError = BaseError;
    class ArgumentError extends BaseError {
        constructor(argName, message) {
            super(`Argument Error (${argName}): ${message}`);
        }
    }
    errors.ArgumentError = ArgumentError;
    class ArgumentNullOrWhitespaceError extends ArgumentError {
        constructor(argName) {
            super(argName, "Cannot be null or whitespace.");
        }
    }
    errors.ArgumentNullOrWhitespaceError = ArgumentNullOrWhitespaceError;
    class ArgumentOutOfRangeError extends ArgumentError {
        constructor(argName, value, range) {
            super(argName, `Range is ${range[0]} to ${range[1]}, but ${value} was provided.`);
        }
    }
    errors.ArgumentOutOfRangeError = ArgumentOutOfRangeError;
    class ArgumentTypeError extends ArgumentError {
        constructor(argName, expectedType, actualType) {
            super(argName, `Expected type '${expectedType}', but was '${actualType}'.`);
        }
    }
    errors.ArgumentTypeError = ArgumentTypeError;
    class PathNotFoundError extends BaseError {
        constructor(path, prefix = "Path") {
            super(`${prefix} not found: ${path}`);
            this.path = path;
            this.code = "ENOENT";
        }
    }
    errors.PathNotFoundError = PathNotFoundError;
    class DirectoryNotFoundError extends PathNotFoundError {
        constructor(dirPath) {
            super(dirPath, "Directory");
        }
    }
    errors.DirectoryNotFoundError = DirectoryNotFoundError;
    class FileNotFoundError extends PathNotFoundError {
        constructor(filePath) {
            super(filePath, "File");
        }
    }
    errors.FileNotFoundError = FileNotFoundError;
    class InvalidOperationError extends BaseError {
        constructor(message) {
            super(message);
        }
    }
    errors.InvalidOperationError = InvalidOperationError;
    class NotImplementedError extends BaseError {
        constructor(message = "Not implemented.") {
            super(message);
        }
    }
    errors.NotImplementedError = NotImplementedError;
    class NotSupportedError extends BaseError {
        constructor(message) {
            super(message);
        }
    }
    errors.NotSupportedError = NotSupportedError;
    function throwIfNotType(value, expectedType, argName) {
        if (typeof value !== expectedType)
            throw new ArgumentTypeError(argName, expectedType, typeof value);
    }
    errors.throwIfNotType = throwIfNotType;
    function throwIfNotString(value, argName) {
        if (typeof value !== "string")
            throw new ArgumentTypeError(argName, "string", typeof value);
    }
    errors.throwIfNotString = throwIfNotString;
    function throwIfWhitespaceOrNotString(value, argName) {
        throwIfNotString(value, argName);
        if (value.trim().length === 0)
            throw new ArgumentNullOrWhitespaceError(argName);
    }
    errors.throwIfWhitespaceOrNotString = throwIfWhitespaceOrNotString;
    function throwIfOutOfRange(value, range, argName) {
        if (value < range[0] || value > range[1])
            throw new ArgumentOutOfRangeError(argName, value, range);
    }
    errors.throwIfOutOfRange = throwIfOutOfRange;
    function throwIfRangeOutOfRange(actualRange, range, argName) {
        if (actualRange[0] > actualRange[1])
            throw new ArgumentError(argName, `The start of a range must not be greater than the end: [${actualRange[0]}, ${actualRange[1]}]`);
        throwIfOutOfRange(actualRange[0], range, argName);
        throwIfOutOfRange(actualRange[1], range, argName);
    }
    errors.throwIfRangeOutOfRange = throwIfRangeOutOfRange;
    function throwNotImplementedForSyntaxKindError(kind) {
        throw new NotImplementedError(`Not implemented feature for syntax kind '${getSyntaxKindName(kind)}'.`);
    }
    errors.throwNotImplementedForSyntaxKindError = throwNotImplementedForSyntaxKindError;
    function throwIfNegative(value, argName) {
        if (value < 0)
            throw new ArgumentError(argName, "Expected a non-negative value.");
    }
    errors.throwIfNegative = throwIfNegative;
    function throwIfNullOrUndefined(value, errorMessage) {
        if (value == null)
            throw new InvalidOperationError(typeof errorMessage === "string" ? errorMessage : errorMessage());
        return value;
    }
    errors.throwIfNullOrUndefined = throwIfNullOrUndefined;
    function throwNotImplementedForNeverValueError(value) {
        const node = value;
        if (node != null && typeof node.kind === "number")
            return throwNotImplementedForSyntaxKindError(node.kind);
        throw new NotImplementedError(`Not implemented value: ${JSON.stringify(value)}`);
    }
    errors.throwNotImplementedForNeverValueError = throwNotImplementedForNeverValueError;
    function throwIfNotEqual(actual, expected, description) {
        if (actual !== expected)
            throw new InvalidOperationError(`Expected ${actual} to equal ${expected}. ${description}`);
    }
    errors.throwIfNotEqual = throwIfNotEqual;
    function throwIfTrue(value, errorMessage) {
        if (value === true)
            throw new InvalidOperationError(errorMessage);
    }
    errors.throwIfTrue = throwIfTrue;
})(exports.errors || (exports.errors = {}));

const CharCodes = {
    ASTERISK: "*".charCodeAt(0),
    NEWLINE: "\n".charCodeAt(0),
    CARRIAGE_RETURN: "\r".charCodeAt(0),
    SPACE: " ".charCodeAt(0),
    TAB: "\t".charCodeAt(0),
    CLOSE_BRACE: "}".charCodeAt(0),
};

const regExWhitespaceSet = new Set([" ", "\f", "\n", "\r", "\t", "\v", "\u00A0", "\u2028", "\u2029"].map(c => c.charCodeAt(0)));
class StringUtils {
    constructor() {
    }
    static isWhitespaceCharCode(charCode) {
        return regExWhitespaceSet.has(charCode);
    }
    static isSpaces(text) {
        if (text == null || text.length === 0)
            return false;
        for (let i = 0; i < text.length; i++) {
            if (text.charCodeAt(i) !== CharCodes.SPACE)
                return false;
        }
        return true;
    }
    static hasBom(text) {
        return text.charCodeAt(0) === 0xFEFF;
    }
    static stripBom(text) {
        if (StringUtils.hasBom(text))
            return text.slice(1);
        return text;
    }
    static stripQuotes(text) {
        if (StringUtils.isQuoted(text))
            return text.substring(1, text.length - 1);
        return text;
    }
    static isQuoted(text) {
        return text.startsWith("'") && text.endsWith("'") || text.startsWith("\"") && text.endsWith("\"");
    }
    static isNullOrWhitespace(str) {
        return typeof str !== "string" || StringUtils.isWhitespace(str);
    }
    static isNullOrEmpty(str) {
        return typeof str !== "string" || str.length === 0;
    }
    static isWhitespace(text) {
        if (text == null)
            return true;
        for (let i = 0; i < text.length; i++) {
            if (!StringUtils.isWhitespaceCharCode(text.charCodeAt(i)))
                return false;
        }
        return true;
    }
    static startsWithNewLine(str) {
        if (str == null)
            return false;
        return str.charCodeAt(0) === CharCodes.NEWLINE || str.charCodeAt(0) === CharCodes.CARRIAGE_RETURN && str.charCodeAt(1) === CharCodes.NEWLINE;
    }
    static endsWithNewLine(str) {
        if (str == null)
            return false;
        return str.charCodeAt(str.length - 1) === CharCodes.NEWLINE;
    }
    static insertAtLastNonWhitespace(str, insertText) {
        let i = str.length;
        while (i > 0 && StringUtils.isWhitespaceCharCode(str.charCodeAt(i - 1)))
            i--;
        return str.substring(0, i) + insertText + str.substring(i);
    }
    static getLineNumberAtPos(str, pos) {
        exports.errors.throwIfOutOfRange(pos, [0, str.length], "pos");
        let count = 0;
        for (let i = 0; i < pos; i++) {
            if (str.charCodeAt(i) === CharCodes.NEWLINE)
                count++;
        }
        return count + 1;
    }
    static getLengthFromLineStartAtPos(str, pos) {
        exports.errors.throwIfOutOfRange(pos, [0, str.length], "pos");
        return pos - StringUtils.getLineStartFromPos(str, pos);
    }
    static getLineStartFromPos(str, pos) {
        exports.errors.throwIfOutOfRange(pos, [0, str.length], "pos");
        while (pos > 0) {
            const previousCharCode = str.charCodeAt(pos - 1);
            if (previousCharCode === CharCodes.NEWLINE || previousCharCode === CharCodes.CARRIAGE_RETURN)
                break;
            pos--;
        }
        return pos;
    }
    static getLineEndFromPos(str, pos) {
        exports.errors.throwIfOutOfRange(pos, [0, str.length], "pos");
        while (pos < str.length) {
            const currentChar = str.charCodeAt(pos);
            if (currentChar === CharCodes.NEWLINE || currentChar === CharCodes.CARRIAGE_RETURN)
                break;
            pos++;
        }
        return pos;
    }
    static escapeForWithinString(str, quoteKind) {
        return StringUtils.escapeChar(str, quoteKind).replace(/(\r?\n)/g, "\\$1");
    }
    static escapeChar(str, char) {
        if (char.length !== 1)
            throw new exports.errors.InvalidOperationError(`Specified char must be one character long.`);
        let result = "";
        for (const currentChar of str) {
            if (currentChar === char)
                result += "\\";
            result += currentChar;
        }
        return result;
    }
    static removeIndentation(str, opts) {
        const { isInStringAtPos, indentSizeInSpaces } = opts;
        const startPositions = [];
        const endPositions = [];
        let minIndentWidth;
        analyze();
        return buildString();
        function analyze() {
            let isAtStartOfLine = str.charCodeAt(0) === CharCodes.SPACE || str.charCodeAt(0) === CharCodes.TAB;
            for (let i = 0; i < str.length; i++) {
                if (!isAtStartOfLine) {
                    if (str.charCodeAt(i) === CharCodes.NEWLINE && !isInStringAtPos(i + 1))
                        isAtStartOfLine = true;
                    continue;
                }
                startPositions.push(i);
                let spacesCount = 0;
                let tabsCount = 0;
                while (true) {
                    if (str.charCodeAt(i) === CharCodes.SPACE)
                        spacesCount++;
                    else if (str.charCodeAt(i) === CharCodes.TAB)
                        tabsCount++;
                    else
                        break;
                    i++;
                }
                const indentWidth = Math.ceil(spacesCount / indentSizeInSpaces) * indentSizeInSpaces + tabsCount * indentSizeInSpaces;
                if (minIndentWidth == null || indentWidth < minIndentWidth)
                    minIndentWidth = indentWidth;
                endPositions.push(i);
                isAtStartOfLine = false;
            }
        }
        function buildString() {
            if (startPositions.length === 0)
                return str;
            if (minIndentWidth == null || minIndentWidth === 0)
                return str;
            const deindentWidth = minIndentWidth;
            let result = "";
            result += str.substring(0, startPositions[0]);
            let lastEndPos = startPositions[0];
            for (let i = 0; i < startPositions.length; i++) {
                const startPosition = startPositions[i];
                const endPosition = endPositions[i];
                let indentCount = 0;
                let pos;
                for (pos = startPosition; pos < endPosition; pos++) {
                    if (indentCount >= deindentWidth)
                        break;
                    if (str.charCodeAt(pos) === CharCodes.SPACE)
                        indentCount++;
                    else if (str.charCodeAt(pos) === CharCodes.TAB)
                        indentCount += indentSizeInSpaces;
                }
                lastEndPos = startPositions[i + 1] == null ? str.length : startPositions[i + 1];
                result += str.substring(pos, lastEndPos);
            }
            result += str.substring(lastEndPos);
            return result;
        }
    }
    static indent(str, times, options) {
        if (times === 0)
            return str;
        const { indentText, indentSizeInSpaces, isInStringAtPos } = options;
        const fullIndentationText = times > 0 ? indentText.repeat(times) : undefined;
        const totalIndentSpaces = Math.abs(times * indentSizeInSpaces);
        let result = "";
        let lineStart = 0;
        let lineEnd = 0;
        for (let i = 0; i < str.length; i++) {
            lineStart = i;
            while (i < str.length && str.charCodeAt(i) !== CharCodes.NEWLINE)
                i++;
            lineEnd = i === str.length ? i : i + 1;
            appendLine();
        }
        return result;
        function appendLine() {
            if (isInStringAtPos(lineStart))
                result += str.substring(lineStart, lineEnd);
            else if (times > 0)
                result += fullIndentationText + str.substring(lineStart, lineEnd);
            else {
                let start = lineStart;
                let indentSpaces = 0;
                for (start = lineStart; start < str.length; start++) {
                    if (indentSpaces >= totalIndentSpaces)
                        break;
                    if (str.charCodeAt(start) === CharCodes.SPACE)
                        indentSpaces++;
                    else if (str.charCodeAt(start) === CharCodes.TAB)
                        indentSpaces += indentSizeInSpaces;
                    else
                        break;
                }
                result += str.substring(start, lineEnd);
            }
        }
    }
}

class SortedKeyValueArray {
    constructor(getKey, comparer) {
        this.getKey = getKey;
        this.comparer = comparer;
        this.array = [];
    }
    set(value) {
        ArrayUtils.binaryInsertWithOverwrite(this.array, value, new PropertyComparer(this.getKey, this.comparer));
    }
    removeByValue(value) {
        this.removeByKey(this.getKey(value));
    }
    removeByKey(key) {
        const storedComparer = new ComparerToStoredComparer(this.comparer, key);
        const index = ArrayUtils.binarySearch(this.array, new PropertyStoredComparer(this.getKey, storedComparer));
        if (index >= 0)
            this.array.splice(index, 1);
    }
    getArrayCopy() {
        return [...this.array];
    }
    hasItems() {
        return this.array.length > 0;
    }
    *entries() {
        yield* this.array;
    }
}

class WeakCache {
    constructor() {
        this.cacheItems = new WeakMap();
    }
    getOrCreate(key, createFunc) {
        let item = this.get(key);
        if (item == null) {
            item = createFunc();
            this.set(key, item);
        }
        return item;
    }
    has(key) {
        return this.cacheItems.has(key);
    }
    get(key) {
        return this.cacheItems.get(key);
    }
    set(key, value) {
        this.cacheItems.set(key, value);
    }
    removeByKey(key) {
        this.cacheItems.delete(key);
    }
}

function createCompilerSourceFile(filePath, scriptSnapshot, scriptTarget, version, setParentNodes, scriptKind) {
    return ts__namespace.createLanguageServiceSourceFile(filePath, scriptSnapshot, scriptTarget !== null && scriptTarget !== void 0 ? scriptTarget : ts.ScriptTarget.Latest, version, setParentNodes, scriptKind);
}

function createDocumentCache(files) {
    const cache = new InternalDocumentCache();
    cache._addFiles(files);
    return cache;
}
class FileSystemDocumentCache {
    constructor(fileSystem, documentCache) {
        this.documentCache = documentCache;
        this.absoluteToOriginalPath = new Map();
        for (const filePath of documentCache._getFilePaths())
            this.absoluteToOriginalPath.set(fileSystem.getStandardizedAbsolutePath(filePath), filePath);
    }
    getDocumentIfMatch(filePath, scriptSnapshot, scriptTarget, scriptKind) {
        const originalFilePath = this.absoluteToOriginalPath.get(filePath);
        if (originalFilePath == null)
            return;
        return this.documentCache._getDocumentIfMatch(originalFilePath, filePath, scriptSnapshot, scriptTarget, scriptKind);
    }
}
class InternalDocumentCache {
    constructor() {
        this._fileTexts = new Map();
        this._documents = new Map();
    }
    _addFiles(files) {
        for (const file of files)
            this._fileTexts.set(file.fileName, file.text);
    }
    _getFilePaths() {
        return this._fileTexts.keys();
    }
    _getCacheForFileSystem(fileSystem) {
        return new FileSystemDocumentCache(fileSystem, this);
    }
    _getDocumentIfMatch(filePath, absoluteFilePath, scriptSnapshot, scriptTarget, scriptKind) {
        const fileText = this._fileTexts.get(filePath);
        if (fileText == null)
            return undefined;
        if (fileText !== scriptSnapshot.getText(0, scriptSnapshot.getLength()))
            return undefined;
        return this._getDocument(filePath, absoluteFilePath, scriptSnapshot, scriptTarget, scriptKind);
    }
    _getDocument(filePath, absoluteFilePath, scriptSnapshot, scriptTarget, scriptKind) {
        const documentKey = this._getKey(filePath, scriptTarget, scriptKind);
        let document = this._documents.get(documentKey);
        if (document == null) {
            document = createCompilerSourceFile(absoluteFilePath, scriptSnapshot, scriptTarget, "-1", false, scriptKind);
            this._documents.set(documentKey, document);
        }
        document = deepClone(document);
        document.fileName = absoluteFilePath;
        return document;
    }
    _getKey(filePath, scriptTarget, scriptKind) {
        var _a, _b;
        return (filePath + ((_a = scriptTarget === null || scriptTarget === void 0 ? void 0 : scriptTarget.toString()) !== null && _a !== void 0 ? _a : "-1") + ((_b = scriptKind === null || scriptKind === void 0 ? void 0 : scriptKind.toString()) !== null && _b !== void 0 ? _b : "-1"));
    }
}

function getLibFiles() {
    const libFiles = require("./data/libFiles");
    return libFiles.libFiles;
}
const libFolderInMemoryPath = "/node_modules/typescript/lib";

const path$1 = require("path-browserify");
class BrowserRuntime {
    constructor() {
        this.fs = new BrowserRuntimeFileSystem();
        this.path = new BrowserRuntimePath();
    }
    getEnvVar(_name) {
        return undefined;
    }
    getEndOfLine() {
        return "\n";
    }
    getPathMatchesPattern(path, pattern) {
        return minimatch__default["default"](path, pattern);
    }
}
class BrowserRuntimePath {
    join(...paths) {
        return path$1.join(...paths);
    }
    normalize(pathToNormalize) {
        return path$1.normalize(pathToNormalize);
    }
    relative(from, to) {
        return path$1.relative(from, to);
    }
}
class BrowserRuntimeFileSystem {
    constructor() {
        this._errorMessage = "Access to the file system is not supported in the browser. Please use an in-memory file system (specify `useInMemoryFileSystem: true` when creating the project).";
    }
    delete(_path) {
        return Promise.reject(new Error(this._errorMessage));
    }
    deleteSync(_path) {
        throw new Error(this._errorMessage);
    }
    readDirSync(_dirPath) {
        throw new Error(this._errorMessage);
    }
    readFile(_filePath, _encoding) {
        return Promise.reject(new Error(this._errorMessage));
    }
    readFileSync(_filePath, _encoding) {
        throw new Error(this._errorMessage);
    }
    writeFile(_filePath, _fileText) {
        return Promise.reject(new Error(this._errorMessage));
    }
    writeFileSync(_filePath, _fileText) {
        throw new Error(this._errorMessage);
    }
    mkdir(_dirPath) {
        return Promise.reject(new Error(this._errorMessage));
    }
    mkdirSync(_dirPath) {
        throw new Error(this._errorMessage);
    }
    move(_srcPath, _destPath) {
        return Promise.reject(new Error(this._errorMessage));
    }
    moveSync(_srcPath, _destPath) {
        throw new Error(this._errorMessage);
    }
    copy(_srcPath, _destPath) {
        return Promise.reject(new Error(this._errorMessage));
    }
    copySync(_srcPath, _destPath) {
        throw new Error(this._errorMessage);
    }
    fileExists(_filePath) {
        return Promise.reject(new Error(this._errorMessage));
    }
    fileExistsSync(_filePath) {
        throw new Error(this._errorMessage);
    }
    directoryExists(_dirPath) {
        return Promise.reject(new Error(this._errorMessage));
    }
    directoryExistsSync(_dirPath) {
        throw new Error(this._errorMessage);
    }
    realpathSync(_path) {
        throw new Error(this._errorMessage);
    }
    getCurrentDirectory() {
        throw new Error(this._errorMessage);
    }
    glob(_patterns) {
        return Promise.reject(new Error(this._errorMessage));
    }
    globSync(_patterns) {
        throw new Error(this._errorMessage);
    }
    isCaseSensitive() {
        return true;
    }
}

/*! *****************************************************************************
Copyright (c) Microsoft Corporation.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
***************************************************************************** */

function __decorate(decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
}

function __awaiter(thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
}

function __await(v) {
    return this instanceof __await ? (this.v = v, this) : new __await(v);
}

function __asyncGenerator(thisArg, _arguments, generator) {
    if (!Symbol.asyncIterator) throw new TypeError("Symbol.asyncIterator is not defined.");
    var g = generator.apply(thisArg, _arguments || []), i, q = [];
    return i = {}, verb("next"), verb("throw"), verb("return"), i[Symbol.asyncIterator] = function () { return this; }, i;
    function verb(n) { if (g[n]) i[n] = function (v) { return new Promise(function (a, b) { q.push([n, v, a, b]) > 1 || resume(n, v); }); }; }
    function resume(n, v) { try { step(g[n](v)); } catch (e) { settle(q[0][3], e); } }
    function step(r) { r.value instanceof __await ? Promise.resolve(r.value.v).then(fulfill, reject) : settle(q[0][2], r); }
    function fulfill(value) { resume("next", value); }
    function reject(value) { resume("throw", value); }
    function settle(f, v) { if (f(v), q.shift(), q.length) resume(q[0][0], q[0][1]); }
}

class NodeRuntime {
    constructor() {
        this.fs = new NodeRuntimeFileSystem();
        this.path = new NodeRuntimePath();
    }
    getEnvVar(name) {
        return process === null || process === void 0 ? void 0 : process.env[name];
    }
    getEndOfLine() {
        return os__namespace.EOL;
    }
    getPathMatchesPattern(path, pattern) {
        return minimatch__default["default"](path, pattern);
    }
}
class NodeRuntimePath {
    join(...paths) {
        return path__namespace.join(...paths);
    }
    normalize(pathToNormalize) {
        return path__namespace.normalize(pathToNormalize);
    }
    relative(from, to) {
        return path__namespace.relative(from, to);
    }
}
class NodeRuntimeFileSystem {
    delete(path) {
        return new Promise((resolve, reject) => {
            fs__namespace.unlink(path, err => {
                if (err)
                    reject(err);
                else
                    resolve();
            });
        });
    }
    deleteSync(path) {
        fs__namespace.unlinkSync(path);
    }
    readDirSync(dirPath) {
        return fs__namespace.readdirSync(dirPath);
    }
    readFile(filePath, encoding = "utf-8") {
        return new Promise((resolve, reject) => {
            fs__namespace.readFile(filePath, encoding, (err, data) => {
                if (err)
                    reject(err);
                else
                    resolve(data);
            });
        });
    }
    readFileSync(filePath, encoding = "utf-8") {
        return fs__namespace.readFileSync(filePath, encoding);
    }
    writeFile(filePath, fileText) {
        return __awaiter(this, void 0, void 0, function* () {
            yield new Promise((resolve, reject) => {
                fs__namespace.writeFile(filePath, fileText, err => {
                    if (err)
                        reject(err);
                    else
                        resolve();
                });
            });
        });
    }
    writeFileSync(filePath, fileText) {
        fs__namespace.writeFileSync(filePath, fileText);
    }
    mkdir(dirPath) {
        return __awaiter(this, void 0, void 0, function* () {
            yield mkdirp__default["default"](dirPath);
        });
    }
    mkdirSync(dirPath) {
        mkdirp__default["default"].sync(dirPath);
    }
    move(srcPath, destPath) {
        return new Promise((resolve, reject) => {
            fs__namespace.rename(srcPath, destPath, err => {
                if (err)
                    reject(err);
                else
                    resolve();
            });
        });
    }
    moveSync(srcPath, destPath) {
        fs__namespace.renameSync(srcPath, destPath);
    }
    copy(srcPath, destPath) {
        return new Promise((resolve, reject) => {
            fs__namespace.copyFile(srcPath, destPath, err => {
                if (err)
                    reject(err);
                else
                    resolve();
            });
        });
    }
    copySync(srcPath, destPath) {
        fs__namespace.copyFileSync(srcPath, destPath);
    }
    fileExists(filePath) {
        return new Promise(resolve => {
            fs__namespace.stat(filePath, (err, stat) => {
                if (err)
                    resolve(false);
                else
                    resolve(stat.isFile());
            });
        });
    }
    fileExistsSync(filePath) {
        try {
            return fs__namespace.statSync(filePath).isFile();
        }
        catch (err) {
            return false;
        }
    }
    directoryExists(dirPath) {
        return new Promise(resolve => {
            fs__namespace.stat(dirPath, (err, stat) => {
                if (err)
                    resolve(false);
                else
                    resolve(stat.isDirectory());
            });
        });
    }
    directoryExistsSync(dirPath) {
        try {
            return fs__namespace.statSync(dirPath).isDirectory();
        }
        catch (err) {
            return false;
        }
    }
    realpathSync(path) {
        return fs__namespace.realpathSync(path);
    }
    getCurrentDirectory() {
        return path__namespace.resolve();
    }
    glob(patterns) {
        return fastGlob__default["default"](patterns, {
            cwd: this.getCurrentDirectory(),
            absolute: true,
        });
    }
    globSync(patterns) {
        return fastGlob__default["default"].sync(patterns, {
            cwd: this.getCurrentDirectory(),
            absolute: true,
        });
    }
    isCaseSensitive() {
        const platform = process === null || process === void 0 ? void 0 : process.platform;
        return platform !== "win32" && platform !== "darwin";
    }
}

const runtime = getRuntime();
function getRuntime() {
    if (isNodeJs())
        return new NodeRuntime();
    else
        return new BrowserRuntime();
}
function isNodeJs() {
    return typeof globalThis.process === "object"
        && typeof globalThis.process.versions === "object"
        && typeof globalThis.process.versions.node !== "undefined";
}

function createHosts(options) {
    const { transactionalFileSystem, sourceFileContainer, compilerOptions, getNewLine, resolutionHost, getProjectVersion, isKnownTypesPackageName } = options;
    let version = 0;
    const libFolderPath = transactionalFileSystem.getStandardizedAbsolutePath(getLibFolderPath());
    const libFileMap = getLibFileMap();
    const fileExistsSync = (path) => sourceFileContainer.containsSourceFileAtPath(path)
        || transactionalFileSystem.fileExistsSync(path);
    const languageServiceHost = {
        getCompilationSettings: () => compilerOptions.get(),
        getNewLine,
        getProjectVersion,
        getScriptFileNames: () => Array.from(sourceFileContainer.getSourceFilePaths()),
        getScriptVersion: fileName => {
            const filePath = transactionalFileSystem.getStandardizedAbsolutePath(fileName);
            const sourceFile = sourceFileContainer.getSourceFileFromCacheFromFilePath(filePath);
            if (sourceFile == null)
                return (version++).toString();
            return sourceFileContainer.getSourceFileVersion(sourceFile);
        },
        getScriptSnapshot: fileName => {
            const filePath = transactionalFileSystem.getStandardizedAbsolutePath(fileName);
            if (!fileExistsSync(filePath)) {
                if (libFileMap != null) {
                    const libFileText = libFileMap.get(filePath);
                    if (libFileText != null)
                        return ts__namespace.ScriptSnapshot.fromString(libFileText);
                }
                return undefined;
            }
            return ts__namespace.ScriptSnapshot.fromString(sourceFileContainer.addOrGetSourceFileFromFilePathSync(filePath, {
                markInProject: false,
                scriptKind: undefined,
            }).getFullText());
        },
        getCurrentDirectory: () => transactionalFileSystem.getCurrentDirectory(),
        getDefaultLibFileName: options => {
            return libFolderPath + "/" + ts__namespace.getDefaultLibFileName(options);
        },
        isKnownTypesPackageName,
        useCaseSensitiveFileNames: () => true,
        readFile: (path, encoding) => {
            const standardizedPath = transactionalFileSystem.getStandardizedAbsolutePath(path);
            if (libFileMap != null) {
                const libFileText = libFileMap.get(standardizedPath);
                if (libFileText != null)
                    return libFileText;
            }
            if (sourceFileContainer.containsSourceFileAtPath(standardizedPath))
                return sourceFileContainer.getSourceFileFromCacheFromFilePath(standardizedPath).getFullText();
            return transactionalFileSystem.readFileSync(standardizedPath, encoding);
        },
        fileExists: filePath => {
            const standardizedFilePath = transactionalFileSystem.getStandardizedAbsolutePath(filePath);
            return fileExistsSync(standardizedFilePath) || libFileMap != null && libFileMap.has(standardizedFilePath);
        },
        directoryExists: dirName => {
            const dirPath = transactionalFileSystem.getStandardizedAbsolutePath(dirName);
            return sourceFileContainer.containsDirectoryAtPath(dirPath)
                || transactionalFileSystem.directoryExistsSync(dirPath);
        },
        resolveModuleNames: resolutionHost.resolveModuleNames,
        resolveTypeReferenceDirectives: resolutionHost.resolveTypeReferenceDirectives,
        getResolvedModuleWithFailedLookupLocationsFromCache: resolutionHost.getResolvedModuleWithFailedLookupLocationsFromCache,
        realpath: path => transactionalFileSystem.realpathSync(transactionalFileSystem.getStandardizedAbsolutePath(path)),
    };
    const compilerHost = {
        getSourceFile: (fileName, languageVersion, onError) => {
            const filePath = transactionalFileSystem.getStandardizedAbsolutePath(fileName);
            if (libFileMap != null) {
                const libFileText = libFileMap.get(filePath);
                if (libFileText != null) {
                    let sourceFile = sourceFileContainer.getSourceFileFromCacheFromFilePath(filePath);
                    if (sourceFile == null) {
                        sourceFile = sourceFileContainer.addLibFileToCacheByText(filePath, libFileText, ts__namespace.ScriptKind.TS);
                    }
                    return sourceFile;
                }
            }
            return sourceFileContainer.addOrGetSourceFileFromFilePathSync(filePath, {
                markInProject: false,
                scriptKind: undefined,
            });
        },
        getDefaultLibFileName: languageServiceHost.getDefaultLibFileName,
        writeFile: (fileName, data, writeByteOrderMark, onError, sourceFiles) => {
            const filePath = transactionalFileSystem.getStandardizedAbsolutePath(fileName);
            transactionalFileSystem.writeFileSync(filePath, writeByteOrderMark ? "\uFEFF" + data : data);
        },
        getCurrentDirectory: () => languageServiceHost.getCurrentDirectory(),
        getDirectories: (path) => transactionalFileSystem.getDirectories(transactionalFileSystem.getStandardizedAbsolutePath(path)),
        fileExists: languageServiceHost.fileExists,
        readFile: languageServiceHost.readFile,
        getCanonicalFileName: (fileName) => transactionalFileSystem.getStandardizedAbsolutePath(fileName),
        useCaseSensitiveFileNames: languageServiceHost.useCaseSensitiveFileNames,
        getNewLine: languageServiceHost.getNewLine,
        getEnvironmentVariable: (name) => runtime.getEnvVar(name),
        directoryExists: dirName => languageServiceHost.directoryExists(dirName),
        resolveModuleNames: resolutionHost.resolveModuleNames,
        resolveTypeReferenceDirectives: resolutionHost.resolveTypeReferenceDirectives,
        realpath: languageServiceHost.realpath,
    };
    return { languageServiceHost, compilerHost };
    function getLibFolderPath() {
        if (options.libFolderPath != null) {
            if (options.skipLoadingLibFiles === true) {
                throw new exports.errors.InvalidOperationError(`Cannot set ${"skipLoadingLibFiles"} to true when ${"libFolderPath"} is provided.`);
            }
            return options.libFolderPath;
        }
        return libFolderInMemoryPath;
    }
    function getLibFileMap() {
        if (options.skipLoadingLibFiles || options.libFolderPath != null)
            return undefined;
        const libFilesMap = new Map();
        const libFiles = getLibFiles();
        for (const libFile of libFiles) {
            libFilesMap.set(transactionalFileSystem.getStandardizedAbsolutePath(libFolderPath + "/" + libFile.fileName), libFile.text);
        }
        return libFilesMap;
    }
}

const isWindowsRootDirRegex = /^[a-z]+:[\\\/]$/i;
const path = runtime.path;
class FileUtils {
    constructor() {
    }
    static isNotExistsError(err) {
        return err != null && err.code === FileUtils.ENOENT;
    }
    static pathJoin(basePath, ...paths) {
        if (FileUtils.pathIsAbsolute(basePath)) {
            return FileUtils.standardizeSlashes(path.normalize(path.join(basePath, ...paths)));
        }
        return FileUtils.standardizeSlashes(path.join(basePath, ...paths));
    }
    static pathIsAbsolute(fileOrDirPath) {
        return isAbsolutePath(fileOrDirPath);
    }
    static getStandardizedAbsolutePath(fileSystem, fileOrDirPath, relativeBase) {
        return FileUtils.standardizeSlashes(path.normalize(getAbsolutePath()));
        function getAbsolutePath() {
            if (isAbsolutePath(fileOrDirPath))
                return fileOrDirPath;
            if (!fileOrDirPath.startsWith("./") && relativeBase != null)
                return path.join(relativeBase, fileOrDirPath);
            return path.join(fileSystem.getCurrentDirectory(), fileOrDirPath);
        }
    }
    static getDirPath(fileOrDirPath) {
        fileOrDirPath = FileUtils.standardizeSlashes(fileOrDirPath);
        const lastIndexOfSlash = fileOrDirPath.lastIndexOf("/");
        if (lastIndexOfSlash === -1)
            return ".";
        return FileUtils.standardizeSlashes(fileOrDirPath.substring(0, lastIndexOfSlash + 1));
    }
    static getBaseName(fileOrDirPath) {
        const lastIndexOfSlash = fileOrDirPath.lastIndexOf("/");
        return fileOrDirPath.substring(lastIndexOfSlash + 1);
    }
    static getExtension(fileOrDirPath) {
        const baseName = FileUtils.getBaseName(fileOrDirPath);
        const lastDotIndex = baseName.lastIndexOf(".");
        if (lastDotIndex <= 0)
            return "";
        const lastExt = baseName.substring(lastDotIndex);
        const lastExtLowerCase = lastExt.toLowerCase();
        if (lastExtLowerCase === ".ts" && baseName.substring(lastDotIndex - 2, lastDotIndex).toLowerCase() === ".d")
            return baseName.substring(lastDotIndex - 2);
        if (lastExtLowerCase === ".map" && baseName.substring(lastDotIndex - 3, lastDotIndex).toLowerCase() === ".js")
            return baseName.substring(lastDotIndex - 3);
        return lastExt;
    }
    static standardizeSlashes(fileOrDirPath) {
        let result = fileOrDirPath.replace(this.standardizeSlashesRegex, "/");
        if (!FileUtils.isRootDirPath(result) && result.endsWith("/"))
            result = result.substring(0, result.length - 1);
        return result;
    }
    static pathEndsWith(fileOrDirPath, endsWithPath) {
        const pathItems = FileUtils.splitPathBySlashes(fileOrDirPath);
        const endsWithItems = FileUtils.splitPathBySlashes(endsWithPath);
        if (endsWithItems.length > pathItems.length)
            return false;
        for (let i = 0; i < endsWithItems.length; i++) {
            if (endsWithItems[endsWithItems.length - i - 1] !== pathItems[pathItems.length - i - 1])
                return false;
        }
        return endsWithItems.length > 0;
    }
    static pathStartsWith(fileOrDirPath, startsWithPath) {
        const isfileOrDirPathEmpty = StringUtils.isNullOrWhitespace(fileOrDirPath);
        const isStartsWithPathEmpty = StringUtils.isNullOrWhitespace(startsWithPath);
        const pathItems = FileUtils.splitPathBySlashes(fileOrDirPath);
        const startsWithItems = FileUtils.splitPathBySlashes(startsWithPath);
        if (isfileOrDirPathEmpty && isStartsWithPathEmpty)
            return true;
        if (isStartsWithPathEmpty || startsWithItems.length > pathItems.length)
            return false;
        if (startsWithItems.length === 1 && startsWithItems[0].length === 0)
            return true;
        for (let i = 0; i < startsWithItems.length; i++) {
            if (startsWithItems[i] !== pathItems[i])
                return false;
        }
        return startsWithItems.length > 0;
    }
    static splitPathBySlashes(fileOrDirPath) {
        fileOrDirPath = (fileOrDirPath || "").replace(FileUtils.trimSlashStartRegex, "").replace(FileUtils.trimSlashEndRegex, "");
        return FileUtils.standardizeSlashes(fileOrDirPath).replace(/^\//, "").split("/");
    }
    static getParentMostPaths(paths) {
        const finalPaths = [];
        for (const fileOrDirPath of ArrayUtils.sortByProperty(paths, p => p.length)) {
            if (finalPaths.every(p => !FileUtils.pathStartsWith(fileOrDirPath, p)))
                finalPaths.push(fileOrDirPath);
        }
        return finalPaths;
    }
    static readFileOrNotExists(fileSystem, filePath, encoding) {
        return __awaiter(this, void 0, void 0, function* () {
            try {
                return yield fileSystem.readFile(filePath, encoding);
            }
            catch (err) {
                if (!FileUtils.isNotExistsError(err))
                    throw err;
                return false;
            }
        });
    }
    static readFileOrNotExistsSync(fileSystem, filePath, encoding) {
        try {
            return fileSystem.readFileSync(filePath, encoding);
        }
        catch (err) {
            if (!FileUtils.isNotExistsError(err))
                throw err;
            return false;
        }
    }
    static getTextWithByteOrderMark(text) {
        if (StringUtils.hasBom(text))
            return text;
        return "\uFEFF" + text;
    }
    static getRelativePathTo(absoluteDirPathFrom, absolutePathTo) {
        const relativePath = path.relative(absoluteDirPathFrom, FileUtils.getDirPath(absolutePathTo));
        return FileUtils.standardizeSlashes(path.join(relativePath, FileUtils.getBaseName(absolutePathTo)));
    }
    static isRootDirPath(dirOrFilePath) {
        return dirOrFilePath === "/" || isWindowsRootDirRegex.test(dirOrFilePath);
    }
    static *getDescendantDirectories(fileSystemWrapper, dirPath) {
        for (const subDirPath of fileSystemWrapper.readDirSync(dirPath)) {
            if (!fileSystemWrapper.directoryExistsSync(subDirPath))
                continue;
            yield subDirPath;
            yield* FileUtils.getDescendantDirectories(fileSystemWrapper, subDirPath);
        }
    }
    static toAbsoluteGlob(glob, cwd) {
        if (glob.slice(0, 2) === "./")
            glob = glob.slice(2);
        if (glob.length === 1 && glob === ".")
            glob = "";
        const suffix = glob.slice(-1);
        const isNegated = FileUtils.isNegatedGlob(glob);
        if (isNegated)
            glob = glob.slice(1);
        if (!isAbsolutePath(glob) || glob.slice(0, 1) === "\\")
            glob = globJoin(cwd, glob);
        if (suffix === "/" && glob.slice(-1) !== "/")
            glob += "/";
        return isNegated ? "!" + glob : glob;
    }
    static isNegatedGlob(glob) {
        return glob[0] === "!" && glob[1] !== "(";
    }
}
FileUtils.standardizeSlashesRegex = /\\/g;
FileUtils.trimSlashStartRegex = /^\//;
FileUtils.trimSlashEndRegex = /\/$/;
FileUtils.ENOENT = "ENOENT";
function globJoin(dir, glob) {
    if (dir.charAt(dir.length - 1) === "/")
        dir = dir.slice(0, -1);
    if (glob.charAt(0) === "/")
        glob = glob.slice(1);
    if (!glob)
        return dir;
    return dir + "/" + glob;
}
function isAbsolutePath(filePath) {
    return filePath.startsWith("/") || isWindowsAbsolutePath(filePath);
}
const isWindowsAbsolutePathRegex = /^[a-z]+:[\\\/]/i;
function isWindowsAbsolutePath(filePath) {
    return isWindowsAbsolutePathRegex.test(filePath) || isAzureAbsolutePath(filePath) || isUncPath(filePath);
}
function isAzureAbsolutePath(filePath) {
    return filePath.startsWith("\\\\");
}
const uncPathRegex = /^[\\\/]{2,}[^\\\/]+[\\\/]+[^\\\/]+/;
function isUncPath(filePath) {
    return uncPathRegex.test(filePath);
}

function matchGlobs(paths, patterns, cwd) {
    if (typeof patterns === "string")
        patterns = [FileUtils.toAbsoluteGlob(patterns, cwd)];
    else
        patterns = patterns.map(p => FileUtils.toAbsoluteGlob(p, cwd));
    const result = [];
    for (const path of paths) {
        for (let pattern of patterns) {
            let process = addArray;
            if (FileUtils.isNegatedGlob(pattern)) {
                process = removeArray;
                pattern = pattern.slice(1);
            }
            if (runtime.getPathMatchesPattern(path, pattern))
                process(result, path);
        }
    }
    return result;
}
function addArray(items, newItem) {
    if (items.indexOf(newItem) === -1)
        items.push(newItem);
}
function removeArray(items, removeItem) {
    const index = items.indexOf(removeItem);
    if (index >= 0)
        items.splice(index, 1);
}

class InMemoryFileSystemHost {
    constructor() {
        this.directories = new Map();
        this.getOrCreateDir("/");
    }
    isCaseSensitive() {
        return true;
    }
    delete(path) {
        try {
            this.deleteSync(path);
            return Promise.resolve();
        }
        catch (err) {
            return Promise.reject(err);
        }
    }
    deleteSync(path) {
        const standardizedPath = FileUtils.getStandardizedAbsolutePath(this, path);
        if (this.directories.has(standardizedPath)) {
            for (const descendantDirPath of getDescendantDirectories(this.directories.keys(), standardizedPath))
                this.directories.delete(descendantDirPath);
            this.directories.delete(standardizedPath);
            return;
        }
        const parentDir = this.directories.get(FileUtils.getDirPath(standardizedPath));
        if (parentDir == null || !parentDir.files.has(standardizedPath))
            throw new exports.errors.FileNotFoundError(standardizedPath);
        parentDir.files.delete(standardizedPath);
    }
    readDirSync(dirPath) {
        const standardizedDirPath = FileUtils.getStandardizedAbsolutePath(this, dirPath);
        const dir = this.directories.get(standardizedDirPath);
        if (dir == null)
            throw new exports.errors.DirectoryNotFoundError(standardizedDirPath);
        return [...getDirectories(this.directories.keys()), ...dir.files.keys()];
        function* getDirectories(dirPaths) {
            for (const path of dirPaths) {
                const parentDir = FileUtils.getDirPath(path);
                if (parentDir === standardizedDirPath && parentDir !== path)
                    yield path;
            }
        }
    }
    readFile(filePath, encoding = "utf-8") {
        try {
            return Promise.resolve(this.readFileSync(filePath, encoding));
        }
        catch (err) {
            return Promise.reject(err);
        }
    }
    readFileSync(filePath, encoding = "utf-8") {
        const standardizedFilePath = FileUtils.getStandardizedAbsolutePath(this, filePath);
        const parentDir = this.directories.get(FileUtils.getDirPath(standardizedFilePath));
        if (parentDir == null)
            throw new exports.errors.FileNotFoundError(standardizedFilePath);
        const fileText = parentDir.files.get(standardizedFilePath);
        if (fileText === undefined)
            throw new exports.errors.FileNotFoundError(standardizedFilePath);
        return fileText;
    }
    writeFile(filePath, fileText) {
        this.writeFileSync(filePath, fileText);
        return Promise.resolve();
    }
    writeFileSync(filePath, fileText) {
        this._writeFileSync(filePath, fileText);
    }
    _writeFileSync(filePath, fileText) {
        const standardizedFilePath = FileUtils.getStandardizedAbsolutePath(this, filePath);
        const dirPath = FileUtils.getDirPath(standardizedFilePath);
        this.getOrCreateDir(dirPath).files.set(standardizedFilePath, fileText);
    }
    mkdir(dirPath) {
        this.mkdirSync(dirPath);
        return Promise.resolve();
    }
    mkdirSync(dirPath) {
        this.getOrCreateDir(FileUtils.getStandardizedAbsolutePath(this, dirPath));
    }
    move(srcPath, destPath) {
        this.moveSync(srcPath, destPath);
        return Promise.resolve();
    }
    moveSync(srcPath, destPath) {
        const standardizedSrcPath = FileUtils.getStandardizedAbsolutePath(this, srcPath);
        const standardizedDestPath = FileUtils.getStandardizedAbsolutePath(this, destPath);
        if (this.fileExistsSync(standardizedSrcPath)) {
            const fileText = this.readFileSync(standardizedSrcPath);
            this.deleteSync(standardizedSrcPath);
            this.writeFileSync(standardizedDestPath, fileText);
        }
        else if (this.directories.has(standardizedSrcPath)) {
            const moveDirectory = (from, to) => {
                this._copyDirInternal(from, to);
                this.directories.delete(from);
            };
            moveDirectory(standardizedSrcPath, standardizedDestPath);
            for (const descendantDirPath of getDescendantDirectories(this.directories.keys(), standardizedSrcPath)) {
                const relativePath = FileUtils.getRelativePathTo(standardizedSrcPath, descendantDirPath);
                moveDirectory(descendantDirPath, FileUtils.pathJoin(standardizedDestPath, relativePath));
            }
        }
        else {
            throw new exports.errors.PathNotFoundError(standardizedSrcPath);
        }
    }
    copy(srcPath, destPath) {
        this.copySync(srcPath, destPath);
        return Promise.resolve();
    }
    copySync(srcPath, destPath) {
        const standardizedSrcPath = FileUtils.getStandardizedAbsolutePath(this, srcPath);
        const standardizedDestPath = FileUtils.getStandardizedAbsolutePath(this, destPath);
        if (this.fileExistsSync(standardizedSrcPath))
            this.writeFileSync(standardizedDestPath, this.readFileSync(standardizedSrcPath));
        else if (this.directories.has(standardizedSrcPath)) {
            this._copyDirInternal(standardizedSrcPath, standardizedDestPath);
            for (const descendantDirPath of getDescendantDirectories(this.directories.keys(), standardizedSrcPath)) {
                const relativePath = FileUtils.getRelativePathTo(standardizedSrcPath, descendantDirPath);
                this._copyDirInternal(descendantDirPath, FileUtils.pathJoin(standardizedDestPath, relativePath));
            }
        }
        else {
            throw new exports.errors.PathNotFoundError(standardizedSrcPath);
        }
    }
    _copyDirInternal(from, to) {
        const dir = this.directories.get(from);
        const newDir = this.getOrCreateDir(to);
        for (const [filePath, text] of dir.files.entries()) {
            const toDir = FileUtils.pathJoin(to, FileUtils.getBaseName(filePath));
            newDir.files.set(toDir, text);
        }
    }
    fileExists(filePath) {
        return Promise.resolve(this.fileExistsSync(filePath));
    }
    fileExistsSync(filePath) {
        const standardizedFilePath = FileUtils.getStandardizedAbsolutePath(this, filePath);
        const dirPath = FileUtils.getDirPath(standardizedFilePath);
        const dir = this.directories.get(dirPath);
        if (dir == null)
            return false;
        return dir.files.has(standardizedFilePath);
    }
    directoryExists(dirPath) {
        return Promise.resolve(this.directoryExistsSync(dirPath));
    }
    directoryExistsSync(dirPath) {
        return this.directories.has(FileUtils.getStandardizedAbsolutePath(this, dirPath));
    }
    realpathSync(path) {
        return path;
    }
    getCurrentDirectory() {
        return "/";
    }
    glob(patterns) {
        try {
            return Promise.resolve(this.globSync(patterns));
        }
        catch (err) {
            return Promise.reject(err);
        }
    }
    globSync(patterns) {
        const allFilePaths = Array.from(getAllFilePaths(this.directories.values()));
        return matchGlobs(allFilePaths, patterns, this.getCurrentDirectory());
        function* getAllFilePaths(directories) {
            for (const dir of directories)
                yield* dir.files.keys();
        }
    }
    getOrCreateDir(dirPath) {
        let dir = this.directories.get(dirPath);
        if (dir == null) {
            dir = { path: dirPath, files: new Map() };
            this.directories.set(dirPath, dir);
            const parentDirPath = FileUtils.getDirPath(dirPath);
            if (parentDirPath !== dirPath)
                this.getOrCreateDir(parentDirPath);
        }
        return dir;
    }
}
function* getDescendantDirectories(directoryPaths, dirPath) {
    for (const path of directoryPaths) {
        if (FileUtils.pathStartsWith(path, dirPath))
            yield path;
    }
}

const fs = runtime.fs;
class RealFileSystemHost {
    delete(path) {
        return __awaiter(this, void 0, void 0, function* () {
            try {
                yield fs.delete(path);
            }
            catch (err) {
                throw this.getFileNotFoundErrorIfNecessary(err, path);
            }
        });
    }
    deleteSync(path) {
        try {
            fs.deleteSync(path);
        }
        catch (err) {
            throw this.getFileNotFoundErrorIfNecessary(err, path);
        }
    }
    readDirSync(dirPath) {
        try {
            return fs.readDirSync(dirPath).map(name => FileUtils.pathJoin(dirPath, name));
        }
        catch (err) {
            throw this.getDirectoryNotFoundErrorIfNecessary(err, dirPath);
        }
    }
    readFile(filePath, encoding = "utf-8") {
        return __awaiter(this, void 0, void 0, function* () {
            try {
                return yield fs.readFile(filePath, encoding);
            }
            catch (err) {
                throw this.getFileNotFoundErrorIfNecessary(err, filePath);
            }
        });
    }
    readFileSync(filePath, encoding = "utf-8") {
        try {
            return fs.readFileSync(filePath, encoding);
        }
        catch (err) {
            throw this.getFileNotFoundErrorIfNecessary(err, filePath);
        }
    }
    writeFile(filePath, fileText) {
        return __awaiter(this, void 0, void 0, function* () {
            return fs.writeFile(filePath, fileText);
        });
    }
    writeFileSync(filePath, fileText) {
        fs.writeFileSync(filePath, fileText);
    }
    mkdir(dirPath) {
        return fs.mkdir(dirPath);
    }
    mkdirSync(dirPath) {
        fs.mkdirSync(dirPath);
    }
    move(srcPath, destPath) {
        return fs.move(srcPath, destPath);
    }
    moveSync(srcPath, destPath) {
        fs.moveSync(srcPath, destPath);
    }
    copy(srcPath, destPath) {
        return fs.copy(srcPath, destPath);
    }
    copySync(srcPath, destPath) {
        fs.copySync(srcPath, destPath);
    }
    fileExists(filePath) {
        return fs.fileExists(filePath);
    }
    fileExistsSync(filePath) {
        return fs.fileExistsSync(filePath);
    }
    directoryExists(dirPath) {
        return fs.directoryExists(dirPath);
    }
    directoryExistsSync(dirPath) {
        return fs.directoryExistsSync(dirPath);
    }
    realpathSync(path) {
        return fs.realpathSync(path);
    }
    getCurrentDirectory() {
        return FileUtils.standardizeSlashes(fs.getCurrentDirectory());
    }
    glob(patterns) {
        return fs.glob(backSlashesToForward(patterns));
    }
    globSync(patterns) {
        return fs.globSync(backSlashesToForward(patterns));
    }
    isCaseSensitive() {
        return fs.isCaseSensitive();
    }
    getDirectoryNotFoundErrorIfNecessary(err, path) {
        return FileUtils.isNotExistsError(err) ? new exports.errors.DirectoryNotFoundError(FileUtils.getStandardizedAbsolutePath(this, path)) : err;
    }
    getFileNotFoundErrorIfNecessary(err, path) {
        return FileUtils.isNotExistsError(err) ? new exports.errors.FileNotFoundError(FileUtils.getStandardizedAbsolutePath(this, path)) : err;
    }
}
function backSlashesToForward(patterns) {
    return patterns.map(p => p.replace(/\\/g, "/"));
}

class Directory {
    constructor(path) {
        this.path = path;
        this.operations = [];
        this.inboundOperations = [];
        this.isDeleted = false;
        this.wasEverDeleted = false;
        this.childDirs = new SortedKeyValueArray(item => item.path, LocaleStringComparer.instance);
    }
    getExternalOperations() {
        return [
            ...ArrayUtils.flatten(this.getAncestors().map(a => getMoveCopyOrDeleteOperations(a))).filter(o => isAncestorAffectedOperation(this, o)),
            ...ArrayUtils.flatten([this, ...this.getDescendants()].map(d => getMoveOrCopyOperations(d))).filter(o => !isInternalOperation(this, o)),
        ];
        function isInternalOperation(thisDir, operation) {
            return operation.oldDir.isDescendantOrEqual(thisDir) && operation.newDir.isDescendantOrEqual(thisDir);
        }
        function isAncestorAffectedOperation(thisDir, operation) {
            switch (operation.kind) {
                case "move":
                case "copy":
                    return thisDir.isDescendantOrEqual(operation.oldDir) || thisDir.isDescendantOrEqual(operation.newDir);
                case "deleteDir":
                    return thisDir.isDescendantOrEqual(operation.dir);
                default:
                    return exports.errors.throwNotImplementedForNeverValueError(operation);
            }
        }
        function getMoveOrCopyOperations(dir) {
            return dir.operations.filter(o => o.kind === "move" || o.kind === "copy");
        }
        function getMoveCopyOrDeleteOperations(dir) {
            return dir.operations.filter(o => o.kind === "move" || o.kind === "deleteDir" || o.kind === "copy");
        }
    }
    isDescendantOrEqual(directory) {
        return this.isDescendant(directory) || this === directory;
    }
    isDescendant(directory) {
        return FileUtils.pathStartsWith(this.path, directory.path);
    }
    getIsDeleted() {
        return this.isDeleted;
    }
    getWasEverDeleted() {
        if (this.wasEverDeleted)
            return true;
        for (const ancestor of this.getAncestorsIterator()) {
            if (ancestor.wasEverDeleted)
                return true;
        }
        return false;
    }
    setIsDeleted(isDeleted) {
        if (this.isDeleted === isDeleted)
            return;
        if (isDeleted) {
            this.wasEverDeleted = true;
            for (const child of this.childDirs.entries())
                child.setIsDeleted(true);
        }
        else {
            if (this.parent != null)
                this.parent.setIsDeleted(false);
        }
        this.isDeleted = isDeleted;
    }
    getParent() {
        return this.parent;
    }
    setParent(parent) {
        if (this.parent != null)
            throw new exports.errors.InvalidOperationError("For some reason, a parent was being set when the directory already had a parent. Please open an issue.");
        this.parent = parent;
        parent.childDirs.set(this);
        if (parent.isDeleted && !this.isDeleted)
            parent.setIsDeleted(false);
    }
    removeParent() {
        const parent = this.parent;
        if (parent == null)
            return;
        parent.childDirs.removeByValue(this);
        this.parent = undefined;
    }
    getAncestors() {
        return Array.from(this.getAncestorsIterator());
    }
    *getAncestorsIterator() {
        let parent = this.parent;
        while (parent != null) {
            yield parent;
            parent = parent.parent;
        }
    }
    *getChildrenPathsIterator() {
        for (const childDir of this.childDirs.entries())
            yield childDir.path;
    }
    getDescendants() {
        const descendants = [];
        for (const child of this.childDirs.entries()) {
            descendants.push(child);
            descendants.push(...child.getDescendants());
        }
        return descendants;
    }
    isFileQueuedForDelete(filePath) {
        return this.hasOperation(operation => operation.kind === "deleteFile" && operation.filePath === filePath);
    }
    hasOperation(operationMatches) {
        for (const operation of this.operations) {
            if (operationMatches(operation))
                return true;
        }
        return false;
    }
    dequeueFileDelete(filePath) {
        this.removeMatchingOperations(operation => operation.kind === "deleteFile" && operation.filePath === filePath);
    }
    dequeueDirDelete(dirPath) {
        this.removeMatchingOperations(operation => operation.kind === "deleteDir" && operation.dir.path === dirPath);
    }
    isRootDir() {
        return FileUtils.isRootDirPath(this.path);
    }
    removeMatchingOperations(operationMatches) {
        ArrayUtils.removeAll(this.operations, operationMatches);
    }
}
class TransactionalFileSystem {
    constructor(fileSystem) {
        this.fileSystem = fileSystem;
        this.directories = new KeyValueCache();
        this.operationIndex = 0;
        this.pathCasingMaintainer = new PathCasingMaintainer(fileSystem);
    }
    queueFileDelete(filePath) {
        const parentDir = this.getOrCreateParentDirectory(filePath);
        parentDir.operations.push({
            kind: "deleteFile",
            index: this.getNextOperationIndex(),
            filePath,
        });
        this.pathCasingMaintainer.removePath(filePath);
    }
    removeFileDelete(filePath) {
        this.getOrCreateParentDirectory(filePath).dequeueFileDelete(filePath);
    }
    queueMkdir(dirPath) {
        const dir = this.getOrCreateDirectory(dirPath);
        dir.setIsDeleted(false);
        const parentDir = this.getOrCreateParentDirectory(dirPath);
        parentDir.operations.push({
            kind: "mkdir",
            index: this.getNextOperationIndex(),
            dir,
        });
    }
    queueDirectoryDelete(dirPath) {
        const dir = this.getOrCreateDirectory(dirPath);
        dir.setIsDeleted(true);
        const parentDir = this.getOrCreateParentDirectory(dirPath);
        parentDir.operations.push({
            kind: "deleteDir",
            index: this.getNextOperationIndex(),
            dir,
        });
        this.pathCasingMaintainer.removePath(dirPath);
    }
    queueMoveDirectory(srcPath, destPath) {
        const parentDir = this.getOrCreateParentDirectory(srcPath);
        const moveDir = this.getOrCreateDirectory(srcPath);
        const destinationDir = this.getOrCreateDirectory(destPath);
        const moveOperation = {
            kind: "move",
            index: this.getNextOperationIndex(),
            oldDir: moveDir,
            newDir: destinationDir,
        };
        parentDir.operations.push(moveOperation);
        (destinationDir.getParent() || destinationDir).inboundOperations.push(moveOperation);
        moveDir.setIsDeleted(true);
        this.pathCasingMaintainer.removePath(srcPath);
    }
    queueCopyDirectory(srcPath, destPath) {
        const parentDir = this.getOrCreateParentDirectory(srcPath);
        const copyDir = this.getOrCreateDirectory(srcPath);
        const destinationDir = this.getOrCreateDirectory(destPath);
        const copyOperation = {
            kind: "copy",
            index: this.getNextOperationIndex(),
            oldDir: copyDir,
            newDir: destinationDir,
        };
        parentDir.operations.push(copyOperation);
        (destinationDir.getParent() || destinationDir).inboundOperations.push(copyOperation);
    }
    flush() {
        return __awaiter(this, void 0, void 0, function* () {
            const operations = this.getAndClearOperations();
            for (const operation of operations)
                yield this.executeOperation(operation);
        });
    }
    flushSync() {
        for (const operation of this.getAndClearOperations())
            this.executeOperationSync(operation);
    }
    saveForDirectory(dirPath) {
        return __awaiter(this, void 0, void 0, function* () {
            const dir = this.getOrCreateDirectory(dirPath);
            this.throwIfHasExternalOperations(dir, "save directory");
            const operations = this.getAndClearOperationsForDir(dir);
            yield this.ensureDirectoryExists(dir);
            for (const operation of operations)
                yield this.executeOperation(operation);
        });
    }
    saveForDirectorySync(dirPath) {
        const dir = this.getOrCreateDirectory(dirPath);
        this.throwIfHasExternalOperations(dir, "save directory");
        this.ensureDirectoryExistsSync(dir);
        for (const operation of this.getAndClearOperationsForDir(dir))
            this.executeOperationSync(operation);
    }
    getAndClearOperationsForDir(dir) {
        const operations = getAndClearParentMkDirOperations(dir.getParent(), dir);
        for (const currentDir of [dir, ...dir.getDescendants()])
            operations.push(...currentDir.operations);
        ArrayUtils.sortByProperty(operations, item => item.index);
        this.removeDirAndSubDirs(dir);
        return operations;
        function getAndClearParentMkDirOperations(parentDir, childDir) {
            if (parentDir == null)
                return [];
            const parentOperations = ArrayUtils.removeAll(parentDir.operations, operation => operation.kind === "mkdir" && operation.dir === childDir);
            return [...parentOperations, ...getAndClearParentMkDirOperations(parentDir.getParent(), parentDir)];
        }
    }
    executeOperation(operation) {
        return __awaiter(this, void 0, void 0, function* () {
            switch (operation.kind) {
                case "deleteDir":
                    yield this.deleteSuppressNotFound(operation.dir.path);
                    break;
                case "deleteFile":
                    yield this.deleteSuppressNotFound(operation.filePath);
                    break;
                case "move":
                    yield this.fileSystem.move(operation.oldDir.path, operation.newDir.path);
                    break;
                case "copy":
                    yield this.fileSystem.copy(operation.oldDir.path, operation.newDir.path);
                    break;
                case "mkdir":
                    yield this.fileSystem.mkdir(operation.dir.path);
                    break;
                default:
                    exports.errors.throwNotImplementedForNeverValueError(operation);
            }
        });
    }
    executeOperationSync(operation) {
        switch (operation.kind) {
            case "deleteDir":
                this.deleteSuppressNotFoundSync(operation.dir.path);
                break;
            case "deleteFile":
                this.deleteSuppressNotFoundSync(operation.filePath);
                break;
            case "move":
                this.fileSystem.moveSync(operation.oldDir.path, operation.newDir.path);
                break;
            case "copy":
                this.fileSystem.copySync(operation.oldDir.path, operation.newDir.path);
                break;
            case "mkdir":
                this.fileSystem.mkdirSync(operation.dir.path);
                break;
            default:
                exports.errors.throwNotImplementedForNeverValueError(operation);
        }
    }
    getAndClearOperations() {
        const operations = [];
        for (const dir of this.directories.getValues())
            operations.push(...dir.operations);
        ArrayUtils.sortByProperty(operations, item => item.index);
        this.directories.clear();
        return operations;
    }
    moveFileImmediately(oldFilePath, newFilePath, fileText) {
        return __awaiter(this, void 0, void 0, function* () {
            this.throwIfHasExternalOperations(this.getOrCreateParentDirectory(oldFilePath), "move file");
            this.throwIfHasExternalOperations(this.getOrCreateParentDirectory(newFilePath), "move file");
            yield this.writeFile(newFilePath, fileText);
            yield this.deleteFileImmediately(oldFilePath);
        });
    }
    moveFileImmediatelySync(oldFilePath, newFilePath, fileText) {
        this.throwIfHasExternalOperations(this.getOrCreateParentDirectory(oldFilePath), "move file");
        this.throwIfHasExternalOperations(this.getOrCreateParentDirectory(newFilePath), "move file");
        this.writeFileSync(newFilePath, fileText);
        this.deleteFileImmediatelySync(oldFilePath);
    }
    deleteFileImmediately(filePath) {
        return __awaiter(this, void 0, void 0, function* () {
            const dir = this.getOrCreateParentDirectory(filePath);
            this.throwIfHasExternalOperations(dir, "delete file");
            dir.dequeueFileDelete(filePath);
            this.pathCasingMaintainer.removePath(filePath);
            try {
                yield this.deleteSuppressNotFound(filePath);
            }
            catch (err) {
                this.queueFileDelete(filePath);
                throw err;
            }
        });
    }
    deleteFileImmediatelySync(filePath) {
        const dir = this.getOrCreateParentDirectory(filePath);
        this.throwIfHasExternalOperations(dir, "delete file");
        dir.dequeueFileDelete(filePath);
        this.pathCasingMaintainer.removePath(filePath);
        try {
            this.deleteSuppressNotFoundSync(filePath);
        }
        catch (err) {
            this.queueFileDelete(filePath);
            throw err;
        }
    }
    copyDirectoryImmediately(srcDirPath, destDirPath) {
        return __awaiter(this, void 0, void 0, function* () {
            const srcDir = this.getOrCreateDirectory(srcDirPath);
            const destDir = this.getOrCreateDirectory(destDirPath);
            this.throwIfHasExternalOperations(srcDir, "copy directory");
            this.throwIfHasExternalOperations(destDir, "copy directory");
            const saveTask = Promise.all([this.saveForDirectory(srcDirPath), this.saveForDirectory(destDirPath)]);
            this.removeDirAndSubDirs(srcDir);
            yield saveTask;
            yield this.fileSystem.copy(srcDirPath, destDirPath);
        });
    }
    copyDirectoryImmediatelySync(srcDirPath, destDirPath) {
        const srcDir = this.getOrCreateDirectory(srcDirPath);
        const destDir = this.getOrCreateDirectory(destDirPath);
        this.throwIfHasExternalOperations(srcDir, "copy directory");
        this.throwIfHasExternalOperations(destDir, "copy directory");
        this.saveForDirectorySync(srcDirPath);
        this.saveForDirectorySync(destDirPath);
        this.removeDirAndSubDirs(srcDir);
        this.fileSystem.copySync(srcDirPath, destDirPath);
    }
    moveDirectoryImmediately(srcDirPath, destDirPath) {
        return __awaiter(this, void 0, void 0, function* () {
            const srcDir = this.getOrCreateDirectory(srcDirPath);
            const destDir = this.getOrCreateDirectory(destDirPath);
            this.throwIfHasExternalOperations(srcDir, "move directory");
            this.throwIfHasExternalOperations(destDir, "move directory");
            const saveTask = Promise.all([this.saveForDirectory(srcDirPath), this.saveForDirectory(destDirPath)]);
            this.removeDirAndSubDirs(srcDir);
            this.pathCasingMaintainer.removePath(srcDirPath);
            yield saveTask;
            yield this.fileSystem.move(srcDirPath, destDirPath);
        });
    }
    moveDirectoryImmediatelySync(srcDirPath, destDirPath) {
        const srcDir = this.getOrCreateDirectory(srcDirPath);
        const destDir = this.getOrCreateDirectory(destDirPath);
        this.throwIfHasExternalOperations(srcDir, "move directory");
        this.throwIfHasExternalOperations(destDir, "move directory");
        this.saveForDirectorySync(srcDirPath);
        this.saveForDirectorySync(destDirPath);
        this.removeDirAndSubDirs(srcDir);
        this.pathCasingMaintainer.removePath(srcDirPath);
        this.fileSystem.moveSync(srcDirPath, destDirPath);
    }
    deleteDirectoryImmediately(dirPath) {
        return __awaiter(this, void 0, void 0, function* () {
            const dir = this.getOrCreateDirectory(dirPath);
            this.throwIfHasExternalOperations(dir, "delete");
            this.removeDirAndSubDirs(dir);
            this.pathCasingMaintainer.removePath(dirPath);
            try {
                yield this.deleteSuppressNotFound(dirPath);
            }
            catch (err) {
                this.addBackDirAndSubDirs(dir);
                this.queueDirectoryDelete(dirPath);
            }
        });
    }
    clearDirectoryImmediately(dirPath) {
        return __awaiter(this, void 0, void 0, function* () {
            yield this.deleteDirectoryImmediately(dirPath);
            this.getOrCreateDirectory(dirPath).setIsDeleted(false);
            yield this.fileSystem.mkdir(dirPath);
        });
    }
    clearDirectoryImmediatelySync(dirPath) {
        this.deleteDirectoryImmediatelySync(dirPath);
        this.getOrCreateDirectory(dirPath).setIsDeleted(false);
        this.fileSystem.mkdirSync(dirPath);
    }
    deleteDirectoryImmediatelySync(dirPath) {
        const dir = this.getOrCreateDirectory(dirPath);
        this.throwIfHasExternalOperations(dir, "delete");
        this.removeDirAndSubDirs(dir);
        this.pathCasingMaintainer.removePath(dirPath);
        try {
            this.deleteSuppressNotFoundSync(dirPath);
        }
        catch (err) {
            this.addBackDirAndSubDirs(dir);
            this.queueDirectoryDelete(dirPath);
        }
    }
    deleteSuppressNotFound(path) {
        return __awaiter(this, void 0, void 0, function* () {
            try {
                yield this.fileSystem.delete(path);
            }
            catch (err) {
                if (!FileUtils.isNotExistsError(err))
                    throw err;
            }
        });
    }
    deleteSuppressNotFoundSync(path) {
        try {
            this.fileSystem.deleteSync(path);
        }
        catch (err) {
            if (!FileUtils.isNotExistsError(err))
                throw err;
        }
    }
    fileExists(filePath) {
        if (this._fileDeletedInMemory(filePath))
            return false;
        return this.fileSystem.fileExists(filePath);
    }
    fileExistsSync(filePath) {
        if (this._fileDeletedInMemory(filePath))
            return false;
        return this.fileSystem.fileExistsSync(filePath);
    }
    _fileDeletedInMemory(filePath) {
        if (this.isPathQueuedForDeletion(filePath))
            return true;
        const parentDir = this.getParentDirectoryIfExists(filePath);
        if (parentDir != null && parentDir.getWasEverDeleted())
            return true;
        return false;
    }
    directoryExistsSync(dirPath) {
        if (this.isPathQueuedForDeletion(dirPath))
            return false;
        if (this.isPathDirectoryInQueueThatExists(dirPath))
            return true;
        const dir = this.getDirectoryIfExists(dirPath);
        if (dir != null && dir.getWasEverDeleted())
            return false;
        return this.fileSystem.directoryExistsSync(dirPath);
    }
    readFileSync(filePath, encoding) {
        this._verifyCanReadFile(filePath);
        return this.fileSystem.readFileSync(filePath, encoding);
    }
    readFile(filePath, encoding) {
        this._verifyCanReadFile(filePath);
        return this.fileSystem.readFile(filePath, encoding);
    }
    _verifyCanReadFile(filePath) {
        if (this.isPathQueuedForDeletion(filePath))
            throw new exports.errors.InvalidOperationError(`Cannot read file at ${filePath} when it is queued for deletion.`);
        if (this.getOrCreateParentDirectory(filePath).getWasEverDeleted())
            throw new exports.errors.InvalidOperationError(`Cannot read file at ${filePath} because one of its ancestor directories was once deleted or moved.`);
    }
    readDirSync(dirPath) {
        const dir = this.getOrCreateDirectory(dirPath);
        if (dir.getIsDeleted())
            throw new exports.errors.InvalidOperationError(`Cannot read directory at ${dirPath} when it is queued for deletion.`);
        if (dir.getWasEverDeleted())
            throw new exports.errors.InvalidOperationError(`Cannot read directory at ${dirPath} because one of its ancestor directories was once deleted or moved.`);
        const uniqueDirPaths = new Set(dir.getChildrenPathsIterator());
        for (const childDirOrFilePath of this.fileSystem.readDirSync(dirPath)) {
            const standardizedChildDirOrFilePath = this.getStandardizedAbsolutePath(childDirOrFilePath);
            if (!this.isPathQueuedForDeletion(standardizedChildDirOrFilePath))
                uniqueDirPaths.add(standardizedChildDirOrFilePath);
        }
        return Array.from(uniqueDirPaths).sort();
    }
    glob(patterns) {
        return __asyncGenerator(this, arguments, function* glob_1() {
            const filePaths = yield __await(this.fileSystem.glob(patterns));
            for (const filePath of filePaths) {
                const standardizedFilePath = this.getStandardizedAbsolutePath(filePath);
                if (!this.isPathQueuedForDeletion(standardizedFilePath))
                    yield yield __await(standardizedFilePath);
            }
        });
    }
    *globSync(patterns) {
        const filePaths = this.fileSystem.globSync(patterns);
        for (const filePath of filePaths) {
            const standardizedFilePath = this.getStandardizedAbsolutePath(filePath);
            if (!this.isPathQueuedForDeletion(standardizedFilePath))
                yield standardizedFilePath;
        }
    }
    getFileSystem() {
        return this.fileSystem;
    }
    getCurrentDirectory() {
        return this.getStandardizedAbsolutePath(this.fileSystem.getCurrentDirectory());
    }
    getDirectories(dirPath) {
        return this.readDirSync(dirPath).filter(path => this.directoryExistsSync(path));
    }
    realpathSync(path) {
        try {
            return this.getStandardizedAbsolutePath(this.fileSystem.realpathSync(path));
        }
        catch (_a) {
            return path;
        }
    }
    getStandardizedAbsolutePath(fileOrDirPath, relativeBase) {
        const standardizedFileOrDirPath = FileUtils.getStandardizedAbsolutePath(this.fileSystem, fileOrDirPath, relativeBase);
        return this.pathCasingMaintainer.getPath(standardizedFileOrDirPath);
    }
    readFileOrNotExists(filePath, encoding) {
        if (this.isPathQueuedForDeletion(filePath))
            return false;
        return FileUtils.readFileOrNotExists(this.fileSystem, filePath, encoding);
    }
    readFileOrNotExistsSync(filePath, encoding) {
        if (this.isPathQueuedForDeletion(filePath))
            return false;
        return FileUtils.readFileOrNotExistsSync(this.fileSystem, filePath, encoding);
    }
    writeFile(filePath, fileText) {
        return __awaiter(this, void 0, void 0, function* () {
            const parentDir = this.getOrCreateParentDirectory(filePath);
            this.throwIfHasExternalOperations(parentDir, "write file");
            parentDir.dequeueFileDelete(filePath);
            yield this.ensureDirectoryExists(parentDir);
            yield this.fileSystem.writeFile(filePath, fileText);
        });
    }
    writeFileSync(filePath, fileText) {
        const parentDir = this.getOrCreateParentDirectory(filePath);
        this.throwIfHasExternalOperations(parentDir, "write file");
        parentDir.dequeueFileDelete(filePath);
        this.ensureDirectoryExistsSync(parentDir);
        this.fileSystem.writeFileSync(filePath, fileText);
    }
    isPathDirectoryInQueueThatExists(path) {
        const pathDir = this.getDirectoryIfExists(path);
        return pathDir == null ? false : !pathDir.getIsDeleted();
    }
    isPathQueuedForDeletion(path) {
        const pathDir = this.getDirectoryIfExists(path);
        if (pathDir != null)
            return pathDir.getIsDeleted();
        const parentDir = this.getParentDirectoryIfExists(path);
        if (parentDir == null)
            return false;
        return parentDir.isFileQueuedForDelete(path) || parentDir.getIsDeleted();
    }
    removeDirAndSubDirs(dir) {
        const originalParent = dir.getParent();
        dir.removeParent();
        for (const dirToRemove of [dir, ...dir.getDescendants()])
            this.directories.removeByKey(dirToRemove.path);
        if (originalParent != null)
            originalParent.dequeueDirDelete(dir.path);
    }
    addBackDirAndSubDirs(dir) {
        for (const dirToAdd of [dir, ...dir.getDescendants()])
            this.directories.set(dirToAdd.path, dirToAdd);
        if (!dir.isRootDir())
            dir.setParent(this.getOrCreateParentDirectory(dir.path));
    }
    getNextOperationIndex() {
        return this.operationIndex++;
    }
    getParentDirectoryIfExists(filePath) {
        return this.getDirectoryIfExists(FileUtils.getDirPath(filePath));
    }
    getOrCreateParentDirectory(filePath) {
        return this.getOrCreateDirectory(FileUtils.getDirPath(filePath));
    }
    getDirectoryIfExists(dirPath) {
        return this.directories.get(dirPath);
    }
    getOrCreateDirectory(dirPath) {
        let dir = this.directories.get(dirPath);
        if (dir != null)
            return dir;
        const getOrCreateDir = (creatingDirPath) => this.directories.getOrCreate(creatingDirPath, () => new Directory(creatingDirPath));
        dir = getOrCreateDir(dirPath);
        let currentDirPath = dirPath;
        let currentDir = dir;
        while (!FileUtils.isRootDirPath(currentDirPath)) {
            const nextDirPath = FileUtils.getDirPath(currentDirPath);
            const hadNextDir = this.directories.has(nextDirPath);
            const nextDir = getOrCreateDir(nextDirPath);
            currentDir.setParent(nextDir);
            if (hadNextDir)
                return dir;
            currentDir = nextDir;
            currentDirPath = nextDirPath;
        }
        return dir;
    }
    throwIfHasExternalOperations(dir, commandName) {
        const operations = dir.getExternalOperations();
        if (operations.length === 0)
            return;
        throw new exports.errors.InvalidOperationError(getErrorText());
        function getErrorText() {
            let hasCopy = false;
            let errorText = `Cannot execute immediate operation '${commandName}' because of the following external operations:\n`;
            for (const operation of operations) {
                if (operation.kind === "move")
                    errorText += `\n* Move: ${operation.oldDir.path} --> ${operation.newDir.path}`;
                else if (operation.kind === "copy") {
                    errorText += `\n* Copy: ${operation.oldDir.path} --> ${operation.newDir.path}`;
                    hasCopy = true;
                }
                else if (operation.kind === "deleteDir")
                    errorText += `\n* Delete: ${operation.dir.path}`;
                else {
                    errorText += `\n* Unknown operation: Please report this as a bug.`;
                }
            }
            if (hasCopy)
                errorText += "\n\nNote: Copy operations can be removed from external operations by setting `includeUntrackedFiles` to `false` when copying.";
            return errorText;
        }
    }
    ensureDirectoryExists(dir) {
        return __awaiter(this, void 0, void 0, function* () {
            if (dir.isRootDir())
                return;
            this.removeMkDirOperationsForDir(dir);
            yield this.fileSystem.mkdir(dir.path);
        });
    }
    ensureDirectoryExistsSync(dir) {
        if (dir.isRootDir())
            return;
        this.removeMkDirOperationsForDir(dir);
        this.fileSystem.mkdirSync(dir.path);
    }
    removeMkDirOperationsForDir(dir) {
        const parentDir = dir.getParent();
        if (parentDir != null) {
            ArrayUtils.removeAll(parentDir.operations, operation => operation.kind === "mkdir" && operation.dir === dir);
            this.removeMkDirOperationsForDir(parentDir);
        }
    }
}
class PathCasingMaintainer {
    constructor(fileSystem) {
        if (fileSystem.isCaseSensitive != null && !fileSystem.isCaseSensitive())
            this.caseInsensitiveMappings = new Map();
    }
    getPath(fileOrDirPath) {
        if (this.caseInsensitiveMappings == null)
            return fileOrDirPath;
        const key = fileOrDirPath.toLowerCase();
        let path = this.caseInsensitiveMappings.get(key);
        if (path == null) {
            path = fileOrDirPath;
            this.caseInsensitiveMappings.set(key, path);
        }
        return path;
    }
    removePath(dirPath) {
        if (this.caseInsensitiveMappings == null)
            return;
        this.caseInsensitiveMappings.delete(dirPath.toLowerCase());
    }
}

function createModuleResolutionHost(options) {
    const { transactionalFileSystem, sourceFileContainer, getEncoding } = options;
    return {
        directoryExists: dirName => {
            const dirPath = transactionalFileSystem.getStandardizedAbsolutePath(dirName);
            if (sourceFileContainer.containsDirectoryAtPath(dirPath))
                return true;
            return transactionalFileSystem.directoryExistsSync(dirPath);
        },
        fileExists: fileName => {
            const filePath = transactionalFileSystem.getStandardizedAbsolutePath(fileName);
            if (sourceFileContainer.containsSourceFileAtPath(filePath))
                return true;
            return transactionalFileSystem.fileExistsSync(filePath);
        },
        readFile: fileName => {
            const filePath = transactionalFileSystem.getStandardizedAbsolutePath(fileName);
            const sourceFile = sourceFileContainer.getSourceFileFromCacheFromFilePath(filePath);
            if (sourceFile != null)
                return sourceFile.getFullText();
            try {
                return transactionalFileSystem.readFileSync(filePath, getEncoding());
            }
            catch (err) {
                if (FileUtils.isNotExistsError(err))
                    return undefined;
                throw err;
            }
        },
        getCurrentDirectory: () => transactionalFileSystem.getCurrentDirectory(),
        getDirectories: dirName => {
            const dirPath = transactionalFileSystem.getStandardizedAbsolutePath(dirName);
            const dirs = new Set(transactionalFileSystem.readDirSync(dirPath));
            for (const childDirPath of sourceFileContainer.getChildDirectoriesOfDirectory(dirPath))
                dirs.add(childDirPath);
            return Array.from(dirs);
        },
        realpath: path => transactionalFileSystem.realpathSync(transactionalFileSystem.getStandardizedAbsolutePath(path)),
    };
}

class DocumentRegistry {
    constructor(transactionalFileSystem) {
        this.transactionalFileSystem = transactionalFileSystem;
        this.sourceFileCacheByFilePath = new Map();
    }
    createOrUpdateSourceFile(fileName, compilationSettings, scriptSnapshot, scriptKind) {
        let sourceFile = this.sourceFileCacheByFilePath.get(fileName);
        if (sourceFile == null)
            sourceFile = this.updateSourceFile(fileName, compilationSettings, scriptSnapshot, DocumentRegistry.initialVersion, scriptKind);
        else
            sourceFile = this.updateSourceFile(fileName, compilationSettings, scriptSnapshot, this.getNextSourceFileVersion(sourceFile), scriptKind);
        return sourceFile;
    }
    removeSourceFile(fileName) {
        this.sourceFileCacheByFilePath.delete(fileName);
    }
    acquireDocument(fileName, compilationSettings, scriptSnapshot, version, scriptKind) {
        const standardizedFilePath = this.transactionalFileSystem.getStandardizedAbsolutePath(fileName);
        let sourceFile = this.sourceFileCacheByFilePath.get(standardizedFilePath);
        if (sourceFile == null || this.getSourceFileVersion(sourceFile) !== version)
            sourceFile = this.updateSourceFile(standardizedFilePath, compilationSettings, scriptSnapshot, version, scriptKind);
        return sourceFile;
    }
    acquireDocumentWithKey(fileName, path, compilationSettings, key, scriptSnapshot, version, scriptKind) {
        return this.acquireDocument(fileName, compilationSettings, scriptSnapshot, version, scriptKind);
    }
    updateDocument(fileName, compilationSettings, scriptSnapshot, version, scriptKind) {
        return this.acquireDocument(fileName, compilationSettings, scriptSnapshot, version, scriptKind);
    }
    updateDocumentWithKey(fileName, path, compilationSettings, key, scriptSnapshot, version, scriptKind) {
        return this.updateDocument(fileName, compilationSettings, scriptSnapshot, version, scriptKind);
    }
    getKeyForCompilationSettings(settings) {
        return "defaultKey";
    }
    releaseDocument(fileName, compilationSettings) {
    }
    releaseDocumentWithKey(path, key) {
    }
    reportStats() {
        throw new exports.errors.NotImplementedError();
    }
    getSourceFileVersion(sourceFile) {
        return sourceFile.version || "0";
    }
    getNextSourceFileVersion(sourceFile) {
        const currentVersion = parseInt(this.getSourceFileVersion(sourceFile), 10) || 0;
        return (currentVersion + 1).toString();
    }
    updateSourceFile(fileName, compilationSettings, scriptSnapshot, version, scriptKind) {
        const newSourceFile = createCompilerSourceFile(fileName, scriptSnapshot, compilationSettings.target, version, true, scriptKind);
        this.sourceFileCacheByFilePath.set(fileName, newSourceFile);
        return newSourceFile;
    }
}
DocumentRegistry.initialVersion = "0";

const denoResolutionHostFactory = (moduleResolutionHost, getCompilerOptions) => {
    return {
        resolveModuleNames: (moduleNames, containingFile) => {
            const compilerOptions = getCompilerOptions();
            const resolvedModules = [];
            for (const moduleName of moduleNames.map(removeTsExtension)) {
                const result = ts__namespace.resolveModuleName(moduleName, containingFile, compilerOptions, moduleResolutionHost);
                if (result.resolvedModule)
                    resolvedModules.push(result.resolvedModule);
            }
            return resolvedModules;
        },
    };
    function removeTsExtension(moduleName) {
        if (moduleName.slice(-3).toLowerCase() === ".ts")
            return moduleName.slice(0, -3);
        return moduleName;
    }
};
const ResolutionHosts = {
    deno: denoResolutionHostFactory,
};

function Memoize(target, propertyName, descriptor) {
    if (descriptor.value != null)
        descriptor.value = getNewFunction(descriptor.value);
    else if (descriptor.get != null)
        descriptor.get = getNewFunction(descriptor.get);
    else
        throw new Error("Only put a Memoize decorator on a method or get accessor.");
}
const weakMap = new WeakMap();
let counter = 0;
function getNewFunction(originalFunction) {
    const identifier = counter++;
    function decorator(...args) {
        let propertyValues = weakMap.get(this);
        if (propertyValues == null) {
            propertyValues = new Map();
            weakMap.set(this, propertyValues);
        }
        let propName = `__memoized_value_${identifier}`;
        if (arguments.length > 0)
            propName += "_" + JSON.stringify(args);
        let returnedValue;
        if (propertyValues.has(propName))
            returnedValue = propertyValues.get(propName);
        else {
            returnedValue = originalFunction.apply(this, args);
            propertyValues.set(propName, returnedValue);
        }
        return returnedValue;
    }
    return decorator;
}

class SettingsContainer {
    constructor(defaultSettings) {
        this._defaultSettings = ObjectUtils.assign({}, defaultSettings);
        this._settings = defaultSettings;
    }
    reset() {
        this._settings = ObjectUtils.assign({}, this._defaultSettings);
        this._fireModified();
    }
    get() {
        return ObjectUtils.assign({}, this._settings);
    }
    set(settings) {
        ObjectUtils.assign(this._settings, settings);
        this._fireModified();
    }
    onModified(action) {
        if (this._modifiedEventContainer == null)
            this._modifiedEventContainer = new EventContainer();
        this._modifiedEventContainer.subscribe(action);
    }
    _fireModified() {
        if (this._modifiedEventContainer != null)
            this._modifiedEventContainer.fire(undefined);
    }
}

class CompilerOptionsContainer extends SettingsContainer {
    constructor() {
        super({});
    }
    set(settings) {
        super.set(settings);
    }
    getEncoding() {
        return this._settings.charset || "utf-8";
    }
}

function readDirectory(fileSystemWrapper, useCaseSensitiveFileNames, rootDir, extensions, excludes, includes, depth) {
    const currentDir = fileSystemWrapper.getCurrentDirectory();
    const directories = [];
    const regexFlag = useCaseSensitiveFileNames ? "" : "i";
    const patterns = getFileMatcherPatterns(rootDir, excludes || [], includes, useCaseSensitiveFileNames, currentDir);
    const includeDirectoryRegex = patterns.includeDirectoryPattern && new RegExp(patterns.includeDirectoryPattern, regexFlag);
    const excludeRegex = patterns.excludePattern && new RegExp(patterns.excludePattern, regexFlag);
    return {
        files: matchFiles(rootDir, extensions, excludes || [], includes, useCaseSensitiveFileNames, currentDir, depth, path => {
            const includeDir = dirPathMatches(path);
            const standardizedPath = fileSystemWrapper.getStandardizedAbsolutePath(path);
            if (includeDir)
                directories.push(standardizedPath);
            return getFileSystemEntries(standardizedPath, fileSystemWrapper);
        }, path => fileSystemWrapper.realpathSync(fileSystemWrapper.getStandardizedAbsolutePath(path)), path => fileSystemWrapper.directoryExistsSync(fileSystemWrapper.getStandardizedAbsolutePath(path))),
        directories,
    };
    function dirPathMatches(absoluteName) {
        if (absoluteName[absoluteName.length - 1] !== "/")
            absoluteName += "/";
        return (!includeDirectoryRegex || includeDirectoryRegex.test(absoluteName))
            && (!excludeRegex || !excludeRegex.test(absoluteName));
    }
}
function getFileSystemEntries(path, fileSystemWrapper) {
    const files = [];
    const directories = [];
    try {
        const entries = fileSystemWrapper.readDirSync(path);
        for (const entry of entries) {
            if (fileSystemWrapper.fileExistsSync(entry))
                files.push(entry);
            else
                directories.push(entry);
        }
    }
    catch (err) {
        if (!FileUtils.isNotExistsError(err))
            throw err;
    }
    return { files, directories };
}

function getTsParseConfigHost(fileSystemWrapper, options) {
    const directories = [];
    const useCaseSensitiveFileNames = false;
    const host = {
        useCaseSensitiveFileNames,
        readDirectory: (rootDir, extensions, excludes, includes, depth) => {
            const result = readDirectory(fileSystemWrapper, useCaseSensitiveFileNames, rootDir, extensions, excludes, includes, depth);
            directories.push(...result.directories);
            return result.files;
        },
        fileExists: path => fileSystemWrapper.fileExistsSync(fileSystemWrapper.getStandardizedAbsolutePath(path)),
        readFile: path => fileSystemWrapper.readFileSync(fileSystemWrapper.getStandardizedAbsolutePath(path), options.encoding),
        getDirectories: () => [...directories],
        clearDirectories: () => directories.length = 0,
    };
    return host;
}

class TsConfigResolver {
    constructor(fileSystem, tsConfigFilePath, encoding) {
        this.fileSystem = fileSystem;
        this.encoding = encoding;
        this.host = getTsParseConfigHost(fileSystem, { encoding });
        this.tsConfigFilePath = fileSystem.getStandardizedAbsolutePath(tsConfigFilePath);
        this.tsConfigDirPath = FileUtils.getDirPath(this.tsConfigFilePath);
    }
    getCompilerOptions() {
        return this.parseJsonConfigFileContent().options;
    }
    getErrors() {
        return this.parseJsonConfigFileContent().errors || [];
    }
    getPaths(compilerOptions) {
        const files = new Set();
        const { fileSystem } = this;
        const directories = new Set();
        compilerOptions = compilerOptions || this.getCompilerOptions();
        const configFileContent = this.parseJsonConfigFileContent();
        for (let dirName of configFileContent.directories) {
            const dirPath = fileSystem.getStandardizedAbsolutePath(dirName);
            if (fileSystem.directoryExistsSync(dirPath))
                directories.add(dirPath);
        }
        for (let fileName of configFileContent.fileNames) {
            const filePath = fileSystem.getStandardizedAbsolutePath(fileName);
            const parentDirPath = FileUtils.getDirPath(filePath);
            if (fileSystem.fileExistsSync(filePath)) {
                directories.add(parentDirPath);
                files.add(filePath);
            }
        }
        return {
            filePaths: Array.from(files.values()),
            directoryPaths: Array.from(directories.values()),
        };
    }
    parseJsonConfigFileContent() {
        this.host.clearDirectories();
        const result = ts__namespace.parseJsonConfigFileContent(this.getTsConfigFileJson(), this.host, this.tsConfigDirPath, undefined, this.tsConfigFilePath);
        return Object.assign(Object.assign({}, result), { directories: this.host.getDirectories() });
    }
    getTsConfigFileJson() {
        const text = this.fileSystem.readFileSync(this.tsConfigFilePath, this.encoding);
        const parseResult = ts__namespace.parseConfigFileTextToJson(this.tsConfigFilePath, text);
        if (parseResult.error != null)
            throw new Error(parseResult.error.messageText.toString());
        return parseResult.config;
    }
}
__decorate([
    Memoize
], TsConfigResolver.prototype, "getCompilerOptions", null);
__decorate([
    Memoize
], TsConfigResolver.prototype, "getErrors", null);
__decorate([
    Memoize
], TsConfigResolver.prototype, "getPaths", null);
__decorate([
    Memoize
], TsConfigResolver.prototype, "parseJsonConfigFileContent", null);
__decorate([
    Memoize
], TsConfigResolver.prototype, "getTsConfigFileJson", null);

function getCompilerOptionsFromTsConfig(filePath, options = {}) {
    const fileSystemWrapper = new TransactionalFileSystem(options.fileSystem || new RealFileSystemHost());
    const tsConfigResolver = new TsConfigResolver(fileSystemWrapper, fileSystemWrapper.getStandardizedAbsolutePath(filePath), options.encoding || "utf-8");
    return {
        options: tsConfigResolver.getCompilerOptions(),
        errors: tsConfigResolver.getErrors(),
    };
}

Object.defineProperty(exports, 'DiagnosticCategory', {
    enumerable: true,
    get: function () { return ts.DiagnosticCategory; }
});
Object.defineProperty(exports, 'EmitHint', {
    enumerable: true,
    get: function () { return ts.EmitHint; }
});
Object.defineProperty(exports, 'LanguageVariant', {
    enumerable: true,
    get: function () { return ts.LanguageVariant; }
});
Object.defineProperty(exports, 'ModuleKind', {
    enumerable: true,
    get: function () { return ts.ModuleKind; }
});
Object.defineProperty(exports, 'ModuleResolutionKind', {
    enumerable: true,
    get: function () { return ts.ModuleResolutionKind; }
});
Object.defineProperty(exports, 'NewLineKind', {
    enumerable: true,
    get: function () { return ts.NewLineKind; }
});
Object.defineProperty(exports, 'NodeFlags', {
    enumerable: true,
    get: function () { return ts.NodeFlags; }
});
Object.defineProperty(exports, 'ObjectFlags', {
    enumerable: true,
    get: function () { return ts.ObjectFlags; }
});
Object.defineProperty(exports, 'ScriptKind', {
    enumerable: true,
    get: function () { return ts.ScriptKind; }
});
Object.defineProperty(exports, 'ScriptTarget', {
    enumerable: true,
    get: function () { return ts.ScriptTarget; }
});
Object.defineProperty(exports, 'SymbolFlags', {
    enumerable: true,
    get: function () { return ts.SymbolFlags; }
});
Object.defineProperty(exports, 'SyntaxKind', {
    enumerable: true,
    get: function () { return ts.SyntaxKind; }
});
Object.defineProperty(exports, 'TypeFlags', {
    enumerable: true,
    get: function () { return ts.TypeFlags; }
});
Object.defineProperty(exports, 'TypeFormatFlags', {
    enumerable: true,
    get: function () { return ts.TypeFormatFlags; }
});
exports.ts = ts__namespace;
exports.ArrayUtils = ArrayUtils;
exports.ComparerToStoredComparer = ComparerToStoredComparer;
exports.CompilerOptionsContainer = CompilerOptionsContainer;
exports.DocumentRegistry = DocumentRegistry;
exports.EventContainer = EventContainer;
exports.FileUtils = FileUtils;
exports.InMemoryFileSystemHost = InMemoryFileSystemHost;
exports.IterableUtils = IterableUtils;
exports.KeyValueCache = KeyValueCache;
exports.LocaleStringComparer = LocaleStringComparer;
exports.Memoize = Memoize;
exports.ObjectUtils = ObjectUtils;
exports.PropertyComparer = PropertyComparer;
exports.PropertyStoredComparer = PropertyStoredComparer;
exports.RealFileSystemHost = RealFileSystemHost;
exports.ResolutionHosts = ResolutionHosts;
exports.SettingsContainer = SettingsContainer;
exports.SortedKeyValueArray = SortedKeyValueArray;
exports.StringUtils = StringUtils;
exports.TransactionalFileSystem = TransactionalFileSystem;
exports.TsConfigResolver = TsConfigResolver;
exports.WeakCache = WeakCache;
exports.createDocumentCache = createDocumentCache;
exports.createHosts = createHosts;
exports.createModuleResolutionHost = createModuleResolutionHost;
exports.deepClone = deepClone;
exports.getCompilerOptionsFromTsConfig = getCompilerOptionsFromTsConfig;
exports.getEmitModuleResolutionKind = getEmitModuleResolutionKind;
exports.getFileMatcherPatterns = getFileMatcherPatterns;
exports.getLibFiles = getLibFiles;
exports.getSyntaxKindName = getSyntaxKindName;
exports.libFolderInMemoryPath = libFolderInMemoryPath;
exports.matchFiles = matchFiles;
exports.matchGlobs = matchGlobs;
exports.runtime = runtime;
