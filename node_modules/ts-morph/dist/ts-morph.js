'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

var common = require('@ts-morph/common');
var CodeBlockWriter = require('code-block-writer');

function _interopDefaultLegacy (e) { return e && typeof e === 'object' && 'default' in e ? e : { 'default': e }; }

var CodeBlockWriter__default = /*#__PURE__*/_interopDefaultLegacy(CodeBlockWriter);

class AdvancedIterator {
    constructor(iterator) {
        this.iterator = iterator;
        this.buffer = [undefined, undefined, undefined];
        this.bufferIndex = 0;
        this.isDone = false;
        this.nextCount = 0;
        this.advance();
    }
    get done() {
        return this.isDone;
    }
    get current() {
        if (this.nextCount === 0)
            throw new common.errors.InvalidOperationError("Cannot get the current when the iterator has not been advanced.");
        return this.buffer[this.bufferIndex];
    }
    get previous() {
        if (this.nextCount <= 1)
            throw new common.errors.InvalidOperationError("Cannot get the previous when the iterator has not advanced enough.");
        return this.buffer[(this.bufferIndex + this.buffer.length - 1) % this.buffer.length];
    }
    get peek() {
        if (this.isDone)
            throw new common.errors.InvalidOperationError("Cannot peek at the end of the iterator.");
        return this.buffer[(this.bufferIndex + 1) % this.buffer.length];
    }
    next() {
        if (this.done)
            throw new common.errors.InvalidOperationError("Cannot get the next when at the end of the iterator.");
        const next = this.buffer[this.getNextBufferIndex()];
        this.advance();
        this.nextCount++;
        return next;
    }
    *rest() {
        while (!this.done)
            yield this.next();
    }
    advance() {
        const next = this.iterator.next();
        this.bufferIndex = this.getNextBufferIndex();
        if (next.done) {
            this.isDone = true;
            return;
        }
        this.buffer[this.getNextBufferIndex()] = next.value;
    }
    getNextBufferIndex() {
        return (this.bufferIndex + 1) % this.buffer.length;
    }
}

const CharCodes = {
    ASTERISK: "*".charCodeAt(0),
    NEWLINE: "\n".charCodeAt(0),
    CARRIAGE_RETURN: "\r".charCodeAt(0),
    SPACE: " ".charCodeAt(0),
    TAB: "\t".charCodeAt(0),
    CLOSE_BRACE: "}".charCodeAt(0),
};

function getNodeByNameOrFindFunction(items, nameOrFindFunc) {
    let findFunc;
    if (typeof nameOrFindFunc === "string")
        findFunc = dec => nodeHasName(dec, nameOrFindFunc);
    else
        findFunc = nameOrFindFunc;
    return items.find(findFunc);
}
function nodeHasName(node, name) {
    if (node.getNameNode == null)
        return false;
    const nameNode = node.getNameNode();
    if (nameNode == null)
        return false;
    if (Node.isArrayBindingPattern(nameNode) || Node.isObjectBindingPattern(nameNode))
        return nameNode.getElements().some(element => nodeHasName(element, name));
    const nodeName = node.getName != null ? node.getName() : nameNode.getText();
    return nodeName === name;
}
function getNotFoundErrorMessageForNameOrFindFunction(findName, nameOrFindFunction) {
    if (typeof nameOrFindFunction === "string")
        return `Expected to find ${findName} named '${nameOrFindFunction}'.`;
    return `Expected to find ${findName} that matched the provided condition.`;
}

function getParentSyntaxList(node, sourceFile) {
    if (node.kind === common.SyntaxKind.EndOfFileToken)
        return undefined;
    const parent = node.parent;
    if (parent == null)
        return undefined;
    const { pos, end } = node;
    for (const child of parent.getChildren(sourceFile)) {
        if (child.pos > end || child === node)
            return undefined;
        if (child.kind === common.SyntaxKind.SyntaxList && child.pos <= pos && child.end >= end)
            return child;
    }
    return undefined;
}

function getSymbolByNameOrFindFunction(items, nameOrFindFunc) {
    let findFunc;
    if (typeof nameOrFindFunc === "string")
        findFunc = dec => dec.getName() === nameOrFindFunc;
    else
        findFunc = nameOrFindFunc;
    return items.find(findFunc);
}

function isNodeAmbientOrInAmbientContext(node) {
    if (checkNodeIsAmbient(node) || node._sourceFile.isDeclarationFile())
        return true;
    for (const ancestor of node._getAncestorsIterator(false)) {
        if (checkNodeIsAmbient(ancestor))
            return true;
    }
    return false;
}
function checkNodeIsAmbient(node) {
    const isThisAmbient = (node.getCombinedModifierFlags() & common.ts.ModifierFlags.Ambient) === common.ts.ModifierFlags.Ambient;
    return isThisAmbient || Node.isInterfaceDeclaration(node) || Node.isTypeAliasDeclaration(node);
}

function isStringKind(kind) {
    switch (kind) {
        case common.SyntaxKind.StringLiteral:
        case common.SyntaxKind.NoSubstitutionTemplateLiteral:
        case common.SyntaxKind.TemplateHead:
        case common.SyntaxKind.TemplateMiddle:
        case common.SyntaxKind.TemplateTail:
            return true;
        default:
            return false;
    }
}

class ModuleUtils {
    constructor() {
    }
    static isModuleSpecifierRelative(text) {
        return text.startsWith("./")
            || text.startsWith("../");
    }
    static getReferencedSourceFileFromSymbol(symbol) {
        const declarations = symbol.getDeclarations();
        if (declarations.length === 0 || declarations[0].getKind() !== common.SyntaxKind.SourceFile)
            return undefined;
        return declarations[0];
    }
}

function printNode(node, sourceFileOrOptions, secondOverloadOptions) {
    var _a, _b;
    const isFirstOverload = sourceFileOrOptions == null || sourceFileOrOptions.kind !== common.SyntaxKind.SourceFile;
    const options = getOptions();
    const sourceFile = getSourceFile();
    const printer = common.ts.createPrinter({
        newLine: (_a = options.newLineKind) !== null && _a !== void 0 ? _a : common.NewLineKind.LineFeed,
        removeComments: options.removeComments || false,
    });
    if (sourceFile == null)
        return printer.printFile(node);
    else
        return printer.printNode((_b = options.emitHint) !== null && _b !== void 0 ? _b : common.EmitHint.Unspecified, node, sourceFile);
    function getSourceFile() {
        if (isFirstOverload) {
            if (node.kind === common.SyntaxKind.SourceFile)
                return undefined;
            const topParent = getNodeSourceFile();
            if (topParent == null) {
                const scriptKind = getScriptKind();
                return common.ts.createSourceFile(`print.${getFileExt(scriptKind)}`, "", common.ScriptTarget.Latest, false, scriptKind);
            }
            return topParent;
        }
        return sourceFileOrOptions;
        function getScriptKind() {
            var _a;
            return (_a = options.scriptKind) !== null && _a !== void 0 ? _a : common.ScriptKind.TSX;
        }
        function getFileExt(scriptKind) {
            if (scriptKind === common.ScriptKind.JSX || scriptKind === common.ScriptKind.TSX)
                return "tsx";
            return "ts";
        }
    }
    function getNodeSourceFile() {
        let topNode = node.parent;
        while (topNode != null && topNode.parent != null)
            topNode = topNode.parent;
        return topNode;
    }
    function getOptions() {
        return (isFirstOverload ? sourceFileOrOptions : secondOverloadOptions) || {};
    }
}

exports.IndentationText = void 0;
(function (IndentationText) {
    IndentationText["TwoSpaces"] = "  ";
    IndentationText["FourSpaces"] = "    ";
    IndentationText["EightSpaces"] = "        ";
    IndentationText["Tab"] = "\t";
})(exports.IndentationText || (exports.IndentationText = {}));
class ManipulationSettingsContainer extends common.SettingsContainer {
    constructor() {
        super({
            indentationText: exports.IndentationText.FourSpaces,
            newLineKind: common.NewLineKind.LineFeed,
            quoteKind: exports.QuoteKind.Double,
            insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces: true,
            usePrefixAndSuffixTextForRename: false,
            useTrailingCommas: false,
        });
    }
    getEditorSettings() {
        if (this._editorSettings == null) {
            this._editorSettings = {};
            fillDefaultEditorSettings(this._editorSettings, this);
        }
        return Object.assign({}, this._editorSettings);
    }
    getFormatCodeSettings() {
        if (this._formatCodeSettings == null) {
            this._formatCodeSettings = Object.assign(Object.assign({}, this.getEditorSettings()), { insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces: this._settings.insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces });
        }
        return Object.assign({}, this._formatCodeSettings);
    }
    getUserPreferences() {
        if (this._userPreferences == null) {
            this._userPreferences = {
                quotePreference: this.getQuoteKind() === exports.QuoteKind.Double ? "double" : "single",
                providePrefixAndSuffixTextForRename: this.getUsePrefixAndSuffixTextForRename(),
            };
        }
        return Object.assign({}, this._userPreferences);
    }
    getQuoteKind() {
        return this._settings.quoteKind;
    }
    getNewLineKind() {
        return this._settings.newLineKind;
    }
    getNewLineKindAsString() {
        return newLineKindToString(this.getNewLineKind());
    }
    getIndentationText() {
        return this._settings.indentationText;
    }
    getUsePrefixAndSuffixTextForRename() {
        return this._settings.usePrefixAndSuffixTextForRename;
    }
    getUseTrailingCommas() {
        return this._settings.useTrailingCommas;
    }
    set(settings) {
        super.set(settings);
        this._editorSettings = undefined;
        this._formatCodeSettings = undefined;
        this._userPreferences = undefined;
    }
    _getIndentSizeInSpaces() {
        const indentationText = this.getIndentationText();
        switch (indentationText) {
            case exports.IndentationText.EightSpaces:
                return 8;
            case exports.IndentationText.FourSpaces:
                return 4;
            case exports.IndentationText.TwoSpaces:
                return 2;
            case exports.IndentationText.Tab:
                return 4;
            default:
                return common.errors.throwNotImplementedForNeverValueError(indentationText);
        }
    }
}

function setValueIfUndefined(obj, propertyName, defaultValue) {
    if (typeof obj[propertyName] === "undefined")
        obj[propertyName] = defaultValue;
}

function fillDefaultEditorSettings(settings, manipulationSettings) {
    setValueIfUndefined(settings, "convertTabsToSpaces", manipulationSettings.getIndentationText() !== exports.IndentationText.Tab);
    setValueIfUndefined(settings, "newLineCharacter", manipulationSettings.getNewLineKindAsString());
    setValueIfUndefined(settings, "indentStyle", common.ts.IndentStyle.Smart);
    setValueIfUndefined(settings, "indentSize", manipulationSettings.getIndentationText().length);
    setValueIfUndefined(settings, "tabSize", manipulationSettings.getIndentationText().length);
}

function fillDefaultFormatCodeSettings(settings, manipulationSettings) {
    fillDefaultEditorSettings(settings, manipulationSettings);
    setValueIfUndefined(settings, "insertSpaceAfterCommaDelimiter", true);
    setValueIfUndefined(settings, "insertSpaceAfterConstructor", false);
    setValueIfUndefined(settings, "insertSpaceAfterSemicolonInForStatements", true);
    setValueIfUndefined(settings, "insertSpaceAfterKeywordsInControlFlowStatements", true);
    setValueIfUndefined(settings, "insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces", true);
    setValueIfUndefined(settings, "insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets", false);
    setValueIfUndefined(settings, "insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces", false);
    setValueIfUndefined(settings, "insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces", false);
    setValueIfUndefined(settings, "insertSpaceBeforeFunctionParenthesis", false);
    setValueIfUndefined(settings, "insertSpaceBeforeAndAfterBinaryOperators", true);
    setValueIfUndefined(settings, "placeOpenBraceOnNewLineForFunctions", false);
    setValueIfUndefined(settings, "placeOpenBraceOnNewLineForControlBlocks", false);
    setValueIfUndefined(settings, "ensureNewLineAtEndOfFile", true);
}

function getTextFromStringOrWriter(writer, textOrWriterFunction) {
    printTextFromStringOrWriter(writer, textOrWriterFunction);
    return writer.toString();
}
function printTextFromStringOrWriter(writer, textOrWriterFunction) {
    if (typeof textOrWriterFunction === "string")
        writer.write(textOrWriterFunction);
    else if (textOrWriterFunction instanceof Function)
        textOrWriterFunction(writer);
    else {
        for (let i = 0; i < textOrWriterFunction.length; i++) {
            if (i > 0)
                writer.newLineIfLastNot();
            printTextFromStringOrWriter(writer, textOrWriterFunction[i]);
        }
    }
}

class EnableableLogger {
    constructor() {
        this.enabled = false;
    }
    setEnabled(enabled) {
        this.enabled = enabled;
    }
    log(text) {
        if (this.enabled)
            this.logInternal(text);
    }
    warn(text) {
        if (this.enabled)
            this.warnInternal(text);
    }
}

class ConsoleLogger extends EnableableLogger {
    logInternal(text) {
        console.log(text);
    }
    warnInternal(text) {
        console.warn(text);
    }
}

const reg = /^(?!(?:do|if|in|for|let|new|try|var|case|else|enum|eval|false|null|this|true|void|with|break|catch|class|const|super|throw|while|yield|delete|export|import|public|return|static|switch|typeof|default|extends|finally|package|private|continue|debugger|function|arguments|interface|protected|implements|instanceof)$)[$A-Z\_a-z\xaa\xb5\xba\xc0-\xd6\xd8-\xf6\xf8-\u02c1\u02c6-\u02d1\u02e0-\u02e4\u02ec\u02ee\u0370-\u0374\u0376\u0377\u037a-\u037d\u0386\u0388-\u038a\u038c\u038e-\u03a1\u03a3-\u03f5\u03f7-\u0481\u048a-\u0527\u0531-\u0556\u0559\u0561-\u0587\u05d0-\u05ea\u05f0-\u05f2\u0620-\u064a\u066e\u066f\u0671-\u06d3\u06d5\u06e5\u06e6\u06ee\u06ef\u06fa-\u06fc\u06ff\u0710\u0712-\u072f\u074d-\u07a5\u07b1\u07ca-\u07ea\u07f4\u07f5\u07fa\u0800-\u0815\u081a\u0824\u0828\u0840-\u0858\u08a0\u08a2-\u08ac\u0904-\u0939\u093d\u0950\u0958-\u0961\u0971-\u0977\u0979-\u097f\u0985-\u098c\u098f\u0990\u0993-\u09a8\u09aa-\u09b0\u09b2\u09b6-\u09b9\u09bd\u09ce\u09dc\u09dd\u09df-\u09e1\u09f0\u09f1\u0a05-\u0a0a\u0a0f\u0a10\u0a13-\u0a28\u0a2a-\u0a30\u0a32\u0a33\u0a35\u0a36\u0a38\u0a39\u0a59-\u0a5c\u0a5e\u0a72-\u0a74\u0a85-\u0a8d\u0a8f-\u0a91\u0a93-\u0aa8\u0aaa-\u0ab0\u0ab2\u0ab3\u0ab5-\u0ab9\u0abd\u0ad0\u0ae0\u0ae1\u0b05-\u0b0c\u0b0f\u0b10\u0b13-\u0b28\u0b2a-\u0b30\u0b32\u0b33\u0b35-\u0b39\u0b3d\u0b5c\u0b5d\u0b5f-\u0b61\u0b71\u0b83\u0b85-\u0b8a\u0b8e-\u0b90\u0b92-\u0b95\u0b99\u0b9a\u0b9c\u0b9e\u0b9f\u0ba3\u0ba4\u0ba8-\u0baa\u0bae-\u0bb9\u0bd0\u0c05-\u0c0c\u0c0e-\u0c10\u0c12-\u0c28\u0c2a-\u0c33\u0c35-\u0c39\u0c3d\u0c58\u0c59\u0c60\u0c61\u0c85-\u0c8c\u0c8e-\u0c90\u0c92-\u0ca8\u0caa-\u0cb3\u0cb5-\u0cb9\u0cbd\u0cde\u0ce0\u0ce1\u0cf1\u0cf2\u0d05-\u0d0c\u0d0e-\u0d10\u0d12-\u0d3a\u0d3d\u0d4e\u0d60\u0d61\u0d7a-\u0d7f\u0d85-\u0d96\u0d9a-\u0db1\u0db3-\u0dbb\u0dbd\u0dc0-\u0dc6\u0e01-\u0e30\u0e32\u0e33\u0e40-\u0e46\u0e81\u0e82\u0e84\u0e87\u0e88\u0e8a\u0e8d\u0e94-\u0e97\u0e99-\u0e9f\u0ea1-\u0ea3\u0ea5\u0ea7\u0eaa\u0eab\u0ead-\u0eb0\u0eb2\u0eb3\u0ebd\u0ec0-\u0ec4\u0ec6\u0edc-\u0edf\u0f00\u0f40-\u0f47\u0f49-\u0f6c\u0f88-\u0f8c\u1000-\u102a\u103f\u1050-\u1055\u105a-\u105d\u1061\u1065\u1066\u106e-\u1070\u1075-\u1081\u108e\u10a0-\u10c5\u10c7\u10cd\u10d0-\u10fa\u10fc-\u1248\u124a-\u124d\u1250-\u1256\u1258\u125a-\u125d\u1260-\u1288\u128a-\u128d\u1290-\u12b0\u12b2-\u12b5\u12b8-\u12be\u12c0\u12c2-\u12c5\u12c8-\u12d6\u12d8-\u1310\u1312-\u1315\u1318-\u135a\u1380-\u138f\u13a0-\u13f4\u1401-\u166c\u166f-\u167f\u1681-\u169a\u16a0-\u16ea\u16ee-\u16f0\u1700-\u170c\u170e-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176c\u176e-\u1770\u1780-\u17b3\u17d7\u17dc\u1820-\u1877\u1880-\u18a8\u18aa\u18b0-\u18f5\u1900-\u191c\u1950-\u196d\u1970-\u1974\u1980-\u19ab\u19c1-\u19c7\u1a00-\u1a16\u1a20-\u1a54\u1aa7\u1b05-\u1b33\u1b45-\u1b4b\u1b83-\u1ba0\u1bae\u1baf\u1bba-\u1be5\u1c00-\u1c23\u1c4d-\u1c4f\u1c5a-\u1c7d\u1ce9-\u1cec\u1cee-\u1cf1\u1cf5\u1cf6\u1d00-\u1dbf\u1e00-\u1f15\u1f18-\u1f1d\u1f20-\u1f45\u1f48-\u1f4d\u1f50-\u1f57\u1f59\u1f5b\u1f5d\u1f5f-\u1f7d\u1f80-\u1fb4\u1fb6-\u1fbc\u1fbe\u1fc2-\u1fc4\u1fc6-\u1fcc\u1fd0-\u1fd3\u1fd6-\u1fdb\u1fe0-\u1fec\u1ff2-\u1ff4\u1ff6-\u1ffc\u2071\u207f\u2090-\u209c\u2102\u2107\u210a-\u2113\u2115\u2119-\u211d\u2124\u2126\u2128\u212a-\u212d\u212f-\u2139\u213c-\u213f\u2145-\u2149\u214e\u2160-\u2188\u2c00-\u2c2e\u2c30-\u2c5e\u2c60-\u2ce4\u2ceb-\u2cee\u2cf2\u2cf3\u2d00-\u2d25\u2d27\u2d2d\u2d30-\u2d67\u2d6f\u2d80-\u2d96\u2da0-\u2da6\u2da8-\u2dae\u2db0-\u2db6\u2db8-\u2dbe\u2dc0-\u2dc6\u2dc8-\u2dce\u2dd0-\u2dd6\u2dd8-\u2dde\u2e2f\u3005-\u3007\u3021-\u3029\u3031-\u3035\u3038-\u303c\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fc-\u30ff\u3105-\u312d\u3131-\u318e\u31a0-\u31ba\u31f0-\u31ff\u3400-\u4db5\u4e00-\u9fcc\ua000-\ua48c\ua4d0-\ua4fd\ua500-\ua60c\ua610-\ua61f\ua62a\ua62b\ua640-\ua66e\ua67f-\ua697\ua6a0-\ua6ef\ua717-\ua71f\ua722-\ua788\ua78b-\ua78e\ua790-\ua793\ua7a0-\ua7aa\ua7f8-\ua801\ua803-\ua805\ua807-\ua80a\ua80c-\ua822\ua840-\ua873\ua882-\ua8b3\ua8f2-\ua8f7\ua8fb\ua90a-\ua925\ua930-\ua946\ua960-\ua97c\ua984-\ua9b2\ua9cf\uaa00-\uaa28\uaa40-\uaa42\uaa44-\uaa4b\uaa60-\uaa76\uaa7a\uaa80-\uaaaf\uaab1\uaab5\uaab6\uaab9-\uaabd\uaac0\uaac2\uaadb-\uaadd\uaae0-\uaaea\uaaf2-\uaaf4\uab01-\uab06\uab09-\uab0e\uab11-\uab16\uab20-\uab26\uab28-\uab2e\uabc0-\uabe2\uac00-\ud7a3\ud7b0-\ud7c6\ud7cb-\ud7fb\uf900-\ufa6d\ufa70-\ufad9\ufb00-\ufb06\ufb13-\ufb17\ufb1d\ufb1f-\ufb28\ufb2a-\ufb36\ufb38-\ufb3c\ufb3e\ufb40\ufb41\ufb43\ufb44\ufb46-\ufbb1\ufbd3-\ufd3d\ufd50-\ufd8f\ufd92-\ufdc7\ufdf0-\ufdfb\ufe70-\ufe74\ufe76-\ufefc\uff21-\uff3a\uff41-\uff5a\uff66-\uffbe\uffc2-\uffc7\uffca-\uffcf\uffd2-\uffd7\uffda-\uffdc][$A-Z\_a-z\xaa\xb5\xba\xc0-\xd6\xd8-\xf6\xf8-\u02c1\u02c6-\u02d1\u02e0-\u02e4\u02ec\u02ee\u0370-\u0374\u0376\u0377\u037a-\u037d\u0386\u0388-\u038a\u038c\u038e-\u03a1\u03a3-\u03f5\u03f7-\u0481\u048a-\u0527\u0531-\u0556\u0559\u0561-\u0587\u05d0-\u05ea\u05f0-\u05f2\u0620-\u064a\u066e\u066f\u0671-\u06d3\u06d5\u06e5\u06e6\u06ee\u06ef\u06fa-\u06fc\u06ff\u0710\u0712-\u072f\u074d-\u07a5\u07b1\u07ca-\u07ea\u07f4\u07f5\u07fa\u0800-\u0815\u081a\u0824\u0828\u0840-\u0858\u08a0\u08a2-\u08ac\u0904-\u0939\u093d\u0950\u0958-\u0961\u0971-\u0977\u0979-\u097f\u0985-\u098c\u098f\u0990\u0993-\u09a8\u09aa-\u09b0\u09b2\u09b6-\u09b9\u09bd\u09ce\u09dc\u09dd\u09df-\u09e1\u09f0\u09f1\u0a05-\u0a0a\u0a0f\u0a10\u0a13-\u0a28\u0a2a-\u0a30\u0a32\u0a33\u0a35\u0a36\u0a38\u0a39\u0a59-\u0a5c\u0a5e\u0a72-\u0a74\u0a85-\u0a8d\u0a8f-\u0a91\u0a93-\u0aa8\u0aaa-\u0ab0\u0ab2\u0ab3\u0ab5-\u0ab9\u0abd\u0ad0\u0ae0\u0ae1\u0b05-\u0b0c\u0b0f\u0b10\u0b13-\u0b28\u0b2a-\u0b30\u0b32\u0b33\u0b35-\u0b39\u0b3d\u0b5c\u0b5d\u0b5f-\u0b61\u0b71\u0b83\u0b85-\u0b8a\u0b8e-\u0b90\u0b92-\u0b95\u0b99\u0b9a\u0b9c\u0b9e\u0b9f\u0ba3\u0ba4\u0ba8-\u0baa\u0bae-\u0bb9\u0bd0\u0c05-\u0c0c\u0c0e-\u0c10\u0c12-\u0c28\u0c2a-\u0c33\u0c35-\u0c39\u0c3d\u0c58\u0c59\u0c60\u0c61\u0c85-\u0c8c\u0c8e-\u0c90\u0c92-\u0ca8\u0caa-\u0cb3\u0cb5-\u0cb9\u0cbd\u0cde\u0ce0\u0ce1\u0cf1\u0cf2\u0d05-\u0d0c\u0d0e-\u0d10\u0d12-\u0d3a\u0d3d\u0d4e\u0d60\u0d61\u0d7a-\u0d7f\u0d85-\u0d96\u0d9a-\u0db1\u0db3-\u0dbb\u0dbd\u0dc0-\u0dc6\u0e01-\u0e30\u0e32\u0e33\u0e40-\u0e46\u0e81\u0e82\u0e84\u0e87\u0e88\u0e8a\u0e8d\u0e94-\u0e97\u0e99-\u0e9f\u0ea1-\u0ea3\u0ea5\u0ea7\u0eaa\u0eab\u0ead-\u0eb0\u0eb2\u0eb3\u0ebd\u0ec0-\u0ec4\u0ec6\u0edc-\u0edf\u0f00\u0f40-\u0f47\u0f49-\u0f6c\u0f88-\u0f8c\u1000-\u102a\u103f\u1050-\u1055\u105a-\u105d\u1061\u1065\u1066\u106e-\u1070\u1075-\u1081\u108e\u10a0-\u10c5\u10c7\u10cd\u10d0-\u10fa\u10fc-\u1248\u124a-\u124d\u1250-\u1256\u1258\u125a-\u125d\u1260-\u1288\u128a-\u128d\u1290-\u12b0\u12b2-\u12b5\u12b8-\u12be\u12c0\u12c2-\u12c5\u12c8-\u12d6\u12d8-\u1310\u1312-\u1315\u1318-\u135a\u1380-\u138f\u13a0-\u13f4\u1401-\u166c\u166f-\u167f\u1681-\u169a\u16a0-\u16ea\u16ee-\u16f0\u1700-\u170c\u170e-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176c\u176e-\u1770\u1780-\u17b3\u17d7\u17dc\u1820-\u1877\u1880-\u18a8\u18aa\u18b0-\u18f5\u1900-\u191c\u1950-\u196d\u1970-\u1974\u1980-\u19ab\u19c1-\u19c7\u1a00-\u1a16\u1a20-\u1a54\u1aa7\u1b05-\u1b33\u1b45-\u1b4b\u1b83-\u1ba0\u1bae\u1baf\u1bba-\u1be5\u1c00-\u1c23\u1c4d-\u1c4f\u1c5a-\u1c7d\u1ce9-\u1cec\u1cee-\u1cf1\u1cf5\u1cf6\u1d00-\u1dbf\u1e00-\u1f15\u1f18-\u1f1d\u1f20-\u1f45\u1f48-\u1f4d\u1f50-\u1f57\u1f59\u1f5b\u1f5d\u1f5f-\u1f7d\u1f80-\u1fb4\u1fb6-\u1fbc\u1fbe\u1fc2-\u1fc4\u1fc6-\u1fcc\u1fd0-\u1fd3\u1fd6-\u1fdb\u1fe0-\u1fec\u1ff2-\u1ff4\u1ff6-\u1ffc\u2071\u207f\u2090-\u209c\u2102\u2107\u210a-\u2113\u2115\u2119-\u211d\u2124\u2126\u2128\u212a-\u212d\u212f-\u2139\u213c-\u213f\u2145-\u2149\u214e\u2160-\u2188\u2c00-\u2c2e\u2c30-\u2c5e\u2c60-\u2ce4\u2ceb-\u2cee\u2cf2\u2cf3\u2d00-\u2d25\u2d27\u2d2d\u2d30-\u2d67\u2d6f\u2d80-\u2d96\u2da0-\u2da6\u2da8-\u2dae\u2db0-\u2db6\u2db8-\u2dbe\u2dc0-\u2dc6\u2dc8-\u2dce\u2dd0-\u2dd6\u2dd8-\u2dde\u2e2f\u3005-\u3007\u3021-\u3029\u3031-\u3035\u3038-\u303c\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fc-\u30ff\u3105-\u312d\u3131-\u318e\u31a0-\u31ba\u31f0-\u31ff\u3400-\u4db5\u4e00-\u9fcc\ua000-\ua48c\ua4d0-\ua4fd\ua500-\ua60c\ua610-\ua61f\ua62a\ua62b\ua640-\ua66e\ua67f-\ua697\ua6a0-\ua6ef\ua717-\ua71f\ua722-\ua788\ua78b-\ua78e\ua790-\ua793\ua7a0-\ua7aa\ua7f8-\ua801\ua803-\ua805\ua807-\ua80a\ua80c-\ua822\ua840-\ua873\ua882-\ua8b3\ua8f2-\ua8f7\ua8fb\ua90a-\ua925\ua930-\ua946\ua960-\ua97c\ua984-\ua9b2\ua9cf\uaa00-\uaa28\uaa40-\uaa42\uaa44-\uaa4b\uaa60-\uaa76\uaa7a\uaa80-\uaaaf\uaab1\uaab5\uaab6\uaab9-\uaabd\uaac0\uaac2\uaadb-\uaadd\uaae0-\uaaea\uaaf2-\uaaf4\uab01-\uab06\uab09-\uab0e\uab11-\uab16\uab20-\uab26\uab28-\uab2e\uabc0-\uabe2\uac00-\ud7a3\ud7b0-\ud7c6\ud7cb-\ud7fb\uf900-\ufa6d\ufa70-\ufad9\ufb00-\ufb06\ufb13-\ufb17\ufb1d\ufb1f-\ufb28\ufb2a-\ufb36\ufb38-\ufb3c\ufb3e\ufb40\ufb41\ufb43\ufb44\ufb46-\ufbb1\ufbd3-\ufd3d\ufd50-\ufd8f\ufd92-\ufdc7\ufdf0-\ufdfb\ufe70-\ufe74\ufe76-\ufefc\uff21-\uff3a\uff41-\uff5a\uff66-\uffbe\uffc2-\uffc7\uffca-\uffcf\uffd2-\uffd7\uffda-\uffdc0-9\u0300-\u036f\u0483-\u0487\u0591-\u05bd\u05bf\u05c1\u05c2\u05c4\u05c5\u05c7\u0610-\u061a\u064b-\u0669\u0670\u06d6-\u06dc\u06df-\u06e4\u06e7\u06e8\u06ea-\u06ed\u06f0-\u06f9\u0711\u0730-\u074a\u07a6-\u07b0\u07c0-\u07c9\u07eb-\u07f3\u0816-\u0819\u081b-\u0823\u0825-\u0827\u0829-\u082d\u0859-\u085b\u08e4-\u08fe\u0900-\u0903\u093a-\u093c\u093e-\u094f\u0951-\u0957\u0962\u0963\u0966-\u096f\u0981-\u0983\u09bc\u09be-\u09c4\u09c7\u09c8\u09cb-\u09cd\u09d7\u09e2\u09e3\u09e6-\u09ef\u0a01-\u0a03\u0a3c\u0a3e-\u0a42\u0a47\u0a48\u0a4b-\u0a4d\u0a51\u0a66-\u0a71\u0a75\u0a81-\u0a83\u0abc\u0abe-\u0ac5\u0ac7-\u0ac9\u0acb-\u0acd\u0ae2\u0ae3\u0ae6-\u0aef\u0b01-\u0b03\u0b3c\u0b3e-\u0b44\u0b47\u0b48\u0b4b-\u0b4d\u0b56\u0b57\u0b62\u0b63\u0b66-\u0b6f\u0b82\u0bbe-\u0bc2\u0bc6-\u0bc8\u0bca-\u0bcd\u0bd7\u0be6-\u0bef\u0c01-\u0c03\u0c3e-\u0c44\u0c46-\u0c48\u0c4a-\u0c4d\u0c55\u0c56\u0c62\u0c63\u0c66-\u0c6f\u0c82\u0c83\u0cbc\u0cbe-\u0cc4\u0cc6-\u0cc8\u0cca-\u0ccd\u0cd5\u0cd6\u0ce2\u0ce3\u0ce6-\u0cef\u0d02\u0d03\u0d3e-\u0d44\u0d46-\u0d48\u0d4a-\u0d4d\u0d57\u0d62\u0d63\u0d66-\u0d6f\u0d82\u0d83\u0dca\u0dcf-\u0dd4\u0dd6\u0dd8-\u0ddf\u0df2\u0df3\u0e31\u0e34-\u0e3a\u0e47-\u0e4e\u0e50-\u0e59\u0eb1\u0eb4-\u0eb9\u0ebb\u0ebc\u0ec8-\u0ecd\u0ed0-\u0ed9\u0f18\u0f19\u0f20-\u0f29\u0f35\u0f37\u0f39\u0f3e\u0f3f\u0f71-\u0f84\u0f86\u0f87\u0f8d-\u0f97\u0f99-\u0fbc\u0fc6\u102b-\u103e\u1040-\u1049\u1056-\u1059\u105e-\u1060\u1062-\u1064\u1067-\u106d\u1071-\u1074\u1082-\u108d\u108f-\u109d\u135d-\u135f\u1712-\u1714\u1732-\u1734\u1752\u1753\u1772\u1773\u17b4-\u17d3\u17dd\u17e0-\u17e9\u180b-\u180d\u1810-\u1819\u18a9\u1920-\u192b\u1930-\u193b\u1946-\u194f\u19b0-\u19c0\u19c8\u19c9\u19d0-\u19d9\u1a17-\u1a1b\u1a55-\u1a5e\u1a60-\u1a7c\u1a7f-\u1a89\u1a90-\u1a99\u1b00-\u1b04\u1b34-\u1b44\u1b50-\u1b59\u1b6b-\u1b73\u1b80-\u1b82\u1ba1-\u1bad\u1bb0-\u1bb9\u1be6-\u1bf3\u1c24-\u1c37\u1c40-\u1c49\u1c50-\u1c59\u1cd0-\u1cd2\u1cd4-\u1ce8\u1ced\u1cf2-\u1cf4\u1dc0-\u1de6\u1dfc-\u1dff\u200c\u200d\u203f\u2040\u2054\u20d0-\u20dc\u20e1\u20e5-\u20f0\u2cef-\u2cf1\u2d7f\u2de0-\u2dff\u302a-\u302f\u3099\u309a\ua620-\ua629\ua66f\ua674-\ua67d\ua69f\ua6f0\ua6f1\ua802\ua806\ua80b\ua823-\ua827\ua880\ua881\ua8b4-\ua8c4\ua8d0-\ua8d9\ua8e0-\ua8f1\ua900-\ua909\ua926-\ua92d\ua947-\ua953\ua980-\ua983\ua9b3-\ua9c0\ua9d0-\ua9d9\uaa29-\uaa36\uaa43\uaa4c\uaa4d\uaa50-\uaa59\uaa7b\uaab0\uaab2-\uaab4\uaab7\uaab8\uaabe\uaabf\uaac1\uaaeb-\uaaef\uaaf5\uaaf6\uabe3-\uabea\uabec\uabed\uabf0-\uabf9\ufb1e\ufe00-\ufe0f\ufe20-\ufe26\ufe33\ufe34\ufe4d-\ufe4f\uff10-\uff19\uff3f]*$/;
function isValidVariableName(variableName) {
    return reg.test(variableName);
}

function newLineKindToString(kind) {
    switch (kind) {
        case common.NewLineKind.CarriageReturnLineFeed:
            return "\r\n";
        case common.NewLineKind.LineFeed:
            return "\n";
        default:
            throw new common.errors.NotImplementedError(`Not implemented newline kind: ${kind}`);
    }
}

class LazyReferenceCoordinator {
    constructor(factory) {
        this.dirtySourceFiles = new Set();
        const onSourceFileModified = (sourceFile) => {
            if (!sourceFile.wasForgotten())
                this.dirtySourceFiles.add(sourceFile);
        };
        factory.onSourceFileAdded(sourceFile => {
            this.dirtySourceFiles.add(sourceFile);
            sourceFile.onModified(onSourceFileModified);
        });
        factory.onSourceFileRemoved(sourceFile => {
            sourceFile._referenceContainer.clear();
            this.dirtySourceFiles.delete(sourceFile);
            sourceFile.onModified(onSourceFileModified, false);
        });
    }
    refreshDirtySourceFiles() {
        for (const sourceFile of this.dirtySourceFiles.values())
            sourceFile._referenceContainer.refresh();
        this.clearDirtySourceFiles();
    }
    refreshSourceFileIfDirty(sourceFile) {
        if (!this.dirtySourceFiles.has(sourceFile))
            return;
        sourceFile._referenceContainer.refresh();
        this.clearDityForSourceFile(sourceFile);
    }
    addDirtySourceFile(sourceFile) {
        this.dirtySourceFiles.add(sourceFile);
    }
    clearDirtySourceFiles() {
        this.dirtySourceFiles.clear();
    }
    clearDityForSourceFile(sourceFile) {
        this.dirtySourceFiles.delete(sourceFile);
    }
}

class SourceFileReferenceContainer {
    constructor(sourceFile) {
        this.sourceFile = sourceFile;
        this.nodesInThis = new common.KeyValueCache();
        this.nodesInOther = new common.KeyValueCache();
        this.unresolvedLiterals = [];
        this.resolveUnresolved = () => {
            for (let i = this.unresolvedLiterals.length - 1; i >= 0; i--) {
                const literal = this.unresolvedLiterals[i];
                const sourceFile = this.getSourceFileForLiteral(literal);
                if (sourceFile != null) {
                    this.unresolvedLiterals.splice(i, 1);
                    this.addNodeInThis(literal, sourceFile);
                }
            }
            if (this.unresolvedLiterals.length === 0)
                this.sourceFile._context.compilerFactory.onSourceFileAdded(this.resolveUnresolved, false);
        };
    }
    getDependentSourceFiles() {
        this.sourceFile._context.lazyReferenceCoordinator.refreshDirtySourceFiles();
        const hashSet = new Set();
        for (const nodeInOther of this.nodesInOther.getKeys())
            hashSet.add(nodeInOther._sourceFile);
        return hashSet.values();
    }
    getLiteralsReferencingOtherSourceFilesEntries() {
        this.sourceFile._context.lazyReferenceCoordinator.refreshSourceFileIfDirty(this.sourceFile);
        return this.nodesInThis.getEntries();
    }
    getReferencingLiteralsInOtherSourceFiles() {
        this.sourceFile._context.lazyReferenceCoordinator.refreshDirtySourceFiles();
        return this.nodesInOther.getKeys();
    }
    refresh() {
        if (this.unresolvedLiterals.length > 0)
            this.sourceFile._context.compilerFactory.onSourceFileAdded(this.resolveUnresolved, false);
        this.clear();
        this.populateReferences();
        if (this.unresolvedLiterals.length > 0)
            this.sourceFile._context.compilerFactory.onSourceFileAdded(this.resolveUnresolved);
    }
    clear() {
        this.unresolvedLiterals.length = 0;
        for (const [node, sourceFile] of this.nodesInThis.getEntries()) {
            this.nodesInThis.removeByKey(node);
            sourceFile._referenceContainer.nodesInOther.removeByKey(node);
        }
    }
    populateReferences() {
        this.sourceFile._context.compilerFactory.forgetNodesCreatedInBlock(remember => {
            for (const literal of this.sourceFile.getImportStringLiterals()) {
                const sourceFile = this.getSourceFileForLiteral(literal);
                remember(literal);
                if (sourceFile == null)
                    this.unresolvedLiterals.push(literal);
                else
                    this.addNodeInThis(literal, sourceFile);
            }
        });
    }
    getSourceFileForLiteral(literal) {
        const parent = literal.getParentOrThrow();
        const grandParent = parent.getParent();
        if (Node.isImportDeclaration(parent) || Node.isExportDeclaration(parent))
            return parent.getModuleSpecifierSourceFile();
        else if (grandParent != null && Node.isImportEqualsDeclaration(grandParent))
            return grandParent.getExternalModuleReferenceSourceFile();
        else if (Node.isCallExpression(parent)) {
            const literalSymbol = literal.getSymbol();
            if (literalSymbol != null)
                return ModuleUtils.getReferencedSourceFileFromSymbol(literalSymbol);
        }
        else {
            this.sourceFile._context.logger.warn(`Unknown import string literal parent: ${parent.getKindName()}`);
        }
        return undefined;
    }
    addNodeInThis(literal, sourceFile) {
        this.nodesInThis.set(literal, sourceFile);
        sourceFile._referenceContainer.nodesInOther.set(literal, sourceFile);
    }
}

function getCompilerOptionsFromTsConfig(filePath, options = {}) {
    const result = common.getCompilerOptionsFromTsConfig(filePath, options);
    return {
        options: result.options,
        errors: result.errors.map(error => new Diagnostic(undefined, error)),
    };
}

common.ts.version.split(".").map(v => parseInt(v, 10));

class WriterUtils {
    constructor() {
    }
    static getLastCharactersToPos(writer, pos) {
        const writerLength = writer.getLength();
        const charCount = writerLength - pos;
        const chars = new Array(charCount);
        writer.iterateLastChars((char, i) => {
            const insertPos = i - pos;
            if (insertPos < 0)
                return true;
            chars[insertPos] = char;
            return undefined;
        });
        return chars.join("");
    }
}

function callBaseGetStructure(basePrototype, node, structure) {
    let newStructure;
    if (basePrototype.getStructure != null)
        newStructure = basePrototype.getStructure.call(node);
    else
        newStructure = {};
    if (structure != null)
        common.ObjectUtils.assign(newStructure, structure);
    return newStructure;
}

function callBaseSet(basePrototype, node, structure) {
    if (basePrototype.set != null)
        basePrototype.set.call(node, structure);
}

function AmbientableNode(Base) {
    return class extends Base {
        hasDeclareKeyword() {
            return this.getDeclareKeyword() != null;
        }
        getDeclareKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getDeclareKeyword(), "Expected to find a declare keyword.");
        }
        getDeclareKeyword() {
            return this.getFirstModifierByKind(common.SyntaxKind.DeclareKeyword);
        }
        isAmbient() {
            return isNodeAmbientOrInAmbientContext(this);
        }
        setHasDeclareKeyword(value) {
            this.toggleModifier("declare", value);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.hasDeclareKeyword != null)
                this.setHasDeclareKeyword(structure.hasDeclareKeyword);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                hasDeclareKeyword: this.hasDeclareKeyword(),
            });
        }
    };
}

var FormattingKind;
(function (FormattingKind) {
    FormattingKind[FormattingKind["Newline"] = 0] = "Newline";
    FormattingKind[FormattingKind["Blankline"] = 1] = "Blankline";
    FormattingKind[FormattingKind["Space"] = 2] = "Space";
    FormattingKind[FormattingKind["None"] = 3] = "None";
})(FormattingKind || (FormattingKind = {}));

function getClassMemberFormatting(parent, member) {
    if (Node.isAmbientableNode(parent) && parent.isAmbient())
        return FormattingKind.Newline;
    if (hasBody$1(member))
        return FormattingKind.Blankline;
    return FormattingKind.Newline;
}
function hasBody$1(node) {
    if (Node.isBodyableNode(node) && node.getBody() != null)
        return true;
    if (Node.isBodiedNode(node))
        return true;
    return false;
}

function getFormattingKindText(formattingKind, opts) {
    switch (formattingKind) {
        case FormattingKind.Space:
            return " ";
        case FormattingKind.Newline:
            return opts.newLineKind;
        case FormattingKind.Blankline:
            return opts.newLineKind + opts.newLineKind;
        case FormattingKind.None:
            return "";
        default:
            throw new common.errors.NotImplementedError(`Not implemented formatting kind: ${formattingKind}`);
    }
}

function getInterfaceMemberFormatting(parent, member) {
    return FormattingKind.Newline;
}

function hasBody(node) {
    if (Node.isBodyableNode(node) && node.hasBody())
        return true;
    if (Node.isBodiedNode(node))
        return true;
    return Node.isInterfaceDeclaration(node) || Node.isClassDeclaration(node) || Node.isEnumDeclaration(node);
}

function getStatementedNodeChildFormatting(parent, member) {
    if (hasBody(member))
        return FormattingKind.Blankline;
    return FormattingKind.Newline;
}
function getClausedNodeChildFormatting(parent, member) {
    return FormattingKind.Newline;
}

function getGeneralFormatting(parent, child) {
    if (Node.isClassDeclaration(parent))
        return getClassMemberFormatting(parent, child);
    if (Node.isInterfaceDeclaration(parent))
        return getInterfaceMemberFormatting();
    return getStatementedNodeChildFormatting(parent, child);
}

function getTextFromTextChanges(sourceFile, textChanges) {
    const text = sourceFile.getFullText();
    const editResult = [];
    let start = 0;
    for (const { edit } of getSortedTextChanges()) {
        const span = edit.getSpan();
        const beforeEdit = text.slice(start, span.getStart());
        start = span.getEnd();
        editResult.push(beforeEdit);
        editResult.push(edit.getNewText());
    }
    editResult.push(text.slice(start));
    return editResult.join("");
    function getSortedTextChanges() {
        return textChanges.map((edit, index) => ({ edit: toWrappedTextChange(edit), index })).sort((a, b) => {
            const aStart = a.edit.getSpan().getStart();
            const bStart = b.edit.getSpan().getStart();
            const difference = aStart - bStart;
            if (difference === 0)
                return a.index < b.index ? -1 : 1;
            return difference < 0 ? -1 : 1;
        });
    }
    function toWrappedTextChange(change) {
        if (change instanceof TextChange)
            return change;
        else
            return new TextChange(change);
    }
}

function getNewInsertCode(opts) {
    var _a;
    const { structures, newCodes, parent, getSeparator, previousFormattingKind, nextFormattingKind } = opts;
    const indentationText = (_a = opts.indentationText) !== null && _a !== void 0 ? _a : parent.getChildIndentationText();
    const newLineKind = parent._context.manipulationSettings.getNewLineKindAsString();
    return getFormattingKindTextWithIndent(previousFormattingKind) + getChildCode() + getFormattingKindTextWithIndent(nextFormattingKind);
    function getChildCode() {
        let code = newCodes[0];
        for (let i = 1; i < newCodes.length; i++) {
            const formattingKind = getSeparator(structures[i - 1], structures[i]);
            code += getFormattingKindTextWithIndent(formattingKind);
            code += newCodes[i];
        }
        return code;
    }
    function getFormattingKindTextWithIndent(formattingKind) {
        let code = getFormattingKindText(formattingKind, { newLineKind });
        if (formattingKind === FormattingKind.Newline || formattingKind === FormattingKind.Blankline)
            code += indentationText;
        return code;
    }
}

const scanner = common.ts.createScanner(common.ts.ScriptTarget.Latest, true);
function appendCommaToText(text) {
    const pos = getAppendCommaPos(text);
    if (pos === -1)
        return text;
    return text.substring(0, pos) + "," + text.substring(pos);
}
function getAppendCommaPos(text) {
    scanner.setText(text);
    try {
        if (scanner.scan() === common.ts.SyntaxKind.EndOfFileToken)
            return -1;
        while (scanner.scan() !== common.ts.SyntaxKind.EndOfFileToken) {
        }
        const pos = scanner.getStartPos();
        return text[pos - 1] === "," ? -1 : pos;
    }
    finally {
        scanner.setText(undefined);
    }
}

function getEndIndexFromArray(array) {
    var _a;
    return (_a = array === null || array === void 0 ? void 0 : array.length) !== null && _a !== void 0 ? _a : 0;
}

function getNextMatchingPos(text, pos, condition) {
    while (pos < text.length) {
        const charCode = text.charCodeAt(pos);
        if (!condition(charCode))
            pos++;
        else
            break;
    }
    return pos;
}

function getPreviousMatchingPos(text, pos, condition) {
    while (pos > 0) {
        const charCode = text.charCodeAt(pos - 1);
        if (!condition(charCode))
            pos--;
        else
            break;
    }
    return pos;
}

function getNextNonWhitespacePos(text, pos) {
    return getNextMatchingPos(text, pos, isNotWhitespace);
}
function getPreviousNonWhitespacePos(text, pos) {
    return getPreviousMatchingPos(text, pos, isNotWhitespace);
}
function isNotWhitespace(charCode) {
    return !common.StringUtils.isWhitespaceCharCode(charCode);
}

function getPosAtEndOfPreviousLine(fullText, pos) {
    while (pos > 0) {
        pos--;
        if (fullText[pos] === "\n") {
            if (fullText[pos - 1] === "\r")
                return pos - 1;
            return pos;
        }
    }
    return pos;
}

function getPosAtNextNonBlankLine(text, pos) {
    let newPos = pos;
    for (let i = pos; i < text.length; i++) {
        if (text[i] === " " || text[i] === "\t")
            continue;
        if (text[i] === "\r" && text[i + 1] === "\n" || text[i] === "\n") {
            newPos = i + 1;
            if (text[i] === "\r") {
                i++;
                newPos++;
            }
            continue;
        }
        return newPos;
    }
    return newPos;
}

function getPosAtStartOfLineOrNonWhitespace(fullText, pos) {
    while (pos > 0) {
        pos--;
        const currentChar = fullText[pos];
        if (currentChar === "\n")
            return pos + 1;
        else if (currentChar !== " " && currentChar !== "\t")
            return pos + 1;
    }
    return pos;
}

function getInsertPosFromIndex(index, syntaxList, children) {
    if (index === 0) {
        const parent = syntaxList.getParentOrThrow();
        if (Node.isSourceFile(parent))
            return 0;
        else if (Node.isCaseClause(parent) || Node.isDefaultClause(parent)) {
            const colonToken = parent.getFirstChildByKindOrThrow(common.SyntaxKind.ColonToken);
            return colonToken.getEnd();
        }
        const isInline = syntaxList !== parent.getChildSyntaxList();
        if (isInline)
            return syntaxList.getStart();
        const parentContainer = getParentContainerOrThrow(parent);
        const openBraceToken = parentContainer.getFirstChildByKindOrThrow(common.SyntaxKind.OpenBraceToken);
        return openBraceToken.getEnd();
    }
    else {
        return children[index - 1].getEnd();
    }
}
function getEndPosFromIndex(index, parent, children, fullText) {
    let endPos;
    if (index === children.length) {
        if (Node.isSourceFile(parent))
            endPos = parent.getEnd();
        else if (Node.isCaseClause(parent) || Node.isDefaultClause(parent))
            endPos = parent.getEnd();
        else {
            const parentContainer = getParentContainerOrThrow(parent);
            const closeBraceToken = parentContainer.getLastChildByKind(common.SyntaxKind.CloseBraceToken);
            if (closeBraceToken == null)
                endPos = parent.getEnd();
            else
                endPos = closeBraceToken.getStart();
        }
    }
    else {
        endPos = children[index].getNonWhitespaceStart();
    }
    return getPosAtStartOfLineOrNonWhitespace(fullText, endPos);
}
function getParentContainerOrThrow(parent) {
    if (Node.isModuleDeclaration(parent)) {
        const innerBody = parent._getInnerBody();
        if (innerBody == null)
            throw new common.errors.InvalidOperationError("This operation requires the module to have a body.");
        return innerBody;
    }
    else if (Node.isBodiedNode(parent))
        return parent.getBody();
    else if (Node.isBodyableNode(parent))
        return parent.getBodyOrThrow();
    else
        return parent;
}

function fromAbstractableNode(node) {
    return {
        isAbstract: node.isAbstract(),
    };
}
function fromAmbientableNode(node) {
    return {
        hasDeclareKeyword: node.hasDeclareKeyword(),
    };
}
function fromExportableNode(node) {
    return {
        isDefaultExport: node.hasDefaultKeyword(),
        isExported: node.hasExportKeyword(),
    };
}
function fromStaticableNode(node) {
    return {
        isStatic: node.isStatic(),
    };
}
function fromScopedNode(node) {
    return {
        scope: node.hasScopeKeyword() ? node.getScope() : undefined,
    };
}
function fromOverrideableNode(node) {
    return {
        hasOverrideKeyword: node.hasOverrideKeyword(),
    };
}
function fromQuestionTokenableNode(node) {
    return {
        hasQuestionToken: node.hasQuestionToken(),
    };
}

function getNodesToReturn(oldChildren, newChildren, index, allowCommentNodes) {
    const oldChildCount = typeof oldChildren === "number" ? oldChildren : oldChildren.length;
    const newLength = newChildren.length - oldChildCount;
    const result = [];
    for (let i = 0; i < newLength; i++) {
        const currentChild = newChildren[index + i];
        if (allowCommentNodes || !Node.isCommentNode(currentChild))
            result.push(currentChild);
    }
    return result;
}

function getRangeWithoutCommentsFromArray(array, index, length, expectedKind) {
    const children = [];
    while (index < array.length && children.length < length) {
        const child = array[index];
        const childKind = child.getKind();
        if (childKind !== common.SyntaxKind.SingleLineCommentTrivia && childKind !== common.SyntaxKind.MultiLineCommentTrivia) {
            if (childKind !== expectedKind) {
                throw new common.errors.NotImplementedError(`Unexpected! Inserting syntax kind of ${common.getSyntaxKindName(expectedKind)}`
                    + `, but ${child.getKindName()} was inserted.`);
            }
            children.push(child);
        }
        index++;
    }
    if (children.length !== length)
        throw new common.errors.NotImplementedError(`Unexpected! Inserted ${length} child/children, but ${children.length} were inserted.`);
    return children;
}

function fromConstructorDeclarationOverload(node) {
    const structure = {};
    common.ObjectUtils.assign(structure, fromScopedNode(node));
    return structure;
}
function fromMethodDeclarationOverload(node) {
    const structure = {};
    common.ObjectUtils.assign(structure, fromStaticableNode(node));
    common.ObjectUtils.assign(structure, fromAbstractableNode(node));
    common.ObjectUtils.assign(structure, fromScopedNode(node));
    common.ObjectUtils.assign(structure, fromQuestionTokenableNode(node));
    common.ObjectUtils.assign(structure, fromOverrideableNode(node));
    return structure;
}
function fromFunctionDeclarationOverload(node) {
    const structure = {};
    common.ObjectUtils.assign(structure, fromAmbientableNode(node));
    common.ObjectUtils.assign(structure, fromExportableNode(node));
    return structure;
}

function verifyAndGetIndex(index, length) {
    const newIndex = index < 0 ? length + index : index;
    if (newIndex < 0)
        throw new common.errors.InvalidOperationError(`Invalid index: The max negative index is ${length * -1}, but ${index} was specified.`);
    if (index > length)
        throw new common.errors.InvalidOperationError(`Invalid index: The max index is ${length}, but ${index} was specified.`);
    return newIndex;
}

exports.CommentNodeKind = void 0;
(function (CommentNodeKind) {
    CommentNodeKind[CommentNodeKind["Statement"] = 0] = "Statement";
    CommentNodeKind[CommentNodeKind["ClassElement"] = 1] = "ClassElement";
    CommentNodeKind[CommentNodeKind["TypeElement"] = 2] = "TypeElement";
    CommentNodeKind[CommentNodeKind["ObjectLiteralElement"] = 3] = "ObjectLiteralElement";
    CommentNodeKind[CommentNodeKind["EnumMember"] = 4] = "EnumMember";
})(exports.CommentNodeKind || (exports.CommentNodeKind = {}));
class CompilerCommentNode {
    constructor(fullStart, pos, end, kind, sourceFile, parent) {
        this._fullStart = fullStart;
        this._start = pos;
        this._sourceFile = sourceFile;
        this.pos = pos;
        this.end = end;
        this.kind = kind;
        this.flags = common.ts.NodeFlags.None;
        this.parent = parent;
    }
    getSourceFile() {
        return this._sourceFile;
    }
    getChildCount(sourceFile) {
        return 0;
    }
    getChildAt(index, sourceFile) {
        return undefined;
    }
    getChildren(sourceFile) {
        return [];
    }
    getStart(sourceFile, includeJsDocComment) {
        return this._start;
    }
    getFullStart() {
        return this._fullStart;
    }
    getEnd() {
        return this.end;
    }
    getWidth(sourceFile) {
        return this.end - this._start;
    }
    getFullWidth() {
        return this.end - this._fullStart;
    }
    getLeadingTriviaWidth(sourceFile) {
        return this._start - this._fullStart;
    }
    getFullText(sourceFile) {
        return this._sourceFile.text.substring(this._fullStart, this.end);
    }
    getText(sourceFile) {
        return this._sourceFile.text.substring(this._start, this.end);
    }
    getFirstToken(sourceFile) {
        return undefined;
    }
    getLastToken(sourceFile) {
        return undefined;
    }
    forEachChild(cbNode, cbNodeArray) {
        return undefined;
    }
}
class CompilerCommentStatement extends CompilerCommentNode {
    constructor() {
        super(...arguments);
        this._commentKind = exports.CommentNodeKind.Statement;
    }
}
class CompilerCommentClassElement extends CompilerCommentNode {
    constructor() {
        super(...arguments);
        this._commentKind = exports.CommentNodeKind.ClassElement;
    }
}
class CompilerCommentTypeElement extends CompilerCommentNode {
    constructor() {
        super(...arguments);
        this._commentKind = exports.CommentNodeKind.TypeElement;
    }
}
class CompilerCommentObjectLiteralElement extends CompilerCommentNode {
    constructor() {
        super(...arguments);
        this._commentKind = exports.CommentNodeKind.ObjectLiteralElement;
    }
}
class CompilerCommentEnumMember extends CompilerCommentNode {
    constructor() {
        super(...arguments);
        this._commentKind = exports.CommentNodeKind.EnumMember;
    }
}

var CommentKind;
(function (CommentKind) {
    CommentKind[CommentKind["SingleLine"] = 0] = "SingleLine";
    CommentKind[CommentKind["MultiLine"] = 1] = "MultiLine";
    CommentKind[CommentKind["JsDoc"] = 2] = "JsDoc";
})(CommentKind || (CommentKind = {}));
const childrenSaver = new WeakMap();
const commentNodeParserKinds = new Set([
    common.SyntaxKind.SourceFile,
    common.SyntaxKind.Block,
    common.SyntaxKind.ModuleBlock,
    common.SyntaxKind.CaseClause,
    common.SyntaxKind.DefaultClause,
    common.SyntaxKind.ClassDeclaration,
    common.SyntaxKind.InterfaceDeclaration,
    common.SyntaxKind.EnumDeclaration,
    common.SyntaxKind.ClassExpression,
    common.SyntaxKind.TypeLiteral,
    common.SyntaxKind.ObjectLiteralExpression,
]);
class CommentNodeParser {
    constructor() {
    }
    static getOrParseChildren(container, sourceFile) {
        if (isSyntaxList(container))
            container = container.parent;
        let children = childrenSaver.get(container);
        if (children == null) {
            children = Array.from(getNodes(container, sourceFile));
            childrenSaver.set(container, children);
        }
        return children;
    }
    static shouldParseChildren(container) {
        return commentNodeParserKinds.has(container.kind)
            && container.pos !== container.end;
    }
    static hasParsedChildren(container) {
        if (isSyntaxList(container))
            container = container.parent;
        return childrenSaver.has(container);
    }
    static isCommentStatement(node) {
        return node._commentKind === exports.CommentNodeKind.Statement;
    }
    static isCommentClassElement(node) {
        return node._commentKind === exports.CommentNodeKind.ClassElement;
    }
    static isCommentTypeElement(node) {
        return node._commentKind === exports.CommentNodeKind.TypeElement;
    }
    static isCommentObjectLiteralElement(node) {
        return node._commentKind === exports.CommentNodeKind.ObjectLiteralElement;
    }
    static isCommentEnumMember(node) {
        return node._commentKind === exports.CommentNodeKind.EnumMember;
    }
    static getContainerBodyPos(container, sourceFile) {
        if (common.ts.isSourceFile(container))
            return 0;
        if (common.ts.isClassDeclaration(container)
            || common.ts.isEnumDeclaration(container)
            || common.ts.isInterfaceDeclaration(container)
            || common.ts.isTypeLiteralNode(container)
            || common.ts.isClassExpression(container)
            || common.ts.isBlock(container)
            || common.ts.isModuleBlock(container)
            || common.ts.isObjectLiteralExpression(container)) {
            return getTokenEnd(container, common.SyntaxKind.OpenBraceToken);
        }
        if (common.ts.isCaseClause(container) || common.ts.isDefaultClause(container))
            return getTokenEnd(container, common.SyntaxKind.ColonToken);
        return common.errors.throwNotImplementedForNeverValueError(container);
        function getTokenEnd(node, kind) {
            var _a;
            return (_a = node.getChildren(sourceFile).find(c => c.kind === kind)) === null || _a === void 0 ? void 0 : _a.end;
        }
    }
}
function* getNodes(container, sourceFile) {
    const sourceFileText = sourceFile.text;
    const childNodes = getContainerChildren();
    const createComment = getCreationFunction();
    if (childNodes.length === 0) {
        const bodyStartPos = CommentNodeParser.getContainerBodyPos(container, sourceFile);
        if (bodyStartPos != null)
            yield* getCommentNodes(bodyStartPos, false);
    }
    else {
        for (const childNode of childNodes) {
            yield* getCommentNodes(childNode.pos, true);
            yield childNode;
        }
        const lastChild = childNodes[childNodes.length - 1];
        yield* getCommentNodes(lastChild.end, false);
    }
    function* getCommentNodes(pos, stopAtJsDoc) {
        const fullStart = pos;
        skipTrailingLine();
        const leadingComments = Array.from(getLeadingComments());
        const maxEnd = sourceFileText.length === pos || sourceFileText[pos] === "}" ? pos : common.StringUtils.getLineStartFromPos(sourceFileText, pos);
        for (const leadingComment of leadingComments) {
            if (leadingComment.end <= maxEnd)
                yield leadingComment;
        }
        function skipTrailingLine() {
            if (pos === 0)
                return;
            let lineEnd = common.StringUtils.getLineEndFromPos(sourceFileText, pos);
            while (pos < lineEnd) {
                const commentKind = getCommentKind();
                if (commentKind != null) {
                    const comment = parseForComment(commentKind);
                    if (comment.kind === common.SyntaxKind.SingleLineCommentTrivia)
                        return;
                    else
                        lineEnd = common.StringUtils.getLineEndFromPos(sourceFileText, pos);
                }
                else if (!common.StringUtils.isWhitespace(sourceFileText[pos]) && sourceFileText[pos] !== ",")
                    return;
                else
                    pos++;
            }
            while (common.StringUtils.startsWithNewLine(sourceFileText[pos]))
                pos++;
        }
        function* getLeadingComments() {
            while (pos < sourceFileText.length) {
                const commentKind = getCommentKind();
                if (commentKind != null) {
                    const isJsDoc = commentKind === CommentKind.JsDoc;
                    if (isJsDoc && stopAtJsDoc)
                        return;
                    else
                        yield parseForComment(commentKind);
                    skipTrailingLine();
                }
                else if (!common.StringUtils.isWhitespace(sourceFileText[pos]))
                    return;
                else
                    pos++;
            }
        }
        function parseForComment(commentKind) {
            if (commentKind === CommentKind.SingleLine)
                return parseSingleLineComment();
            const isJsDoc = commentKind === CommentKind.JsDoc;
            return parseMultiLineComment(isJsDoc);
        }
        function getCommentKind() {
            const currentChar = sourceFileText[pos];
            if (currentChar !== "/")
                return undefined;
            const nextChar = sourceFileText[pos + 1];
            if (nextChar === "/")
                return CommentKind.SingleLine;
            if (nextChar !== "*")
                return undefined;
            const nextNextChar = sourceFileText[pos + 2];
            return nextNextChar === "*" ? CommentKind.JsDoc : CommentKind.MultiLine;
        }
        function parseSingleLineComment() {
            const start = pos;
            skipSingleLineComment();
            const end = pos;
            return createComment(fullStart, start, end, common.SyntaxKind.SingleLineCommentTrivia);
        }
        function skipSingleLineComment() {
            pos += 2;
            while (pos < sourceFileText.length && sourceFileText[pos] !== "\n" && sourceFileText[pos] !== "\r")
                pos++;
        }
        function parseMultiLineComment(isJsDoc) {
            const start = pos;
            skipSlashStarComment(isJsDoc);
            const end = pos;
            return createComment(fullStart, start, end, common.SyntaxKind.MultiLineCommentTrivia);
        }
        function skipSlashStarComment(isJsDoc) {
            pos += isJsDoc ? 3 : 2;
            while (pos < sourceFileText.length) {
                if (sourceFileText[pos] === "*" && sourceFileText[pos + 1] === "/") {
                    pos += 2;
                    break;
                }
                pos++;
            }
        }
    }
    function getContainerChildren() {
        if (common.ts.isSourceFile(container) || common.ts.isBlock(container) || common.ts.isModuleBlock(container) || common.ts.isCaseClause(container) || common.ts.isDefaultClause(container))
            return container.statements;
        if (common.ts.isClassDeclaration(container)
            || common.ts.isClassExpression(container)
            || common.ts.isEnumDeclaration(container)
            || common.ts.isInterfaceDeclaration(container)
            || common.ts.isTypeLiteralNode(container)
            || common.ts.isClassExpression(container)) {
            return container.members;
        }
        if (common.ts.isObjectLiteralExpression(container))
            return container.properties;
        return common.errors.throwNotImplementedForNeverValueError(container);
    }
    function getCreationFunction() {
        const ctor = getCtor();
        return (fullStart, pos, end, kind) => new ctor(fullStart, pos, end, kind, sourceFile, container);
        function getCtor() {
            if (isStatementContainerNode(container))
                return CompilerCommentStatement;
            if (common.ts.isClassLike(container))
                return CompilerCommentClassElement;
            if (common.ts.isInterfaceDeclaration(container) || common.ts.isTypeLiteralNode(container))
                return CompilerCommentTypeElement;
            if (common.ts.isObjectLiteralExpression(container))
                return CompilerCommentObjectLiteralElement;
            if (common.ts.isEnumDeclaration(container))
                return CompilerCommentEnumMember;
            throw new common.errors.NotImplementedError(`Not implemented comment node container type: ${common.getSyntaxKindName(container.kind)}`);
        }
    }
}
function isSyntaxList(node) {
    return node.kind === common.SyntaxKind.SyntaxList;
}
function isStatementContainerNode(node) {
    return getStatementContainerNode() != null;
    function getStatementContainerNode() {
        const container = node;
        if (common.ts.isSourceFile(container)
            || common.ts.isBlock(container)
            || common.ts.isModuleBlock(container)
            || common.ts.isCaseClause(container)
            || common.ts.isDefaultClause(container)) {
            return container;
        }
        return undefined;
    }
}

function hasParsedTokens(node) {
    return node._children != null;
}

const forEachChildSaver = new WeakMap();
const getChildrenSaver = new WeakMap();
class ExtendedParser {
    static getContainerArray(container, sourceFile) {
        return CommentNodeParser.getOrParseChildren(container, sourceFile);
    }
    static getCompilerChildrenFast(node, sourceFile) {
        if (hasParsedTokens(node))
            return ExtendedParser.getCompilerChildren(node, sourceFile);
        return ExtendedParser.getCompilerForEachChildren(node, sourceFile);
    }
    static getCompilerForEachChildren(node, sourceFile) {
        if (CommentNodeParser.shouldParseChildren(node)) {
            let result = forEachChildSaver.get(node);
            if (result == null) {
                result = getForEachChildren();
                mergeInComments(result, CommentNodeParser.getOrParseChildren(node, sourceFile));
                forEachChildSaver.set(node, result);
            }
            return result;
        }
        return getForEachChildren();
        function getForEachChildren() {
            const children = [];
            node.forEachChild(child => {
                children.push(child);
            });
            return children;
        }
    }
    static getCompilerChildren(node, sourceFile) {
        if (isStatementMemberOrPropertyHoldingSyntaxList()) {
            let result = getChildrenSaver.get(node);
            if (result == null) {
                result = [...node.getChildren(sourceFile)];
                mergeInComments(result, CommentNodeParser.getOrParseChildren(node, sourceFile));
                getChildrenSaver.set(node, result);
            }
            return result;
        }
        return node.getChildren(sourceFile);
        function isStatementMemberOrPropertyHoldingSyntaxList() {
            if (node.kind !== common.ts.SyntaxKind.SyntaxList)
                return false;
            const parent = node.parent;
            if (!CommentNodeParser.shouldParseChildren(parent))
                return false;
            return CommentNodeParser.getContainerBodyPos(parent, sourceFile) === node.pos;
        }
    }
}
function mergeInComments(nodes, otherNodes) {
    let currentIndex = 0;
    for (const child of otherNodes) {
        if (child.kind !== common.SyntaxKind.SingleLineCommentTrivia && child.kind !== common.SyntaxKind.MultiLineCommentTrivia)
            continue;
        while (currentIndex < nodes.length && nodes[currentIndex].end < child.end)
            currentIndex++;
        nodes.splice(currentIndex, 0, child);
        currentIndex++;
    }
}

function isComment(node) {
    return node.kind === common.ts.SyntaxKind.SingleLineCommentTrivia
        || node.kind === common.ts.SyntaxKind.MultiLineCommentTrivia;
}

class NodeHandlerHelper {
    constructor(compilerFactory) {
        this.compilerFactory = compilerFactory;
    }
    handleForValues(handler, currentNode, newNode, newSourceFile) {
        if (this.compilerFactory.hasCompilerNode(currentNode))
            handler.handleNode(this.compilerFactory.getExistingNodeFromCompilerNode(currentNode), newNode, newSourceFile);
        else if (currentNode.kind === common.SyntaxKind.SyntaxList) {
            const sourceFile = this.compilerFactory.getExistingNodeFromCompilerNode(currentNode.getSourceFile());
            handler.handleNode(this.compilerFactory.getNodeFromCompilerNode(currentNode, sourceFile), newNode, newSourceFile);
        }
    }
    forgetNodeIfNecessary(currentNode) {
        if (this.compilerFactory.hasCompilerNode(currentNode))
            this.compilerFactory.getExistingNodeFromCompilerNode(currentNode).forget();
    }
    getCompilerChildrenAsIterators(currentNode, newNode, newSourceFile) {
        const children = this.getCompilerChildren(currentNode, newNode, newSourceFile);
        return [
            new AdvancedIterator(common.ArrayUtils.toIterator(children[0])),
            new AdvancedIterator(common.ArrayUtils.toIterator(children[1])),
        ];
    }
    getCompilerChildren(currentNode, newNode, newSourceFile) {
        const currentCompilerNode = currentNode.compilerNode;
        const currentSourceFile = currentNode._sourceFile.compilerNode;
        return [
            ExtendedParser.getCompilerChildren(currentCompilerNode, currentSourceFile),
            ExtendedParser.getCompilerChildren(newNode, newSourceFile),
        ];
    }
    getChildrenFast(currentNode, newNode, newSourceFile) {
        const currentCompilerNode = currentNode.compilerNode;
        const currentSourceFile = currentNode._sourceFile.compilerNode;
        if (hasParsedTokens(currentCompilerNode)) {
            return [
                ExtendedParser.getCompilerChildren(currentCompilerNode, currentSourceFile),
                ExtendedParser.getCompilerChildren(newNode, newSourceFile),
            ];
        }
        return [
            ExtendedParser.getCompilerForEachChildren(currentCompilerNode, currentSourceFile),
            ExtendedParser.getCompilerForEachChildren(newNode, newSourceFile),
        ];
    }
}

class StraightReplacementNodeHandler {
    constructor(compilerFactory) {
        this.compilerFactory = compilerFactory;
        this.helper = new NodeHandlerHelper(compilerFactory);
    }
    handleNode(currentNode, newNode, newSourceFile) {
        if (currentNode.getKind() !== newNode.kind) {
            throw new common.errors.InvalidOperationError(`Error replacing tree! Perhaps a syntax error was inserted `
                + `(Current: ${currentNode.getKindName()} -- New: ${common.getSyntaxKindName(newNode.kind)}).`);
        }
        if (currentNode._hasWrappedChildren())
            this.handleChildren(currentNode, newNode, newSourceFile);
        this.compilerFactory.replaceCompilerNode(currentNode, newNode);
    }
    handleChildren(currentNode, newNode, newSourceFile) {
        const [currentChildren, newChildren] = this.helper.getChildrenFast(currentNode, newNode, newSourceFile);
        if (currentChildren.length !== newChildren.length) {
            throw new Error(`Error replacing tree: The children of the old and new trees were expected to have the `
                + `same count (${currentChildren.length}:${newChildren.length}).`);
        }
        for (let i = 0; i < currentChildren.length; i++)
            this.helper.handleForValues(this, currentChildren[i], newChildren[i], newSourceFile);
    }
}

class ChangeChildOrderParentHandler {
    constructor(compilerFactory, opts) {
        this.compilerFactory = compilerFactory;
        this.straightReplacementNodeHandler = new StraightReplacementNodeHandler(compilerFactory);
        this.helper = new NodeHandlerHelper(compilerFactory);
        this.oldIndex = opts.oldIndex;
        this.newIndex = opts.newIndex;
    }
    handleNode(currentNode, newNode, newSourceFile) {
        const [currentChildren, newChildren] = this.helper.getCompilerChildren(currentNode, newNode, newSourceFile);
        const currentChildrenInNewOrder = this.getChildrenInNewOrder(currentChildren);
        common.errors.throwIfNotEqual(newChildren.length, currentChildrenInNewOrder.length, "New children length should match the old children length.");
        for (let i = 0; i < newChildren.length; i++)
            this.helper.handleForValues(this.straightReplacementNodeHandler, currentChildrenInNewOrder[i], newChildren[i], newSourceFile);
        this.compilerFactory.replaceCompilerNode(currentNode, newNode);
    }
    getChildrenInNewOrder(children) {
        const result = [...children];
        const movingNode = result.splice(this.oldIndex, 1)[0];
        result.splice(this.newIndex, 0, movingNode);
        return result;
    }
}

class DefaultParentHandler {
    constructor(compilerFactory, opts) {
        var _a;
        this.compilerFactory = compilerFactory;
        this.straightReplacementNodeHandler = new StraightReplacementNodeHandler(compilerFactory);
        this.helper = new NodeHandlerHelper(compilerFactory);
        this.childCount = opts.childCount;
        this.isFirstChild = opts.isFirstChild;
        this.replacingNodes = (_a = opts.replacingNodes) === null || _a === void 0 ? void 0 : _a.map(n => n.compilerNode);
        this.customMappings = opts.customMappings;
    }
    handleNode(currentNode, newNode, newSourceFile) {
        const [currentChildren, newChildren] = this.helper.getCompilerChildrenAsIterators(currentNode, newNode, newSourceFile);
        let count = this.childCount;
        this.handleCustomMappings(newNode);
        while (!currentChildren.done && !newChildren.done && !this.isFirstChild(currentChildren.peek, newChildren.peek))
            this.helper.handleForValues(this.straightReplacementNodeHandler, currentChildren.next(), newChildren.next(), newSourceFile);
        while (!currentChildren.done && this.tryReplaceNode(currentChildren.peek))
            currentChildren.next();
        if (count > 0) {
            while (count > 0) {
                newChildren.next();
                count--;
            }
        }
        else if (count < 0) {
            while (count < 0) {
                this.helper.forgetNodeIfNecessary(currentChildren.next());
                count++;
            }
        }
        while (!currentChildren.done)
            this.helper.handleForValues(this.straightReplacementNodeHandler, currentChildren.next(), newChildren.next(), newSourceFile);
        if (!newChildren.done)
            throw new Error("Error replacing tree: Should not have children left over.");
        this.compilerFactory.replaceCompilerNode(currentNode, newNode);
    }
    handleCustomMappings(newParentNode) {
        if (this.customMappings == null)
            return;
        const customMappings = this.customMappings(newParentNode);
        for (const mapping of customMappings)
            this.compilerFactory.replaceCompilerNode(mapping.currentNode, mapping.newNode);
    }
    tryReplaceNode(currentCompilerNode) {
        if (this.replacingNodes == null || this.replacingNodes.length === 0)
            return false;
        const index = this.replacingNodes.indexOf(currentCompilerNode);
        if (index === -1)
            return false;
        this.replacingNodes.splice(index, 1);
        this.helper.forgetNodeIfNecessary(currentCompilerNode);
        return true;
    }
}

class ForgetChangedNodeHandler {
    constructor(compilerFactory) {
        this.compilerFactory = compilerFactory;
        this.helper = new NodeHandlerHelper(compilerFactory);
    }
    handleNode(currentNode, newNode, newSourceFile) {
        if (currentNode.getKind() !== newNode.kind) {
            currentNode.forget();
            return;
        }
        if (currentNode._hasWrappedChildren())
            this.handleChildren(currentNode, newNode, newSourceFile);
        this.compilerFactory.replaceCompilerNode(currentNode, newNode);
    }
    handleChildren(currentNode, newNode, newSourceFile) {
        const [currentNodeChildren, newNodeChildrenArray] = this.helper.getChildrenFast(currentNode, newNode, newSourceFile);
        const newNodeChildren = common.ArrayUtils.toIterator(newNodeChildrenArray);
        for (const currentNodeChild of currentNodeChildren) {
            const nextNodeChildResult = newNodeChildren.next();
            if (nextNodeChildResult.done) {
                const existingNode = this.compilerFactory.getExistingNodeFromCompilerNode(currentNodeChild);
                if (existingNode != null)
                    existingNode.forget();
            }
            else {
                this.helper.handleForValues(this, currentNodeChild, nextNodeChildResult.value, newSourceFile);
            }
        }
    }
}

class ParentFinderReplacementNodeHandler extends StraightReplacementNodeHandler {
    constructor(compilerFactory, parentNodeHandler, changingParent) {
        super(compilerFactory);
        this.parentNodeHandler = parentNodeHandler;
        this.changingParent = changingParent;
        this.foundParent = false;
        this.changingParentParent = this.changingParent.getParentSyntaxList() || this.changingParent.getParent();
        this.parentsAtSamePos = this.changingParentParent != null && this.changingParentParent.getPos() === this.changingParent.getPos();
    }
    handleNode(currentNode, newNode, newSourceFile) {
        if (!this.foundParent && this.isParentNode(newNode, newSourceFile)) {
            this.foundParent = true;
            this.parentNodeHandler.handleNode(currentNode, newNode, newSourceFile);
        }
        else {
            super.handleNode(currentNode, newNode, newSourceFile);
        }
    }
    isParentNode(newNode, newSourceFile) {
        const positionsAndKindsEqual = areNodesEqual(newNode, this.changingParent)
            && areNodesEqual(getParentSyntaxList(newNode, newSourceFile) || newNode.parent, this.changingParentParent);
        if (!positionsAndKindsEqual)
            return false;
        if (!this.parentsAtSamePos)
            return true;
        return getAncestorLength(this.changingParent.compilerNode) === getAncestorLength(newNode);
        function getAncestorLength(nodeToCheck) {
            let node = nodeToCheck;
            let count = 0;
            while (node.parent != null) {
                count++;
                node = node.parent;
            }
            return count;
        }
    }
}
function areNodesEqual(a, b) {
    if (a == null && b == null)
        return true;
    if (a == null || b == null)
        return false;
    if (a.pos === b.getPos() && a.kind === b.getKind())
        return true;
    return false;
}

class RangeHandler {
    constructor(compilerFactory, opts) {
        this.compilerFactory = compilerFactory;
        this.straightReplacementNodeHandler = new StraightReplacementNodeHandler(compilerFactory);
        this.helper = new NodeHandlerHelper(compilerFactory);
        this.start = opts.start;
        this.end = opts.end;
    }
    handleNode(currentNode, newNode, newSourceFile) {
        const currentSourceFile = currentNode._sourceFile.compilerNode;
        const children = this.helper.getChildrenFast(currentNode, newNode, newSourceFile);
        const currentNodeChildren = new AdvancedIterator(common.ArrayUtils.toIterator(children[0]));
        const newNodeChildren = new AdvancedIterator(common.ArrayUtils.toIterator(children[1]));
        while (!currentNodeChildren.done && !newNodeChildren.done && newNodeChildren.peek.getEnd() <= this.start)
            this.straightReplace(currentNodeChildren.next(), newNodeChildren.next(), newSourceFile);
        while (!currentNodeChildren.done && !newNodeChildren.done
            && (currentNodeChildren.peek.getStart(currentSourceFile) < this.start
                || currentNodeChildren.peek.getStart(currentSourceFile) === this.start && newNodeChildren.peek.end > this.end)) {
            this.rangeHandlerReplace(currentNodeChildren.next(), newNodeChildren.next(), newSourceFile);
        }
        while (!newNodeChildren.done && newNodeChildren.peek.getEnd() <= this.end)
            newNodeChildren.next();
        while (!currentNodeChildren.done)
            this.straightReplace(currentNodeChildren.next(), newNodeChildren.next(), newSourceFile);
        if (!newNodeChildren.done)
            throw new Error("Error replacing tree: Should not have children left over.");
        this.compilerFactory.replaceCompilerNode(currentNode, newNode);
    }
    straightReplace(currentNode, nextNode, newSourceFile) {
        this.helper.handleForValues(this.straightReplacementNodeHandler, currentNode, nextNode, newSourceFile);
    }
    rangeHandlerReplace(currentNode, nextNode, newSourceFile) {
        this.helper.handleForValues(this, currentNode, nextNode, newSourceFile);
    }
}

class RangeParentHandler {
    constructor(compilerFactory, opts) {
        var _a;
        this.compilerFactory = compilerFactory;
        this.straightReplacementNodeHandler = new StraightReplacementNodeHandler(compilerFactory);
        this.helper = new NodeHandlerHelper(compilerFactory);
        this.start = opts.start;
        this.end = opts.end;
        this.replacingLength = opts.replacingLength;
        this.replacingNodes = (_a = opts.replacingNodes) === null || _a === void 0 ? void 0 : _a.map(n => n.compilerNode);
        this.customMappings = opts.customMappings;
    }
    handleNode(currentNode, newNode, newSourceFile) {
        const currentSourceFile = currentNode._sourceFile.compilerNode;
        const [currentNodeChildren, newNodeChildren] = this.helper.getCompilerChildrenAsIterators(currentNode, newNode, newSourceFile);
        this.handleCustomMappings(newNode, newSourceFile);
        while (!currentNodeChildren.done && !newNodeChildren.done && newNodeChildren.peek.getStart(newSourceFile) < this.start)
            this.straightReplace(currentNodeChildren.next(), newNodeChildren.next(), newSourceFile);
        const newNodes = [];
        while (!newNodeChildren.done && newNodeChildren.peek.getStart(newSourceFile) >= this.start
            && getRealEnd(newNodeChildren.peek, newSourceFile) <= this.end) {
            newNodes.push(newNodeChildren.next());
        }
        if (this.replacingLength != null) {
            const replacingEnd = this.start + this.replacingLength;
            const oldNodes = [];
            while (!currentNodeChildren.done
                && (getRealEnd(currentNodeChildren.peek, currentSourceFile) <= replacingEnd
                    || currentNodeChildren.peek.getStart(currentSourceFile) < replacingEnd)) {
                oldNodes.push(currentNodeChildren.next());
            }
            if (oldNodes.length === newNodes.length && oldNodes.every((node, i) => node.kind === newNodes[i].kind)) {
                for (let i = 0; i < oldNodes.length; i++) {
                    const node = this.compilerFactory.getExistingNodeFromCompilerNode(oldNodes[i]);
                    if (node != null) {
                        node.forgetDescendants();
                        this.compilerFactory.replaceCompilerNode(oldNodes[i], newNodes[i]);
                    }
                }
            }
            else {
                oldNodes.forEach(node => this.helper.forgetNodeIfNecessary(node));
            }
        }
        while (!currentNodeChildren.done)
            this.straightReplace(currentNodeChildren.next(), newNodeChildren.next(), newSourceFile);
        if (!newNodeChildren.done)
            throw new Error("Error replacing tree: Should not have children left over.");
        this.compilerFactory.replaceCompilerNode(currentNode, newNode);
    }
    handleCustomMappings(newParentNode, newSourceFile) {
        if (this.customMappings == null)
            return;
        const customMappings = this.customMappings(newParentNode, newSourceFile);
        for (const mapping of customMappings)
            mapping.currentNode._context.compilerFactory.replaceCompilerNode(mapping.currentNode, mapping.newNode);
    }
    straightReplace(currentNode, nextNode, newSourceFile) {
        if (!this.tryReplaceNode(currentNode))
            this.helper.handleForValues(this.straightReplacementNodeHandler, currentNode, nextNode, newSourceFile);
    }
    tryReplaceNode(currentCompilerNode) {
        if (this.replacingNodes == null || this.replacingNodes.length === 0)
            return false;
        const index = this.replacingNodes.indexOf(currentCompilerNode);
        if (index === -1)
            return false;
        this.replacingNodes.splice(index, 1);
        this.helper.forgetNodeIfNecessary(currentCompilerNode);
        return true;
    }
}
function getRealEnd(node, sourceFile) {
    if (node.kind >= common.ts.SyntaxKind.FirstJSDocNode && node.kind <= common.ts.SyntaxKind.LastJSDocNode) {
        return getPreviousMatchingPos(sourceFile.text, node.end, charCode => charCode !== CharCodes.ASTERISK && !common.StringUtils.isWhitespaceCharCode(charCode));
    }
    return node.end;
}

class RenameNodeHandler extends StraightReplacementNodeHandler {
    handleNode(currentNode, newNode, newSourceFile) {
        const currentNodeKind = currentNode.getKind();
        const newNodeKind = newNode.kind;
        if (currentNodeKind === common.SyntaxKind.ShorthandPropertyAssignment && newNodeKind === common.SyntaxKind.PropertyAssignment) {
            const currentSourceFile = currentNode.getSourceFile();
            const currentIdentifier = currentNode.getNameNode();
            const newIdentifier = newNode.initializer;
            this.compilerFactory.replaceCompilerNode(currentIdentifier, newIdentifier);
            currentNode.forget();
            this.compilerFactory.getNodeFromCompilerNode(newNode, currentSourceFile);
            return;
        }
        else if (currentNodeKind === common.SyntaxKind.ExportSpecifier && newNodeKind === common.SyntaxKind.ExportSpecifier
            && currentNode.compilerNode.propertyName == null && newNode.propertyName != null) {
            handleImportOrExportSpecifier(this.compilerFactory);
            return;
        }
        else if (currentNodeKind === common.SyntaxKind.ImportSpecifier && newNodeKind === common.SyntaxKind.ImportSpecifier
            && currentNode.compilerNode.propertyName == null && newNode.propertyName != null) {
            handleImportOrExportSpecifier(this.compilerFactory);
            return;
        }
        super.handleNode(currentNode, newNode, newSourceFile);
        return;
        function handleImportOrExportSpecifier(compilerFactory) {
            const currentIdentifier = currentNode.getNameNode();
            const newSpecifier = newNode;
            const newPropertyName = newSpecifier.propertyName;
            const newName = newSpecifier.name;
            const newIdentifier = newPropertyName.escapedText === currentIdentifier.compilerNode.escapedText ? newName : newPropertyName;
            compilerFactory.replaceCompilerNode(currentIdentifier, newIdentifier);
            compilerFactory.replaceCompilerNode(currentNode, newNode);
        }
    }
}

class TryOrForgetNodeHandler {
    constructor(handler) {
        this.handler = handler;
    }
    handleNode(currentNode, newNode, newSourceFile) {
        if (!Node.isSourceFile(currentNode))
            throw new common.errors.InvalidOperationError(`Can only use a ${"TryOrForgetNodeHandler"} with a source file.`);
        try {
            this.handler.handleNode(currentNode, newNode, newSourceFile);
        }
        catch (ex) {
            currentNode._context.logger.warn("Could not replace tree, so forgetting all nodes instead. Message: " + ex);
            currentNode.getChildSyntaxListOrThrow().forget();
            currentNode._context.compilerFactory.replaceCompilerNode(currentNode, newNode);
        }
    }
}

class UnwrapParentHandler {
    constructor(compilerFactory, childIndex) {
        this.compilerFactory = compilerFactory;
        this.childIndex = childIndex;
        this.straightReplacementNodeHandler = new StraightReplacementNodeHandler(compilerFactory);
        this.helper = new NodeHandlerHelper(compilerFactory);
    }
    handleNode(currentNode, newNode, newSourceFile) {
        const [currentChildren, newChildren] = this.helper.getCompilerChildrenAsIterators(currentNode, newNode, newSourceFile);
        let index = 0;
        while (!currentChildren.done && !newChildren.done && index++ < this.childIndex)
            this.helper.handleForValues(this.straightReplacementNodeHandler, currentChildren.next(), newChildren.next(), newSourceFile);
        const currentChild = this.compilerFactory.getExistingNodeFromCompilerNode(currentChildren.next());
        const childSyntaxList = currentChild.getChildSyntaxListOrThrow();
        for (const child of ExtendedParser.getCompilerChildren(childSyntaxList.compilerNode, childSyntaxList._sourceFile.compilerNode))
            this.helper.handleForValues(this.straightReplacementNodeHandler, child, newChildren.next(), newSourceFile);
        forgetNodes(currentChild);
        function forgetNodes(node) {
            if (node === childSyntaxList) {
                node._forgetOnlyThis();
                return;
            }
            for (const child of node._getChildrenInCacheIterator())
                forgetNodes(child);
            node._forgetOnlyThis();
        }
        while (!currentChildren.done)
            this.helper.handleForValues(this.straightReplacementNodeHandler, currentChildren.next(), newChildren.next(), newSourceFile);
        if (!newChildren.done)
            throw new Error("Error replacing tree: Should not have children left over.");
        this.compilerFactory.replaceCompilerNode(currentNode, newNode);
    }
}

class NodeHandlerFactory {
    getDefault(opts) {
        const { parent: changingParent, isFirstChild, childCount, customMappings } = opts;
        const sourceFile = changingParent.getSourceFile();
        const compilerFactory = sourceFile._context.compilerFactory;
        const replacingNodes = opts.replacingNodes == null ? undefined : [...opts.replacingNodes];
        const parentHandler = new DefaultParentHandler(compilerFactory, { childCount, isFirstChild, replacingNodes, customMappings });
        if (changingParent === sourceFile)
            return parentHandler;
        else
            return new ParentFinderReplacementNodeHandler(compilerFactory, parentHandler, changingParent);
    }
    getForParentRange(opts) {
        const { parent: changingParent, start, end, replacingLength, replacingNodes, customMappings } = opts;
        const sourceFile = changingParent.getSourceFile();
        const compilerFactory = sourceFile._context.compilerFactory;
        const parentHandler = new RangeParentHandler(compilerFactory, { start, end, replacingLength, replacingNodes, customMappings });
        if (changingParent === sourceFile)
            return parentHandler;
        else
            return new ParentFinderReplacementNodeHandler(compilerFactory, parentHandler, changingParent);
    }
    getForRange(opts) {
        const { sourceFile, start, end } = opts;
        const compilerFactory = sourceFile._context.compilerFactory;
        return new RangeHandler(compilerFactory, { start, end });
    }
    getForChildIndex(opts) {
        const { parent, childIndex, childCount, replacingNodes, customMappings } = opts;
        const parentChildren = parent.getChildren();
        common.errors.throwIfOutOfRange(childIndex, [0, parentChildren.length], "opts.childIndex");
        if (childCount < 0)
            common.errors.throwIfOutOfRange(childCount, [childIndex - parentChildren.length, 0], "opts.childCount");
        let i = 0;
        const isFirstChild = () => i++ === childIndex;
        return this.getDefault({
            parent,
            isFirstChild,
            childCount,
            replacingNodes,
            customMappings,
        });
    }
    getForStraightReplacement(compilerFactory) {
        return new StraightReplacementNodeHandler(compilerFactory);
    }
    getForForgetChanged(compilerFactory) {
        return new ForgetChangedNodeHandler(compilerFactory);
    }
    getForRename(compilerFactory) {
        return new RenameNodeHandler(compilerFactory);
    }
    getForTryOrForget(handler) {
        return new TryOrForgetNodeHandler(handler);
    }
    getForChangingChildOrder(opts) {
        const { parent: changingParent, oldIndex, newIndex } = opts;
        const sourceFile = changingParent.getSourceFile();
        const compilerFactory = sourceFile._context.compilerFactory;
        const changeChildOrderParentHandler = new ChangeChildOrderParentHandler(compilerFactory, { oldIndex, newIndex });
        if (changingParent === sourceFile)
            return changeChildOrderParentHandler;
        else
            return new ParentFinderReplacementNodeHandler(compilerFactory, changeChildOrderParentHandler, changingParent);
    }
    getForUnwrappingNode(unwrappingNode) {
        const changingParent = unwrappingNode.getParentSyntaxList() || unwrappingNode.getParentOrThrow();
        const childIndex = unwrappingNode.getChildIndex();
        const sourceFile = changingParent.getSourceFile();
        const compilerFactory = sourceFile._context.compilerFactory;
        const unwrapParentHandler = new UnwrapParentHandler(compilerFactory, childIndex);
        if (changingParent === sourceFile)
            return unwrapParentHandler;
        else
            return new ParentFinderReplacementNodeHandler(compilerFactory, unwrapParentHandler, changingParent);
    }
}

function getSpacingBetweenNodes(opts) {
    const { parent, previousSibling, nextSibling, newLineKind, getSiblingFormatting } = opts;
    if (previousSibling == null || nextSibling == null)
        return "";
    const previousSiblingFormatting = getSiblingFormatting(parent, previousSibling);
    const nextSiblingFormatting = getSiblingFormatting(parent, nextSibling);
    if (previousSiblingFormatting === FormattingKind.Blankline || nextSiblingFormatting === FormattingKind.Blankline)
        return newLineKind + newLineKind;
    else if (previousSiblingFormatting === FormattingKind.Newline || nextSiblingFormatting === FormattingKind.Newline)
        return newLineKind;
    else if (previousSiblingFormatting === FormattingKind.Space || nextSiblingFormatting === FormattingKind.Space)
        return " ";
    else
        return "";
}

class ChangingChildOrderTextManipulator {
    constructor(opts) {
        this.opts = opts;
    }
    getNewText(inputText) {
        const { parent, oldIndex, newIndex, getSiblingFormatting } = this.opts;
        const children = parent.getChildren();
        const newLineKind = parent._context.manipulationSettings.getNewLineKindAsString();
        const movingNode = children[oldIndex];
        const fullText = parent._sourceFile.getFullText();
        const movingNodeStart = getPosAtNextNonBlankLine(fullText, movingNode.getPos());
        const movingNodeText = fullText.substring(movingNodeStart, movingNode.getEnd());
        const lowerIndex = Math.min(newIndex, oldIndex);
        const upperIndex = Math.max(newIndex, oldIndex);
        const childrenInNewOrder = getChildrenInNewOrder();
        const isParentSourceFile = Node.isSourceFile(parent.getParentOrThrow());
        let finalText = "";
        fillPrefixText();
        fillTextForIndex(lowerIndex);
        fillMiddleText();
        fillTextForIndex(upperIndex);
        fillSuffixText();
        return finalText;
        function getChildrenInNewOrder() {
            const result = [...children];
            result.splice(oldIndex, 1);
            result.splice(newIndex, 0, movingNode);
            return result;
        }
        function fillPrefixText() {
            finalText += fullText.substring(0, children[lowerIndex].getPos());
            if (lowerIndex === 0 && !isParentSourceFile)
                finalText += newLineKind;
        }
        function fillMiddleText() {
            let startPos;
            let endPos;
            if (lowerIndex === oldIndex) {
                startPos = getPosAtNextNonBlankLine(fullText, children[lowerIndex].getEnd());
                endPos = children[upperIndex].getEnd();
            }
            else {
                startPos = getPosAtNextNonBlankLine(fullText, children[lowerIndex].getPos());
                endPos = children[upperIndex].getPos();
            }
            finalText += fullText.substring(startPos, endPos);
        }
        function fillSuffixText() {
            if (children.length - 1 === upperIndex && !isParentSourceFile)
                finalText += newLineKind;
            finalText += fullText.substring(getPosAtNextNonBlankLine(fullText, children[upperIndex].getEnd()));
        }
        function fillTextForIndex(index) {
            if (index === oldIndex)
                fillSpacingForRemoval();
            else {
                fillSpacingBeforeInsertion();
                finalText += movingNodeText;
                fillSpacingAfterInsertion();
            }
        }
        function fillSpacingForRemoval() {
            if (oldIndex === 0 || oldIndex === children.length - 1)
                return;
            fillSpacingCommon({
                previousSibling: childrenInNewOrder[oldIndex - 1],
                nextSibling: childrenInNewOrder[oldIndex],
            });
        }
        function fillSpacingBeforeInsertion() {
            if (newIndex === 0)
                return;
            fillSpacingCommon({
                previousSibling: childrenInNewOrder[newIndex - 1],
                nextSibling: childrenInNewOrder[newIndex],
            });
        }
        function fillSpacingAfterInsertion() {
            fillSpacingCommon({
                previousSibling: childrenInNewOrder[newIndex],
                nextSibling: childrenInNewOrder[newIndex + 1],
            });
        }
        function fillSpacingCommon(spacingOpts) {
            const spacing = getSpacingBetweenNodes({
                parent,
                getSiblingFormatting,
                newLineKind,
                previousSibling: spacingOpts.previousSibling,
                nextSibling: spacingOpts.nextSibling,
            });
            const twoNewLines = newLineKind + newLineKind;
            if (spacing === twoNewLines) {
                if (finalText.endsWith(twoNewLines))
                    return;
                else if (finalText.endsWith(newLineKind))
                    finalText += newLineKind;
                else
                    finalText += twoNewLines;
            }
            else if (spacing === newLineKind) {
                if (finalText.endsWith(newLineKind))
                    return;
                else
                    finalText += newLineKind;
            }
            else if (spacing === " ") {
                if (finalText.endsWith(" "))
                    return;
                else
                    finalText += " ";
            }
            else {
                finalText += spacing;
            }
        }
    }
    getTextForError(newText) {
        return newText;
    }
}

class FullReplacementTextManipulator {
    constructor(newText) {
        this.newText = newText;
    }
    getNewText(inputText) {
        return this.newText;
    }
    getTextForError(newText) {
        return newText;
    }
}

function getTextForError(newText, pos, length = 0) {
    const startPos = Math.max(0, newText.lastIndexOf("\n", pos) - 100);
    let endPos = Math.min(newText.length, newText.indexOf("\n", pos + length));
    endPos = endPos === -1 ? newText.length : Math.min(newText.length, endPos + 100);
    let text = "";
    text += newText.substring(startPos, endPos);
    if (startPos !== 0)
        text = "..." + text;
    if (endPos !== newText.length)
        text += "...";
    return text;
}

class InsertionTextManipulator {
    constructor(opts) {
        this.opts = opts;
    }
    getNewText(inputText) {
        const { insertPos, newText, replacingLength = 0 } = this.opts;
        return inputText.substring(0, insertPos) + newText + inputText.substring(insertPos + replacingLength);
    }
    getTextForError(newText) {
        return getTextForError(newText, this.opts.insertPos, this.opts.newText.length);
    }
}

class RemoveChildrenTextManipulator {
    constructor(opts) {
        this.opts = opts;
    }
    getNewText(inputText) {
        const opts = this.opts;
        const { children, removePrecedingSpaces = false, removeFollowingSpaces = false, removePrecedingNewLines = false, removeFollowingNewLines = false, replaceTrivia = "", } = opts;
        const sourceFile = children[0].getSourceFile();
        const fullText = sourceFile.getFullText();
        const removalPos = getRemovalPos();
        this.removalPos = removalPos;
        return getPrefix() + replaceTrivia + getSuffix();
        function getPrefix() {
            return fullText.substring(0, removalPos);
        }
        function getSuffix() {
            return fullText.substring(getRemovalEnd());
        }
        function getRemovalPos() {
            if (opts.customRemovalPos != null)
                return opts.customRemovalPos;
            const pos = children[0].getNonWhitespaceStart();
            if (removePrecedingSpaces || removePrecedingNewLines)
                return getPreviousMatchingPos(fullText, pos, getCharRemovalFunction(removePrecedingSpaces, removePrecedingNewLines));
            return pos;
        }
        function getRemovalEnd() {
            if (opts.customRemovalEnd != null)
                return opts.customRemovalEnd;
            const end = children[children.length - 1].getEnd();
            if (removeFollowingSpaces || removeFollowingNewLines)
                return getNextMatchingPos(fullText, end, getCharRemovalFunction(removeFollowingSpaces, removeFollowingNewLines));
            return end;
        }
        function getCharRemovalFunction(removeSpaces, removeNewLines) {
            return (char) => {
                if (removeNewLines && (char === CharCodes.CARRIAGE_RETURN || char === CharCodes.NEWLINE))
                    return false;
                if (removeSpaces && !charNotSpaceOrTab(char))
                    return false;
                return true;
            };
        }
        function charNotSpaceOrTab(charCode) {
            return charCode !== CharCodes.SPACE && charCode !== CharCodes.TAB;
        }
    }
    getTextForError(newText) {
        return getTextForError(newText, this.removalPos);
    }
}

function isNewLineAtPos(fullText, pos) {
    return fullText[pos] === "\n" || (fullText[pos] === "\r" && fullText[pos + 1] === "\n");
}
function hasNewLineInRange(fullText, range) {
    for (let i = range[0]; i < range[1]; i++) {
        if (fullText[i] === "\n")
            return true;
    }
    return false;
}

class RemoveChildrenWithFormattingTextManipulator {
    constructor(opts) {
        this.opts = opts;
    }
    getNewText(inputText) {
        const { children, getSiblingFormatting } = this.opts;
        const firstChild = children[0];
        const lastChild = children[children.length - 1];
        const parent = firstChild.getParentOrThrow();
        const sourceFile = parent.getSourceFile();
        const fullText = sourceFile.getFullText();
        const newLineKind = sourceFile._context.manipulationSettings.getNewLineKindAsString();
        const previousSibling = firstChild.getPreviousSibling();
        const nextSibling = lastChild.getNextSibling();
        const removalPos = getRemovalPos();
        this.removalPos = removalPos;
        return getPrefix() + getSpacing() + getSuffix();
        function getPrefix() {
            return fullText.substring(0, removalPos);
        }
        function getSpacing() {
            return getSpacingBetweenNodes({
                parent,
                previousSibling,
                nextSibling,
                newLineKind,
                getSiblingFormatting,
            });
        }
        function getSuffix() {
            return fullText.substring(getRemovalEnd());
        }
        function getRemovalPos() {
            if (previousSibling != null) {
                const trailingEnd = previousSibling.getTrailingTriviaEnd();
                return isNewLineAtPos(fullText, trailingEnd) ? trailingEnd : previousSibling.getEnd();
            }
            const firstPos = getPreviousNonWhitespacePos(fullText, firstChild.getPos());
            if (parent.getPos() === firstPos)
                return firstChild.getNonWhitespaceStart();
            return firstChild.isFirstNodeOnLine() ? firstPos : firstChild.getNonWhitespaceStart();
        }
        function getRemovalEnd() {
            const triviaEnd = lastChild.getTrailingTriviaEnd();
            if (previousSibling != null && nextSibling != null) {
                const nextSiblingFormatting = getSiblingFormatting(parent, nextSibling);
                if (nextSiblingFormatting === FormattingKind.Blankline || nextSiblingFormatting === FormattingKind.Newline)
                    return getPosAtStartOfLineOrNonWhitespace(fullText, nextSibling.getNonWhitespaceStart());
                return nextSibling.getNonWhitespaceStart();
            }
            if (parent.getEnd() === lastChild.getEnd())
                return lastChild.getEnd();
            if (isNewLineAtPos(fullText, triviaEnd)) {
                if (previousSibling == null && firstChild.getPos() === 0)
                    return getPosAtNextNonBlankLine(fullText, triviaEnd);
                return getPosAtEndOfPreviousLine(fullText, getPosAtNextNonBlankLine(fullText, triviaEnd));
            }
            if (previousSibling == null)
                return triviaEnd;
            else
                return lastChild.getEnd();
        }
    }
    getTextForError(newText) {
        return getTextForError(newText, this.removalPos);
    }
}

class RenameLocationTextManipulator {
    constructor(renameLocations, newName) {
        this.renameLocations = renameLocations;
        this.newName = newName;
    }
    getNewText(inputText) {
        const renameLocations = [...this.renameLocations].sort((a, b) => b.getTextSpan().getStart() - a.getTextSpan().getStart());
        let currentPos = inputText.length;
        let result = "";
        for (let i = 0; i < renameLocations.length; i++) {
            const renameLocation = renameLocations[i];
            const textSpan = renameLocation.getTextSpan();
            result = (renameLocation.getPrefixText() || "")
                + this.newName
                + (renameLocation.getSuffixText() || "")
                + inputText.substring(textSpan.getEnd(), currentPos)
                + result;
            currentPos = textSpan.getStart();
        }
        return inputText.substring(0, currentPos) + result;
    }
    getTextForError(newText) {
        if (this.renameLocations.length === 0)
            return newText;
        return "..." + newText.substring(this.renameLocations[0].getTextSpan().getStart());
    }
}

class UnchangedTextManipulator {
    getNewText(inputText) {
        return inputText;
    }
    getTextForError(newText) {
        return newText;
    }
}

class UnwrapTextManipulator extends InsertionTextManipulator {
    constructor(node) {
        super({
            insertPos: node.getStart(true),
            newText: getReplacementText(node),
            replacingLength: node.getWidth(true),
        });
    }
}
function getReplacementText(node) {
    const sourceFile = node._sourceFile;
    const range = getInnerBraceRange();
    const startPos = range[0];
    const text = sourceFile.getFullText().substring(range[0], range[1]);
    return common.StringUtils.indent(text, -1, {
        indentText: sourceFile._context.manipulationSettings.getIndentationText(),
        indentSizeInSpaces: sourceFile._context.manipulationSettings._getIndentSizeInSpaces(),
        isInStringAtPos: pos => sourceFile.isInStringAtPos(startPos + pos),
    }).trim();
    function getInnerBraceRange() {
        const bodyNode = getBodyNodeOrThrow();
        return [bodyNode.getStart() + 1, bodyNode.getEnd() - 1];
        function getBodyNodeOrThrow() {
            if (Node.isModuleDeclaration(node)) {
                const bodyNode = node._getInnerBody();
                if (bodyNode == null)
                    throw new common.errors.InvalidOperationError("This operation requires the module to have a body.");
                return bodyNode;
            }
            else if (Node.isBodiedNode(node))
                return node.getBody();
            else if (Node.isBodyableNode(node))
                return node.getBodyOrThrow();
            else
                throw new common.errors.NotImplementedError(`Not implemented unwrap scenario for ${node.getKindName()}.`);
        }
    }
}

class ManipulationError extends common.errors.InvalidOperationError {
    constructor(filePath, oldText, newText, errorMessage) {
        super(errorMessage);
        this.filePath = filePath;
        this.oldText = oldText;
        this.newText = newText;
    }
}

function doManipulation(sourceFile, textManipulator, nodeHandler, newFilePath) {
    sourceFile._firePreModified();
    const oldFileText = sourceFile.getFullText();
    const newFileText = textManipulator.getNewText(oldFileText);
    try {
        const replacementSourceFile = sourceFile._context.compilerFactory.createCompilerSourceFileFromText(newFilePath || sourceFile.getFilePath(), newFileText, sourceFile.getScriptKind());
        nodeHandler.handleNode(sourceFile, replacementSourceFile, replacementSourceFile);
    }
    catch (err) {
        const diagnostics = getSyntacticDiagnostics(sourceFile, newFileText);
        const errorDetails = err.message + "\n\n"
            + `-- Details --\n`
            + "Path: " + sourceFile.getFilePath() + "\n"
            + "Text: " + JSON.stringify(textManipulator.getTextForError(newFileText)) + "\n"
            + "Stack: " + err.stack;
        if (diagnostics.length > 0) {
            throwError("Manipulation error: " + "A syntax error was inserted." + "\n\n"
                + sourceFile._context.project.formatDiagnosticsWithColorAndContext(diagnostics, { newLineChar: "\n" })
                + "\n" + errorDetails);
        }
        throwError("Manipulation error: " + errorDetails);
        function throwError(message) {
            throw new ManipulationError(sourceFile.getFilePath(), oldFileText, newFileText, message);
        }
    }
}
function getSyntacticDiagnostics(sourceFile, newText) {
    try {
        const projectOptions = { useInMemoryFileSystem: true };
        const project = new sourceFile._context.project.constructor(projectOptions);
        const newFile = project.createSourceFile(sourceFile.getFilePath(), newText);
        return project.getProgram().getSyntacticDiagnostics(newFile);
    }
    catch (err) {
        return [];
    }
}

function insertIntoParentTextRange(opts) {
    var _a, _b, _c;
    const { insertPos, newText, parent } = opts;
    doManipulation(parent._sourceFile, new InsertionTextManipulator({
        insertPos,
        newText,
        replacingLength: (_a = opts.replacing) === null || _a === void 0 ? void 0 : _a.textLength,
    }), new NodeHandlerFactory().getForParentRange({
        parent,
        start: insertPos,
        end: insertPos + newText.length,
        replacingLength: (_b = opts.replacing) === null || _b === void 0 ? void 0 : _b.textLength,
        replacingNodes: (_c = opts.replacing) === null || _c === void 0 ? void 0 : _c.nodes,
        customMappings: opts.customMappings,
    }));
}
function insertIntoTextRange(opts) {
    const { insertPos, newText, sourceFile } = opts;
    doManipulation(sourceFile, new InsertionTextManipulator({
        insertPos,
        newText,
    }), new NodeHandlerFactory().getForRange({
        sourceFile,
        start: insertPos,
        end: insertPos + newText.length,
    }));
}
function insertIntoCommaSeparatedNodes(opts) {
    const { currentNodes, insertIndex, parent } = opts;
    const previousNode = currentNodes[insertIndex - 1];
    const previousNonCommentNode = getPreviousNonCommentNode();
    const nextNode = currentNodes[insertIndex];
    const nextNonCommentNode = getNextNonCommentNode();
    const separator = opts.useNewLines ? parent._context.manipulationSettings.getNewLineKindAsString() : " ";
    const parentNextSibling = parent.getNextSibling();
    const isContained = parentNextSibling != null && (parentNextSibling.getKind() === common.SyntaxKind.CloseBraceToken || parentNextSibling.getKind() === common.SyntaxKind.CloseBracketToken);
    let { newText } = opts;
    if (previousNode != null) {
        prependCommaAndSeparator();
        if (nextNonCommentNode != null || opts.useTrailingCommas)
            appendCommaAndSeparator();
        else if (opts.useNewLines || opts.surroundWithSpaces)
            appendSeparator();
        else
            appendIndentation();
        const nextEndStart = nextNode == null ? (isContained ? parentNextSibling.getStart(true) : parent.getEnd()) : nextNode.getStart(true);
        const insertPos = (previousNonCommentNode || previousNode).getEnd();
        insertIntoParentTextRange({
            insertPos,
            newText,
            parent,
            replacing: { textLength: nextEndStart - insertPos },
        });
    }
    else if (nextNode != null) {
        if (opts.useNewLines || opts.surroundWithSpaces)
            prependSeparator();
        if (nextNonCommentNode != null || opts.useTrailingCommas)
            appendCommaAndSeparator();
        else
            appendSeparator();
        const insertPos = isContained ? parent.getPos() : parent.getStart(true);
        insertIntoParentTextRange({
            insertPos,
            newText,
            parent,
            replacing: { textLength: nextNode.getStart(true) - insertPos },
        });
    }
    else {
        if (opts.useNewLines || opts.surroundWithSpaces) {
            prependSeparator();
            if (opts.useTrailingCommas)
                appendCommaAndSeparator();
            else
                appendSeparator();
        }
        else {
            appendIndentation();
        }
        insertIntoParentTextRange({
            insertPos: parent.getPos(),
            newText,
            parent,
            replacing: { textLength: parent.getNextSiblingOrThrow().getStart() - parent.getPos() },
        });
    }
    function prependCommaAndSeparator() {
        if (previousNonCommentNode == null) {
            prependSeparator();
            return;
        }
        const originalSourceFileText = parent.getSourceFile().getFullText();
        const previousNodeNextSibling = previousNonCommentNode.getNextSibling();
        let text = "";
        if (previousNodeNextSibling != null && previousNodeNextSibling.getKind() === common.SyntaxKind.CommaToken) {
            appendNodeTrailingCommentRanges(previousNonCommentNode);
            text += ",";
            if (previousNonCommentNode === previousNode)
                appendNodeTrailingCommentRanges(previousNodeNextSibling);
            else
                appendCommentNodeTexts();
        }
        else {
            text += ",";
            if (previousNonCommentNode === previousNode)
                appendNodeTrailingCommentRanges(previousNonCommentNode);
            else
                appendCommentNodeTexts();
        }
        prependSeparator();
        newText = text + newText;
        function appendCommentNodeTexts() {
            const lastCommentRangeEnd = getLastCommentRangeEnd(previousNode) || previousNode.getEnd();
            text += originalSourceFileText.substring(previousNonCommentNode.getEnd(), lastCommentRangeEnd);
        }
        function appendNodeTrailingCommentRanges(node) {
            const lastCommentRangeEnd = getLastCommentRangeEnd(node);
            if (lastCommentRangeEnd == null)
                return;
            text += originalSourceFileText.substring(node.getEnd(), lastCommentRangeEnd);
        }
        function getLastCommentRangeEnd(node) {
            const commentRanges = node.getTrailingCommentRanges();
            const lastCommentRange = commentRanges[commentRanges.length - 1];
            return lastCommentRange === null || lastCommentRange === void 0 ? void 0 : lastCommentRange.getEnd();
        }
    }
    function getPreviousNonCommentNode() {
        for (let i = insertIndex - 1; i >= 0; i--) {
            if (!Node.isCommentNode(currentNodes[i]))
                return currentNodes[i];
        }
        return undefined;
    }
    function getNextNonCommentNode() {
        for (let i = insertIndex; i < currentNodes.length; i++) {
            if (!Node.isCommentNode(currentNodes[i]))
                return currentNodes[i];
        }
        return undefined;
    }
    function prependSeparator() {
        if (!common.StringUtils.startsWithNewLine(newText))
            newText = separator + newText;
    }
    function appendCommaAndSeparator() {
        newText = appendCommaToText(newText);
        appendSeparator();
    }
    function appendSeparator() {
        if (!common.StringUtils.endsWithNewLine(newText))
            newText += separator;
        appendIndentation();
    }
    function appendIndentation() {
        if (opts.useNewLines || common.StringUtils.endsWithNewLine(newText)) {
            if (nextNode != null)
                newText += parent.getParentOrThrow().getChildIndentationText();
            else
                newText += parent.getParentOrThrow().getIndentationText();
        }
    }
}
function insertIntoBracesOrSourceFile(opts) {
    const { parent, index, children } = opts;
    const fullText = parent._sourceFile.getFullText();
    const childSyntaxList = parent.getChildSyntaxListOrThrow();
    const insertPos = getInsertPosFromIndex(index, childSyntaxList, children);
    const endPos = getEndPosFromIndex(index, parent, children, fullText);
    const replacingLength = endPos - insertPos;
    const newText = getNewText();
    doManipulation(parent._sourceFile, new InsertionTextManipulator({ insertPos, replacingLength, newText }), new NodeHandlerFactory().getForParentRange({
        parent: childSyntaxList,
        start: insertPos,
        end: insertPos + newText.length,
        replacingLength,
    }));
    function getNewText() {
        const writer = parent._getWriterWithChildIndentation();
        opts.write(writer, {
            previousMember: getChild(children[index - 1]),
            nextMember: getChild(children[index]),
            isStartOfFile: insertPos === 0,
        });
        return writer.toString();
        function getChild(child) {
            if (child == null)
                return child;
            else if (Node.isOverloadableNode(child))
                return child.getImplementation() || child;
            else
                return child;
        }
    }
}
function insertIntoBracesOrSourceFileWithGetChildren(opts) {
    if (opts.structures.length === 0)
        return [];
    const startChildren = opts.getIndexedChildren();
    const parentSyntaxList = opts.parent.getChildSyntaxListOrThrow();
    const index = verifyAndGetIndex(opts.index, startChildren.length);
    const previousJsDocCount = getPreviousJsDocCount();
    insertIntoBracesOrSourceFile({
        parent: opts.parent,
        index: getChildIndex(),
        children: parentSyntaxList.getChildren(),
        write: opts.write,
    });
    return getRangeWithoutCommentsFromArray(opts.getIndexedChildren(), opts.index - previousJsDocCount, opts.structures.length, opts.expectedKind);
    function getChildIndex() {
        if (index === 0)
            return 0;
        return startChildren[index - 1].getChildIndex() + 1;
    }
    function getPreviousJsDocCount() {
        let commentCount = 0;
        let count = 0;
        for (let i = index - 1; i >= 0; i--) {
            const node = startChildren[i];
            if (Node.isCommentNode(node)) {
                commentCount++;
                if (node.getText().startsWith("/**"))
                    count = commentCount;
            }
            else {
                break;
            }
        }
        return count;
    }
}
function insertIntoBracesOrSourceFileWithGetChildrenWithComments(opts) {
    const startChildren = opts.getIndexedChildren();
    const parentSyntaxList = opts.parent.getChildSyntaxListOrThrow();
    const index = verifyAndGetIndex(opts.index, startChildren.length);
    insertIntoBracesOrSourceFile({
        parent: opts.parent,
        index: getChildIndex(),
        children: parentSyntaxList.getChildren(),
        write: opts.write,
    });
    return getNodesToReturn(startChildren, opts.getIndexedChildren(), index, true);
    function getChildIndex() {
        if (index === 0)
            return 0;
        return startChildren[index - 1].getChildIndex() + 1;
    }
}

function changeChildOrder(opts) {
    const { parent } = opts;
    doManipulation(parent._sourceFile, new ChangingChildOrderTextManipulator(opts), new NodeHandlerFactory().getForChangingChildOrder(opts));
}

function removeChildren(opts) {
    const { children } = opts;
    if (children.length === 0)
        return;
    doManipulation(children[0].getSourceFile(), new RemoveChildrenTextManipulator(opts), new NodeHandlerFactory().getForChildIndex({
        parent: children[0].getParentSyntaxList() || children[0].getParentOrThrow(),
        childIndex: children[0].getChildIndex(),
        childCount: -1 * children.length,
    }));
}
function removeChildrenWithFormattingFromCollapsibleSyntaxList(opts) {
    const { children } = opts;
    if (children.length === 0)
        return;
    const syntaxList = children[0].getParentSyntaxListOrThrow();
    if (syntaxList.getChildCount() === children.length) {
        removeChildrenWithFormatting({
            children: [syntaxList],
            getSiblingFormatting: () => FormattingKind.None,
        });
    }
    else {
        removeChildrenWithFormatting(opts);
    }
}
function removeChildrenWithFormatting(opts) {
    const { children, getSiblingFormatting } = opts;
    if (children.length === 0)
        return;
    doManipulation(children[0]._sourceFile, new RemoveChildrenWithFormattingTextManipulator({
        children,
        getSiblingFormatting,
    }), new NodeHandlerFactory().getForChildIndex({
        parent: children[0].getParentSyntaxList() || children[0].getParentOrThrow(),
        childIndex: children[0].getChildIndex(),
        childCount: -1 * children.length,
    }));
}
function removeClassMember(classMember) {
    if (Node.isOverloadableNode(classMember)) {
        if (classMember.isImplementation())
            removeClassMembers([...classMember.getOverloads(), classMember]);
        else {
            const parent = classMember.getParentOrThrow();
            if (Node.isAmbientableNode(parent) && parent.isAmbient())
                removeClassMembers([classMember]);
            else
                removeChildren({ children: [classMember], removeFollowingSpaces: true, removeFollowingNewLines: true });
        }
    }
    else {
        removeClassMembers([classMember]);
    }
}
function removeClassMembers(classMembers) {
    removeChildrenWithFormatting({
        getSiblingFormatting: getClassMemberFormatting,
        children: classMembers,
    });
}
function removeInterfaceMember(interfaceMember) {
    removeInterfaceMembers([interfaceMember]);
}
function removeInterfaceMembers(interfaceMembers) {
    removeChildrenWithFormatting({
        getSiblingFormatting: getInterfaceMemberFormatting,
        children: interfaceMembers,
    });
}
function removeCommaSeparatedChild(child) {
    const childrenToRemove = [child];
    const syntaxList = child.getParentSyntaxListOrThrow();
    const isRemovingFirstChild = childrenToRemove[0] === syntaxList.getFirstChild();
    addNextCommaIfAble();
    addPreviousCommaIfAble();
    removeChildren({
        children: childrenToRemove,
        removePrecedingSpaces: !isRemovingFirstChild || syntaxList.getChildren().length === childrenToRemove.length && childrenToRemove[0].isFirstNodeOnLine(),
        removeFollowingSpaces: isRemovingFirstChild,
        removePrecedingNewLines: !isRemovingFirstChild,
        removeFollowingNewLines: isRemovingFirstChild,
    });
    function addNextCommaIfAble() {
        const commaToken = child.getNextSiblingIfKind(common.SyntaxKind.CommaToken);
        if (commaToken != null)
            childrenToRemove.push(commaToken);
    }
    function addPreviousCommaIfAble() {
        if (syntaxList.getLastChild() !== childrenToRemove[childrenToRemove.length - 1])
            return;
        const precedingComma = child.getPreviousSiblingIfKind(common.SyntaxKind.CommaToken);
        if (precedingComma != null)
            childrenToRemove.unshift(precedingComma);
    }
}
function removeOverloadableStatementedNodeChild(node) {
    if (node.isOverload())
        removeChildren({ children: [node], removeFollowingSpaces: true, removeFollowingNewLines: true });
    else
        removeStatementedNodeChildren([...node.getOverloads(), node]);
}
function removeStatementedNodeChild(node) {
    removeStatementedNodeChildren([node]);
}
function removeStatementedNodeChildren(nodes) {
    removeChildrenWithFormatting({
        getSiblingFormatting: getStatementedNodeChildFormatting,
        children: nodes,
    });
}
function removeClausedNodeChild(node) {
    removeClausedNodeChildren([node]);
}
function removeClausedNodeChildren(nodes) {
    removeChildrenWithFormatting({
        getSiblingFormatting: getClausedNodeChildFormatting,
        children: nodes,
    });
}
function unwrapNode(node) {
    doManipulation(node._sourceFile, new UnwrapTextManipulator(node), new NodeHandlerFactory().getForUnwrappingNode(node));
}

function replaceNodeText(opts) {
    doManipulation(opts.sourceFile, new InsertionTextManipulator({
        insertPos: opts.start,
        newText: opts.newText,
        replacingLength: opts.replacingLength,
    }), new NodeHandlerFactory().getForForgetChanged(opts.sourceFile._context.compilerFactory));
}
function replaceSourceFileTextForFormatting(opts) {
    replaceSourceFileTextStraight(opts);
}
function replaceSourceFileTextStraight(opts) {
    const { sourceFile, newText } = opts;
    doManipulation(sourceFile, new FullReplacementTextManipulator(newText), new NodeHandlerFactory().getForStraightReplacement(sourceFile._context.compilerFactory));
}
function replaceSourceFileTextForRename(opts) {
    const { sourceFile, renameLocations, newName } = opts;
    const nodeHandlerFactory = new NodeHandlerFactory();
    doManipulation(sourceFile, new RenameLocationTextManipulator(renameLocations, newName), nodeHandlerFactory.getForTryOrForget(nodeHandlerFactory.getForRename(sourceFile._context.compilerFactory)));
}
function replaceTextPossiblyCreatingChildNodes(opts) {
    const { replacePos, replacingLength, newText, parent } = opts;
    doManipulation(parent._sourceFile, new InsertionTextManipulator({
        insertPos: replacePos,
        replacingLength,
        newText,
    }), new NodeHandlerFactory().getForParentRange({
        parent,
        start: replacePos,
        end: replacePos + newText.length,
    }));
}
function replaceSourceFileForFilePathMove(opts) {
    const { sourceFile, newFilePath } = opts;
    doManipulation(sourceFile, new UnchangedTextManipulator(), new NodeHandlerFactory().getForStraightReplacement(sourceFile._context.compilerFactory), newFilePath);
}
function replaceSourceFileForCacheUpdate(sourceFile) {
    replaceSourceFileForFilePathMove({ sourceFile, newFilePath: sourceFile.getFilePath() });
}

function ArgumentedNode(Base) {
    return class extends Base {
        getArguments() {
            var _a, _b;
            return (_b = (_a = this.compilerNode.arguments) === null || _a === void 0 ? void 0 : _a.map(a => this._getNodeFromCompilerNode(a))) !== null && _b !== void 0 ? _b : [];
        }
        addArgument(argumentText) {
            return this.addArguments([argumentText])[0];
        }
        addArguments(argumentTexts) {
            return this.insertArguments(this.getArguments().length, argumentTexts);
        }
        insertArgument(index, argumentText) {
            return this.insertArguments(index, [argumentText])[0];
        }
        insertArguments(index, argumentTexts) {
            if (argumentTexts instanceof Function)
                argumentTexts = [argumentTexts];
            if (common.ArrayUtils.isNullOrEmpty(argumentTexts))
                return [];
            this._addParensIfNecessary();
            const originalArgs = this.getArguments();
            index = verifyAndGetIndex(index, originalArgs.length);
            const writer = this._getWriterWithQueuedChildIndentation();
            for (let i = 0; i < argumentTexts.length; i++) {
                writer.conditionalWrite(i > 0, ", ");
                printTextFromStringOrWriter(writer, argumentTexts[i]);
            }
            insertIntoCommaSeparatedNodes({
                parent: this.getFirstChildByKindOrThrow(common.SyntaxKind.OpenParenToken).getNextSiblingIfKindOrThrow(common.SyntaxKind.SyntaxList),
                currentNodes: originalArgs,
                insertIndex: index,
                newText: writer.toString(),
                useTrailingCommas: false,
            });
            return getNodesToReturn(originalArgs, this.getArguments(), index, false);
        }
        removeArgument(argOrIndex) {
            const args = this.getArguments();
            if (args.length === 0)
                throw new common.errors.InvalidOperationError("Cannot remove an argument when none exist.");
            const argToRemove = typeof argOrIndex === "number" ? getArgFromIndex(argOrIndex) : argOrIndex;
            removeCommaSeparatedChild(argToRemove);
            return this;
            function getArgFromIndex(index) {
                return args[verifyAndGetIndex(index, args.length - 1)];
            }
        }
        _addParensIfNecessary() {
            const fullText = this.getFullText();
            if (fullText[fullText.length - 1] !== ")") {
                insertIntoParentTextRange({
                    insertPos: this.getEnd(),
                    newText: "()",
                    parent: this,
                });
            }
        }
    };
}

function AsyncableNode(Base) {
    return class extends Base {
        isAsync() {
            return this.hasModifier(common.SyntaxKind.AsyncKeyword);
        }
        getAsyncKeyword() {
            return this.getFirstModifierByKind(common.SyntaxKind.AsyncKeyword);
        }
        getAsyncKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getAsyncKeyword(), "Expected to find an async keyword.");
        }
        setIsAsync(value) {
            this.toggleModifier("async", value);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.isAsync != null)
                this.setIsAsync(structure.isAsync);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                isAsync: this.isAsync(),
            });
        }
    };
}

function AwaitableNode(Base) {
    return class extends Base {
        isAwaited() {
            return this.compilerNode.awaitModifier != null;
        }
        getAwaitKeyword() {
            const awaitModifier = this.compilerNode.awaitModifier;
            return this._getNodeFromCompilerNodeIfExists(awaitModifier);
        }
        getAwaitKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getAwaitKeyword(), "Expected to find an await token.");
        }
        setIsAwaited(value) {
            const awaitModifier = this.getAwaitKeyword();
            const isSet = awaitModifier != null;
            if (isSet === value)
                return this;
            if (awaitModifier == null) {
                insertIntoParentTextRange({
                    insertPos: getAwaitInsertPos(this),
                    parent: this,
                    newText: " await",
                });
            }
            else {
                removeChildren({
                    children: [awaitModifier],
                    removePrecedingSpaces: true,
                });
            }
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.isAwaited != null)
                this.setIsAwaited(structure.isAwaited);
            return this;
        }
    };
}
function getAwaitInsertPos(node) {
    if (node.getKind() === common.SyntaxKind.ForOfStatement)
        return node.getFirstChildByKindOrThrow(common.SyntaxKind.ForKeyword).getEnd();
    throw new common.errors.NotImplementedError("Expected a for of statement node.");
}

function getBodyText(writer, textOrWriterFunction) {
    writer.newLineIfLastNot();
    if (typeof textOrWriterFunction !== "string" || textOrWriterFunction.length > 0) {
        writer.indent(() => {
            printTextFromStringOrWriter(writer, textOrWriterFunction);
        });
    }
    writer.newLineIfLastNot();
    writer.write("");
    return writer.toString();
}

function getBodyTextWithoutLeadingIndentation(body) {
    const sourceFile = body._sourceFile;
    const textArea = body.getChildSyntaxList() || body;
    const startPos = textArea.getNonWhitespaceStart();
    const endPos = Math.max(startPos, textArea._getTrailingTriviaNonWhitespaceEnd());
    const width = endPos - startPos;
    if (width === 0)
        return "";
    const fullText = sourceFile.getFullText().substring(startPos, endPos);
    return common.StringUtils.removeIndentation(fullText, {
        indentSizeInSpaces: body._context.manipulationSettings._getIndentSizeInSpaces(),
        isInStringAtPos: pos => sourceFile.isInStringAtPos(pos + startPos),
    });
}

class TextRange {
    constructor(compilerObject, sourceFile) {
        this._compilerObject = compilerObject;
        this._sourceFile = sourceFile;
    }
    get compilerObject() {
        this._throwIfForgotten();
        return this._compilerObject;
    }
    getSourceFile() {
        this._throwIfForgotten();
        return this._sourceFile;
    }
    getPos() {
        return this.compilerObject.pos;
    }
    getEnd() {
        return this.compilerObject.end;
    }
    getWidth() {
        return this.getEnd() - this.getPos();
    }
    getText() {
        const fullText = this.getSourceFile().getFullText();
        return fullText.substring(this.compilerObject.pos, this.compilerObject.end);
    }
    _forget() {
        this._compilerObject = undefined;
        this._sourceFile = undefined;
    }
    wasForgotten() {
        return this._compilerObject == null;
    }
    _throwIfForgotten() {
        if (this._compilerObject != null)
            return;
        const message = "Attempted to get a text range that was forgotten. "
            + "Text ranges are forgotten after a manipulation has occurred. "
            + "Please re-request the text range after manipulations.";
        throw new common.errors.InvalidOperationError(message);
    }
}

class CommentRange extends TextRange {
    constructor(compilerObject, sourceFile) {
        super(compilerObject, sourceFile);
    }
    getKind() {
        return this.compilerObject.kind;
    }
}

class Node {
    constructor(context, node, sourceFile) {
        this._wrappedChildCount = 0;
        if (context == null || context.compilerFactory == null) {
            throw new common.errors.InvalidOperationError("Constructing a node is not supported. Please create a source file from the default export "
                + "of the package and manipulate the source file from there.");
        }
        this._context = context;
        this._compilerNode = node;
        this.__sourceFile = sourceFile;
    }
    get _sourceFile() {
        if (this.__sourceFile == null)
            throw new common.errors.InvalidOperationError("Operation cannot be performed on a node that has no source file.");
        return this.__sourceFile;
    }
    get compilerNode() {
        if (this._compilerNode == null) {
            let message = "Attempted to get information from a node that was removed or forgotten.";
            if (this._forgottenText != null)
                message += `\n\nNode text: ${this._forgottenText}`;
            throw new common.errors.InvalidOperationError(message);
        }
        return this._compilerNode;
    }
    forget() {
        if (this.wasForgotten())
            return;
        this.forgetDescendants();
        this._forgetOnlyThis();
    }
    forgetDescendants() {
        for (const child of this._getChildrenInCacheIterator())
            child.forget();
        return this;
    }
    _forgetOnlyThis() {
        if (this.wasForgotten())
            return;
        const parent = this.getParent();
        if (parent != null)
            parent._wrappedChildCount--;
        const parentSyntaxList = this._getParentSyntaxListIfWrapped();
        if (parentSyntaxList != null)
            parentSyntaxList._wrappedChildCount--;
        this._storeTextForForgetting();
        this._context.compilerFactory.removeNodeFromCache(this);
        this._clearInternals();
    }
    wasForgotten() {
        return this._compilerNode == null;
    }
    _hasWrappedChildren() {
        return this._wrappedChildCount > 0;
    }
    _replaceCompilerNodeFromFactory(compilerNode) {
        if (compilerNode == null)
            this._storeTextForForgetting();
        this._clearInternals();
        this._compilerNode = compilerNode;
    }
    _storeTextForForgetting() {
        const sourceFileCompilerNode = this._sourceFile && this._sourceFile.compilerNode;
        const compilerNode = this._compilerNode;
        if (sourceFileCompilerNode == null || compilerNode == null)
            return;
        this._forgottenText = getText();
        function getText() {
            const start = compilerNode.getStart(sourceFileCompilerNode);
            const length = compilerNode.end - start;
            const trimmedLength = Math.min(length, 100);
            const text = sourceFileCompilerNode.text.substr(start, trimmedLength);
            return trimmedLength !== length ? text + "..." : text;
        }
    }
    _clearInternals() {
        this._compilerNode = undefined;
        this._childStringRanges = undefined;
        clearTextRanges(this._leadingCommentRanges);
        clearTextRanges(this._trailingCommentRanges);
        delete this._leadingCommentRanges;
        delete this._trailingCommentRanges;
        function clearTextRanges(textRanges) {
            if (textRanges == null)
                return;
            textRanges.forEach(r => r._forget());
        }
    }
    getKind() {
        return this.compilerNode.kind;
    }
    getKindName() {
        return common.getSyntaxKindName(this.compilerNode.kind);
    }
    getFlags() {
        return this.compilerNode.flags;
    }
    print(options = {}) {
        if (options.newLineKind == null)
            options.newLineKind = this._context.manipulationSettings.getNewLineKind();
        if (this.getKind() === common.SyntaxKind.SourceFile)
            return printNode(this.compilerNode, options);
        else
            return printNode(this.compilerNode, this._sourceFile.compilerNode, options);
    }
    getSymbolOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getSymbol(), "Could not find the node's symbol.");
    }
    getSymbol() {
        const boundSymbol = this.compilerNode.symbol;
        if (boundSymbol != null)
            return this._context.compilerFactory.getSymbol(boundSymbol);
        const typeChecker = this._context.typeChecker;
        const typeCheckerSymbol = typeChecker.getSymbolAtLocation(this);
        if (typeCheckerSymbol != null)
            return typeCheckerSymbol;
        const nameNode = this.compilerNode.name;
        if (nameNode != null)
            return this._getNodeFromCompilerNode(nameNode).getSymbol();
        return undefined;
    }
    getSymbolsInScope(meaning) {
        return this._context.typeChecker.getSymbolsInScope(this, meaning);
    }
    getLocalOrThrow(name) {
        return common.errors.throwIfNullOrUndefined(this.getLocal(name), `Expected to find local symbol with name: ${name}`);
    }
    getLocal(name) {
        const locals = this._getCompilerLocals();
        if (locals == null)
            return undefined;
        const tsSymbol = locals.get(common.ts.escapeLeadingUnderscores(name));
        return tsSymbol == null ? undefined : this._context.compilerFactory.getSymbol(tsSymbol);
    }
    getLocals() {
        const locals = this._getCompilerLocals();
        if (locals == null)
            return [];
        return common.ArrayUtils.from(locals.values()).map(symbol => this._context.compilerFactory.getSymbol(symbol));
    }
    _getCompilerLocals() {
        this._ensureBound();
        return this.compilerNode.locals;
    }
    getType() {
        return this._context.typeChecker.getTypeAtLocation(this);
    }
    containsRange(pos, end) {
        return this.getPos() <= pos && end <= this.getEnd();
    }
    isInStringAtPos(pos) {
        common.errors.throwIfOutOfRange(pos, [this.getPos(), this.getEnd()], "pos");
        if (this._childStringRanges == null) {
            this._childStringRanges = [];
            for (const descendant of this._getCompilerDescendantsIterator()) {
                if (isStringKind(descendant.kind))
                    this._childStringRanges.push([descendant.getStart(this._sourceFile.compilerNode), descendant.getEnd()]);
            }
        }
        class InStringRangeComparer {
            compareTo(value) {
                if (pos <= value[0])
                    return -1;
                if (pos >= value[1] - 1)
                    return 1;
                return 0;
            }
        }
        return common.ArrayUtils.binarySearch(this._childStringRanges, new InStringRangeComparer()) !== -1;
    }
    asKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.asKind(kind), () => `Expected the node to be of kind ${common.getSyntaxKindName(kind)}, but it was ${common.getSyntaxKindName(this.getKind())}.`);
    }
    asKind(kind) {
        if (this.getKind() === kind) {
            return this;
        }
        else {
            return undefined;
        }
    }
    getFirstChildOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getFirstChild(condition), "Could not find a child that matched the specified condition.");
    }
    getFirstChild(condition) {
        const firstChild = this._getCompilerFirstChild(getWrappedCondition(this, condition));
        return this._getNodeFromCompilerNodeIfExists(firstChild);
    }
    getLastChildOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getLastChild(condition), "Could not find a child that matched the specified condition.");
    }
    getLastChild(condition) {
        const lastChild = this._getCompilerLastChild(getWrappedCondition(this, condition));
        return this._getNodeFromCompilerNodeIfExists(lastChild);
    }
    getFirstDescendantOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getFirstDescendant(condition), "Could not find a descendant that matched the specified condition.");
    }
    getFirstDescendant(condition) {
        for (const descendant of this._getDescendantsIterator()) {
            if (condition == null || condition(descendant))
                return descendant;
        }
        return undefined;
    }
    getPreviousSiblingOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getPreviousSibling(condition), "Could not find the previous sibling.");
    }
    getPreviousSibling(condition) {
        const previousSibling = this._getCompilerPreviousSibling(getWrappedCondition(this, condition));
        return this._getNodeFromCompilerNodeIfExists(previousSibling);
    }
    getNextSiblingOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getNextSibling(condition), "Could not find the next sibling.");
    }
    getNextSibling(condition) {
        const nextSibling = this._getCompilerNextSibling(getWrappedCondition(this, condition));
        return this._getNodeFromCompilerNodeIfExists(nextSibling);
    }
    getPreviousSiblings() {
        return this._getCompilerPreviousSiblings().map(n => this._getNodeFromCompilerNode(n));
    }
    getNextSiblings() {
        return this._getCompilerNextSiblings().map(n => this._getNodeFromCompilerNode(n));
    }
    getChildren() {
        return this._getCompilerChildren().map(n => this._getNodeFromCompilerNode(n));
    }
    getChildAtIndex(index) {
        return this._getNodeFromCompilerNode(this._getCompilerChildAtIndex(index));
    }
    *_getChildrenIterator() {
        for (const compilerChild of this._getCompilerChildren())
            yield this._getNodeFromCompilerNode(compilerChild);
    }
    *_getChildrenInCacheIterator() {
        const children = this._getCompilerChildrenFast();
        for (const child of children) {
            if (this._context.compilerFactory.hasCompilerNode(child))
                yield this._context.compilerFactory.getExistingNodeFromCompilerNode(child);
            else if (child.kind === common.SyntaxKind.SyntaxList) {
                yield this._getNodeFromCompilerNode(child);
            }
        }
    }
    getChildSyntaxListOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getChildSyntaxList(), "A child syntax list was expected.");
    }
    getChildSyntaxList() {
        let node = this;
        if (Node.isBodyableNode(node) || Node.isBodiedNode(node)) {
            do {
                const bodyNode = Node.isBodyableNode(node) ? node.getBody() : node.getBody();
                if (bodyNode == null)
                    return undefined;
                node = bodyNode;
            } while ((Node.isBodyableNode(node) || Node.isBodiedNode(node)) && node.compilerNode.statements == null);
        }
        if (Node.isSourceFile(node)
            || Node.isBodyableNode(this)
            || Node.isBodiedNode(this)
            || Node.isCaseBlock(this)
            || Node.isCaseClause(this)
            || Node.isDefaultClause(this)
            || Node.isJsxElement(this)) {
            return node.getFirstChildByKind(common.SyntaxKind.SyntaxList);
        }
        let passedBrace = false;
        for (const child of node._getCompilerChildren()) {
            if (!passedBrace)
                passedBrace = child.kind === common.SyntaxKind.OpenBraceToken;
            else if (child.kind === common.SyntaxKind.SyntaxList)
                return this._getNodeFromCompilerNode(child);
        }
        return undefined;
    }
    forEachChild(cbNode, cbNodeArray) {
        const snapshots = [];
        this.compilerNode.forEachChild(node => {
            snapshots.push(this._getNodeFromCompilerNode(node));
        }, cbNodeArray == null ? undefined : nodes => {
            snapshots.push(nodes.map(n => this._getNodeFromCompilerNode(n)));
        });
        for (const snapshot of snapshots) {
            if (snapshot instanceof Array) {
                const filteredNodes = snapshot.filter(n => !n.wasForgotten());
                if (filteredNodes.length > 0) {
                    const returnValue = cbNodeArray(filteredNodes);
                    if (returnValue)
                        return returnValue;
                }
            }
            else if (!snapshot.wasForgotten()) {
                const returnValue = cbNode(snapshot);
                if (returnValue)
                    return returnValue;
            }
        }
        return undefined;
    }
    forEachDescendant(cbNode, cbNodeArray) {
        const stopReturnValue = {};
        const upReturnValue = {};
        let stop = false;
        let up = false;
        const traversal = {
            stop: () => stop = true,
            up: () => up = true,
        };
        const nodeCallback = (node) => {
            if (stop)
                return stopReturnValue;
            let skip = false;
            const returnValue = cbNode(node, Object.assign(Object.assign({}, traversal), { skip: () => skip = true }));
            if (returnValue)
                return returnValue;
            if (stop)
                return stopReturnValue;
            if (skip || up)
                return undefined;
            if (!node.wasForgotten())
                return forEachChildForNode(node);
            return undefined;
        };
        const arrayCallback = cbNodeArray == null ? undefined : (nodes) => {
            if (stop)
                return stopReturnValue;
            let skip = false;
            const returnValue = cbNodeArray(nodes, Object.assign(Object.assign({}, traversal), { skip: () => skip = true }));
            if (returnValue)
                return returnValue;
            if (skip)
                return undefined;
            for (const node of nodes) {
                if (stop)
                    return stopReturnValue;
                if (up)
                    return undefined;
                const innerReturnValue = forEachChildForNode(node);
                if (innerReturnValue)
                    return innerReturnValue;
            }
            return undefined;
        };
        const finalResult = forEachChildForNode(this);
        return finalResult === stopReturnValue ? undefined : finalResult;
        function forEachChildForNode(node) {
            const result = node.forEachChild(innerNode => {
                const returnValue = nodeCallback(innerNode);
                if (up) {
                    up = false;
                    return returnValue || upReturnValue;
                }
                return returnValue;
            }, arrayCallback == null ? undefined : nodes => {
                const returnValue = arrayCallback(nodes);
                if (up) {
                    up = false;
                    return returnValue || upReturnValue;
                }
                return returnValue;
            });
            return result === upReturnValue ? undefined : result;
        }
    }
    forEachChildAsArray() {
        const children = [];
        this.compilerNode.forEachChild(child => {
            children.push(this._getNodeFromCompilerNode(child));
        });
        return children;
    }
    forEachDescendantAsArray() {
        const descendants = [];
        this.forEachDescendant(descendant => {
            descendants.push(descendant);
        });
        return descendants;
    }
    getDescendants() {
        return Array.from(this._getDescendantsIterator());
    }
    *_getDescendantsIterator() {
        for (const descendant of this._getCompilerDescendantsIterator())
            yield this._getNodeFromCompilerNode(descendant);
    }
    getDescendantStatements() {
        const statements = [];
        handleNode(this, this.compilerNode);
        return statements;
        function handleNode(thisNode, node) {
            if (handleStatements(thisNode, node))
                return;
            else if (node.kind === common.SyntaxKind.ArrowFunction) {
                const arrowFunction = node;
                if (arrowFunction.body.kind !== common.SyntaxKind.Block)
                    statements.push(thisNode._getNodeFromCompilerNode(arrowFunction.body));
                else
                    handleNode(thisNode, arrowFunction.body);
            }
            else {
                handleChildren(thisNode, node);
            }
        }
        function handleStatements(thisNode, node) {
            if (node.statements == null)
                return false;
            const statementedNode = thisNode._getNodeFromCompilerNode(node);
            for (const statement of statementedNode.getStatements()) {
                statements.push(statement);
                handleChildren(thisNode, statement.compilerNode);
            }
            return true;
        }
        function handleChildren(thisNode, node) {
            common.ts.forEachChild(node, childNode => handleNode(thisNode, childNode));
        }
    }
    getChildCount() {
        return this._getCompilerChildren().length;
    }
    getChildAtPos(pos) {
        if (pos < this.getPos() || pos >= this.getEnd())
            return undefined;
        for (const child of this._getCompilerChildren()) {
            if (pos >= child.pos && pos < child.end)
                return this._getNodeFromCompilerNode(child);
        }
        return undefined;
    }
    getDescendantAtPos(pos) {
        let node;
        while (true) {
            const nextNode = (node || this).getChildAtPos(pos);
            if (nextNode == null)
                return node;
            else
                node = nextNode;
        }
    }
    getDescendantAtStartWithWidth(start, width) {
        let foundNode;
        this._context.compilerFactory.forgetNodesCreatedInBlock(remember => {
            let nextNode = this.getSourceFile();
            do {
                nextNode = nextNode.getChildAtPos(start);
                if (nextNode != null) {
                    if (nextNode.getStart() === start && nextNode.getWidth() === width)
                        foundNode = nextNode;
                    else if (foundNode != null)
                        break;
                }
            } while (nextNode != null);
            if (foundNode != null)
                remember(foundNode);
        });
        return foundNode;
    }
    getPos() {
        return this.compilerNode.pos;
    }
    getEnd() {
        return this.compilerNode.end;
    }
    getStart(includeJsDocComments) {
        return this.compilerNode.getStart(this._sourceFile.compilerNode, includeJsDocComments);
    }
    getFullStart() {
        return this.compilerNode.getFullStart();
    }
    getNonWhitespaceStart() {
        return this._context.compilerFactory.forgetNodesCreatedInBlock(() => {
            const parent = this.getParent();
            const pos = this.getPos();
            const parentTakesPrecedence = parent != null
                && !Node.isSourceFile(parent)
                && parent.getPos() === pos;
            if (parentTakesPrecedence)
                return this.getStart(true);
            let startSearchPos;
            const sourceFileFullText = this._sourceFile.getFullText();
            const previousSibling = this.getPreviousSibling();
            if (previousSibling != null && Node.isCommentNode(previousSibling))
                startSearchPos = previousSibling.getEnd();
            else if (previousSibling != null) {
                if (hasNewLineInRange(sourceFileFullText, [pos, this.getStart(true)]))
                    startSearchPos = previousSibling.getTrailingTriviaEnd();
                else
                    startSearchPos = pos;
            }
            else {
                startSearchPos = this.getPos();
            }
            return getNextNonWhitespacePos(sourceFileFullText, startSearchPos);
        });
    }
    _getTrailingTriviaNonWhitespaceEnd() {
        return getPreviousNonWhitespacePos(this._sourceFile.getFullText(), this.getTrailingTriviaEnd());
    }
    getWidth(includeJsDocComments) {
        return this.getEnd() - this.getStart(includeJsDocComments);
    }
    getFullWidth() {
        return this.compilerNode.getFullWidth();
    }
    getLeadingTriviaWidth() {
        return this.compilerNode.getLeadingTriviaWidth(this._sourceFile.compilerNode);
    }
    getTrailingTriviaWidth() {
        return this.getTrailingTriviaEnd() - this.getEnd();
    }
    getTrailingTriviaEnd() {
        const parent = this.getParent();
        const end = this.getEnd();
        if (parent == null)
            return end;
        const parentEnd = parent.getEnd();
        if (parentEnd === end)
            return end;
        const trailingComments = this.getTrailingCommentRanges();
        const searchStart = getSearchStart();
        return getNextMatchingPos(this._sourceFile.getFullText(), searchStart, char => char !== CharCodes.SPACE && char !== CharCodes.TAB);
        function getSearchStart() {
            return trailingComments.length > 0 ? trailingComments[trailingComments.length - 1].getEnd() : end;
        }
    }
    getText(includeJsDocCommentOrOptions) {
        const options = typeof includeJsDocCommentOrOptions === "object" ? includeJsDocCommentOrOptions : undefined;
        const includeJsDocComments = includeJsDocCommentOrOptions === true || (options != null && options.includeJsDocComments);
        const trimLeadingIndentation = options != null && options.trimLeadingIndentation;
        const startPos = this.getStart(includeJsDocComments);
        const text = this._sourceFile.getFullText().substring(startPos, this.getEnd());
        if (trimLeadingIndentation) {
            return common.StringUtils.removeIndentation(text, {
                isInStringAtPos: pos => this._sourceFile.isInStringAtPos(pos + startPos),
                indentSizeInSpaces: this._context.manipulationSettings._getIndentSizeInSpaces(),
            });
        }
        else {
            return text;
        }
    }
    getFullText() {
        return this.compilerNode.getFullText(this._sourceFile.compilerNode);
    }
    getCombinedModifierFlags() {
        return common.ts.getCombinedModifierFlags(this.compilerNode);
    }
    getSourceFile() {
        return this._sourceFile;
    }
    getProject() {
        return this._context.project;
    }
    getNodeProperty(propertyName) {
        const property = this.compilerNode[propertyName];
        if (property == null)
            return undefined;
        else if (property instanceof Array)
            return property.map(p => isNode(p) ? this._getNodeFromCompilerNode(p) : p);
        else if (isNode(property))
            return this._getNodeFromCompilerNode(property);
        else
            return property;
        function isNode(value) {
            return typeof value.kind === "number" && typeof value.pos === "number" && typeof value.end === "number";
        }
    }
    getAncestors(includeSyntaxLists = false) {
        return Array.from(this._getAncestorsIterator(includeSyntaxLists));
    }
    *_getAncestorsIterator(includeSyntaxLists) {
        let parent = getParent(this);
        while (parent != null) {
            yield parent;
            parent = getParent(parent);
        }
        function getParent(node) {
            return includeSyntaxLists ? node.getParentSyntaxList() || node.getParent() : node.getParent();
        }
    }
    getParent() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.parent);
    }
    getParentOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getParent(), "Expected to find a parent.");
    }
    getParentWhileOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getParentWhile(condition), "The initial parent did not match the provided condition.");
    }
    getParentWhile(condition) {
        let node = undefined;
        let parent = this.getParent();
        while (parent && condition(parent, node || this)) {
            node = parent;
            parent = node.getParent();
        }
        return node;
    }
    getParentWhileKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getParentWhileKind(kind), `The initial parent was not a syntax kind of ${common.getSyntaxKindName(kind)}.`);
    }
    getParentWhileKind(kind) {
        return this.getParentWhile(n => n.getKind() === kind);
    }
    getLastToken() {
        const lastToken = this.compilerNode.getLastToken(this._sourceFile.compilerNode);
        if (lastToken == null)
            throw new common.errors.NotImplementedError("Not implemented scenario where the last token does not exist.");
        return this._getNodeFromCompilerNode(lastToken);
    }
    isInSyntaxList() {
        return this.getParentSyntaxList() != null;
    }
    getParentSyntaxListOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getParentSyntaxList(), "Expected the parent to be a syntax list.");
    }
    getParentSyntaxList() {
        const kind = this.getKind();
        if (kind === common.SyntaxKind.SingleLineCommentTrivia || kind === common.SyntaxKind.MultiLineCommentTrivia)
            return this.getParentOrThrow().getChildSyntaxList();
        const syntaxList = getParentSyntaxList(this.compilerNode, this._sourceFile.compilerNode);
        return this._getNodeFromCompilerNodeIfExists(syntaxList);
    }
    _getParentSyntaxListIfWrapped() {
        const parent = this.getParent();
        if (parent == null || !hasParsedTokens(parent.compilerNode))
            return undefined;
        return this.getParentSyntaxList();
    }
    getChildIndex() {
        const parent = this.getParentSyntaxList() || this.getParentOrThrow();
        const index = parent._getCompilerChildren().indexOf(this.compilerNode);
        if (index === -1)
            throw new common.errors.NotImplementedError("For some reason the child's parent did not contain the child.");
        return index;
    }
    getIndentationLevel() {
        const indentationText = this._context.manipulationSettings.getIndentationText();
        return this._context.languageService.getIdentationAtPosition(this._sourceFile, this.getStart()) / indentationText.length;
    }
    getChildIndentationLevel() {
        if (Node.isSourceFile(this))
            return 0;
        return this.getIndentationLevel() + 1;
    }
    getIndentationText(offset = 0) {
        return this._getIndentationTextForLevel(this.getIndentationLevel() + offset);
    }
    getChildIndentationText(offset = 0) {
        return this._getIndentationTextForLevel(this.getChildIndentationLevel() + offset);
    }
    _getIndentationTextForLevel(level) {
        return this._context.manipulationSettings.getIndentationText().repeat(level);
    }
    getStartLinePos(includeJsDocComments) {
        const sourceFileText = this._sourceFile.getFullText();
        return getPreviousMatchingPos(sourceFileText, this.getStart(includeJsDocComments), char => char === CharCodes.NEWLINE || char === CharCodes.CARRIAGE_RETURN);
    }
    getStartLineNumber(includeJsDocComments) {
        return common.StringUtils.getLineNumberAtPos(this._sourceFile.getFullText(), this.getStartLinePos(includeJsDocComments));
    }
    getEndLineNumber() {
        const sourceFileText = this._sourceFile.getFullText();
        const endLinePos = getPreviousMatchingPos(sourceFileText, this.getEnd(), char => char === CharCodes.NEWLINE || char === CharCodes.CARRIAGE_RETURN);
        return common.StringUtils.getLineNumberAtPos(this._sourceFile.getFullText(), endLinePos);
    }
    isFirstNodeOnLine() {
        const sourceFileText = this._sourceFile.getFullText();
        const startPos = this.getNonWhitespaceStart();
        for (let i = startPos - 1; i >= 0; i--) {
            const currentChar = sourceFileText[i];
            if (currentChar === " " || currentChar === "\t")
                continue;
            if (currentChar === "\n")
                return true;
            return false;
        }
        return true;
    }
    replaceWithText(textOrWriterFunction, writer) {
        const newText = getTextFromStringOrWriter(writer || this._getWriterWithQueuedIndentation(), textOrWriterFunction);
        if (Node.isSourceFile(this)) {
            this.replaceText([this.getPos(), this.getEnd()], newText);
            return this;
        }
        const parent = this.getParentSyntaxList() || this.getParentOrThrow();
        const childIndex = this.getChildIndex();
        const start = this.getStart(true);
        insertIntoParentTextRange({
            parent,
            insertPos: start,
            newText,
            replacing: {
                textLength: this.getEnd() - start,
            },
        });
        return parent.getChildren()[childIndex];
    }
    prependWhitespace(textOrWriterFunction) {
        insertWhiteSpaceTextAtPos(this, this.getStart(true), textOrWriterFunction, "prependWhitespace");
    }
    appendWhitespace(textOrWriterFunction) {
        insertWhiteSpaceTextAtPos(this, this.getEnd(), textOrWriterFunction, "appendWhitespace");
    }
    formatText(settings = {}) {
        const formattingEdits = this._context.languageService.getFormattingEditsForRange(this._sourceFile.getFilePath(), [this.getStart(true), this.getEnd()], settings);
        replaceSourceFileTextForFormatting({
            sourceFile: this._sourceFile,
            newText: getTextFromTextChanges(this._sourceFile, formattingEdits),
        });
    }
    transform(visitNode) {
        const compilerFactory = this._context.compilerFactory;
        const printer = common.ts.createPrinter({
            newLine: this._context.manipulationSettings.getNewLineKind(),
            removeComments: false,
        });
        const transformations = [];
        const compilerSourceFile = this._sourceFile.compilerNode;
        const compilerNode = this.compilerNode;
        const transformerFactory = context => {
            return rootNode => innerVisit(rootNode, context);
        };
        common.ts.transform(compilerNode, [transformerFactory], this._context.compilerOptions.get());
        replaceSourceFileTextStraight({
            sourceFile: this._sourceFile,
            newText: getTransformedText(),
        });
        return this;
        function innerVisit(node, context) {
            const traversal = {
                visitChildren() {
                    node = common.ts.visitEachChild(node, child => innerVisit(child, context), context);
                    return node;
                },
                currentNode: node,
            };
            const resultNode = visitNode(traversal);
            handleTransformation(node, resultNode);
            return resultNode;
        }
        function handleTransformation(oldNode, newNode) {
            if (oldNode === newNode)
                return;
            const start = oldNode.getStart(compilerSourceFile, true);
            const end = oldNode.end;
            let lastTransformation;
            while ((lastTransformation = transformations[transformations.length - 1]) && lastTransformation.start > start)
                transformations.pop();
            const wrappedNode = compilerFactory.getExistingNodeFromCompilerNode(oldNode);
            transformations.push({
                start,
                end,
                compilerNode: newNode,
            });
            if (wrappedNode != null) {
                if (oldNode.kind !== newNode.kind)
                    wrappedNode.forget();
                else
                    wrappedNode.forgetDescendants();
            }
        }
        function getTransformedText() {
            const fileText = compilerSourceFile.getFullText();
            let finalText = "";
            let lastPos = 0;
            for (const transform of transformations) {
                finalText += fileText.substring(lastPos, transform.start);
                finalText += printer.printNode(common.ts.EmitHint.Unspecified, transform.compilerNode, compilerSourceFile);
                lastPos = transform.end;
            }
            finalText += fileText.substring(lastPos);
            return finalText;
        }
    }
    getLeadingCommentRanges() {
        return this._leadingCommentRanges || (this._leadingCommentRanges = this._getCommentsAtPos(this.getFullStart(), (text, pos) => {
            const comments = common.ts.getLeadingCommentRanges(text, pos) || [];
            if (this.getKind() === common.SyntaxKind.SingleLineCommentTrivia || this.getKind() === common.SyntaxKind.MultiLineCommentTrivia) {
                const thisPos = this.getPos();
                return comments.filter(r => r.pos < thisPos);
            }
            else {
                return comments;
            }
        }));
    }
    getTrailingCommentRanges() {
        return this._trailingCommentRanges || (this._trailingCommentRanges = this._getCommentsAtPos(this.getEnd(), common.ts.getTrailingCommentRanges));
    }
    _getCommentsAtPos(pos, getComments) {
        if (this.getKind() === common.SyntaxKind.SourceFile)
            return [];
        return (getComments(this._sourceFile.getFullText(), pos) || []).map(r => new CommentRange(r, this._sourceFile));
    }
    getChildrenOfKind(kind) {
        return this._getCompilerChildrenOfKind(kind).map(c => this._getNodeFromCompilerNode(c));
    }
    getFirstChildByKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getFirstChildByKind(kind), `A child of the kind ${common.getSyntaxKindName(kind)} was expected.`);
    }
    getFirstChildByKind(kind) {
        const child = this._getCompilerChildrenOfKind(kind)[0];
        return child == null ? undefined : this._getNodeFromCompilerNode(child);
    }
    getFirstChildIfKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getFirstChildIfKind(kind), `A first child of the kind ${common.getSyntaxKindName(kind)} was expected.`);
    }
    getFirstChildIfKind(kind) {
        const firstChild = this._getCompilerFirstChild();
        return firstChild != null && firstChild.kind === kind ? this._getNodeFromCompilerNode(firstChild) : undefined;
    }
    getLastChildByKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getLastChildByKind(kind), `A child of the kind ${common.getSyntaxKindName(kind)} was expected.`);
    }
    getLastChildByKind(kind) {
        const children = this._getCompilerChildrenOfKind(kind);
        const lastChild = children[children.length - 1];
        return this._getNodeFromCompilerNodeIfExists(lastChild);
    }
    getLastChildIfKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getLastChildIfKind(kind), `A last child of the kind ${common.getSyntaxKindName(kind)} was expected.`);
    }
    getLastChildIfKind(kind) {
        const lastChild = this._getCompilerLastChild();
        return lastChild != null && lastChild.kind === kind ? this._getNodeFromCompilerNode(lastChild) : undefined;
    }
    getChildAtIndexIfKindOrThrow(index, kind) {
        return common.errors.throwIfNullOrUndefined(this.getChildAtIndexIfKind(index, kind), `Child at index ${index} was expected to be ${common.getSyntaxKindName(kind)}`);
    }
    getChildAtIndexIfKind(index, kind) {
        const node = this._getCompilerChildAtIndex(index);
        return node.kind === kind ? this._getNodeFromCompilerNode(node) : undefined;
    }
    getPreviousSiblingIfKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getPreviousSiblingIfKind(kind), `A previous sibling of kind ${common.getSyntaxKindName(kind)} was expected.`);
    }
    getNextSiblingIfKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getNextSiblingIfKind(kind), `A next sibling of kind ${common.getSyntaxKindName(kind)} was expected.`);
    }
    getPreviousSiblingIfKind(kind) {
        const previousSibling = this._getCompilerPreviousSibling();
        return previousSibling != null && previousSibling.kind === kind
            ? this._getNodeFromCompilerNode(previousSibling)
            : undefined;
    }
    getNextSiblingIfKind(kind) {
        const nextSibling = this._getCompilerNextSibling();
        return nextSibling != null && nextSibling.kind === kind ? this._getNodeFromCompilerNode(nextSibling) : undefined;
    }
    getParentIfOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getParentIf(condition), "The parent did not match the provided condition.");
    }
    getParentIf(condition) {
        return condition(this.getParent(), this) ? this.getParent() : undefined;
    }
    getParentIfKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getParentIfKind(kind), `The parent was not a syntax kind of ${common.getSyntaxKindName(kind)}.`);
    }
    getParentIfKind(kind) {
        return this.getParentIf(n => n !== undefined && n.getKind() === kind);
    }
    getFirstAncestorByKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getFirstAncestorByKind(kind), `Expected an ancestor with a syntax kind of ${common.getSyntaxKindName(kind)}.`);
    }
    getFirstAncestorByKind(kind) {
        for (const parent of this._getAncestorsIterator(kind === common.SyntaxKind.SyntaxList)) {
            if (parent.getKind() === kind)
                return parent;
        }
        return undefined;
    }
    getFirstAncestorOrThrow(condition) {
        return common.errors.throwIfNullOrUndefined(this.getFirstAncestor(condition), `Expected to find an ancestor that matched the provided condition.`);
    }
    getFirstAncestor(condition) {
        for (const ancestor of this._getAncestorsIterator(false)) {
            if (condition == null || condition(ancestor))
                return ancestor;
        }
        return undefined;
    }
    getDescendantsOfKind(kind) {
        const descendants = [];
        for (const descendant of this._getCompilerDescendantsOfKindIterator(kind))
            descendants.push(this._getNodeFromCompilerNode(descendant));
        return descendants;
    }
    getFirstDescendantByKindOrThrow(kind) {
        return common.errors.throwIfNullOrUndefined(this.getFirstDescendantByKind(kind), `A descendant of kind ${common.getSyntaxKindName(kind)} was expected to be found.`);
    }
    getFirstDescendantByKind(kind) {
        for (const descendant of this._getCompilerDescendantsOfKindIterator(kind))
            return this._getNodeFromCompilerNode(descendant);
        return undefined;
    }
    _getCompilerChildren() {
        return ExtendedParser.getCompilerChildren(this.compilerNode, this._sourceFile.compilerNode);
    }
    _getCompilerForEachChildren() {
        return ExtendedParser.getCompilerForEachChildren(this.compilerNode, this._sourceFile.compilerNode);
    }
    _getCompilerChildrenFast() {
        return hasParsedTokens(this.compilerNode) ? this._getCompilerChildren() : this._getCompilerForEachChildren();
    }
    _getCompilerChildrenOfKind(kind) {
        const children = useParseTreeSearchForKind(this, kind) ? this._getCompilerForEachChildren() : this._getCompilerChildren();
        return children.filter(c => c.kind === kind);
    }
    *_getCompilerDescendantsOfKindIterator(kind) {
        const children = useParseTreeSearchForKind(this, kind) ? this._getCompilerForEachChildren() : this._getCompilerChildren();
        for (const child of children) {
            if (child.kind === kind)
                yield child;
            const descendants = useParseTreeSearchForKind(child.kind, kind)
                ? getCompilerForEachDescendantsIterator(child)
                : getCompilerDescendantsIterator(child, this._sourceFile.compilerNode);
            for (const descendant of descendants) {
                if (descendant.kind === kind)
                    yield descendant;
            }
        }
    }
    _getCompilerDescendantsIterator() {
        return getCompilerDescendantsIterator(this.compilerNode, this._sourceFile.compilerNode);
    }
    _getCompilerForEachDescendantsIterator() {
        return getCompilerForEachDescendantsIterator(this.compilerNode);
    }
    _getCompilerFirstChild(condition) {
        for (const child of this._getCompilerChildren()) {
            if (condition == null || condition(child))
                return child;
        }
        return undefined;
    }
    _getCompilerLastChild(condition) {
        const children = this._getCompilerChildren();
        for (let i = children.length - 1; i >= 0; i--) {
            const child = children[i];
            if (condition == null || condition(child))
                return child;
        }
        return undefined;
    }
    _getCompilerPreviousSiblings() {
        const parent = this.getParentSyntaxList() || this.getParentOrThrow();
        const previousSiblings = [];
        for (const child of parent._getCompilerChildren()) {
            if (child === this.compilerNode)
                break;
            previousSiblings.unshift(child);
        }
        return previousSiblings;
    }
    _getCompilerNextSiblings() {
        let foundChild = false;
        const parent = this.getParentSyntaxList() || this.getParentOrThrow();
        const nextSiblings = [];
        for (const child of parent._getCompilerChildren()) {
            if (!foundChild) {
                foundChild = child === this.compilerNode;
                continue;
            }
            nextSiblings.push(child);
        }
        return nextSiblings;
    }
    _getCompilerPreviousSibling(condition) {
        for (const sibling of this._getCompilerPreviousSiblings()) {
            if (condition == null || condition(sibling))
                return sibling;
        }
        return undefined;
    }
    _getCompilerNextSibling(condition) {
        for (const sibling of this._getCompilerNextSiblings()) {
            if (condition == null || condition(sibling))
                return sibling;
        }
        return undefined;
    }
    _getCompilerChildAtIndex(index) {
        const children = this._getCompilerChildren();
        common.errors.throwIfOutOfRange(index, [0, children.length - 1], "index");
        return children[index];
    }
    _getWriterWithIndentation() {
        const writer = this._getWriter();
        writer.setIndentationLevel(this.getIndentationLevel());
        return writer;
    }
    _getWriterWithQueuedIndentation() {
        const writer = this._getWriter();
        writer.queueIndentationLevel(this.getIndentationLevel());
        return writer;
    }
    _getWriterWithChildIndentation() {
        const writer = this._getWriter();
        writer.setIndentationLevel(this.getChildIndentationLevel());
        return writer;
    }
    _getWriterWithQueuedChildIndentation() {
        const writer = this._getWriter();
        writer.queueIndentationLevel(this.getChildIndentationLevel());
        return writer;
    }
    _getTextWithQueuedChildIndentation(textOrWriterFunc) {
        const writer = this._getWriterWithQueuedChildIndentation();
        if (typeof textOrWriterFunc === "string")
            writer.write(textOrWriterFunc);
        else
            textOrWriterFunc(writer);
        return writer.toString();
    }
    _getWriter() {
        return this._context.createWriter();
    }
    _getNodeFromCompilerNode(compilerNode) {
        return this._context.compilerFactory.getNodeFromCompilerNode(compilerNode, this._sourceFile);
    }
    _getNodeFromCompilerNodeIfExists(compilerNode) {
        return compilerNode == null ? undefined : this._getNodeFromCompilerNode(compilerNode);
    }
    _ensureBound() {
        if (this.compilerNode.symbol != null)
            return;
        this.getSymbol();
    }
    static hasExpression(node) {
        var _a, _b;
        return ((_b = (_a = node).getExpression) === null || _b === void 0 ? void 0 : _b.call(_a)) != null;
    }
    static hasName(node) {
        var _a, _b;
        return typeof ((_b = (_a = node).getName) === null || _b === void 0 ? void 0 : _b.call(_a)) === "string";
    }
    static hasBody(node) {
        var _a, _b;
        return ((_b = (_a = node).getBody) === null || _b === void 0 ? void 0 : _b.call(_a)) != null;
    }
    static is(kind) {
        return (node) => {
            return (node === null || node === void 0 ? void 0 : node.getKind()) == kind;
        };
    }
    static isNode(value) {
        return value != null && value.compilerNode != null;
    }
    static isCommentNode(node) {
        const kind = node === null || node === void 0 ? void 0 : node.getKind();
        return kind === common.SyntaxKind.SingleLineCommentTrivia || kind === common.SyntaxKind.MultiLineCommentTrivia;
    }
    static isCommentStatement(node) {
        return (node === null || node === void 0 ? void 0 : node.compilerNode)._commentKind === exports.CommentNodeKind.Statement;
    }
    static isCommentClassElement(node) {
        return (node === null || node === void 0 ? void 0 : node.compilerNode)._commentKind === exports.CommentNodeKind.ClassElement;
    }
    static isCommentTypeElement(node) {
        return (node === null || node === void 0 ? void 0 : node.compilerNode)._commentKind === exports.CommentNodeKind.TypeElement;
    }
    static isCommentObjectLiteralElement(node) {
        return (node === null || node === void 0 ? void 0 : node.compilerNode)._commentKind === exports.CommentNodeKind.ObjectLiteralElement;
    }
    static isCommentEnumMember(node) {
        return (node === null || node === void 0 ? void 0 : node.compilerNode)._commentKind == exports.CommentNodeKind.EnumMember;
    }
    static isAbstractableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.ConstructorType:
                return true;
            default:
                return false;
        }
    }
    static isAmbientableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.TypeAliasDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isArgumentedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.NewExpression:
                return true;
            default:
                return false;
        }
    }
    static isArrayTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ArrayType;
    }
    static isAsyncableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
                return true;
            default:
                return false;
        }
    }
    static isAwaitableNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ForOfStatement;
    }
    static isBindingNamedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.BindingElement:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isBodiedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionExpression:
                return true;
            default:
                return false;
        }
    }
    static isBodyableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isCallSignatureDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.CallSignature;
    }
    static isChildOrderableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.IndexSignature:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.ExportAssignment:
            case common.SyntaxKind.ExportDeclaration:
            case common.SyntaxKind.ImportDeclaration:
            case common.SyntaxKind.ImportEqualsDeclaration:
            case common.SyntaxKind.ModuleBlock:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.Block:
            case common.SyntaxKind.BreakStatement:
            case common.SyntaxKind.ContinueStatement:
            case common.SyntaxKind.DebuggerStatement:
            case common.SyntaxKind.DoStatement:
            case common.SyntaxKind.EmptyStatement:
            case common.SyntaxKind.ExpressionStatement:
            case common.SyntaxKind.ForInStatement:
            case common.SyntaxKind.ForOfStatement:
            case common.SyntaxKind.ForStatement:
            case common.SyntaxKind.IfStatement:
            case common.SyntaxKind.LabeledStatement:
            case common.SyntaxKind.NotEmittedStatement:
            case common.SyntaxKind.ReturnStatement:
            case common.SyntaxKind.SwitchStatement:
            case common.SyntaxKind.ThrowStatement:
            case common.SyntaxKind.TryStatement:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.WhileStatement:
            case common.SyntaxKind.WithStatement:
            case common.SyntaxKind.TypeAliasDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isClassLikeDeclarationBase(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
                return true;
            default:
                return false;
        }
    }
    static isConditionalTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ConditionalType;
    }
    static isConstructSignatureDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ConstructSignature;
    }
    static isConstructorDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.Constructor;
    }
    static isConstructorTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ConstructorType;
    }
    static isDecoratableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.Parameter:
                return true;
            default:
                return false;
        }
    }
    static isDotDotDotTokenableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.BindingElement:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.JsxExpression:
            case common.SyntaxKind.NamedTupleMember:
                return true;
            default:
                return false;
        }
    }
    static isExclamationTokenableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isExportGetableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.TypeAliasDeclaration:
            case common.SyntaxKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isExportableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.TypeAliasDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isExpression(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.AnyKeyword:
            case common.SyntaxKind.BooleanKeyword:
            case common.SyntaxKind.NumberKeyword:
            case common.SyntaxKind.ObjectKeyword:
            case common.SyntaxKind.StringKeyword:
            case common.SyntaxKind.SymbolKeyword:
            case common.SyntaxKind.UndefinedKeyword:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.AsExpression:
            case common.SyntaxKind.AwaitExpression:
            case common.SyntaxKind.BinaryExpression:
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.CommaListExpression:
            case common.SyntaxKind.ConditionalExpression:
            case common.SyntaxKind.DeleteExpression:
            case common.SyntaxKind.ElementAccessExpression:
            case common.SyntaxKind.ImportKeyword:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.NonNullExpression:
            case common.SyntaxKind.OmittedExpression:
            case common.SyntaxKind.ParenthesizedExpression:
            case common.SyntaxKind.PartiallyEmittedExpression:
            case common.SyntaxKind.PostfixUnaryExpression:
            case common.SyntaxKind.PrefixUnaryExpression:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.SpreadElement:
            case common.SyntaxKind.SuperKeyword:
            case common.SyntaxKind.ThisKeyword:
            case common.SyntaxKind.TypeAssertionExpression:
            case common.SyntaxKind.TypeOfExpression:
            case common.SyntaxKind.VoidExpression:
            case common.SyntaxKind.YieldExpression:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.JsxClosingFragment:
            case common.SyntaxKind.JsxElement:
            case common.SyntaxKind.JsxExpression:
            case common.SyntaxKind.JsxFragment:
            case common.SyntaxKind.JsxOpeningElement:
            case common.SyntaxKind.JsxOpeningFragment:
            case common.SyntaxKind.JsxSelfClosingElement:
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.TrueKeyword:
            case common.SyntaxKind.FalseKeyword:
            case common.SyntaxKind.NullKeyword:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.ArrayLiteralExpression:
            case common.SyntaxKind.ObjectLiteralExpression:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
            case common.SyntaxKind.TaggedTemplateExpression:
            case common.SyntaxKind.TemplateExpression:
                return true;
            default:
                return false;
        }
    }
    static isExpressionableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.YieldExpression:
            case common.SyntaxKind.JsxExpression:
            case common.SyntaxKind.ExternalModuleReference:
            case common.SyntaxKind.ReturnStatement:
                return true;
            default:
                return false;
        }
    }
    static isExpressionedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.AsExpression:
            case common.SyntaxKind.NonNullExpression:
            case common.SyntaxKind.ParenthesizedExpression:
            case common.SyntaxKind.PartiallyEmittedExpression:
            case common.SyntaxKind.SpreadElement:
            case common.SyntaxKind.JsxSpreadAttribute:
            case common.SyntaxKind.ExportAssignment:
            case common.SyntaxKind.ComputedPropertyName:
            case common.SyntaxKind.CaseClause:
            case common.SyntaxKind.DoStatement:
            case common.SyntaxKind.ExpressionStatement:
            case common.SyntaxKind.ForInStatement:
            case common.SyntaxKind.ForOfStatement:
            case common.SyntaxKind.IfStatement:
            case common.SyntaxKind.SwitchStatement:
            case common.SyntaxKind.ThrowStatement:
            case common.SyntaxKind.WhileStatement:
            case common.SyntaxKind.WithStatement:
            case common.SyntaxKind.SpreadAssignment:
            case common.SyntaxKind.TemplateSpan:
                return true;
            default:
                return false;
        }
    }
    static isExtendsClauseableNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.InterfaceDeclaration;
    }
    static isFalseLiteral(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.FalseKeyword;
    }
    static isFunctionLikeDeclaration(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isFunctionTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.FunctionType;
    }
    static isGeneratorableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.YieldExpression:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
                return true;
            default:
                return false;
        }
    }
    static isGetAccessorDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.GetAccessor;
    }
    static isHeritageClauseableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.InterfaceDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isImplementsClauseableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
                return true;
            default:
                return false;
        }
    }
    static isImportExpression(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ImportKeyword;
    }
    static isImportTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ImportType;
    }
    static isIndexSignatureDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.IndexSignature;
    }
    static isIndexedAccessTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.IndexedAccessType;
    }
    static isInferTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.InferType;
    }
    static isInitializerExpressionGetableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.BindingElement:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.EnumMember:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.VariableDeclaration:
            case common.SyntaxKind.PropertyAssignment:
            case common.SyntaxKind.ShorthandPropertyAssignment:
                return true;
            default:
                return false;
        }
    }
    static isInitializerExpressionableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.BindingElement:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.EnumMember:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isIntersectionTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.IntersectionType;
    }
    static isIterationStatement(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.DoStatement:
            case common.SyntaxKind.ForInStatement:
            case common.SyntaxKind.ForOfStatement:
            case common.SyntaxKind.ForStatement:
            case common.SyntaxKind.WhileStatement:
                return true;
            default:
                return false;
        }
    }
    static isJSDoc(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.JSDocComment;
    }
    static isJSDocPropertyLikeTag(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JSDocParameterTag:
            case common.SyntaxKind.JSDocPropertyTag:
                return true;
            default:
                return false;
        }
    }
    static isJSDocTag(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JSDocAugmentsTag:
            case common.SyntaxKind.JSDocAuthorTag:
            case common.SyntaxKind.JSDocCallbackTag:
            case common.SyntaxKind.JSDocClassTag:
            case common.SyntaxKind.JSDocDeprecatedTag:
            case common.SyntaxKind.JSDocEnumTag:
            case common.SyntaxKind.JSDocImplementsTag:
            case common.SyntaxKind.JSDocOverrideTag:
            case common.SyntaxKind.JSDocParameterTag:
            case common.SyntaxKind.JSDocPrivateTag:
            case common.SyntaxKind.JSDocPropertyTag:
            case common.SyntaxKind.JSDocProtectedTag:
            case common.SyntaxKind.JSDocPublicTag:
            case common.SyntaxKind.JSDocReadonlyTag:
            case common.SyntaxKind.JSDocReturnTag:
            case common.SyntaxKind.JSDocSeeTag:
            case common.SyntaxKind.JSDocTemplateTag:
            case common.SyntaxKind.JSDocThisTag:
            case common.SyntaxKind.JSDocTypedefTag:
            case common.SyntaxKind.JSDocTypeTag:
            case common.SyntaxKind.JSDocTag:
                return true;
            default:
                return false;
        }
    }
    static isJSDocType(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JSDocFunctionType:
            case common.SyntaxKind.JSDocSignature:
                return true;
            default:
                return false;
        }
    }
    static isJSDocTypeExpressionableTag(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JSDocReturnTag:
            case common.SyntaxKind.JSDocSeeTag:
            case common.SyntaxKind.JSDocThisTag:
                return true;
            default:
                return false;
        }
    }
    static isJSDocTypeParameteredTag(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.JSDocTemplateTag;
    }
    static isJSDocUnknownTag(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.JSDocTag;
    }
    static isJSDocableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.EnumMember:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.IndexSignature:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.ImportEqualsDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.ExpressionStatement:
            case common.SyntaxKind.LabeledStatement:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.NamedTupleMember:
            case common.SyntaxKind.TypeAliasDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isJsxAttributedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JsxOpeningElement:
            case common.SyntaxKind.JsxSelfClosingElement:
                return true;
            default:
                return false;
        }
    }
    static isJsxTagNamedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JsxClosingElement:
            case common.SyntaxKind.JsxOpeningElement:
            case common.SyntaxKind.JsxSelfClosingElement:
                return true;
            default:
                return false;
        }
    }
    static isLeftHandSideExpression(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.ElementAccessExpression:
            case common.SyntaxKind.ImportKeyword:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.NonNullExpression:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.SuperKeyword:
            case common.SyntaxKind.ThisKeyword:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.JsxElement:
            case common.SyntaxKind.JsxFragment:
            case common.SyntaxKind.JsxSelfClosingElement:
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.TrueKeyword:
            case common.SyntaxKind.FalseKeyword:
            case common.SyntaxKind.NullKeyword:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.ArrayLiteralExpression:
            case common.SyntaxKind.ObjectLiteralExpression:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
            case common.SyntaxKind.TaggedTemplateExpression:
            case common.SyntaxKind.TemplateExpression:
                return true;
            default:
                return false;
        }
    }
    static isLeftHandSideExpressionedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.Decorator:
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.ElementAccessExpression:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.ExpressionWithTypeArguments:
                return true;
            default:
                return false;
        }
    }
    static isLiteralExpression(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
                return true;
            default:
                return false;
        }
    }
    static isLiteralLikeNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JsxText:
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
            case common.SyntaxKind.TemplateHead:
            case common.SyntaxKind.TemplateMiddle:
            case common.SyntaxKind.TemplateTail:
                return true;
            default:
                return false;
        }
    }
    static isLiteralTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.LiteralType;
    }
    static isMappedTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.MappedType;
    }
    static isMemberExpression(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.ElementAccessExpression:
            case common.SyntaxKind.ImportKeyword:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.SuperKeyword:
            case common.SyntaxKind.ThisKeyword:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.JsxElement:
            case common.SyntaxKind.JsxFragment:
            case common.SyntaxKind.JsxSelfClosingElement:
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.TrueKeyword:
            case common.SyntaxKind.FalseKeyword:
            case common.SyntaxKind.NullKeyword:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.ArrayLiteralExpression:
            case common.SyntaxKind.ObjectLiteralExpression:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
            case common.SyntaxKind.TaggedTemplateExpression:
            case common.SyntaxKind.TemplateExpression:
                return true;
            default:
                return false;
        }
    }
    static isModifierableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.IndexSignature:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.ConstructorType:
            case common.SyntaxKind.TypeAliasDeclaration:
            case common.SyntaxKind.VariableDeclarationList:
                return true;
            default:
                return false;
        }
    }
    static isModuleChildableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.VariableStatement:
                return true;
            default:
                return false;
        }
    }
    static isModuleNamedNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ModuleDeclaration;
    }
    static isModuledNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.SourceFile:
                return true;
            default:
                return false;
        }
    }
    static isNameableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
                return true;
            default:
                return false;
        }
    }
    static isNamedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.JsxAttribute:
            case common.SyntaxKind.ImportEqualsDeclaration:
            case common.SyntaxKind.NamedTupleMember:
            case common.SyntaxKind.TypeAliasDeclaration:
            case common.SyntaxKind.TypeParameter:
            case common.SyntaxKind.ShorthandPropertyAssignment:
                return true;
            default:
                return false;
        }
    }
    static isNullLiteral(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.NullKeyword;
    }
    static isOverloadableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.FunctionDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isOverrideableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.Parameter:
                return true;
            default:
                return false;
        }
    }
    static isParameterDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.Parameter;
    }
    static isParameteredNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.JSDocFunctionType:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.ConstructorType:
            case common.SyntaxKind.FunctionType:
                return true;
            default:
                return false;
        }
    }
    static isParenthesizedTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ParenthesizedType;
    }
    static isPrimaryExpression(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.ImportKeyword:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.SuperKeyword:
            case common.SyntaxKind.ThisKeyword:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.JsxElement:
            case common.SyntaxKind.JsxFragment:
            case common.SyntaxKind.JsxSelfClosingElement:
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.TrueKeyword:
            case common.SyntaxKind.FalseKeyword:
            case common.SyntaxKind.NullKeyword:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.ArrayLiteralExpression:
            case common.SyntaxKind.ObjectLiteralExpression:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
            case common.SyntaxKind.TemplateExpression:
                return true;
            default:
                return false;
        }
    }
    static isPropertyNamedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.EnumMember:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.PropertyAssignment:
                return true;
            default:
                return false;
        }
    }
    static isQuestionDotTokenableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.ElementAccessExpression:
            case common.SyntaxKind.PropertyAccessExpression:
                return true;
            default:
                return false;
        }
    }
    static isQuestionTokenableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.NamedTupleMember:
            case common.SyntaxKind.PropertyAssignment:
            case common.SyntaxKind.ShorthandPropertyAssignment:
                return true;
            default:
                return false;
        }
    }
    static isReadonlyableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.IndexSignature:
            case common.SyntaxKind.PropertySignature:
                return true;
            default:
                return false;
        }
    }
    static isReferenceFindableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.BindingElement:
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.EnumMember:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.JsxAttribute:
            case common.SyntaxKind.ImportEqualsDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.PrivateIdentifier:
            case common.SyntaxKind.NamedTupleMember:
            case common.SyntaxKind.TypeAliasDeclaration:
            case common.SyntaxKind.TypeParameter:
            case common.SyntaxKind.VariableDeclaration:
            case common.SyntaxKind.PropertyAssignment:
            case common.SyntaxKind.ShorthandPropertyAssignment:
                return true;
            default:
                return false;
        }
    }
    static isRenameableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.BindingElement:
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.EnumMember:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.JsxAttribute:
            case common.SyntaxKind.ImportEqualsDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.NamespaceExport:
            case common.SyntaxKind.NamespaceImport:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.PrivateIdentifier:
            case common.SyntaxKind.NamedTupleMember:
            case common.SyntaxKind.TypeAliasDeclaration:
            case common.SyntaxKind.TypeParameter:
            case common.SyntaxKind.VariableDeclaration:
            case common.SyntaxKind.PropertyAssignment:
            case common.SyntaxKind.ShorthandPropertyAssignment:
                return true;
            default:
                return false;
        }
    }
    static isReturnTypedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.JSDocFunctionType:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.IndexSignature:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.ConstructorType:
            case common.SyntaxKind.FunctionType:
                return true;
            default:
                return false;
        }
    }
    static isScopeableNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.Parameter;
    }
    static isScopedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
                return true;
            default:
                return false;
        }
    }
    static isSetAccessorDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.SetAccessor;
    }
    static isSignaturedDeclaration(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.JSDocFunctionType:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.ConstructorType:
            case common.SyntaxKind.FunctionType:
                return true;
            default:
                return false;
        }
    }
    static isStatement(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.ExportAssignment:
            case common.SyntaxKind.ExportDeclaration:
            case common.SyntaxKind.ImportDeclaration:
            case common.SyntaxKind.ImportEqualsDeclaration:
            case common.SyntaxKind.ModuleBlock:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.Block:
            case common.SyntaxKind.BreakStatement:
            case common.SyntaxKind.ContinueStatement:
            case common.SyntaxKind.DebuggerStatement:
            case common.SyntaxKind.DoStatement:
            case common.SyntaxKind.EmptyStatement:
            case common.SyntaxKind.ExpressionStatement:
            case common.SyntaxKind.ForInStatement:
            case common.SyntaxKind.ForOfStatement:
            case common.SyntaxKind.ForStatement:
            case common.SyntaxKind.IfStatement:
            case common.SyntaxKind.LabeledStatement:
            case common.SyntaxKind.NotEmittedStatement:
            case common.SyntaxKind.ReturnStatement:
            case common.SyntaxKind.SwitchStatement:
            case common.SyntaxKind.ThrowStatement:
            case common.SyntaxKind.TryStatement:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.WhileStatement:
            case common.SyntaxKind.WithStatement:
            case common.SyntaxKind.TypeAliasDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isStatementedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.ModuleBlock:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.SourceFile:
            case common.SyntaxKind.Block:
            case common.SyntaxKind.CaseClause:
            case common.SyntaxKind.DefaultClause:
                return true;
            default:
                return false;
        }
    }
    static isStaticableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
                return true;
            default:
                return false;
        }
    }
    static isSuperExpression(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.SuperKeyword;
    }
    static isTemplateLiteralTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TemplateLiteralType;
    }
    static isTextInsertableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.SourceFile:
            case common.SyntaxKind.Block:
            case common.SyntaxKind.CaseBlock:
            case common.SyntaxKind.CaseClause:
            case common.SyntaxKind.DefaultClause:
                return true;
            default:
                return false;
        }
    }
    static isThisExpression(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ThisKeyword;
    }
    static isThisTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.ThisType;
    }
    static isTrueLiteral(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TrueKeyword;
    }
    static isTupleTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TupleType;
    }
    static isTypeArgumentedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.ImportType:
                return true;
            default:
                return false;
        }
    }
    static isTypeAssertion(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TypeAssertionExpression;
    }
    static isTypeElement(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.IndexSignature:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
                return true;
            default:
                return false;
        }
    }
    static isTypeElementMemberedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.TypeLiteral:
                return true;
            default:
                return false;
        }
    }
    static isTypeLiteralNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TypeLiteral;
    }
    static isTypeNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.JSDocFunctionType:
            case common.SyntaxKind.JSDocSignature:
            case common.SyntaxKind.JSDocTypeExpression:
            case common.SyntaxKind.ArrayType:
            case common.SyntaxKind.ConditionalType:
            case common.SyntaxKind.ConstructorType:
            case common.SyntaxKind.ExpressionWithTypeArguments:
            case common.SyntaxKind.FunctionType:
            case common.SyntaxKind.ImportType:
            case common.SyntaxKind.IndexedAccessType:
            case common.SyntaxKind.InferType:
            case common.SyntaxKind.IntersectionType:
            case common.SyntaxKind.LiteralType:
            case common.SyntaxKind.MappedType:
            case common.SyntaxKind.NamedTupleMember:
            case common.SyntaxKind.ParenthesizedType:
            case common.SyntaxKind.TemplateLiteralType:
            case common.SyntaxKind.ThisType:
            case common.SyntaxKind.TupleType:
            case common.SyntaxKind.TypeLiteral:
            case common.SyntaxKind.TypePredicate:
            case common.SyntaxKind.TypeReference:
            case common.SyntaxKind.UnionType:
                return true;
            default:
                return false;
        }
    }
    static isTypeParameterDeclaration(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TypeParameter;
    }
    static isTypeParameteredNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.ArrowFunction:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.FunctionType:
            case common.SyntaxKind.TypeAliasDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isTypePredicateNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TypePredicate;
    }
    static isTypeReferenceNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.TypeReference;
    }
    static isTypedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.AsExpression:
            case common.SyntaxKind.TypeAssertionExpression:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.NamedTupleMember:
            case common.SyntaxKind.TypeAliasDeclaration:
            case common.SyntaxKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isUnaryExpression(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.AwaitExpression:
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.DeleteExpression:
            case common.SyntaxKind.ElementAccessExpression:
            case common.SyntaxKind.ImportKeyword:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.NonNullExpression:
            case common.SyntaxKind.PostfixUnaryExpression:
            case common.SyntaxKind.PrefixUnaryExpression:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.SuperKeyword:
            case common.SyntaxKind.ThisKeyword:
            case common.SyntaxKind.TypeAssertionExpression:
            case common.SyntaxKind.TypeOfExpression:
            case common.SyntaxKind.VoidExpression:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.JsxElement:
            case common.SyntaxKind.JsxFragment:
            case common.SyntaxKind.JsxSelfClosingElement:
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.TrueKeyword:
            case common.SyntaxKind.FalseKeyword:
            case common.SyntaxKind.NullKeyword:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.ArrayLiteralExpression:
            case common.SyntaxKind.ObjectLiteralExpression:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
            case common.SyntaxKind.TaggedTemplateExpression:
            case common.SyntaxKind.TemplateExpression:
                return true;
            default:
                return false;
        }
    }
    static isUnaryExpressionedNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.AwaitExpression:
            case common.SyntaxKind.DeleteExpression:
            case common.SyntaxKind.TypeAssertionExpression:
            case common.SyntaxKind.TypeOfExpression:
            case common.SyntaxKind.VoidExpression:
                return true;
            default:
                return false;
        }
    }
    static isUnionTypeNode(node) {
        return (node === null || node === void 0 ? void 0 : node.getKind()) === common.SyntaxKind.UnionType;
    }
    static isUnwrappableNode(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.ModuleDeclaration:
                return true;
            default:
                return false;
        }
    }
    static isUpdateExpression(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassExpression:
            case common.SyntaxKind.CallExpression:
            case common.SyntaxKind.ElementAccessExpression:
            case common.SyntaxKind.ImportKeyword:
            case common.SyntaxKind.MetaProperty:
            case common.SyntaxKind.NewExpression:
            case common.SyntaxKind.NonNullExpression:
            case common.SyntaxKind.PropertyAccessExpression:
            case common.SyntaxKind.SuperKeyword:
            case common.SyntaxKind.ThisKeyword:
            case common.SyntaxKind.FunctionExpression:
            case common.SyntaxKind.JsxElement:
            case common.SyntaxKind.JsxFragment:
            case common.SyntaxKind.JsxSelfClosingElement:
            case common.SyntaxKind.BigIntLiteral:
            case common.SyntaxKind.TrueKeyword:
            case common.SyntaxKind.FalseKeyword:
            case common.SyntaxKind.NullKeyword:
            case common.SyntaxKind.NumericLiteral:
            case common.SyntaxKind.RegularExpressionLiteral:
            case common.SyntaxKind.StringLiteral:
            case common.SyntaxKind.Identifier:
            case common.SyntaxKind.ArrayLiteralExpression:
            case common.SyntaxKind.ObjectLiteralExpression:
            case common.SyntaxKind.NoSubstitutionTemplateLiteral:
            case common.SyntaxKind.TaggedTemplateExpression:
            case common.SyntaxKind.TemplateExpression:
                return true;
            default:
                return false;
        }
    }
    static _hasStructure(node) {
        switch (node === null || node === void 0 ? void 0 : node.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
            case common.SyntaxKind.ClassStaticBlockDeclaration:
            case common.SyntaxKind.Constructor:
            case common.SyntaxKind.GetAccessor:
            case common.SyntaxKind.MethodDeclaration:
            case common.SyntaxKind.PropertyDeclaration:
            case common.SyntaxKind.SetAccessor:
            case common.SyntaxKind.Decorator:
            case common.SyntaxKind.JSDocComment:
            case common.SyntaxKind.EnumDeclaration:
            case common.SyntaxKind.EnumMember:
            case common.SyntaxKind.FunctionDeclaration:
            case common.SyntaxKind.Parameter:
            case common.SyntaxKind.CallSignature:
            case common.SyntaxKind.ConstructSignature:
            case common.SyntaxKind.IndexSignature:
            case common.SyntaxKind.InterfaceDeclaration:
            case common.SyntaxKind.MethodSignature:
            case common.SyntaxKind.PropertySignature:
            case common.SyntaxKind.JsxAttribute:
            case common.SyntaxKind.JsxElement:
            case common.SyntaxKind.JsxSelfClosingElement:
            case common.SyntaxKind.JsxSpreadAttribute:
            case common.SyntaxKind.ExportAssignment:
            case common.SyntaxKind.ExportDeclaration:
            case common.SyntaxKind.ExportSpecifier:
            case common.SyntaxKind.ImportDeclaration:
            case common.SyntaxKind.ImportSpecifier:
            case common.SyntaxKind.ModuleDeclaration:
            case common.SyntaxKind.SourceFile:
            case common.SyntaxKind.VariableStatement:
            case common.SyntaxKind.TypeAliasDeclaration:
            case common.SyntaxKind.TypeParameter:
            case common.SyntaxKind.VariableDeclaration:
            case common.SyntaxKind.PropertyAssignment:
            case common.SyntaxKind.ShorthandPropertyAssignment:
            case common.SyntaxKind.SpreadAssignment:
                return true;
            default:
                return false;
        }
    }
}
Node.isAnyKeyword = Node.is(common.SyntaxKind.AnyKeyword);
Node.isArrayBindingPattern = Node.is(common.SyntaxKind.ArrayBindingPattern);
Node.isArrayLiteralExpression = Node.is(common.SyntaxKind.ArrayLiteralExpression);
Node.isArrowFunction = Node.is(common.SyntaxKind.ArrowFunction);
Node.isAsExpression = Node.is(common.SyntaxKind.AsExpression);
Node.isAwaitExpression = Node.is(common.SyntaxKind.AwaitExpression);
Node.isBigIntLiteral = Node.is(common.SyntaxKind.BigIntLiteral);
Node.isBinaryExpression = Node.is(common.SyntaxKind.BinaryExpression);
Node.isBindingElement = Node.is(common.SyntaxKind.BindingElement);
Node.isBlock = Node.is(common.SyntaxKind.Block);
Node.isBooleanKeyword = Node.is(common.SyntaxKind.BooleanKeyword);
Node.isBreakStatement = Node.is(common.SyntaxKind.BreakStatement);
Node.isCallExpression = Node.is(common.SyntaxKind.CallExpression);
Node.isCaseBlock = Node.is(common.SyntaxKind.CaseBlock);
Node.isCaseClause = Node.is(common.SyntaxKind.CaseClause);
Node.isCatchClause = Node.is(common.SyntaxKind.CatchClause);
Node.isClassDeclaration = Node.is(common.SyntaxKind.ClassDeclaration);
Node.isClassExpression = Node.is(common.SyntaxKind.ClassExpression);
Node.isClassStaticBlockDeclaration = Node.is(common.SyntaxKind.ClassStaticBlockDeclaration);
Node.isCommaListExpression = Node.is(common.SyntaxKind.CommaListExpression);
Node.isComputedPropertyName = Node.is(common.SyntaxKind.ComputedPropertyName);
Node.isConditionalExpression = Node.is(common.SyntaxKind.ConditionalExpression);
Node.isContinueStatement = Node.is(common.SyntaxKind.ContinueStatement);
Node.isDebuggerStatement = Node.is(common.SyntaxKind.DebuggerStatement);
Node.isDecorator = Node.is(common.SyntaxKind.Decorator);
Node.isDefaultClause = Node.is(common.SyntaxKind.DefaultClause);
Node.isDeleteExpression = Node.is(common.SyntaxKind.DeleteExpression);
Node.isDoStatement = Node.is(common.SyntaxKind.DoStatement);
Node.isElementAccessExpression = Node.is(common.SyntaxKind.ElementAccessExpression);
Node.isEmptyStatement = Node.is(common.SyntaxKind.EmptyStatement);
Node.isEnumDeclaration = Node.is(common.SyntaxKind.EnumDeclaration);
Node.isEnumMember = Node.is(common.SyntaxKind.EnumMember);
Node.isExportAssignment = Node.is(common.SyntaxKind.ExportAssignment);
Node.isExportDeclaration = Node.is(common.SyntaxKind.ExportDeclaration);
Node.isExportSpecifier = Node.is(common.SyntaxKind.ExportSpecifier);
Node.isExpressionStatement = Node.is(common.SyntaxKind.ExpressionStatement);
Node.isExpressionWithTypeArguments = Node.is(common.SyntaxKind.ExpressionWithTypeArguments);
Node.isExternalModuleReference = Node.is(common.SyntaxKind.ExternalModuleReference);
Node.isForInStatement = Node.is(common.SyntaxKind.ForInStatement);
Node.isForOfStatement = Node.is(common.SyntaxKind.ForOfStatement);
Node.isForStatement = Node.is(common.SyntaxKind.ForStatement);
Node.isFunctionDeclaration = Node.is(common.SyntaxKind.FunctionDeclaration);
Node.isFunctionExpression = Node.is(common.SyntaxKind.FunctionExpression);
Node.isHeritageClause = Node.is(common.SyntaxKind.HeritageClause);
Node.isIdentifier = Node.is(common.SyntaxKind.Identifier);
Node.isIfStatement = Node.is(common.SyntaxKind.IfStatement);
Node.isImportClause = Node.is(common.SyntaxKind.ImportClause);
Node.isImportDeclaration = Node.is(common.SyntaxKind.ImportDeclaration);
Node.isImportEqualsDeclaration = Node.is(common.SyntaxKind.ImportEqualsDeclaration);
Node.isImportSpecifier = Node.is(common.SyntaxKind.ImportSpecifier);
Node.isInferKeyword = Node.is(common.SyntaxKind.InferKeyword);
Node.isInterfaceDeclaration = Node.is(common.SyntaxKind.InterfaceDeclaration);
Node.isJSDocAugmentsTag = Node.is(common.SyntaxKind.JSDocAugmentsTag);
Node.isJSDocAuthorTag = Node.is(common.SyntaxKind.JSDocAuthorTag);
Node.isJSDocCallbackTag = Node.is(common.SyntaxKind.JSDocCallbackTag);
Node.isJSDocClassTag = Node.is(common.SyntaxKind.JSDocClassTag);
Node.isJSDocDeprecatedTag = Node.is(common.SyntaxKind.JSDocDeprecatedTag);
Node.isJSDocEnumTag = Node.is(common.SyntaxKind.JSDocEnumTag);
Node.isJSDocFunctionType = Node.is(common.SyntaxKind.JSDocFunctionType);
Node.isJSDocImplementsTag = Node.is(common.SyntaxKind.JSDocImplementsTag);
Node.isJSDocLink = Node.is(common.SyntaxKind.JSDocLink);
Node.isJSDocLinkCode = Node.is(common.SyntaxKind.JSDocLinkCode);
Node.isJSDocLinkPlain = Node.is(common.SyntaxKind.JSDocLinkPlain);
Node.isJSDocMemberName = Node.is(common.SyntaxKind.JSDocMemberName);
Node.isJSDocOverrideTag = Node.is(common.SyntaxKind.JSDocOverrideTag);
Node.isJSDocParameterTag = Node.is(common.SyntaxKind.JSDocParameterTag);
Node.isJSDocPrivateTag = Node.is(common.SyntaxKind.JSDocPrivateTag);
Node.isJSDocPropertyTag = Node.is(common.SyntaxKind.JSDocPropertyTag);
Node.isJSDocProtectedTag = Node.is(common.SyntaxKind.JSDocProtectedTag);
Node.isJSDocPublicTag = Node.is(common.SyntaxKind.JSDocPublicTag);
Node.isJSDocReadonlyTag = Node.is(common.SyntaxKind.JSDocReadonlyTag);
Node.isJSDocReturnTag = Node.is(common.SyntaxKind.JSDocReturnTag);
Node.isJSDocSeeTag = Node.is(common.SyntaxKind.JSDocSeeTag);
Node.isJSDocSignature = Node.is(common.SyntaxKind.JSDocSignature);
Node.isJSDocTemplateTag = Node.is(common.SyntaxKind.JSDocTemplateTag);
Node.isJSDocText = Node.is(common.SyntaxKind.JSDocText);
Node.isJSDocThisTag = Node.is(common.SyntaxKind.JSDocThisTag);
Node.isJSDocTypeExpression = Node.is(common.SyntaxKind.JSDocTypeExpression);
Node.isJSDocTypeTag = Node.is(common.SyntaxKind.JSDocTypeTag);
Node.isJSDocTypedefTag = Node.is(common.SyntaxKind.JSDocTypedefTag);
Node.isJsxAttribute = Node.is(common.SyntaxKind.JsxAttribute);
Node.isJsxClosingElement = Node.is(common.SyntaxKind.JsxClosingElement);
Node.isJsxClosingFragment = Node.is(common.SyntaxKind.JsxClosingFragment);
Node.isJsxElement = Node.is(common.SyntaxKind.JsxElement);
Node.isJsxExpression = Node.is(common.SyntaxKind.JsxExpression);
Node.isJsxFragment = Node.is(common.SyntaxKind.JsxFragment);
Node.isJsxOpeningElement = Node.is(common.SyntaxKind.JsxOpeningElement);
Node.isJsxOpeningFragment = Node.is(common.SyntaxKind.JsxOpeningFragment);
Node.isJsxSelfClosingElement = Node.is(common.SyntaxKind.JsxSelfClosingElement);
Node.isJsxSpreadAttribute = Node.is(common.SyntaxKind.JsxSpreadAttribute);
Node.isJsxText = Node.is(common.SyntaxKind.JsxText);
Node.isLabeledStatement = Node.is(common.SyntaxKind.LabeledStatement);
Node.isMetaProperty = Node.is(common.SyntaxKind.MetaProperty);
Node.isMethodDeclaration = Node.is(common.SyntaxKind.MethodDeclaration);
Node.isMethodSignature = Node.is(common.SyntaxKind.MethodSignature);
Node.isModuleBlock = Node.is(common.SyntaxKind.ModuleBlock);
Node.isModuleDeclaration = Node.is(common.SyntaxKind.ModuleDeclaration);
Node.isNamedExports = Node.is(common.SyntaxKind.NamedExports);
Node.isNamedImports = Node.is(common.SyntaxKind.NamedImports);
Node.isNamedTupleMember = Node.is(common.SyntaxKind.NamedTupleMember);
Node.isNamespaceExport = Node.is(common.SyntaxKind.NamespaceExport);
Node.isNamespaceImport = Node.is(common.SyntaxKind.NamespaceImport);
Node.isNeverKeyword = Node.is(common.SyntaxKind.NeverKeyword);
Node.isNewExpression = Node.is(common.SyntaxKind.NewExpression);
Node.isNoSubstitutionTemplateLiteral = Node.is(common.SyntaxKind.NoSubstitutionTemplateLiteral);
Node.isNonNullExpression = Node.is(common.SyntaxKind.NonNullExpression);
Node.isNotEmittedStatement = Node.is(common.SyntaxKind.NotEmittedStatement);
Node.isNumberKeyword = Node.is(common.SyntaxKind.NumberKeyword);
Node.isNumericLiteral = Node.is(common.SyntaxKind.NumericLiteral);
Node.isObjectBindingPattern = Node.is(common.SyntaxKind.ObjectBindingPattern);
Node.isObjectKeyword = Node.is(common.SyntaxKind.ObjectKeyword);
Node.isObjectLiteralExpression = Node.is(common.SyntaxKind.ObjectLiteralExpression);
Node.isOmittedExpression = Node.is(common.SyntaxKind.OmittedExpression);
Node.isParenthesizedExpression = Node.is(common.SyntaxKind.ParenthesizedExpression);
Node.isPartiallyEmittedExpression = Node.is(common.SyntaxKind.PartiallyEmittedExpression);
Node.isPostfixUnaryExpression = Node.is(common.SyntaxKind.PostfixUnaryExpression);
Node.isPrefixUnaryExpression = Node.is(common.SyntaxKind.PrefixUnaryExpression);
Node.isPrivateIdentifier = Node.is(common.SyntaxKind.PrivateIdentifier);
Node.isPropertyAccessExpression = Node.is(common.SyntaxKind.PropertyAccessExpression);
Node.isPropertyAssignment = Node.is(common.SyntaxKind.PropertyAssignment);
Node.isPropertyDeclaration = Node.is(common.SyntaxKind.PropertyDeclaration);
Node.isPropertySignature = Node.is(common.SyntaxKind.PropertySignature);
Node.isQualifiedName = Node.is(common.SyntaxKind.QualifiedName);
Node.isRegularExpressionLiteral = Node.is(common.SyntaxKind.RegularExpressionLiteral);
Node.isReturnStatement = Node.is(common.SyntaxKind.ReturnStatement);
Node.isSemicolonToken = Node.is(common.SyntaxKind.SemicolonToken);
Node.isShorthandPropertyAssignment = Node.is(common.SyntaxKind.ShorthandPropertyAssignment);
Node.isSourceFile = Node.is(common.SyntaxKind.SourceFile);
Node.isSpreadAssignment = Node.is(common.SyntaxKind.SpreadAssignment);
Node.isSpreadElement = Node.is(common.SyntaxKind.SpreadElement);
Node.isStringKeyword = Node.is(common.SyntaxKind.StringKeyword);
Node.isStringLiteral = Node.is(common.SyntaxKind.StringLiteral);
Node.isSwitchStatement = Node.is(common.SyntaxKind.SwitchStatement);
Node.isSymbolKeyword = Node.is(common.SyntaxKind.SymbolKeyword);
Node.isSyntaxList = Node.is(common.SyntaxKind.SyntaxList);
Node.isTaggedTemplateExpression = Node.is(common.SyntaxKind.TaggedTemplateExpression);
Node.isTemplateExpression = Node.is(common.SyntaxKind.TemplateExpression);
Node.isTemplateHead = Node.is(common.SyntaxKind.TemplateHead);
Node.isTemplateMiddle = Node.is(common.SyntaxKind.TemplateMiddle);
Node.isTemplateSpan = Node.is(common.SyntaxKind.TemplateSpan);
Node.isTemplateTail = Node.is(common.SyntaxKind.TemplateTail);
Node.isThrowStatement = Node.is(common.SyntaxKind.ThrowStatement);
Node.isTryStatement = Node.is(common.SyntaxKind.TryStatement);
Node.isTypeAliasDeclaration = Node.is(common.SyntaxKind.TypeAliasDeclaration);
Node.isTypeOfExpression = Node.is(common.SyntaxKind.TypeOfExpression);
Node.isUndefinedKeyword = Node.is(common.SyntaxKind.UndefinedKeyword);
Node.isVariableDeclaration = Node.is(common.SyntaxKind.VariableDeclaration);
Node.isVariableDeclarationList = Node.is(common.SyntaxKind.VariableDeclarationList);
Node.isVariableStatement = Node.is(common.SyntaxKind.VariableStatement);
Node.isVoidExpression = Node.is(common.SyntaxKind.VoidExpression);
Node.isWhileStatement = Node.is(common.SyntaxKind.WhileStatement);
Node.isWithStatement = Node.is(common.SyntaxKind.WithStatement);
Node.isYieldExpression = Node.is(common.SyntaxKind.YieldExpression);
function getWrappedCondition(thisNode, condition) {
    return condition == null ? undefined : ((c) => condition(thisNode._getNodeFromCompilerNode(c)));
}
function insertWhiteSpaceTextAtPos(node, insertPos, textOrWriterFunction, methodName) {
    const parent = Node.isSourceFile(node) ? node.getChildSyntaxListOrThrow() : node.getParentSyntaxList() || node.getParentOrThrow();
    const newText = getTextFromStringOrWriter(node._getWriterWithQueuedIndentation(), textOrWriterFunction);
    if (!/^[\s\r\n]*$/.test(newText))
        throw new common.errors.InvalidOperationError(`Cannot insert non-whitespace into ${methodName}.`);
    insertIntoParentTextRange({
        parent,
        insertPos,
        newText,
    });
}
function* getCompilerForEachDescendantsIterator(node) {
    for (const child of getForEachChildren()) {
        yield child;
        yield* getCompilerForEachDescendantsIterator(child);
    }
    function getForEachChildren() {
        const children = [];
        node.forEachChild(child => {
            children.push(child);
        });
        return children;
    }
}
function* getCompilerDescendantsIterator(node, sourceFile) {
    for (const child of ExtendedParser.getCompilerChildren(node, sourceFile)) {
        yield child;
        yield* getCompilerDescendantsIterator(child, sourceFile);
    }
}
function useParseTreeSearchForKind(thisNodeOrSyntaxKind, searchingKind) {
    return searchingKind >= common.SyntaxKind.FirstNode && searchingKind < common.SyntaxKind.FirstJSDocNode
        && getThisKind() !== common.SyntaxKind.SyntaxList;
    function getThisKind() {
        if (typeof thisNodeOrSyntaxKind === "number")
            return thisNodeOrSyntaxKind;
        return thisNodeOrSyntaxKind.compilerNode.kind;
    }
}

exports.Scope = void 0;
(function (Scope) {
    Scope["Public"] = "public";
    Scope["Protected"] = "protected";
    Scope["Private"] = "private";
})(exports.Scope || (exports.Scope = {}));

class SyntaxList extends Node {
    addChildText(textOrWriterFunction) {
        return this.insertChildText(this.getChildCount(), textOrWriterFunction);
    }
    insertChildText(index, textOrWriterFunction) {
        const initialChildCount = this.getChildCount();
        const newLineKind = this._context.manipulationSettings.getNewLineKindAsString();
        const parent = this.getParentOrThrow();
        index = verifyAndGetIndex(index, initialChildCount);
        const isInline = this !== parent.getChildSyntaxList();
        let insertText = getTextFromStringOrWriter(isInline ? parent._getWriterWithQueuedChildIndentation() : parent._getWriterWithChildIndentation(), textOrWriterFunction);
        if (insertText.length === 0)
            return [];
        if (isInline) {
            if (index === 0)
                insertText += " ";
            else
                insertText = " " + insertText;
        }
        else {
            if (index === 0 && Node.isSourceFile(parent)) {
                if (!insertText.endsWith("\n"))
                    insertText += newLineKind;
            }
            else {
                insertText = newLineKind + insertText;
                if (!Node.isSourceFile(parent) && index === initialChildCount && insertText.endsWith("\n"))
                    insertText = insertText.replace(/\r?\n$/, "");
            }
        }
        const insertPos = getInsertPosFromIndex(index, this, this.getChildren());
        insertIntoParentTextRange({
            insertPos,
            newText: insertText,
            parent: this,
        });
        const finalChildren = this.getChildren();
        return getNodesToReturn(initialChildCount, finalChildren, index, true);
    }
}

function renameNode(node, newName, options) {
    common.errors.throwIfWhitespaceOrNotString(newName, "newName");
    if (node.getText() === newName)
        return;
    const renameLocations = node._context.languageService.findRenameLocations(node, options);
    const renameLocationsBySourceFile = new common.KeyValueCache();
    for (const renameLocation of renameLocations) {
        const locations = renameLocationsBySourceFile.getOrCreate(renameLocation.getSourceFile(), () => []);
        locations.push(renameLocation);
    }
    for (const [sourceFile, locations] of renameLocationsBySourceFile.getEntries()) {
        replaceSourceFileTextForRename({
            sourceFile,
            renameLocations: locations,
            newName,
        });
    }
}

function setBodyTextForNode(body, textOrWriterFunction) {
    const newText = getBodyText(body._getWriterWithIndentation(), textOrWriterFunction);
    const openBrace = body.getFirstChildByKindOrThrow(common.SyntaxKind.OpenBraceToken);
    const closeBrace = body.getFirstChildByKindOrThrow(common.SyntaxKind.CloseBraceToken);
    insertIntoParentTextRange({
        insertPos: openBrace.getEnd(),
        newText,
        parent: body,
        replacing: {
            textLength: closeBrace.getStart() - openBrace.getEnd(),
        },
    });
}

function BodiedNode(Base) {
    return class extends Base {
        getBody() {
            const body = this.compilerNode.body;
            if (body == null)
                throw new common.errors.InvalidOperationError("Bodied node should have a body.");
            return this._getNodeFromCompilerNode(body);
        }
        setBodyText(textOrWriterFunction) {
            const body = this.getBody();
            setBodyTextForNode(body, textOrWriterFunction);
            return this;
        }
        getBodyText() {
            return getBodyTextWithoutLeadingIndentation(this.getBody());
        }
    };
}

function BodyableNode(Base) {
    return class extends Base {
        getBodyOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getBody(), "Expected to find the node's body.");
        }
        getBody() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.body);
        }
        getBodyText() {
            const body = this.getBody();
            return body == null ? undefined : getBodyTextWithoutLeadingIndentation(body);
        }
        setBodyText(textOrWriterFunction) {
            this.addBody();
            setBodyTextForNode(this.getBodyOrThrow(), textOrWriterFunction);
            return this;
        }
        hasBody() {
            return this.compilerNode.body != null;
        }
        addBody() {
            var _a;
            if (this.hasBody())
                return this;
            const semiColon = this.getLastChildByKind(common.SyntaxKind.SemicolonToken);
            insertIntoParentTextRange({
                parent: this,
                insertPos: semiColon == null ? this.getEnd() : semiColon.getStart(),
                newText: this._getWriterWithQueuedIndentation().space().block().toString(),
                replacing: {
                    textLength: (_a = semiColon === null || semiColon === void 0 ? void 0 : semiColon.getFullWidth()) !== null && _a !== void 0 ? _a : 0,
                },
            });
            return this;
        }
        removeBody() {
            const body = this.getBody();
            if (body == null)
                return this;
            insertIntoParentTextRange({
                parent: this,
                insertPos: body.getPos(),
                newText: ";",
                replacing: {
                    textLength: body.getFullWidth(),
                },
            });
            return this;
        }
    };
}

function ChildOrderableNode(Base) {
    return class extends Base {
        setOrder(order) {
            const childIndex = this.getChildIndex();
            const parent = this.getParentSyntaxList() || this.getParentSyntaxListOrThrow();
            common.errors.throwIfOutOfRange(order, [0, parent.getChildCount() - 1], "order");
            if (childIndex === order)
                return this;
            changeChildOrder({
                parent,
                getSiblingFormatting: getGeneralFormatting,
                oldIndex: childIndex,
                newIndex: order,
            });
            return this;
        }
    };
}

function DecoratableNode(Base) {
    return class extends Base {
        getDecorator(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getDecorators(), nameOrFindFunction);
        }
        getDecoratorOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getDecorator(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("decorator", nameOrFindFunction));
        }
        getDecorators() {
            var _a, _b;
            return (_b = (_a = this.compilerNode.decorators) === null || _a === void 0 ? void 0 : _a.map(d => this._getNodeFromCompilerNode(d))) !== null && _b !== void 0 ? _b : [];
        }
        addDecorator(structure) {
            return this.insertDecorator(getEndIndexFromArray(this.compilerNode.decorators), structure);
        }
        addDecorators(structures) {
            return this.insertDecorators(getEndIndexFromArray(this.compilerNode.decorators), structures);
        }
        insertDecorator(index, structure) {
            return this.insertDecorators(index, [structure])[0];
        }
        insertDecorators(index, structures) {
            if (common.ArrayUtils.isNullOrEmpty(structures))
                return [];
            const decoratorLines = getDecoratorLines(this, structures);
            const decorators = this.getDecorators();
            index = verifyAndGetIndex(index, decorators.length);
            const formattingKind = getDecoratorFormattingKind(this, decorators);
            const previousDecorator = decorators[index - 1];
            const decoratorCode = getNewInsertCode({
                structures,
                newCodes: decoratorLines,
                parent: this,
                indentationText: this.getIndentationText(),
                getSeparator: () => formattingKind,
                previousFormattingKind: previousDecorator == null ? FormattingKind.None : formattingKind,
                nextFormattingKind: previousDecorator == null ? formattingKind : FormattingKind.None,
            });
            insertIntoParentTextRange({
                parent: decorators.length === 0 ? this : decorators[0].getParentSyntaxListOrThrow(),
                insertPos: decorators[index - 1] == null ? this.getStart() : decorators[index - 1].getEnd(),
                newText: decoratorCode,
            });
            return getNodesToReturn(decorators, this.getDecorators(), index, false);
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.decorators != null) {
                this.getDecorators().forEach(d => d.remove());
                this.addDecorators(structure.decorators);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                decorators: this.getDecorators().map(d => d.getStructure()),
            });
        }
    };
}
function getDecoratorLines(node, structures) {
    const lines = [];
    for (const structure of structures) {
        const writer = node._getWriter();
        const structurePrinter = node._context.structurePrinterFactory.forDecorator();
        structurePrinter.printText(writer, structure);
        lines.push(writer.toString());
    }
    return lines;
}
function getDecoratorFormattingKind(parent, currentDecorators) {
    const sameLine = areDecoratorsOnSameLine(parent, currentDecorators);
    return sameLine ? FormattingKind.Space : FormattingKind.Newline;
}
function areDecoratorsOnSameLine(parent, currentDecorators) {
    if (currentDecorators.length <= 1)
        return parent.getKind() === common.SyntaxKind.Parameter;
    const startLinePos = currentDecorators[0].getStartLinePos();
    for (let i = 1; i < currentDecorators.length; i++) {
        if (currentDecorators[i].getStartLinePos() !== startLinePos)
            return false;
    }
    return true;
}

function DotDotDotTokenableNode(Base) {
    return class extends Base {
        getDotDotDotTokenOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getDotDotDotToken(), "Expected to find a dot dot dot token (...).");
        }
        getDotDotDotToken() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.dotDotDotToken);
        }
    };
}

function ExclamationTokenableNode(Base) {
    return class extends Base {
        hasExclamationToken() {
            return this.compilerNode.exclamationToken != null;
        }
        getExclamationTokenNode() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.exclamationToken);
        }
        getExclamationTokenNodeOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getExclamationTokenNode(), "Expected to find an exclamation token.");
        }
        setHasExclamationToken(value) {
            const exclamationTokenNode = this.getExclamationTokenNode();
            const hasExclamationToken = exclamationTokenNode != null;
            if (value === hasExclamationToken)
                return this;
            if (value) {
                if (Node.isQuestionTokenableNode(this))
                    this.setHasQuestionToken(false);
                const colonNode = this.getFirstChildByKind(common.SyntaxKind.ColonToken);
                if (colonNode == null)
                    throw new common.errors.InvalidOperationError("Cannot add an exclamation token to a node that does not have a type.");
                insertIntoParentTextRange({
                    insertPos: colonNode.getStart(),
                    parent: this,
                    newText: "!",
                });
            }
            else {
                removeChildren({ children: [exclamationTokenNode] });
            }
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.hasExclamationToken != null)
                this.setHasExclamationToken(structure.hasExclamationToken);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                hasExclamationToken: this.hasExclamationToken(),
            });
        }
    };
}

function ModifierableNode(Base) {
    return class extends Base {
        getModifiers() {
            return this.getCompilerModifiers().map(m => this._getNodeFromCompilerNode(m));
        }
        getFirstModifierByKindOrThrow(kind) {
            return common.errors.throwIfNullOrUndefined(this.getFirstModifierByKind(kind), `Expected a modifier of syntax kind: ${common.getSyntaxKindName(kind)}`);
        }
        getFirstModifierByKind(kind) {
            for (const modifier of this.getCompilerModifiers()) {
                if (modifier.kind === kind)
                    return this._getNodeFromCompilerNode(modifier);
            }
            return undefined;
        }
        hasModifier(textOrKind) {
            if (typeof textOrKind === "string")
                return this.getModifiers().some(m => m.getText() === textOrKind);
            else
                return this.getCompilerModifiers().some(m => m.kind === textOrKind);
        }
        toggleModifier(text, value) {
            if (value == null)
                value = !this.hasModifier(text);
            if (value)
                this.addModifier(text);
            else
                this.removeModifier(text);
            return this;
        }
        addModifier(text) {
            const modifiers = this.getModifiers();
            const existingModifier = modifiers.find(m => m.getText() === text);
            if (existingModifier != null)
                return existingModifier;
            const insertPos = getInsertPos(this);
            let startPos;
            let newText;
            const isFirstModifier = modifiers.length === 0 || insertPos === modifiers[0].getStart();
            if (isFirstModifier) {
                newText = text + " ";
                startPos = insertPos;
            }
            else {
                newText = " " + text;
                startPos = insertPos + 1;
            }
            insertIntoParentTextRange({
                parent: modifiers.length === 0 ? this : modifiers[0].getParentSyntaxListOrThrow(),
                insertPos,
                newText,
            });
            return this.getModifiers().find(m => m.getStart() === startPos);
            function getInsertPos(node) {
                let pos = getInitialInsertPos();
                for (const addAfterText of getAddAfterModifierTexts(text)) {
                    for (let i = 0; i < modifiers.length; i++) {
                        const modifier = modifiers[i];
                        if (modifier.getText() === addAfterText) {
                            if (pos < modifier.getEnd())
                                pos = modifier.getEnd();
                            break;
                        }
                    }
                }
                return pos;
                function getInitialInsertPos() {
                    if (modifiers.length > 0)
                        return modifiers[0].getStart();
                    for (const child of node._getChildrenIterator()) {
                        if (child.getKind() === common.SyntaxKind.SyntaxList || common.ts.isJSDocCommentContainingNode(child.compilerNode))
                            continue;
                        return child.getStart();
                    }
                    return node.getStart();
                }
            }
        }
        removeModifier(text) {
            const modifiers = this.getModifiers();
            const modifier = modifiers.find(m => m.getText() === text);
            if (modifier == null)
                return false;
            removeChildren({
                children: [modifiers.length === 1 ? modifier.getParentSyntaxListOrThrow() : modifier],
                removeFollowingSpaces: true,
            });
            return true;
        }
        getCompilerModifiers() {
            return this.compilerNode.modifiers || [];
        }
    };
}
function getAddAfterModifierTexts(text) {
    switch (text) {
        case "export":
            return [];
        case "public":
        case "protected":
        case "private":
            return [];
        case "default":
            return ["export"];
        case "const":
            return ["export"];
        case "declare":
            return ["export", "default"];
        case "static":
            return ["public", "protected", "private"];
        case "override":
            return ["public", "private", "protected", "static"];
        case "abstract":
            return ["export", "default", "declare", "public", "private", "protected", "static", "override"];
        case "async":
            return ["export", "default", "declare", "public", "private", "protected", "static", "override", "abstract"];
        case "readonly":
            return ["export", "default", "declare", "public", "private", "protected", "static", "override", "abstract"];
        default:
            common.errors.throwNotImplementedForNeverValueError(text);
    }
}

function ExportGetableNode(Base) {
    return class extends Base {
        hasExportKeyword() {
            return this.getExportKeyword() != null;
        }
        getExportKeyword() {
            if (Node.isVariableDeclaration(this)) {
                const variableStatement = this.getVariableStatement();
                return variableStatement === null || variableStatement === void 0 ? void 0 : variableStatement.getExportKeyword();
            }
            if (!Node.isModifierableNode(this))
                return throwForNotModifierableNode();
            return this.getFirstModifierByKind(common.SyntaxKind.ExportKeyword);
        }
        getExportKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getExportKeyword(), "Expected to find an export keyword.");
        }
        hasDefaultKeyword() {
            return this.getDefaultKeyword() != null;
        }
        getDefaultKeyword() {
            if (Node.isVariableDeclaration(this)) {
                const variableStatement = this.getVariableStatement();
                return variableStatement === null || variableStatement === void 0 ? void 0 : variableStatement.getDefaultKeyword();
            }
            if (!Node.isModifierableNode(this))
                return throwForNotModifierableNode();
            return this.getFirstModifierByKind(common.SyntaxKind.DefaultKeyword);
        }
        getDefaultKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getDefaultKeyword(), "Expected to find a default keyword.");
        }
        isExported() {
            if (this.hasExportKeyword())
                return true;
            const thisSymbol = this.getSymbol();
            const sourceFileSymbol = this.getSourceFile().getSymbol();
            if (thisSymbol == null || sourceFileSymbol == null)
                return false;
            return sourceFileSymbol.getExports().some(e => e === thisSymbol || e.getAliasedSymbol() === thisSymbol);
        }
        isDefaultExport() {
            if (this.hasDefaultKeyword())
                return true;
            const thisSymbol = this.getSymbol();
            if (thisSymbol == null)
                return false;
            const defaultExportSymbol = this.getSourceFile().getDefaultExportSymbol();
            if (defaultExportSymbol == null)
                return false;
            if (thisSymbol === defaultExportSymbol)
                return true;
            const aliasedSymbol = defaultExportSymbol.getAliasedSymbol();
            return thisSymbol === aliasedSymbol;
        }
        isNamedExport() {
            const thisSymbol = this.getSymbol();
            const sourceFileSymbol = this.getSourceFile().getSymbol();
            if (thisSymbol == null || sourceFileSymbol == null)
                return false;
            return !isDefaultExport() && sourceFileSymbol.getExports().some(e => e === thisSymbol || e.getAliasedSymbol() === thisSymbol);
            function isDefaultExport() {
                const defaultExportSymbol = sourceFileSymbol.getExport("default");
                if (defaultExportSymbol == null)
                    return false;
                return thisSymbol === defaultExportSymbol || thisSymbol === defaultExportSymbol.getAliasedSymbol();
            }
        }
    };
}
function throwForNotModifierableNode() {
    throw new common.errors.NotImplementedError(`Not implemented situation where node was not a ${"ModifierableNode"}.`);
}

function ExportableNode(Base) {
    return apply$1(ExportGetableNode(Base));
}
function apply$1(Base) {
    return class extends Base {
        setIsDefaultExport(value) {
            if (value === this.isDefaultExport())
                return this;
            if (value && !Node.isSourceFile(this.getParentOrThrow()))
                throw new common.errors.InvalidOperationError("The parent must be a source file in order to set this node as a default export.");
            const sourceFile = this.getSourceFile();
            const fileDefaultExportSymbol = sourceFile.getDefaultExportSymbol();
            if (fileDefaultExportSymbol != null)
                sourceFile.removeDefaultExport(fileDefaultExportSymbol);
            if (!value)
                return this;
            if (Node.hasName(this) && shouldWriteAsSeparateStatement.call(this)) {
                const parentSyntaxList = this.getFirstAncestorByKindOrThrow(common.SyntaxKind.SyntaxList);
                const name = this.getName();
                parentSyntaxList.insertChildText(this.getChildIndex() + 1, writer => {
                    writer.newLine().write(`export default ${name};`);
                });
            }
            else {
                this.addModifier("export");
                this.addModifier("default");
            }
            return this;
            function shouldWriteAsSeparateStatement() {
                if (Node.isEnumDeclaration(this) || Node.isModuleDeclaration(this) || Node.isTypeAliasDeclaration(this))
                    return true;
                if (Node.isAmbientableNode(this) && this.isAmbient())
                    return true;
                return false;
            }
        }
        setIsExported(value) {
            if (Node.isSourceFile(this.getParentOrThrow()))
                this.toggleModifier("default", false);
            this.toggleModifier("export", value);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.isExported != null)
                this.setIsExported(structure.isExported);
            if (structure.isDefaultExport != null)
                this.setIsDefaultExport(structure.isDefaultExport);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                isExported: this.hasExportKeyword(),
                isDefaultExport: this.hasDefaultKeyword(),
            });
        }
    };
}

class Printer {
    printTextOrWriterFunc(writer, textOrWriterFunc) {
        if (typeof textOrWriterFunc === "string")
            writer.write(textOrWriterFunc);
        else if (textOrWriterFunc != null)
            textOrWriterFunc(writer);
    }
    getNewWriter(writer) {
        return new CodeBlockWriter__default['default'](writer.getOptions());
    }
    getNewWriterWithQueuedChildIndentation(writer) {
        const newWriter = new CodeBlockWriter__default['default'](writer.getOptions());
        newWriter.queueIndentationLevel(1);
        return newWriter;
    }
    getText(writer, textOrWriterFunc) {
        const newWriter = this.getNewWriter(writer);
        this.printTextOrWriterFunc(newWriter, textOrWriterFunc);
        return newWriter.toString();
    }
    getTextWithQueuedChildIndentation(writer, textOrWriterFunc) {
        const queuedChildIndentationWriter = this.getNewWriterWithQueuedChildIndentation(writer);
        this.printTextOrWriterFunc(queuedChildIndentationWriter, textOrWriterFunc);
        return queuedChildIndentationWriter.toString();
    }
}

class InitializerExpressionableNodeStructurePrinter extends Printer {
    printText(writer, structure) {
        const { initializer } = structure;
        if (initializer == null)
            return;
        const initializerText = this.getText(writer, initializer);
        if (!common.StringUtils.isNullOrWhitespace(initializerText)) {
            writer.hangingIndent(() => {
                writer.spaceIfLastNot();
                writer.write(`= ${initializerText}`);
            });
        }
    }
}

class ModifierableNodeStructurePrinter extends Printer {
    printText(writer, structure) {
        const scope = structure.scope;
        if (structure.isDefaultExport)
            writer.write("export default ");
        else if (structure.isExported)
            writer.write("export ");
        if (structure.hasDeclareKeyword)
            writer.write("declare ");
        if (scope != null)
            writer.write(`${scope} `);
        if (structure.isStatic)
            writer.write("static ");
        if (structure.hasOverrideKeyword)
            writer.write("override ");
        if (structure.isAbstract)
            writer.write("abstract ");
        if (structure.isAsync)
            writer.write("async ");
        if (structure.isReadonly)
            writer.write("readonly ");
    }
}

class ReturnTypedNodeStructurePrinter extends Printer {
    constructor(alwaysWrite = false) {
        super();
        this.alwaysWrite = alwaysWrite;
    }
    printText(writer, structure) {
        let { returnType } = structure;
        if (returnType == null && this.alwaysWrite === false)
            return;
        returnType = returnType !== null && returnType !== void 0 ? returnType : "void";
        const returnTypeText = this.getText(writer, returnType);
        if (!common.StringUtils.isNullOrWhitespace(returnTypeText)) {
            writer.hangingIndent(() => {
                writer.write(`: ${returnTypeText}`);
            });
        }
    }
}

class TypedNodeStructurePrinter extends Printer {
    constructor(separator, alwaysWrite = false) {
        super();
        this.separator = separator;
        this.alwaysWrite = alwaysWrite;
    }
    printText(writer, structure) {
        let { type } = structure;
        if (type == null && this.alwaysWrite === false)
            return;
        type = type !== null && type !== void 0 ? type : "any";
        const typeText = this.getText(writer, type);
        if (!common.StringUtils.isNullOrWhitespace(typeText)) {
            writer.hangingIndent(() => {
                writer.write(`${this.separator} ${typeText}`);
            });
        }
    }
}

class BlankLineFormattingStructuresPrinter extends Printer {
    constructor(printer) {
        super();
        this.printer = printer;
    }
    printText(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            writer.conditionalBlankLine(i > 0);
            this.printer.printText(writer, structures[i]);
        }
    }
}

class CommaSeparatedStructuresPrinter extends Printer {
    constructor(printer) {
        super();
        this.printer = printer;
    }
    printText(writer, structures) {
        printTextWithSeparator(this.printer, writer, structures, () => writer.spaceIfLastNot());
    }
}
function printTextWithSeparator(printer, writer, structures, separator) {
    if (structures == null)
        return;
    if (structures instanceof Function || typeof structures === "string")
        printer.printText(writer, structures);
    else {
        const commaAppendPositions = new Array(structures.length);
        for (let i = 0; i < structures.length; i++) {
            if (i > 0)
                separator();
            const structure = structures[i];
            const startPos = writer.getLength();
            printer.printText(writer, structure);
            const pos = getAppendCommaPos(WriterUtils.getLastCharactersToPos(writer, startPos));
            commaAppendPositions[i] = pos === -1 ? false : pos + startPos;
        }
        let foundFirst = false;
        for (let i = commaAppendPositions.length - 1; i >= 0; i--) {
            const pos = commaAppendPositions[i];
            if (pos === false)
                continue;
            else if (!foundFirst)
                foundFirst = true;
            else
                writer.unsafeInsert(pos, ",");
        }
    }
}

class CommaNewLineSeparatedStructuresPrinter extends Printer {
    constructor(printer) {
        super();
        this.printer = printer;
    }
    printText(writer, structures) {
        printTextWithSeparator(this.printer, writer, structures, () => writer.newLineIfLastNot());
    }
}

class NewLineFormattingStructuresPrinter extends Printer {
    constructor(printer) {
        super();
        this.printer = printer;
    }
    printText(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            writer.conditionalNewLine(i > 0);
            this.printer.printText(writer, structures[i]);
        }
    }
}

class SpaceFormattingStructuresPrinter extends Printer {
    constructor(printer) {
        super();
        this.printer = printer;
    }
    printText(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            writer.conditionalWrite(i > 0, " ");
            this.printer.printText(writer, structures[i]);
        }
    }
}

class NodePrinter extends Printer {
    constructor(factory) {
        super();
        this.factory = factory;
    }
    printTextWithoutTrivia(writer, structure) {
        this.printTextInternal(writer, structure);
    }
    printText(writer, structure) {
        this.printLeadingTrivia(writer, structure);
        writer.closeComment();
        this.printTextInternal(writer, structure);
        this.printTrailingTrivia(writer, structure);
    }
    printLeadingTrivia(writer, structure) {
        const leadingTrivia = structure["leadingTrivia"];
        if (leadingTrivia != null) {
            this.printTrivia(writer, leadingTrivia);
            if (writer.isInComment())
                writer.closeComment();
        }
    }
    printTrailingTrivia(writer, structure) {
        const trailingTrivia = structure["trailingTrivia"];
        if (trailingTrivia != null)
            this.printTrivia(writer, trailingTrivia);
    }
    printTrivia(writer, trivia) {
        if (trivia instanceof Array) {
            for (let i = 0; i < trivia.length; i++) {
                this.printTextOrWriterFunc(writer, trivia[i]);
                if (i !== trivia.length - 1)
                    writer.newLineIfLastNot();
            }
        }
        else {
            this.printTextOrWriterFunc(writer, trivia);
        }
    }
}

class ClassDeclarationStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
        this.multipleWriter = new BlankLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        const isAmbient = structure.hasDeclareKeyword || this.options.isAmbient;
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forDecorator().printTexts(writer, structure.decorators);
        this.printHeader(writer, structure);
        writer.inlineBlock(() => {
            this.factory.forPropertyDeclaration().printTexts(writer, structure.properties);
            this.printCtors(writer, structure, isAmbient);
            this.printGetAndSet(writer, structure, isAmbient);
            if (!common.ArrayUtils.isNullOrEmpty(structure.methods)) {
                this.conditionalSeparator(writer, isAmbient);
                this.factory.forMethodDeclaration({ isAmbient }).printTexts(writer, structure.methods);
            }
        });
    }
    printHeader(writer, structure) {
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(`class`);
        if (!common.StringUtils.isNullOrWhitespace(structure.name))
            writer.space().write(structure.name);
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        writer.space();
        writer.hangingIndent(() => {
            if (structure.extends != null) {
                const extendsText = this.getText(writer, structure.extends);
                if (!common.StringUtils.isNullOrWhitespace(extendsText))
                    writer.write(`extends ${extendsText} `);
            }
            if (structure.implements != null) {
                const implementsText = structure.implements instanceof Array
                    ? structure.implements.map(i => this.getText(writer, i)).join(", ")
                    : this.getText(writer, structure.implements);
                if (!common.StringUtils.isNullOrWhitespace(implementsText))
                    writer.write(`implements ${implementsText} `);
            }
        });
    }
    printCtors(writer, structure, isAmbient) {
        if (common.ArrayUtils.isNullOrEmpty(structure.ctors))
            return;
        for (const ctor of structure.ctors) {
            this.conditionalSeparator(writer, isAmbient);
            this.factory.forConstructorDeclaration({ isAmbient }).printText(writer, ctor);
        }
    }
    printGetAndSet(writer, structure, isAmbient) {
        var _a, _b;
        const getAccessors = [...(_a = structure.getAccessors) !== null && _a !== void 0 ? _a : []];
        const setAccessors = [...(_b = structure.setAccessors) !== null && _b !== void 0 ? _b : []];
        const getAccessorWriter = this.factory.forGetAccessorDeclaration({ isAmbient });
        const setAccessorWriter = this.factory.forSetAccessorDeclaration({ isAmbient });
        for (const getAccessor of getAccessors) {
            this.conditionalSeparator(writer, isAmbient);
            getAccessorWriter.printText(writer, getAccessor);
            const setAccessorIndex = setAccessors.findIndex(item => item.name === getAccessor.name);
            if (setAccessorIndex >= 0) {
                this.conditionalSeparator(writer, isAmbient);
                setAccessorWriter.printText(writer, setAccessors[setAccessorIndex]);
                setAccessors.splice(setAccessorIndex, 1);
            }
        }
        for (const setAccessor of setAccessors) {
            this.conditionalSeparator(writer, isAmbient);
            setAccessorWriter.printText(writer, setAccessor);
        }
    }
    conditionalSeparator(writer, isAmbient) {
        if (writer.isAtStartOfFirstLineOfBlock())
            return;
        if (isAmbient)
            writer.newLine();
        else
            writer.blankLine();
    }
}

exports.StructureKind = void 0;
(function (StructureKind) {
    StructureKind[StructureKind["CallSignature"] = 0] = "CallSignature";
    StructureKind[StructureKind["Class"] = 1] = "Class";
    StructureKind[StructureKind["ClassStaticBlock"] = 2] = "ClassStaticBlock";
    StructureKind[StructureKind["ConstructSignature"] = 3] = "ConstructSignature";
    StructureKind[StructureKind["Constructor"] = 4] = "Constructor";
    StructureKind[StructureKind["ConstructorOverload"] = 5] = "ConstructorOverload";
    StructureKind[StructureKind["Decorator"] = 6] = "Decorator";
    StructureKind[StructureKind["Enum"] = 7] = "Enum";
    StructureKind[StructureKind["EnumMember"] = 8] = "EnumMember";
    StructureKind[StructureKind["ExportAssignment"] = 9] = "ExportAssignment";
    StructureKind[StructureKind["ExportDeclaration"] = 10] = "ExportDeclaration";
    StructureKind[StructureKind["ExportSpecifier"] = 11] = "ExportSpecifier";
    StructureKind[StructureKind["Function"] = 12] = "Function";
    StructureKind[StructureKind["FunctionOverload"] = 13] = "FunctionOverload";
    StructureKind[StructureKind["GetAccessor"] = 14] = "GetAccessor";
    StructureKind[StructureKind["ImportDeclaration"] = 15] = "ImportDeclaration";
    StructureKind[StructureKind["ImportSpecifier"] = 16] = "ImportSpecifier";
    StructureKind[StructureKind["IndexSignature"] = 17] = "IndexSignature";
    StructureKind[StructureKind["Interface"] = 18] = "Interface";
    StructureKind[StructureKind["JsxAttribute"] = 19] = "JsxAttribute";
    StructureKind[StructureKind["JsxSpreadAttribute"] = 20] = "JsxSpreadAttribute";
    StructureKind[StructureKind["JsxElement"] = 21] = "JsxElement";
    StructureKind[StructureKind["JsxSelfClosingElement"] = 22] = "JsxSelfClosingElement";
    StructureKind[StructureKind["JSDoc"] = 23] = "JSDoc";
    StructureKind[StructureKind["JSDocTag"] = 24] = "JSDocTag";
    StructureKind[StructureKind["Method"] = 25] = "Method";
    StructureKind[StructureKind["MethodOverload"] = 26] = "MethodOverload";
    StructureKind[StructureKind["MethodSignature"] = 27] = "MethodSignature";
    StructureKind[StructureKind["Module"] = 28] = "Module";
    StructureKind[StructureKind["Parameter"] = 29] = "Parameter";
    StructureKind[StructureKind["Property"] = 30] = "Property";
    StructureKind[StructureKind["PropertyAssignment"] = 31] = "PropertyAssignment";
    StructureKind[StructureKind["PropertySignature"] = 32] = "PropertySignature";
    StructureKind[StructureKind["SetAccessor"] = 33] = "SetAccessor";
    StructureKind[StructureKind["ShorthandPropertyAssignment"] = 34] = "ShorthandPropertyAssignment";
    StructureKind[StructureKind["SourceFile"] = 35] = "SourceFile";
    StructureKind[StructureKind["SpreadAssignment"] = 36] = "SpreadAssignment";
    StructureKind[StructureKind["TypeAlias"] = 37] = "TypeAlias";
    StructureKind[StructureKind["TypeParameter"] = 38] = "TypeParameter";
    StructureKind[StructureKind["VariableDeclaration"] = 39] = "VariableDeclaration";
    StructureKind[StructureKind["VariableStatement"] = 40] = "VariableStatement";
})(exports.StructureKind || (exports.StructureKind = {}));

const Structure = {
    hasName(structure) {
        return typeof structure.name === "string";
    },
    isClass(structure) {
        return structure.kind === exports.StructureKind.Class;
    },
    isClassLikeDeclarationBase(structure) {
        return structure.kind === exports.StructureKind.Class;
    },
    isNameable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Class:
            case exports.StructureKind.Function:
                return true;
            default:
                return false;
        }
    },
    isImplementsClauseable(structure) {
        return structure.kind === exports.StructureKind.Class;
    },
    isDecoratable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Class:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.Property:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Parameter:
                return true;
            default:
                return false;
        }
    },
    isTypeParametered(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Class:
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.Constructor:
            case exports.StructureKind.ConstructorOverload:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
            case exports.StructureKind.CallSignature:
            case exports.StructureKind.ConstructSignature:
            case exports.StructureKind.Interface:
            case exports.StructureKind.MethodSignature:
            case exports.StructureKind.TypeAlias:
                return true;
            default:
                return false;
        }
    },
    isJSDocable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Class:
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.Constructor:
            case exports.StructureKind.ConstructorOverload:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Property:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Enum:
            case exports.StructureKind.EnumMember:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
            case exports.StructureKind.CallSignature:
            case exports.StructureKind.ConstructSignature:
            case exports.StructureKind.IndexSignature:
            case exports.StructureKind.Interface:
            case exports.StructureKind.MethodSignature:
            case exports.StructureKind.PropertySignature:
            case exports.StructureKind.Module:
            case exports.StructureKind.VariableStatement:
            case exports.StructureKind.TypeAlias:
                return true;
            default:
                return false;
        }
    },
    isAbstractable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Class:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Property:
            case exports.StructureKind.SetAccessor:
                return true;
            default:
                return false;
        }
    },
    isAmbientable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Class:
            case exports.StructureKind.Property:
            case exports.StructureKind.Enum:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
            case exports.StructureKind.Interface:
            case exports.StructureKind.Module:
            case exports.StructureKind.VariableStatement:
            case exports.StructureKind.TypeAlias:
                return true;
            default:
                return false;
        }
    },
    isExportable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Class:
            case exports.StructureKind.Enum:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
            case exports.StructureKind.Interface:
            case exports.StructureKind.Module:
            case exports.StructureKind.VariableStatement:
            case exports.StructureKind.TypeAlias:
                return true;
            default:
                return false;
        }
    },
    isClassStaticBlock(structure) {
        return structure.kind === exports.StructureKind.ClassStaticBlock;
    },
    isStaticable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Property:
            case exports.StructureKind.SetAccessor:
                return true;
            default:
                return false;
        }
    },
    isFunctionLike(structure) {
        switch (structure.kind) {
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.Constructor:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Function:
                return true;
            default:
                return false;
        }
    },
    isSignatured(structure) {
        switch (structure.kind) {
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.Constructor:
            case exports.StructureKind.ConstructorOverload:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
            case exports.StructureKind.CallSignature:
            case exports.StructureKind.ConstructSignature:
            case exports.StructureKind.MethodSignature:
                return true;
            default:
                return false;
        }
    },
    isParametered(structure) {
        switch (structure.kind) {
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.Constructor:
            case exports.StructureKind.ConstructorOverload:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
            case exports.StructureKind.CallSignature:
            case exports.StructureKind.ConstructSignature:
            case exports.StructureKind.MethodSignature:
                return true;
            default:
                return false;
        }
    },
    isReturnTyped(structure) {
        switch (structure.kind) {
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.Constructor:
            case exports.StructureKind.ConstructorOverload:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
            case exports.StructureKind.CallSignature:
            case exports.StructureKind.ConstructSignature:
            case exports.StructureKind.IndexSignature:
            case exports.StructureKind.MethodSignature:
                return true;
            default:
                return false;
        }
    },
    isStatemented(structure) {
        switch (structure.kind) {
            case exports.StructureKind.ClassStaticBlock:
            case exports.StructureKind.Constructor:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.Function:
            case exports.StructureKind.Module:
            case exports.StructureKind.SourceFile:
                return true;
            default:
                return false;
        }
    },
    isConstructor(structure) {
        return structure.kind === exports.StructureKind.Constructor;
    },
    isScoped(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Constructor:
            case exports.StructureKind.ConstructorOverload:
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Property:
            case exports.StructureKind.SetAccessor:
                return true;
            default:
                return false;
        }
    },
    isConstructorDeclarationOverload(structure) {
        return structure.kind === exports.StructureKind.ConstructorOverload;
    },
    isGetAccessor(structure) {
        return structure.kind === exports.StructureKind.GetAccessor;
    },
    isPropertyNamed(structure) {
        switch (structure.kind) {
            case exports.StructureKind.GetAccessor:
            case exports.StructureKind.Method:
            case exports.StructureKind.Property:
            case exports.StructureKind.SetAccessor:
            case exports.StructureKind.EnumMember:
            case exports.StructureKind.MethodSignature:
            case exports.StructureKind.PropertySignature:
            case exports.StructureKind.PropertyAssignment:
                return true;
            default:
                return false;
        }
    },
    isMethod(structure) {
        return structure.kind === exports.StructureKind.Method;
    },
    isAsyncable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
                return true;
            default:
                return false;
        }
    },
    isGeneratorable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Function:
            case exports.StructureKind.FunctionOverload:
                return true;
            default:
                return false;
        }
    },
    isQuestionTokenable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Property:
            case exports.StructureKind.Parameter:
            case exports.StructureKind.MethodSignature:
            case exports.StructureKind.PropertySignature:
                return true;
            default:
                return false;
        }
    },
    isOverrideable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Method:
            case exports.StructureKind.MethodOverload:
            case exports.StructureKind.Property:
            case exports.StructureKind.Parameter:
                return true;
            default:
                return false;
        }
    },
    isMethodDeclarationOverload(structure) {
        return structure.kind === exports.StructureKind.MethodOverload;
    },
    isProperty(structure) {
        return structure.kind === exports.StructureKind.Property;
    },
    isTyped(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Property:
            case exports.StructureKind.Parameter:
            case exports.StructureKind.PropertySignature:
            case exports.StructureKind.VariableDeclaration:
            case exports.StructureKind.TypeAlias:
                return true;
            default:
                return false;
        }
    },
    isExclamationTokenable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Property:
            case exports.StructureKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    },
    isReadonlyable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Property:
            case exports.StructureKind.Parameter:
            case exports.StructureKind.IndexSignature:
            case exports.StructureKind.PropertySignature:
                return true;
            default:
                return false;
        }
    },
    isInitializerExpressionable(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Property:
            case exports.StructureKind.EnumMember:
            case exports.StructureKind.Parameter:
            case exports.StructureKind.PropertySignature:
            case exports.StructureKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    },
    isSetAccessor(structure) {
        return structure.kind === exports.StructureKind.SetAccessor;
    },
    isDecorator(structure) {
        return structure.kind === exports.StructureKind.Decorator;
    },
    isJSDoc(structure) {
        return structure.kind === exports.StructureKind.JSDoc;
    },
    isJSDocTag(structure) {
        return structure.kind === exports.StructureKind.JSDocTag;
    },
    isEnum(structure) {
        return structure.kind === exports.StructureKind.Enum;
    },
    isNamed(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Enum:
            case exports.StructureKind.Interface:
            case exports.StructureKind.JsxAttribute:
            case exports.StructureKind.TypeAlias:
            case exports.StructureKind.TypeParameter:
            case exports.StructureKind.ShorthandPropertyAssignment:
                return true;
            default:
                return false;
        }
    },
    isEnumMember(structure) {
        return structure.kind === exports.StructureKind.EnumMember;
    },
    isFunction(structure) {
        return structure.kind === exports.StructureKind.Function;
    },
    isFunctionDeclarationOverload(structure) {
        return structure.kind === exports.StructureKind.FunctionOverload;
    },
    isParameter(structure) {
        return structure.kind === exports.StructureKind.Parameter;
    },
    isBindingNamed(structure) {
        switch (structure.kind) {
            case exports.StructureKind.Parameter:
            case exports.StructureKind.VariableDeclaration:
                return true;
            default:
                return false;
        }
    },
    isScopeable(structure) {
        return structure.kind === exports.StructureKind.Parameter;
    },
    isCallSignature(structure) {
        return structure.kind === exports.StructureKind.CallSignature;
    },
    isConstructSignature(structure) {
        return structure.kind === exports.StructureKind.ConstructSignature;
    },
    isIndexSignature(structure) {
        return structure.kind === exports.StructureKind.IndexSignature;
    },
    isInterface(structure) {
        return structure.kind === exports.StructureKind.Interface;
    },
    isExtendsClauseable(structure) {
        return structure.kind === exports.StructureKind.Interface;
    },
    isTypeElementMembered(structure) {
        return structure.kind === exports.StructureKind.Interface;
    },
    isMethodSignature(structure) {
        return structure.kind === exports.StructureKind.MethodSignature;
    },
    isPropertySignature(structure) {
        return structure.kind === exports.StructureKind.PropertySignature;
    },
    isJsxAttribute(structure) {
        return structure.kind === exports.StructureKind.JsxAttribute;
    },
    isJsxElement(structure) {
        return structure.kind === exports.StructureKind.JsxElement;
    },
    isJsxSelfClosingElement(structure) {
        return structure.kind === exports.StructureKind.JsxSelfClosingElement;
    },
    isJsxTagNamed(structure) {
        return structure.kind === exports.StructureKind.JsxSelfClosingElement;
    },
    isJsxAttributed(structure) {
        return structure.kind === exports.StructureKind.JsxSelfClosingElement;
    },
    isJsxSpreadAttribute(structure) {
        return structure.kind === exports.StructureKind.JsxSpreadAttribute;
    },
    isExportAssignment(structure) {
        return structure.kind === exports.StructureKind.ExportAssignment;
    },
    isExportDeclaration(structure) {
        return structure.kind === exports.StructureKind.ExportDeclaration;
    },
    isExportSpecifier(structure) {
        return structure.kind === exports.StructureKind.ExportSpecifier;
    },
    isImportDeclaration(structure) {
        return structure.kind === exports.StructureKind.ImportDeclaration;
    },
    isImportSpecifier(structure) {
        return structure.kind === exports.StructureKind.ImportSpecifier;
    },
    isModule(structure) {
        return structure.kind === exports.StructureKind.Module;
    },
    isModuleNamed(structure) {
        return structure.kind === exports.StructureKind.Module;
    },
    isSourceFile(structure) {
        return structure.kind === exports.StructureKind.SourceFile;
    },
    isVariableDeclaration(structure) {
        return structure.kind === exports.StructureKind.VariableDeclaration;
    },
    isVariableStatement(structure) {
        return structure.kind === exports.StructureKind.VariableStatement;
    },
    isTypeAlias(structure) {
        return structure.kind === exports.StructureKind.TypeAlias;
    },
    isTypeParameter(structure) {
        return structure.kind === exports.StructureKind.TypeParameter;
    },
    isPropertyAssignment(structure) {
        return structure.kind === exports.StructureKind.PropertyAssignment;
    },
    isShorthandPropertyAssignment(structure) {
        return structure.kind === exports.StructureKind.ShorthandPropertyAssignment;
    },
    isSpreadAssignment(structure) {
        return structure.kind === exports.StructureKind.SpreadAssignment;
    },
    isExpressioned(structure) {
        return structure.kind === exports.StructureKind.SpreadAssignment;
    }
};

function forEachStructureChild(structure, callback) {
    if (common.ArrayUtils.isReadonlyArray(structure)) {
        for (const item of structure) {
            const result = callback(item);
            if (result)
                return result;
        }
        return undefined;
    }
    switch (structure.kind) {
        case exports.StructureKind.Class:
            return forClassDeclaration(structure, callback);
        case exports.StructureKind.ClassStaticBlock:
            return forClassStaticBlockDeclaration(structure, callback);
        case exports.StructureKind.Constructor:
            return forConstructorDeclaration(structure, callback);
        case exports.StructureKind.ConstructorOverload:
            return forConstructorDeclarationOverload(structure, callback);
        case exports.StructureKind.GetAccessor:
            return forGetAccessorDeclaration(structure, callback);
        case exports.StructureKind.Method:
            return forMethodDeclaration(structure, callback);
        case exports.StructureKind.MethodOverload:
            return forMethodDeclarationOverload(structure, callback);
        case exports.StructureKind.Property:
            return forPropertyDeclaration(structure, callback);
        case exports.StructureKind.SetAccessor:
            return forSetAccessorDeclaration(structure, callback);
        case exports.StructureKind.JSDoc:
            return forJSDoc(structure, callback);
        case exports.StructureKind.Enum:
            return forEnumDeclaration(structure, callback);
        case exports.StructureKind.EnumMember:
            return forEnumMember(structure, callback);
        case exports.StructureKind.Function:
            return forFunctionDeclaration(structure, callback);
        case exports.StructureKind.FunctionOverload:
            return forFunctionDeclarationOverload(structure, callback);
        case exports.StructureKind.Parameter:
            return forParameterDeclaration(structure, callback);
        case exports.StructureKind.CallSignature:
            return forCallSignatureDeclaration(structure, callback);
        case exports.StructureKind.ConstructSignature:
            return forConstructSignatureDeclaration(structure, callback);
        case exports.StructureKind.IndexSignature:
            return forIndexSignatureDeclaration(structure, callback);
        case exports.StructureKind.Interface:
            return forInterfaceDeclaration(structure, callback);
        case exports.StructureKind.MethodSignature:
            return forMethodSignature(structure, callback);
        case exports.StructureKind.PropertySignature:
            return forPropertySignature(structure, callback);
        case exports.StructureKind.JsxElement:
            return forJsxElement(structure, callback);
        case exports.StructureKind.JsxSelfClosingElement:
            return forJsxSelfClosingElement(structure, callback);
        case exports.StructureKind.ExportDeclaration:
            return forExportDeclaration(structure, callback);
        case exports.StructureKind.ImportDeclaration:
            return forImportDeclaration(structure, callback);
        case exports.StructureKind.Module:
            return forModuleDeclaration(structure, callback);
        case exports.StructureKind.SourceFile:
            return forSourceFile(structure, callback);
        case exports.StructureKind.VariableStatement:
            return forVariableStatement(structure, callback);
        case exports.StructureKind.TypeAlias:
            return forTypeAliasDeclaration(structure, callback);
        default:
            return undefined;
    }
}
function forClassDeclaration(structure, callback) {
    return forClassLikeDeclarationBase(structure, callback);
}
function forClassLikeDeclarationBase(structure, callback) {
    return forDecoratableNode(structure, callback)
        || forTypeParameteredNode(structure, callback)
        || forJSDocableNode(structure, callback)
        || forAll(structure.ctors, callback, exports.StructureKind.Constructor)
        || forAll(structure.properties, callback, exports.StructureKind.Property)
        || forAll(structure.getAccessors, callback, exports.StructureKind.GetAccessor)
        || forAll(structure.setAccessors, callback, exports.StructureKind.SetAccessor)
        || forAll(structure.methods, callback, exports.StructureKind.Method);
}
function forDecoratableNode(structure, callback) {
    return forAll(structure.decorators, callback, exports.StructureKind.Decorator);
}
function forTypeParameteredNode(structure, callback) {
    return forAllIfStructure(structure.typeParameters, callback, exports.StructureKind.TypeParameter);
}
function forJSDocableNode(structure, callback) {
    return forAllIfStructure(structure.docs, callback, exports.StructureKind.JSDoc);
}
function forClassStaticBlockDeclaration(structure, callback) {
    return forFunctionLikeDeclaration(structure, callback);
}
function forFunctionLikeDeclaration(structure, callback) {
    return forSignaturedDeclaration(structure, callback)
        || forTypeParameteredNode(structure, callback)
        || forJSDocableNode(structure, callback)
        || forStatementedNode(structure, callback);
}
function forSignaturedDeclaration(structure, callback) {
    return forParameteredNode(structure, callback);
}
function forParameteredNode(structure, callback) {
    return forAll(structure.parameters, callback, exports.StructureKind.Parameter);
}
function forStatementedNode(structure, callback) {
    return forAllUnknownKindIfStructure(structure.statements, callback);
}
function forConstructorDeclaration(structure, callback) {
    return forFunctionLikeDeclaration(structure, callback)
        || forAll(structure.overloads, callback, exports.StructureKind.ConstructorOverload);
}
function forConstructorDeclarationOverload(structure, callback) {
    return forSignaturedDeclaration(structure, callback)
        || forTypeParameteredNode(structure, callback)
        || forJSDocableNode(structure, callback);
}
function forGetAccessorDeclaration(structure, callback) {
    return forDecoratableNode(structure, callback)
        || forFunctionLikeDeclaration(structure, callback);
}
function forMethodDeclaration(structure, callback) {
    return forDecoratableNode(structure, callback)
        || forFunctionLikeDeclaration(structure, callback)
        || forAll(structure.overloads, callback, exports.StructureKind.MethodOverload);
}
function forMethodDeclarationOverload(structure, callback) {
    return forSignaturedDeclaration(structure, callback)
        || forTypeParameteredNode(structure, callback)
        || forJSDocableNode(structure, callback);
}
function forPropertyDeclaration(structure, callback) {
    return forJSDocableNode(structure, callback)
        || forDecoratableNode(structure, callback);
}
function forSetAccessorDeclaration(structure, callback) {
    return forDecoratableNode(structure, callback)
        || forFunctionLikeDeclaration(structure, callback);
}
function forJSDoc(structure, callback) {
    return forAll(structure.tags, callback, exports.StructureKind.JSDocTag);
}
function forEnumDeclaration(structure, callback) {
    return forJSDocableNode(structure, callback)
        || forAll(structure.members, callback, exports.StructureKind.EnumMember);
}
function forEnumMember(structure, callback) {
    return forJSDocableNode(structure, callback);
}
function forFunctionDeclaration(structure, callback) {
    return forFunctionLikeDeclaration(structure, callback)
        || forAll(structure.overloads, callback, exports.StructureKind.FunctionOverload);
}
function forFunctionDeclarationOverload(structure, callback) {
    return forSignaturedDeclaration(structure, callback)
        || forTypeParameteredNode(structure, callback)
        || forJSDocableNode(structure, callback);
}
function forParameterDeclaration(structure, callback) {
    return forDecoratableNode(structure, callback);
}
function forCallSignatureDeclaration(structure, callback) {
    return forJSDocableNode(structure, callback)
        || forSignaturedDeclaration(structure, callback)
        || forTypeParameteredNode(structure, callback);
}
function forConstructSignatureDeclaration(structure, callback) {
    return forJSDocableNode(structure, callback)
        || forSignaturedDeclaration(structure, callback)
        || forTypeParameteredNode(structure, callback);
}
function forIndexSignatureDeclaration(structure, callback) {
    return forJSDocableNode(structure, callback);
}
function forInterfaceDeclaration(structure, callback) {
    return forTypeParameteredNode(structure, callback)
        || forJSDocableNode(structure, callback)
        || forTypeElementMemberedNode(structure, callback);
}
function forTypeElementMemberedNode(structure, callback) {
    return forAll(structure.callSignatures, callback, exports.StructureKind.CallSignature)
        || forAll(structure.constructSignatures, callback, exports.StructureKind.ConstructSignature)
        || forAll(structure.indexSignatures, callback, exports.StructureKind.IndexSignature)
        || forAll(structure.methods, callback, exports.StructureKind.MethodSignature)
        || forAll(structure.properties, callback, exports.StructureKind.PropertySignature);
}
function forMethodSignature(structure, callback) {
    return forJSDocableNode(structure, callback)
        || forSignaturedDeclaration(structure, callback)
        || forTypeParameteredNode(structure, callback);
}
function forPropertySignature(structure, callback) {
    return forJSDocableNode(structure, callback);
}
function forJsxElement(structure, callback) {
    return forAllUnknownKindIfStructure(structure.attributes, callback)
        || forAllUnknownKindIfStructure(structure.children, callback);
}
function forJsxSelfClosingElement(structure, callback) {
    return forJsxAttributedNode(structure, callback);
}
function forJsxAttributedNode(structure, callback) {
    return forAllUnknownKindIfStructure(structure.attributes, callback);
}
function forExportDeclaration(structure, callback) {
    return forAllIfStructure(structure.namedExports, callback, exports.StructureKind.ExportSpecifier);
}
function forImportDeclaration(structure, callback) {
    return forAllIfStructure(structure.namedImports, callback, exports.StructureKind.ImportSpecifier);
}
function forModuleDeclaration(structure, callback) {
    return forJSDocableNode(structure, callback)
        || forStatementedNode(structure, callback);
}
function forSourceFile(structure, callback) {
    return forStatementedNode(structure, callback);
}
function forVariableStatement(structure, callback) {
    return forJSDocableNode(structure, callback)
        || forAll(structure.declarations, callback, exports.StructureKind.VariableDeclaration);
}
function forTypeAliasDeclaration(structure, callback) {
    return forTypeParameteredNode(structure, callback)
        || forJSDocableNode(structure, callback);
}
function forAll(structures, callback, kind) {
    if (structures == null)
        return;
    for (const structure of structures) {
        const result = callback(ensureKind(structure, kind));
        if (result)
            return result;
    }
    return undefined;
}
function forAllIfStructure(values, callback, kind) {
    if (values == null || !(values instanceof Array))
        return;
    for (const value of values) {
        if (isStructure(value)) {
            const result = callback(ensureKind(value, kind));
            if (result)
                return result;
        }
    }
    return undefined;
}
function forAllUnknownKindIfStructure(values, callback) {
    if (values == null || !(values instanceof Array))
        return;
    for (const value of values) {
        if (isStructure(value)) {
            const result = callback(value);
            if (result)
                return result;
        }
    }
    return undefined;
}
function ensureKind(structure, kind) {
    if (structure.kind == null)
        structure.kind = kind;
    return structure;
}
function isStructure(value) {
    return value != null && typeof value.kind === "number";
}

function isLastNonWhitespaceCharCloseBrace(writer) {
    return writer.iterateLastCharCodes(charCode => {
        if (charCode === CharCodes.CLOSE_BRACE)
            return true;
        else if (common.StringUtils.isWhitespaceCharCode(charCode))
            return undefined;
        else
            return false;
    }) || false;
}

class ClassMemberStructurePrinter extends Printer {
    constructor(factory, options) {
        super();
        this.factory = factory;
        this.options = options;
    }
    printTexts(writer, members) {
        if (members == null)
            return;
        if (typeof members === "string" || members instanceof Function)
            this.printText(writer, members);
        else {
            for (const member of members) {
                if (isLastNonWhitespaceCharCloseBrace(writer))
                    writer.blankLineIfLastNot();
                else if (!writer.isAtStartOfFirstLineOfBlock())
                    writer.newLineIfLastNot();
                this.printText(writer, member);
            }
        }
    }
    printText(writer, member) {
        if (typeof member === "string" || member instanceof Function || member == null) {
            this.printTextOrWriterFunc(writer, member);
            return;
        }
        switch (member.kind) {
            case exports.StructureKind.Method:
                if (!this.options.isAmbient)
                    ensureBlankLine();
                this.factory.forMethodDeclaration(this.options).printText(writer, member);
                break;
            case exports.StructureKind.Property:
                this.factory.forPropertyDeclaration().printText(writer, member);
                break;
            case exports.StructureKind.GetAccessor:
                if (!this.options.isAmbient)
                    ensureBlankLine();
                this.factory.forGetAccessorDeclaration(this.options).printText(writer, member);
                break;
            case exports.StructureKind.SetAccessor:
                if (!this.options.isAmbient)
                    ensureBlankLine();
                this.factory.forSetAccessorDeclaration(this.options).printText(writer, member);
                break;
            case exports.StructureKind.Constructor:
                if (!this.options.isAmbient)
                    ensureBlankLine();
                this.factory.forConstructorDeclaration(this.options).printText(writer, member);
                break;
            case exports.StructureKind.ClassStaticBlock:
                ensureBlankLine();
                this.factory.forClassStaticBlockDeclaration().printText(writer, member);
                break;
            default:
                common.errors.throwNotImplementedForNeverValueError(member);
        }
        function ensureBlankLine() {
            if (!writer.isAtStartOfFirstLineOfBlock())
                writer.blankLineIfLastNot();
        }
    }
}

class ClassStaticBlockDeclarationStructurePrinter extends NodePrinter {
    constructor(factory) {
        super(factory);
    }
    printTexts(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            if (i > 0)
                writer.blankLine();
            this.printText(writer, structures[i]);
        }
    }
    printTextInternal(writer, structure) {
        writer.write("static");
        writer.space().inlineBlock(() => {
            this.factory.forStatementedNode({ isAmbient: false }).printText(writer, structure);
        });
    }
}

class ConstructorDeclarationStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
    }
    printTexts(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            if (i > 0) {
                if (this.options.isAmbient)
                    writer.newLine();
                else
                    writer.blankLine();
            }
            this.printText(writer, structures[i]);
        }
    }
    printTextInternal(writer, structure) {
        this.printOverloads(writer, getOverloadStructures());
        this.printHeader(writer, structure);
        if (this.options.isAmbient)
            writer.write(";");
        else {
            writer.space().inlineBlock(() => {
                this.factory.forStatementedNode(this.options).printText(writer, structure);
            });
        }
        function getOverloadStructures() {
            const overloads = common.ObjectUtils.clone(structure.overloads);
            if (overloads == null || overloads.length === 0)
                return;
            for (const overload of overloads)
                setValueIfUndefined(overload, "scope", structure.scope);
            return overloads;
        }
    }
    printOverloads(writer, structures) {
        if (structures == null || structures.length === 0)
            return;
        for (const structure of structures) {
            this.printOverload(writer, structure);
            writer.newLine();
        }
    }
    printOverload(writer, structure) {
        this.printHeader(writer, structure);
        writer.write(";");
    }
    printHeader(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write("constructor");
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
    }
}

class GetAccessorDeclarationStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
        this.blankLineWriter = new BlankLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.blankLineWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forDecorator().printTexts(writer, structure.decorators);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(`get ${structure.name}`);
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
        this.factory.forReturnTypedNode().printText(writer, structure);
        if (this.options.isAmbient || structure.isAbstract)
            writer.write(";");
        else {
            writer.spaceIfLastNot().inlineBlock(() => {
                this.factory.forStatementedNode(this.options).printText(writer, structure);
            });
        }
    }
}

class MethodDeclarationStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
    }
    printTexts(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            if (i > 0) {
                if (this.options.isAmbient)
                    writer.newLine();
                else
                    writer.blankLine();
            }
            this.printText(writer, structures[i]);
        }
    }
    printTextInternal(writer, structure) {
        this.printOverloads(writer, structure.name, getOverloadStructures());
        this.printHeader(writer, structure.name, structure);
        if (this.options.isAmbient || structure.isAbstract)
            writer.write(";");
        else {
            writer.spaceIfLastNot().inlineBlock(() => {
                this.factory.forStatementedNode(this.options).printText(writer, structure);
            });
        }
        function getOverloadStructures() {
            const overloads = common.ObjectUtils.clone(structure.overloads);
            if (overloads == null || overloads.length === 0)
                return;
            for (const overload of overloads) {
                setValueIfUndefined(overload, "scope", structure.scope);
                setValueIfUndefined(overload, "isStatic", structure.isStatic);
                setValueIfUndefined(overload, "isAbstract", structure.isAbstract);
                setValueIfUndefined(overload, "hasQuestionToken", structure.hasQuestionToken);
            }
            return overloads;
        }
    }
    printOverloads(writer, name, structures) {
        if (structures == null || structures.length === 0)
            return;
        for (const structure of structures) {
            this.printOverload(writer, name, structure);
            writer.newLine();
        }
    }
    printOverload(writer, name, structure) {
        this.printHeader(writer, name, structure);
        writer.write(";");
    }
    printHeader(writer, name, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        if (structure.decorators != null)
            this.factory.forDecorator().printTexts(writer, structure.decorators);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(name);
        writer.conditionalWrite(structure.hasQuestionToken, "?");
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
        this.factory.forReturnTypedNode().printText(writer, structure);
    }
}

class PropertyDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forDecorator().printTexts(writer, structure.decorators);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(structure.name);
        writer.conditionalWrite(structure.hasQuestionToken, "?");
        writer.conditionalWrite(structure.hasExclamationToken && !structure.hasQuestionToken, "!");
        this.factory.forTypedNode(":").printText(writer, structure);
        this.factory.forInitializerExpressionableNode().printText(writer, structure);
        writer.write(";");
    }
}

class SetAccessorDeclarationStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
        this.multipleWriter = new BlankLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forDecorator().printTexts(writer, structure.decorators);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(`set ${structure.name}`);
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
        this.factory.forReturnTypedNode().printText(writer, structure);
        if (this.options.isAmbient || structure.isAbstract)
            writer.write(";");
        else {
            writer.spaceIfLastNot().inlineBlock(() => {
                this.factory.forStatementedNode(this.options).printText(writer, structure);
            });
        }
    }
}

class StringStructurePrinter extends Printer {
    printText(writer, textOrWriterFunc) {
        if (typeof textOrWriterFunc === "string")
            writer.write(textOrWriterFunc);
        else
            textOrWriterFunc(writer);
    }
}

class DecoratorStructurePrinter extends NodePrinter {
    printTexts(writer, structures) {
        this.printMultiple(writer, structures, () => writer.newLine());
    }
    printTextsInline(writer, structures) {
        this.printMultiple(writer, structures, () => writer.space());
    }
    printTextInternal(writer, structure) {
        writer.write(`@${structure.name}`);
        this.printArguments(writer, structure);
    }
    printArguments(writer, structure) {
        if (structure.arguments == null)
            return;
        writer.write("(");
        const args = structure.arguments instanceof Array ? structure.arguments : [structure.arguments];
        for (let i = 0; i < args.length; i++) {
            writer.conditionalWrite(i > 0, ", ");
            writer.write(this.getTextWithQueuedChildIndentation(writer, args[i]));
        }
        writer.write(")");
    }
    printMultiple(writer, structures, separator) {
        if (structures == null || structures.length === 0)
            return;
        for (const structure of structures) {
            this.printText(writer, structure);
            separator();
        }
    }
}

class JSDocStructurePrinter extends NodePrinter {
    printDocs(writer, structures) {
        if (structures == null)
            return;
        for (const structure of structures) {
            this.printText(writer, structure);
            writer.newLine();
        }
    }
    printTextInternal(writer, structure) {
        const text = getText(this);
        const lines = text.split(/\r?\n/);
        const startsWithNewLine = lines[0].length === 0;
        const isSingleLine = lines.length <= 1;
        const startIndex = startsWithNewLine ? 1 : 0;
        writer.write("/**");
        if (isSingleLine)
            writer.space();
        else
            writer.newLine();
        if (isSingleLine)
            writer.write(lines[startIndex]);
        else {
            for (let i = startIndex; i < lines.length; i++) {
                writer.write(` *`);
                if (lines[i].length > 0)
                    writer.write(` ${lines[i]}`);
                writer.newLine();
            }
        }
        writer.spaceIfLastNot();
        writer.write("*/");
        function getText(jsdocPrinter) {
            if (typeof structure === "string")
                return structure;
            const tempWriter = jsdocPrinter.getNewWriter(writer);
            if (typeof structure === "function")
                structure(tempWriter);
            else {
                if (structure.description)
                    printTextFromStringOrWriter(tempWriter, structure.description);
                if (structure.tags && structure.tags.length > 0) {
                    if (tempWriter.getLength() > 0)
                        tempWriter.newLine();
                    jsdocPrinter.factory.forJSDocTag({ printStarsOnNewLine: false }).printTexts(tempWriter, structure.tags);
                }
            }
            return tempWriter.toString();
        }
    }
}

class JSDocTagStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
    }
    printTexts(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            if (i > 0) {
                writer.newLine();
                writer.conditionalWrite(this.options.printStarsOnNewLine, " * ");
            }
            this.printText(writer, structures[i]);
        }
    }
    printTextInternal(writer, structure) {
        const text = getText(this);
        const lines = text.split(/\r?\n/);
        for (let i = 0; i < lines.length; i++) {
            if (i > 0) {
                writer.newLine();
                if (this.options.printStarsOnNewLine)
                    writer.write(` *`);
            }
            if (lines[i].length > 0) {
                if (this.options.printStarsOnNewLine && i > 0)
                    writer.space();
                writer.write(lines[i]);
            }
        }
        function getText(tagPrinter) {
            if (typeof structure === "string")
                return structure;
            const tempWriter = tagPrinter.getNewWriter(writer);
            if (typeof structure === "function")
                structure(tempWriter);
            else {
                if (structure.text)
                    printTextFromStringOrWriter(tempWriter, structure.text);
                const currentText = tempWriter.toString();
                tempWriter.unsafeInsert(0, `@${structure.tagName}` + (currentText.length > 0 && !common.StringUtils.startsWithNewLine(currentText) ? " " : ""));
            }
            return tempWriter.toString();
        }
    }
}

class EnumDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new BlankLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.conditionalWrite(structure.isConst, "const ");
        writer.write(`enum ${structure.name} `).inlineBlock(() => {
            this.factory.forEnumMember().printTexts(writer, structure.members);
        });
    }
}

class EnumMemberStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new CommaNewLineSeparatedStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        if (structure instanceof Function) {
            structure(writer);
            return;
        }
        else if (typeof structure === "string") {
            writer.write(structure);
            return;
        }
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        if (isValidVariableName(structure.name) || common.StringUtils.isQuoted(structure.name))
            writer.write(structure.name);
        else
            writer.quote(structure.name);
        if (typeof structure.value === "string") {
            const { value } = structure;
            writer.hangingIndent(() => writer.write(` = `).quote(value));
        }
        else if (typeof structure.value === "number")
            writer.write(` = ${structure.value}`);
        else
            this.factory.forInitializerExpressionableNode().printText(writer, structure);
    }
}

class ObjectLiteralExpressionPropertyStructurePrinter extends Printer {
    constructor(factory) {
        super();
        this.factory = factory;
        this.multipleWriter = new CommaNewLineSeparatedStructuresPrinter(this);
        this.options = { isAmbient: false };
    }
    printTexts(writer, members) {
        this.multipleWriter.printText(writer, members);
    }
    printText(writer, member) {
        if (typeof member === "string" || member instanceof Function || member == null) {
            this.printTextOrWriterFunc(writer, member);
            return;
        }
        switch (member.kind) {
            case exports.StructureKind.PropertyAssignment:
                this.factory.forPropertyAssignment().printText(writer, member);
                break;
            case exports.StructureKind.ShorthandPropertyAssignment:
                this.factory.forShorthandPropertyAssignment().printText(writer, member);
                break;
            case exports.StructureKind.SpreadAssignment:
                this.factory.forSpreadAssignment().printText(writer, member);
                break;
            case exports.StructureKind.Method:
                this.factory.forMethodDeclaration(this.options).printText(writer, member);
                break;
            case exports.StructureKind.GetAccessor:
                this.factory.forGetAccessorDeclaration(this.options).printText(writer, member);
                break;
            case exports.StructureKind.SetAccessor:
                this.factory.forSetAccessorDeclaration(this.options).printText(writer, member);
                break;
            default:
                common.errors.throwNotImplementedForNeverValueError(member);
        }
    }
}

class PropertyAssignmentStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        writer.hangingIndent(() => {
            writer.write(`${structure.name}: `);
            printTextFromStringOrWriter(writer, structure.initializer);
        });
    }
}

class ShorthandPropertyAssignmentStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        writer.write(`${structure.name}`);
    }
}

class SpreadAssignmentStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        writer.hangingIndent(() => {
            writer.write("...");
            printTextFromStringOrWriter(writer, structure.expression);
        });
    }
}

class FunctionDeclarationStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
    }
    printTexts(writer, structures) {
        if (structures == null)
            return;
        for (let i = 0; i < structures.length; i++) {
            const currentStructure = structures[i];
            if (i > 0) {
                const previousStructure = structures[i - 1];
                if (this.options.isAmbient || previousStructure.hasDeclareKeyword && currentStructure.hasDeclareKeyword)
                    writer.newLine();
                else
                    writer.blankLine();
            }
            this.printText(writer, currentStructure);
        }
    }
    printTextInternal(writer, structure) {
        this.printOverloads(writer, structure.name, getOverloadStructures());
        this.printHeader(writer, structure.name, structure);
        if (this.options.isAmbient || structure.hasDeclareKeyword)
            writer.write(";");
        else {
            writer.space().inlineBlock(() => {
                this.factory.forStatementedNode({ isAmbient: false }).printText(writer, structure);
            });
        }
        function getOverloadStructures() {
            const overloads = common.ObjectUtils.clone(structure.overloads);
            if (overloads == null || overloads.length === 0)
                return;
            for (const overload of overloads) {
                setValueIfUndefined(overload, "hasDeclareKeyword", structure.hasDeclareKeyword);
                setValueIfUndefined(overload, "isExported", structure.isExported);
                setValueIfUndefined(overload, "isDefaultExport", structure.isDefaultExport);
            }
            return overloads;
        }
    }
    printOverloads(writer, name, structures) {
        if (structures == null || structures.length === 0)
            return;
        for (const structure of structures) {
            this.printOverload(writer, name, structure);
            writer.newLine();
        }
    }
    printOverload(writer, name, structure) {
        this.printHeader(writer, name, structure);
        writer.write(";");
    }
    printHeader(writer, name, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(`function`);
        writer.conditionalWrite(structure.isGenerator, "*");
        if (!common.StringUtils.isNullOrWhitespace(name))
            writer.write(` ${name}`);
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
        this.factory.forReturnTypedNode().printText(writer, structure);
    }
}

class ParameterDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new CommaSeparatedStructuresPrinter(this);
    }
    printTextsWithParenthesis(writer, structures) {
        writer.write("(");
        if (structures != null)
            this.factory.forParameterDeclaration().printTexts(writer, structures);
        writer.write(`)`);
    }
    printTexts(writer, structures) {
        if (structures == null || structures.length === 0)
            return;
        writer.hangingIndent(() => {
            this.multipleWriter.printText(writer, structures);
        });
    }
    printTextInternal(writer, structure) {
        if (structure.name == null) {
            throw new common.errors
                .NotImplementedError("Not implemented scenario where parameter declaration structure doesn't have a name. Please open an issue if you need this.");
        }
        this.factory.forDecorator().printTextsInline(writer, structure.decorators);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.conditionalWrite(structure.isRestParameter, "...");
        writer.write(structure.name);
        writer.conditionalWrite(structure.hasQuestionToken, "?");
        this.factory.forTypedNode(":", structure.hasQuestionToken).printText(writer, structure);
        this.factory.forInitializerExpressionableNode().printText(writer, structure);
    }
}

class CallSignatureDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
        this.factory.forReturnTypedNode(true).printText(writer, structure);
        writer.write(";");
    }
}

class ConstructSignatureDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        writer.write("new");
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
        this.factory.forReturnTypedNode().printText(writer, structure);
        writer.write(";");
    }
}

class IndexSignatureDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(`[${structure.keyName || "key"}: ${structure.keyType || "string"}]`);
        this.factory.forReturnTypedNode().printText(writer, structure);
        writer.write(";");
    }
}

class InterfaceDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new BlankLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(`interface ${structure.name}`);
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        writer.space();
        if (structure.extends != null) {
            const extendsText = structure.extends instanceof Array
                ? structure.extends.map(i => this.getText(writer, i)).join(", ")
                : this.getText(writer, structure.extends);
            if (!common.StringUtils.isNullOrWhitespace(extendsText))
                writer.hangingIndent(() => writer.write(`extends ${extendsText} `));
        }
        writer.inlineBlock(() => {
            this.factory.forTypeElementMemberedNode().printText(writer, structure);
        });
    }
}

class MethodSignatureStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        writer.write(structure.name);
        writer.conditionalWrite(structure.hasQuestionToken, "?");
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forParameterDeclaration().printTextsWithParenthesis(writer, structure.parameters);
        this.factory.forReturnTypedNode().printText(writer, structure);
        writer.write(";");
    }
}

class PropertySignatureStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(structure.name);
        writer.conditionalWrite(structure.hasQuestionToken, "?");
        this.factory.forTypedNode(":").printText(writer, structure);
        this.factory.forInitializerExpressionableNode().printText(writer, structure);
        writer.write(";");
    }
}

class TypeElementMemberedNodeStructurePrinter extends Printer {
    constructor(factory) {
        super();
        this.factory = factory;
    }
    printText(writer, structure) {
        this.factory.forCallSignatureDeclaration().printTexts(writer, structure.callSignatures);
        this.conditionalSeparator(writer, structure.constructSignatures);
        this.factory.forConstructSignatureDeclaration().printTexts(writer, structure.constructSignatures);
        this.conditionalSeparator(writer, structure.indexSignatures);
        this.factory.forIndexSignatureDeclaration().printTexts(writer, structure.indexSignatures);
        this.conditionalSeparator(writer, structure.properties);
        this.factory.forPropertySignature().printTexts(writer, structure.properties);
        this.conditionalSeparator(writer, structure.methods);
        this.factory.forMethodSignature().printTexts(writer, structure.methods);
    }
    conditionalSeparator(writer, structures) {
        if (!common.ArrayUtils.isNullOrEmpty(structures) && !writer.isAtStartOfFirstLineOfBlock())
            writer.newLine();
    }
}

class TypeElementMemberStructurePrinter extends Printer {
    constructor(factory) {
        super();
        this.factory = factory;
    }
    printTexts(writer, members) {
        if (members == null)
            return;
        if (typeof members === "string" || members instanceof Function)
            this.printText(writer, members);
        else {
            for (const member of members) {
                if (isLastNonWhitespaceCharCloseBrace(writer))
                    writer.blankLineIfLastNot();
                else if (!writer.isAtStartOfFirstLineOfBlock())
                    writer.newLineIfLastNot();
                this.printText(writer, member);
            }
        }
    }
    printText(writer, members) {
        if (typeof members === "string" || members instanceof Function || members == null) {
            this.printTextOrWriterFunc(writer, members);
            return;
        }
        switch (members.kind) {
            case exports.StructureKind.PropertySignature:
                this.factory.forPropertySignature().printText(writer, members);
                break;
            case exports.StructureKind.MethodSignature:
                this.factory.forMethodSignature().printText(writer, members);
                break;
            case exports.StructureKind.CallSignature:
                this.factory.forCallSignatureDeclaration().printText(writer, members);
                break;
            case exports.StructureKind.IndexSignature:
                this.factory.forIndexSignatureDeclaration().printText(writer, members);
                break;
            case exports.StructureKind.ConstructSignature:
                this.factory.forConstructSignatureDeclaration().printText(writer, members);
                break;
            default:
                common.errors.throwNotImplementedForNeverValueError(members);
        }
    }
}

class JsxAttributeDeciderStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        if (isJsxAttribute())
            this.factory.forJsxAttribute().printText(writer, structure);
        else if (structure.kind === exports.StructureKind.JsxSpreadAttribute)
            this.factory.forJsxSpreadAttribute().printText(writer, structure);
        else
            throw common.errors.throwNotImplementedForNeverValueError(structure);
        function isJsxAttribute(struct) {
            return structure.kind == null || structure.kind === exports.StructureKind.JsxAttribute;
        }
    }
}

class JsxAttributeStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        writer.write(structure.name);
        if (structure.initializer != null)
            writer.write("=").write(structure.initializer);
    }
}

class JsxChildDeciderStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        if (isJsxElement(structure))
            this.factory.forJsxElement().printText(writer, structure);
        else if (structure.kind === exports.StructureKind.JsxSelfClosingElement)
            this.factory.forJsxSelfClosingElement().printText(writer, structure);
        else
            common.errors.throwNotImplementedForNeverValueError(structure);
        function isJsxElement(struct) {
            return struct.kind == null || struct.kind === exports.StructureKind.JsxElement;
        }
    }
}

class JsxElementStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        writer.hangingIndent(() => {
            writer.write(`<${structure.name}`);
            if (structure.attributes)
                this.printAttributes(writer, structure.attributes);
            writer.write(">");
        });
        this.printChildren(writer, structure.children);
        writer.write(`</${structure.name}>`);
    }
    printAttributes(writer, attributes) {
        const attributePrinter = this.factory.forJsxAttributeDecider();
        for (const attrib of attributes) {
            writer.space();
            attributePrinter.printText(writer, attrib);
        }
    }
    printChildren(writer, children) {
        if (children == null)
            return;
        writer.newLine();
        writer.indent(() => {
            for (const child of children) {
                this.factory.forJsxChildDecider().printText(writer, child);
                writer.newLine();
            }
        });
    }
}

class JsxSelfClosingElementStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        writer.hangingIndent(() => {
            writer.write(`<${structure.name}`);
            if (structure.attributes)
                this.printAttributes(writer, structure.attributes);
            writer.write(" />");
        });
    }
    printAttributes(writer, attributes) {
        const attributePrinter = this.factory.forJsxAttributeDecider();
        for (const attrib of attributes) {
            writer.space();
            attributePrinter.printText(writer, attrib);
        }
    }
}

class JsxSpreadAttributeStructurePrinter extends NodePrinter {
    printTextInternal(writer, structure) {
        writer.hangingIndent(() => {
            writer.write("...");
            writer.write(structure.expression);
        });
    }
}

class ExportAssignmentStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        writer.write("export");
        if (structure.isExportEquals !== false)
            writer.write(" = ");
        else
            writer.write(" default ");
        writer.write(this.getTextWithQueuedChildIndentation(writer, structure.expression)).write(";");
    }
}

class ExportDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        const hasModuleSpecifier = structure.moduleSpecifier != null && structure.moduleSpecifier.length > 0;
        const hasNamedImport = structure.namedExports != null && structure.namedExports.length > 0;
        if (hasNamedImport && structure.namespaceExport != null)
            throw new common.errors.InvalidOperationError("An export declaration cannot have both a namespace export and a named export.");
        writer.write("export");
        if (structure.isTypeOnly)
            writer.write(" type");
        if (structure.namedExports != null && structure.namedExports.length > 0) {
            writer.space();
            this.factory.forNamedImportExportSpecifier().printTextsWithBraces(writer, structure.namedExports);
        }
        else if (structure.namespaceExport != null) {
            writer.write(" *");
            if (!common.StringUtils.isNullOrWhitespace(structure.namespaceExport))
                writer.write(` as ${structure.namespaceExport}`);
        }
        else if (!hasModuleSpecifier) {
            writer.write(" {")
                .conditionalWrite(this.factory.getFormatCodeSettings().insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces, " ")
                .write("}");
        }
        else {
            writer.write(` *`);
        }
        if (hasModuleSpecifier) {
            writer.write(" from ");
            writer.quote(structure.moduleSpecifier);
        }
        writer.write(";");
    }
}

class ImportDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        const hasNamedImport = structure.namedImports != null && structure.namedImports.length > 0;
        if (hasNamedImport && structure.namespaceImport != null)
            throw new common.errors.InvalidOperationError("An import declaration cannot have both a namespace import and a named import.");
        writer.write("import");
        if (structure.isTypeOnly)
            writer.write(" type");
        if (structure.defaultImport != null) {
            writer.write(` ${structure.defaultImport}`);
            writer.conditionalWrite(hasNamedImport || structure.namespaceImport != null, ",");
        }
        if (structure.namespaceImport != null)
            writer.write(` * as ${structure.namespaceImport}`);
        if (structure.namedImports != null && structure.namedImports.length > 0) {
            writer.space();
            this.factory.forNamedImportExportSpecifier().printTextsWithBraces(writer, structure.namedImports);
        }
        writer.conditionalWrite(structure.defaultImport != null || hasNamedImport || structure.namespaceImport != null, " from");
        writer.write(" ");
        writer.quote(structure.moduleSpecifier);
        writer.write(";");
    }
}

class ModuleDeclarationStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
        this.blankLineFormattingWriter = new BlankLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.blankLineFormattingWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        structure = this.validateAndGetStructure(structure);
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        if (structure.declarationKind == null || structure.declarationKind !== exports.ModuleDeclarationKind.Global)
            writer.write(`${structure.declarationKind || "namespace"} ${structure.name}`);
        else
            writer.write("global");
        if (structure.hasDeclareKeyword && common.StringUtils.isQuoted(structure.name.trim())
            && structure.hasOwnProperty("statements") && structure.statements == null) {
            writer.write(";");
        }
        else {
            writer.write(" ");
            writer.inlineBlock(() => {
                this.factory.forStatementedNode({
                    isAmbient: structure.hasDeclareKeyword || this.options.isAmbient,
                }).printText(writer, structure);
            });
        }
    }
    validateAndGetStructure(structure) {
        if (common.StringUtils.isQuoted(structure.name.trim())) {
            if (structure.declarationKind === exports.ModuleDeclarationKind.Namespace) {
                throw new common.errors.InvalidOperationError(`Cannot print a namespace with quotes for namespace with name ${structure.name}. `
                    + `Use ${"ModuleDeclarationKind.Module"} instead.`);
            }
            structure = common.ObjectUtils.clone(structure);
            setValueIfUndefined(structure, "hasDeclareKeyword", true);
            setValueIfUndefined(structure, "declarationKind", exports.ModuleDeclarationKind.Module);
        }
        return structure;
    }
}

class NamedImportExportSpecifierStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new CommaSeparatedStructuresPrinter(this);
    }
    printTextsWithBraces(writer, structures) {
        const formatSettings = this.factory.getFormatCodeSettings();
        writer.write("{");
        const specifierWriter = this.getNewWriter(writer);
        this.printTexts(specifierWriter, structures);
        const specifierText = specifierWriter.toString();
        if (formatSettings.insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces && !common.StringUtils.startsWithNewLine(specifierText))
            writer.space();
        writer.write(specifierText);
        if (formatSettings.insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces && !common.StringUtils.endsWithNewLine(specifierText))
            writer.space();
        writer.write("}");
    }
    printTexts(writer, structures) {
        if (structures instanceof Function)
            this.printText(writer, structures);
        else
            this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        const specifierWriter = this.getNewWriterWithQueuedChildIndentation(writer);
        if (typeof structure === "string")
            specifierWriter.write(structure);
        else if (structure instanceof Function)
            structure(specifierWriter);
        else {
            specifierWriter.write(structure.name);
            if (!common.StringUtils.isNullOrWhitespace(structure.alias)) {
                if (!specifierWriter.isLastNewLine())
                    specifierWriter.space();
                specifierWriter.write(`as ${structure.alias}`);
            }
        }
        writer.write(specifierWriter.toString());
    }
}

class SourceFileStructurePrinter extends NodePrinter {
    constructor(factory, options) {
        super(factory);
        this.options = options;
    }
    printTextInternal(writer, structure) {
        this.factory.forStatementedNode(this.options).printText(writer, structure);
        writer.conditionalNewLine(!writer.isAtStartOfFirstLineOfBlock() && !writer.isLastNewLine());
    }
}

class StatementedNodeStructurePrinter extends Printer {
    constructor(factory, options) {
        super();
        this.factory = factory;
        this.options = options;
    }
    printText(writer, structure) {
        this.factory.forStatement(this.options).printTexts(writer, structure.statements);
    }
}

class StatementStructurePrinter extends Printer {
    constructor(factory, options) {
        super();
        this.factory = factory;
        this.options = options;
    }
    printTexts(writer, statements) {
        if (statements == null)
            return;
        if (typeof statements === "string" || statements instanceof Function)
            this.printText(writer, statements);
        else {
            for (const statement of statements) {
                if (isLastNonWhitespaceCharCloseBrace(writer))
                    writer.blankLineIfLastNot();
                else if (!writer.isAtStartOfFirstLineOfBlock())
                    writer.newLineIfLastNot();
                this.printText(writer, statement);
            }
        }
    }
    printText(writer, statement) {
        if (typeof statement === "string" || statement instanceof Function || statement == null) {
            this.printTextOrWriterFunc(writer, statement);
            return;
        }
        switch (statement.kind) {
            case exports.StructureKind.Function:
                if (!this.options.isAmbient)
                    ensureBlankLine();
                this.factory.forFunctionDeclaration(this.options).printText(writer, statement);
                break;
            case exports.StructureKind.Class:
                ensureBlankLine();
                this.factory.forClassDeclaration(this.options).printText(writer, statement);
                break;
            case exports.StructureKind.Interface:
                ensureBlankLine();
                this.factory.forInterfaceDeclaration().printText(writer, statement);
                break;
            case exports.StructureKind.TypeAlias:
                this.factory.forTypeAliasDeclaration().printText(writer, statement);
                break;
            case exports.StructureKind.VariableStatement:
                this.factory.forVariableStatement().printText(writer, statement);
                break;
            case exports.StructureKind.ImportDeclaration:
                this.factory.forImportDeclaration().printText(writer, statement);
                break;
            case exports.StructureKind.Module:
                ensureBlankLine();
                this.factory.forModuleDeclaration(this.options).printText(writer, statement);
                break;
            case exports.StructureKind.Enum:
                ensureBlankLine();
                this.factory.forEnumDeclaration().printText(writer, statement);
                break;
            case exports.StructureKind.ExportDeclaration:
                this.factory.forExportDeclaration().printText(writer, statement);
                break;
            case exports.StructureKind.ExportAssignment:
                this.factory.forExportAssignment().printText(writer, statement);
                break;
            default:
                common.errors.throwNotImplementedForNeverValueError(statement);
        }
        function ensureBlankLine() {
            if (!writer.isAtStartOfFirstLineOfBlock())
                writer.blankLineIfLastNot();
        }
    }
}

exports.VariableDeclarationKind = void 0;
(function (VariableDeclarationKind) {
    VariableDeclarationKind["Var"] = "var";
    VariableDeclarationKind["Let"] = "let";
    VariableDeclarationKind["Const"] = "const";
})(exports.VariableDeclarationKind || (exports.VariableDeclarationKind = {}));

class VariableStatementStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        writer.hangingIndent(() => {
            this.factory.forModifierableNode().printText(writer, structure);
            writer.write(`${structure.declarationKind || exports.VariableDeclarationKind.Let} `);
            this.factory.forVariableDeclaration().printTexts(writer, structure.declarations);
            writer.write(";");
        });
    }
}

class TypeAliasDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new NewLineFormattingStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        this.factory.forJSDoc().printDocs(writer, structure.docs);
        this.factory.forModifierableNode().printText(writer, structure);
        writer.write(`type ${structure.name}`);
        this.factory.forTypeParameterDeclaration().printTextsWithBrackets(writer, structure.typeParameters);
        this.factory.forTypedNode(" =").printText(writer, structure);
        writer.write(";");
    }
}

class TypeParameterDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new CommaSeparatedStructuresPrinter(this);
    }
    printTextsWithBrackets(writer, structures) {
        if (structures == null || structures.length === 0)
            return;
        writer.write("<");
        this.printTexts(writer, structures);
        writer.write(">");
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        if (typeof structure === "string") {
            writer.write(structure);
            return;
        }
        writer.hangingIndent(() => {
            writer.write(structure.name);
            if (structure.constraint != null) {
                const constraintText = this.getText(writer, structure.constraint);
                if (!common.StringUtils.isNullOrWhitespace(constraintText))
                    writer.write(` extends ${constraintText}`);
            }
            if (structure.default != null) {
                const defaultText = this.getText(writer, structure.default);
                if (!common.StringUtils.isNullOrWhitespace(defaultText))
                    writer.write(` = ${defaultText}`);
            }
        });
    }
}

class VariableDeclarationStructurePrinter extends NodePrinter {
    constructor() {
        super(...arguments);
        this.multipleWriter = new CommaSeparatedStructuresPrinter(this);
    }
    printTexts(writer, structures) {
        this.multipleWriter.printText(writer, structures);
    }
    printTextInternal(writer, structure) {
        writer.write(structure.name);
        writer.conditionalWrite(structure.hasExclamationToken, "!");
        this.factory.forTypedNode(":").printText(writer, structure);
        this.factory.forInitializerExpressionableNode().printText(writer, structure);
    }
}

function ExtendsClauseableNode(Base) {
    return class extends Base {
        getExtends() {
            var _a;
            const extendsClause = this.getHeritageClauseByKind(common.SyntaxKind.ExtendsKeyword);
            return (_a = extendsClause === null || extendsClause === void 0 ? void 0 : extendsClause.getTypeNodes()) !== null && _a !== void 0 ? _a : [];
        }
        addExtends(text) {
            return this.insertExtends(this.getExtends().length, text);
        }
        insertExtends(index, texts) {
            const originalExtends = this.getExtends();
            const wasStringInput = typeof texts === "string";
            if (typeof texts === "string") {
                common.errors.throwIfWhitespaceOrNotString(texts, "texts");
                texts = [texts];
            }
            else if (texts.length === 0) {
                return [];
            }
            const writer = this._getWriterWithQueuedChildIndentation();
            const structurePrinter = new CommaSeparatedStructuresPrinter(new StringStructurePrinter());
            structurePrinter.printText(writer, texts);
            index = verifyAndGetIndex(index, originalExtends.length);
            if (originalExtends.length > 0) {
                const extendsClause = this.getHeritageClauseByKindOrThrow(common.SyntaxKind.ExtendsKeyword);
                insertIntoCommaSeparatedNodes({
                    parent: extendsClause.getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
                    currentNodes: originalExtends,
                    insertIndex: index,
                    newText: writer.toString(),
                    useTrailingCommas: false,
                });
            }
            else {
                const openBraceToken = this.getFirstChildByKindOrThrow(common.SyntaxKind.OpenBraceToken);
                const openBraceStart = openBraceToken.getStart();
                const isLastSpace = /\s/.test(this.getSourceFile().getFullText()[openBraceStart - 1]);
                let insertText = `extends ${writer.toString()} `;
                if (!isLastSpace)
                    insertText = " " + insertText;
                insertIntoParentTextRange({
                    parent: this,
                    insertPos: openBraceStart,
                    newText: insertText,
                });
            }
            const newExtends = this.getExtends();
            return wasStringInput ? newExtends[index] : getNodesToReturn(originalExtends, newExtends, index, false);
        }
        removeExtends(implementsNodeOrIndex) {
            const extendsClause = this.getHeritageClauseByKind(common.SyntaxKind.ExtendsKeyword);
            if (extendsClause == null)
                throw new common.errors.InvalidOperationError("Cannot remove an extends when none exist.");
            extendsClause.removeExpression(implementsNodeOrIndex);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.extends != null) {
                this.getExtends().forEach(e => this.removeExtends(e));
                this.addExtends(structure.extends);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                extends: this.getExtends().map(e => e.getText()),
            });
        }
    };
}

function GeneratorableNode(Base) {
    return class extends Base {
        isGenerator() {
            return this.compilerNode.asteriskToken != null;
        }
        getAsteriskToken() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.asteriskToken);
        }
        getAsteriskTokenOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getAsteriskToken(), "Expected to find an asterisk token.");
        }
        setIsGenerator(value) {
            const asteriskToken = this.getAsteriskToken();
            const isSet = asteriskToken != null;
            if (isSet === value)
                return this;
            if (asteriskToken == null) {
                insertIntoParentTextRange({
                    insertPos: getAsteriskInsertPos(this),
                    parent: this,
                    newText: "*",
                });
            }
            else {
                removeChildrenWithFormatting({
                    children: [asteriskToken],
                    getSiblingFormatting: () => FormattingKind.Space,
                });
            }
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.isGenerator != null)
                this.setIsGenerator(structure.isGenerator);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                isGenerator: this.isGenerator(),
            });
        }
    };
}
function getAsteriskInsertPos(node) {
    if (node.getKind() === common.SyntaxKind.FunctionDeclaration)
        return node.getFirstChildByKindOrThrow(common.SyntaxKind.FunctionKeyword).getEnd();
    const namedNode = node;
    if (namedNode.getName == null)
        throw new common.errors.NotImplementedError("Expected a name node for a non-function declaration.");
    return namedNode.getNameNode().getStart();
}

function HeritageClauseableNode(Base) {
    return class extends Base {
        getHeritageClauses() {
            var _a;
            const heritageClauses = this.compilerNode.heritageClauses;
            return (_a = heritageClauses === null || heritageClauses === void 0 ? void 0 : heritageClauses.map(c => this._getNodeFromCompilerNode(c))) !== null && _a !== void 0 ? _a : [];
        }
        getHeritageClauseByKindOrThrow(kind) {
            return common.errors.throwIfNullOrUndefined(this.getHeritageClauseByKind(kind), `Expected to have heritage clause of kind ${common.getSyntaxKindName(kind)}.`);
        }
        getHeritageClauseByKind(kind) {
            return this.getHeritageClauses().find(c => c.compilerNode.token === kind);
        }
    };
}

function ImplementsClauseableNode(Base) {
    return class extends Base {
        getImplements() {
            var _a;
            const implementsClause = this.getHeritageClauseByKind(common.SyntaxKind.ImplementsKeyword);
            return (_a = implementsClause === null || implementsClause === void 0 ? void 0 : implementsClause.getTypeNodes()) !== null && _a !== void 0 ? _a : [];
        }
        addImplements(text) {
            return this.insertImplements(this.getImplements().length, text);
        }
        insertImplements(index, texts) {
            const originalImplements = this.getImplements();
            const wasStringInput = typeof texts === "string";
            if (typeof texts === "string") {
                common.errors.throwIfWhitespaceOrNotString(texts, "texts");
                texts = [texts];
            }
            else if (texts.length === 0) {
                return [];
            }
            const writer = this._getWriterWithQueuedChildIndentation();
            const structurePrinter = new CommaSeparatedStructuresPrinter(new StringStructurePrinter());
            structurePrinter.printText(writer, texts);
            const heritageClauses = this.getHeritageClauses();
            index = verifyAndGetIndex(index, originalImplements.length);
            if (originalImplements.length > 0) {
                const implementsClause = this.getHeritageClauseByKindOrThrow(common.SyntaxKind.ImplementsKeyword);
                insertIntoCommaSeparatedNodes({
                    parent: implementsClause.getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
                    currentNodes: originalImplements,
                    insertIndex: index,
                    newText: writer.toString(),
                    useTrailingCommas: false,
                });
            }
            else {
                const openBraceToken = this.getFirstChildByKindOrThrow(common.SyntaxKind.OpenBraceToken);
                const openBraceStart = openBraceToken.getStart();
                const isLastSpace = /\s/.test(this.getSourceFile().getFullText()[openBraceStart - 1]);
                let insertText = `implements ${writer.toString()} `;
                if (!isLastSpace)
                    insertText = " " + insertText;
                insertIntoParentTextRange({
                    parent: heritageClauses.length === 0 ? this : heritageClauses[0].getParentSyntaxListOrThrow(),
                    insertPos: openBraceStart,
                    newText: insertText,
                });
            }
            const newImplements = this.getImplements();
            return wasStringInput ? newImplements[0] : getNodesToReturn(originalImplements, newImplements, index, false);
        }
        removeImplements(implementsNodeOrIndex) {
            const implementsClause = this.getHeritageClauseByKind(common.SyntaxKind.ImplementsKeyword);
            if (implementsClause == null)
                throw new common.errors.InvalidOperationError("Cannot remove an implements when none exist.");
            implementsClause.removeExpression(implementsNodeOrIndex);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.implements != null) {
                this.getImplements().forEach(expr => this.removeImplements(expr));
                this.addImplements(structure.implements);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                implements: this.getImplements().map(node => node.getText()),
            });
        }
    };
}

function InitializerExpressionGetableNode(Base) {
    return class extends Base {
        hasInitializer() {
            return this.compilerNode.initializer != null;
        }
        getInitializerIfKindOrThrow(kind) {
            return common.errors.throwIfNullOrUndefined(this.getInitializerIfKind(kind), `Expected to find an initializer of kind '${common.getSyntaxKindName(kind)}'.`);
        }
        getInitializerIfKind(kind) {
            const initializer = this.getInitializer();
            if (initializer != null && initializer.getKind() !== kind)
                return undefined;
            return initializer;
        }
        getInitializerOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getInitializer(), "Expected to find an initializer.");
        }
        getInitializer() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.initializer);
        }
    };
}

function InitializerExpressionableNode(Base) {
    return apply(InitializerExpressionGetableNode(Base));
}
function apply(Base) {
    return class extends Base {
        removeInitializer() {
            const initializer = this.getInitializer();
            if (initializer == null)
                return this;
            const previousSibling = initializer.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.EqualsToken);
            removeChildren({
                children: [previousSibling, initializer],
                removePrecedingSpaces: true,
            });
            return this;
        }
        setInitializer(textOrWriterFunction) {
            const text = getTextFromStringOrWriter(this._getWriterWithQueuedChildIndentation(), textOrWriterFunction);
            common.errors.throwIfWhitespaceOrNotString(text, "textOrWriterFunction");
            if (this.hasInitializer())
                this.removeInitializer();
            const semiColonToken = this.getLastChildIfKind(common.SyntaxKind.SemicolonToken);
            insertIntoParentTextRange({
                insertPos: semiColonToken != null ? semiColonToken.getPos() : this.getEnd(),
                parent: this,
                newText: ` = ${text}`,
            });
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.initializer != null)
                this.setInitializer(structure.initializer);
            else if (structure.hasOwnProperty("initializer"))
                this.removeInitializer();
            return this;
        }
        getStructure() {
            const initializer = this.getInitializer();
            return callBaseGetStructure(Base.prototype, this, {
                initializer: initializer ? initializer.getText() : undefined,
            });
        }
    };
}

function JSDocableNode(Base) {
    return class extends Base {
        getJsDocs() {
            var _a;
            const nodes = this.compilerNode.jsDoc;
            return (_a = nodes === null || nodes === void 0 ? void 0 : nodes.map(n => this._getNodeFromCompilerNode(n))) !== null && _a !== void 0 ? _a : [];
        }
        addJsDoc(structure) {
            return this.addJsDocs([structure])[0];
        }
        addJsDocs(structures) {
            return this.insertJsDocs(getEndIndexFromArray(this.compilerNode.jsDoc), structures);
        }
        insertJsDoc(index, structure) {
            return this.insertJsDocs(index, [structure])[0];
        }
        insertJsDocs(index, structures) {
            if (common.ArrayUtils.isNullOrEmpty(structures))
                return [];
            const writer = this._getWriterWithQueuedIndentation();
            const structurePrinter = this._context.structurePrinterFactory.forJSDoc();
            structurePrinter.printDocs(writer, structures);
            writer.write("");
            const code = writer.toString();
            const nodes = this.getJsDocs();
            index = verifyAndGetIndex(index, nodes.length);
            const insertPos = index === nodes.length ? this.getStart() : nodes[index].getStart();
            insertIntoParentTextRange({
                insertPos,
                parent: this,
                newText: code,
            });
            return getNodesToReturn(nodes, this.getJsDocs(), index, false);
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.docs != null) {
                this.getJsDocs().forEach(doc => doc.remove());
                this.addJsDocs(structure.docs);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                docs: this.getJsDocs().map(jsdoc => jsdoc.getStructure()),
            });
        }
    };
}

function LiteralLikeNode(Base) {
    return class extends Base {
        getLiteralText() {
            return this.compilerNode.text;
        }
        isTerminated() {
            return !(this.compilerNode.isUnterminated || false);
        }
        hasExtendedUnicodeEscape() {
            return this.compilerNode.hasExtendedUnicodeEscape || false;
        }
    };
}

function ModuledNode(Base) {
    return class extends Base {
        addImportDeclaration(structure) {
            return this.addImportDeclarations([structure])[0];
        }
        addImportDeclarations(structures) {
            const compilerChildren = this._getCompilerStatementsWithComments();
            return this.insertImportDeclarations(getInsertIndex(), structures);
            function getInsertIndex() {
                let insertIndex = 0;
                let wasLastComment = true;
                for (let i = 0; i < compilerChildren.length; i++) {
                    const child = compilerChildren[i];
                    if (wasLastComment && child.kind === common.SyntaxKind.MultiLineCommentTrivia)
                        insertIndex = i + 1;
                    else {
                        wasLastComment = false;
                        if (child.kind === common.SyntaxKind.ImportDeclaration)
                            insertIndex = i + 1;
                    }
                }
                return insertIndex;
            }
        }
        insertImportDeclaration(index, structure) {
            return this.insertImportDeclarations(index, [structure])[0];
        }
        insertImportDeclarations(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.ImportDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forImportDeclaration().printTexts(writer, structures);
                    }, {
                        previousNewLine: previousMember => Node.isImportDeclaration(previousMember) || isComment(previousMember.compilerNode),
                        nextNewLine: nextMember => Node.isImportDeclaration(nextMember),
                    });
                },
            });
        }
        getImportDeclaration(conditionOrModuleSpecifier) {
            return this.getImportDeclarations().find(getCondition());
            function getCondition() {
                if (typeof conditionOrModuleSpecifier === "string")
                    return (dec) => dec.getModuleSpecifierValue() === conditionOrModuleSpecifier;
                else
                    return conditionOrModuleSpecifier;
            }
        }
        getImportDeclarationOrThrow(conditionOrModuleSpecifier) {
            return common.errors.throwIfNullOrUndefined(this.getImportDeclaration(conditionOrModuleSpecifier), "Expected to find an import with the provided condition.");
        }
        getImportDeclarations() {
            return this.getStatements().filter(Node.isImportDeclaration);
        }
        addExportDeclaration(structure) {
            return this.addExportDeclarations([structure])[0];
        }
        addExportDeclarations(structures) {
            return this.insertExportDeclarations(this.getChildSyntaxListOrThrow().getChildCount(), structures);
        }
        insertExportDeclaration(index, structure) {
            return this.insertExportDeclarations(index, [structure])[0];
        }
        insertExportDeclarations(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.ExportDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forExportDeclaration().printTexts(writer, structures);
                    }, {
                        previousNewLine: previousMember => Node.isExportDeclaration(previousMember) || isComment(previousMember.compilerNode),
                        nextNewLine: nextMember => Node.isExportDeclaration(nextMember),
                    });
                },
            });
        }
        getExportDeclaration(conditionOrModuleSpecifier) {
            return this.getExportDeclarations().find(getCondition());
            function getCondition() {
                if (typeof conditionOrModuleSpecifier === "string")
                    return (dec) => dec.getModuleSpecifierValue() === conditionOrModuleSpecifier;
                else
                    return conditionOrModuleSpecifier;
            }
        }
        getExportDeclarationOrThrow(conditionOrModuleSpecifier) {
            return common.errors.throwIfNullOrUndefined(this.getExportDeclaration(conditionOrModuleSpecifier), "Expected to find an export declaration with the provided condition.");
        }
        getExportDeclarations() {
            return this.getStatements().filter(Node.isExportDeclaration);
        }
        addExportAssignment(structure) {
            return this.addExportAssignments([structure])[0];
        }
        addExportAssignments(structures) {
            return this.insertExportAssignments(this.getChildSyntaxListOrThrow().getChildCount(), structures);
        }
        insertExportAssignment(index, structure) {
            return this.insertExportAssignments(index, [structure])[0];
        }
        insertExportAssignments(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.ExportAssignment,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forExportAssignment().printTexts(writer, structures);
                    }, {
                        previousNewLine: previousMember => Node.isExportAssignment(previousMember) || isComment(previousMember.compilerNode),
                        nextNewLine: nextMember => Node.isExportAssignment(nextMember),
                    });
                },
            });
        }
        getExportAssignment(condition) {
            return this.getExportAssignments().find(condition);
        }
        getExportAssignmentOrThrow(condition) {
            return common.errors.throwIfNullOrUndefined(this.getExportAssignment(condition), "Expected to find an export assignment with the provided condition.");
        }
        getExportAssignments() {
            return this.getStatements().filter(Node.isExportAssignment);
        }
        getDefaultExportSymbol() {
            const sourceFileSymbol = this.getSymbol();
            if (sourceFileSymbol == null)
                return undefined;
            return sourceFileSymbol.getExport("default");
        }
        getDefaultExportSymbolOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getDefaultExportSymbol(), "Expected to find a default export symbol");
        }
        getExportSymbols() {
            const symbol = this.getSymbol();
            return symbol == null ? [] : this._context.typeChecker.getExportsOfModule(symbol);
        }
        getExportedDeclarations() {
            const result = new Map();
            const exportSymbols = this.getExportSymbols();
            for (const symbol of exportSymbols) {
                for (const declaration of symbol.getDeclarations()) {
                    const declarations = Array.from(getDeclarationHandlingImportsAndExports(declaration));
                    const name = symbol.getName();
                    const existingArray = result.get(name);
                    if (existingArray != null)
                        existingArray.push(...declarations);
                    else
                        result.set(symbol.getName(), declarations);
                }
            }
            return result;
            function* getDeclarationHandlingImportsAndExports(declaration) {
                if (Node.isExportSpecifier(declaration)) {
                    for (const d of declaration.getLocalTargetDeclarations())
                        yield* getDeclarationHandlingImportsAndExports(d);
                }
                else if (Node.isExportAssignment(declaration)) {
                    const expression = declaration.getExpression();
                    if (expression == null || expression.getKind() !== common.SyntaxKind.Identifier) {
                        yield expression;
                        return;
                    }
                    yield* getDeclarationsForSymbol(expression.getSymbol());
                }
                else if (Node.isImportSpecifier(declaration)) {
                    const identifier = declaration.getNameNode();
                    const symbol = identifier.getSymbol();
                    if (symbol == null)
                        return;
                    yield* getDeclarationsForSymbol(symbol.getAliasedSymbol() || symbol);
                }
                else if (Node.isImportClause(declaration)) {
                    const identifier = declaration.getDefaultImport();
                    if (identifier == null)
                        return;
                    const symbol = identifier.getSymbol();
                    if (symbol == null)
                        return;
                    yield* getDeclarationsForSymbol(symbol.getAliasedSymbol() || symbol);
                }
                else if (Node.isNamespaceImport(declaration) || Node.isNamespaceExport(declaration)) {
                    const symbol = declaration.getNameNode().getSymbol();
                    if (symbol == null)
                        return;
                    yield* getDeclarationsForSymbol(symbol.getAliasedSymbol() || symbol);
                }
                else {
                    yield declaration;
                }
                function* getDeclarationsForSymbol(symbol) {
                    if (symbol == null)
                        return;
                    for (const d of symbol.getDeclarations())
                        yield* getDeclarationHandlingImportsAndExports(d);
                }
            }
        }
        removeDefaultExport(defaultExportSymbol) {
            defaultExportSymbol = defaultExportSymbol || this.getDefaultExportSymbol();
            if (defaultExportSymbol == null)
                return this;
            const declaration = defaultExportSymbol.getDeclarations()[0];
            if (declaration.compilerNode.kind === common.SyntaxKind.ExportAssignment)
                removeChildrenWithFormatting({ children: [declaration], getSiblingFormatting: () => FormattingKind.Newline });
            else if (Node.isModifierableNode(declaration)) {
                declaration.toggleModifier("default", false);
                declaration.toggleModifier("export", false);
            }
            return this;
        }
    };
}

function NamedNodeBase(Base) {
    return class extends Base {
        getNameNode() {
            return this._getNodeFromCompilerNode(this.compilerNode.name);
        }
        getName() {
            return this.getNameNode().getText();
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.name != null)
                this.getNameNode().replaceWithText(structure.name);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                name: this.getName(),
            });
        }
    };
}

function ReferenceFindableNode(Base) {
    return class extends Base {
        findReferences() {
            return this._context.languageService.findReferences(getNodeForReferences(this));
        }
        findReferencesAsNodes() {
            return this._context.languageService.findReferencesAsNodes(getNodeForReferences(this));
        }
    };
}
function getNodeForReferences(node) {
    if (Node.isIdentifier(node) || Node.isStringLiteral(node))
        return node;
    const nameNode = node.getNodeProperty("name");
    if (nameNode != null)
        return nameNode;
    if (Node.isExportableNode(node))
        return node.getDefaultKeyword() || node;
    return node;
}

function RenameableNode(Base) {
    return class extends Base {
        rename(newName, options) {
            renameNode(getNodeToRename(this), newName, options);
            return this;
            function getNodeToRename(thisNode) {
                if (Node.isIdentifier(thisNode) || Node.isPrivateIdentifier(thisNode) || Node.isStringLiteral(thisNode))
                    return thisNode;
                else if (thisNode.getNameNode != null) {
                    const node = thisNode.getNameNode();
                    common.errors.throwIfNullOrUndefined(node, "Expected to find a name node when renaming.");
                    if (Node.isArrayBindingPattern(node) || Node.isObjectBindingPattern(node))
                        throw new common.errors.NotImplementedError(`Not implemented renameable scenario for ${node.getKindName()}.`);
                    return node;
                }
                else {
                    throw new common.errors.NotImplementedError(`Not implemented renameable scenario for ${thisNode.getKindName()}`);
                }
            }
        }
    };
}

function BindingNamedNode(Base) {
    const base = ReferenceFindableNode(RenameableNode(Base));
    return NamedNodeBase(base);
}

function ModuleNamedNode(Base) {
    const base = ReferenceFindableNode(RenameableNode(Base));
    return NamedNodeBase(base);
}

function NameableNode(Base) {
    return NameableNodeInternal(ReferenceFindableNode(RenameableNode(Base)));
}
function NameableNodeInternal(Base) {
    return class extends Base {
        getNameNode() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.name);
        }
        getNameNodeOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getNameNode(), "Expected to have a name node.");
        }
        getName() {
            var _a, _b;
            return (_b = (_a = this.getNameNode()) === null || _a === void 0 ? void 0 : _a.getText()) !== null && _b !== void 0 ? _b : undefined;
        }
        getNameOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getName(), "Expected to have a name.");
        }
        rename(newName) {
            if (newName === this.getName())
                return this;
            if (common.StringUtils.isNullOrWhitespace(newName)) {
                this.removeName();
                return this;
            }
            const nameNode = this.getNameNode();
            if (nameNode == null)
                addNameNode(this, newName);
            else
                Base.prototype.rename.call(this, newName);
            return this;
        }
        removeName() {
            const nameNode = this.getNameNode();
            if (nameNode == null)
                return this;
            removeChildren({ children: [nameNode], removePrecedingSpaces: true });
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.name != null) {
                common.errors.throwIfWhitespaceOrNotString(structure.name, "structure.name");
                const nameNode = this.getNameNode();
                if (nameNode == null)
                    addNameNode(this, structure.name);
                else
                    nameNode.replaceWithText(structure.name);
            }
            else if (structure.hasOwnProperty("name")) {
                this.removeName();
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                name: this.getName(),
            });
        }
    };
}
function addNameNode(node, newName) {
    if (Node.isClassDeclaration(node) || Node.isClassExpression(node)) {
        const classKeyword = node.getFirstChildByKindOrThrow(common.SyntaxKind.ClassKeyword);
        insertIntoParentTextRange({
            insertPos: classKeyword.getEnd(),
            newText: " " + newName,
            parent: node,
        });
    }
    else {
        const openParenToken = node.getFirstChildByKindOrThrow(common.SyntaxKind.OpenParenToken);
        insertIntoParentTextRange({
            insertPos: openParenToken.getStart(),
            newText: " " + newName,
            parent: node,
        });
    }
}

function NamedNode(Base) {
    const base = RenameableNode(ReferenceFindableNode(Base));
    return NamedNodeBase(base);
}

function PropertyNamedNode(Base) {
    const base = ReferenceFindableNode(RenameableNode(Base));
    return NamedNodeBase(base);
}

function OverrideableNode(Base) {
    return class extends Base {
        hasOverrideKeyword() {
            return this.hasModifier(common.SyntaxKind.OverrideKeyword);
        }
        getOverrideKeyword() {
            return this.getFirstModifierByKind(common.SyntaxKind.OverrideKeyword);
        }
        getOverrideKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getOverrideKeyword(), "Expected to find an override keyword.");
        }
        setHasOverrideKeyword(value) {
            this.toggleModifier("override", value);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.hasOverrideKeyword != null)
                this.setHasOverrideKeyword(structure.hasOverrideKeyword);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                hasOverrideKeyword: this.hasOverrideKeyword(),
            });
        }
    };
}

function ParameteredNode(Base) {
    return class extends Base {
        getParameter(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getParameters(), nameOrFindFunction);
        }
        getParameterOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getParameter(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("parameter", nameOrFindFunction));
        }
        getParameters() {
            return this.compilerNode.parameters.map(p => this._getNodeFromCompilerNode(p));
        }
        addParameter(structure) {
            return this.addParameters([structure])[0];
        }
        addParameters(structures) {
            return this.insertParameters(getEndIndexFromArray(this.compilerNode.parameters), structures);
        }
        insertParameter(index, structure) {
            return this.insertParameters(index, [structure])[0];
        }
        insertParameters(index, structures) {
            if (common.ArrayUtils.isNullOrEmpty(structures))
                return [];
            const parameters = this.getParameters();
            const syntaxList = this.getFirstChildByKindOrThrow(common.SyntaxKind.OpenParenToken).getNextSiblingIfKindOrThrow(common.SyntaxKind.SyntaxList);
            index = verifyAndGetIndex(index, parameters.length);
            const writer = this._getWriterWithQueuedChildIndentation();
            const structurePrinter = this._context.structurePrinterFactory.forParameterDeclaration();
            structurePrinter.printTexts(writer, structures);
            insertIntoCommaSeparatedNodes({
                parent: syntaxList,
                currentNodes: parameters,
                insertIndex: index,
                newText: writer.toString(),
                useTrailingCommas: false,
            });
            return getNodesToReturn(parameters, this.getParameters(), index, false);
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.parameters != null) {
                this.getParameters().forEach(p => p.remove());
                this.addParameters(structure.parameters);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                parameters: this.getParameters().map(p => p.getStructure()),
            });
        }
    };
}

function QuestionDotTokenableNode(Base) {
    return class extends Base {
        hasQuestionDotToken() {
            return this.compilerNode.questionDotToken != null;
        }
        getQuestionDotTokenNode() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.questionDotToken);
        }
        getQuestionDotTokenNodeOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getQuestionDotTokenNode(), "Expected to find a question dot token.");
        }
        setHasQuestionDotToken(value) {
            const questionDotTokenNode = this.getQuestionDotTokenNode();
            const hasQuestionDotToken = questionDotTokenNode != null;
            if (value === hasQuestionDotToken)
                return this;
            if (value) {
                if (Node.isPropertyAccessExpression(this))
                    this.getFirstChildByKindOrThrow(common.SyntaxKind.DotToken).replaceWithText("?.");
                else {
                    insertIntoParentTextRange({
                        insertPos: getInsertPos.call(this),
                        parent: this,
                        newText: "?.",
                    });
                }
            }
            else {
                if (Node.isPropertyAccessExpression(this))
                    questionDotTokenNode.replaceWithText(".");
                else
                    removeChildren({ children: [questionDotTokenNode] });
            }
            return this;
            function getInsertPos() {
                if (Node.isCallExpression(this))
                    return this.getFirstChildByKindOrThrow(common.SyntaxKind.OpenParenToken).getStart();
                if (Node.isElementAccessExpression(this))
                    return this.getFirstChildByKindOrThrow(common.SyntaxKind.OpenBracketToken).getStart();
                common.errors.throwNotImplementedForSyntaxKindError(this.compilerNode.kind);
            }
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.hasQuestionDotToken != null)
                this.setHasQuestionDotToken(structure.hasQuestionDotToken);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                hasQuestionDotToken: this.hasQuestionDotToken(),
            });
        }
    };
}

function QuestionTokenableNode(Base) {
    return class extends Base {
        hasQuestionToken() {
            return this.compilerNode.questionToken != null;
        }
        getQuestionTokenNode() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.questionToken);
        }
        getQuestionTokenNodeOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getQuestionTokenNode(), "Expected to find a question token.");
        }
        setHasQuestionToken(value) {
            const questionTokenNode = this.getQuestionTokenNode();
            const hasQuestionToken = questionTokenNode != null;
            if (value === hasQuestionToken)
                return this;
            if (value) {
                if (Node.isExclamationTokenableNode(this))
                    this.setHasExclamationToken(false);
                insertIntoParentTextRange({
                    insertPos: getInsertPos.call(this),
                    parent: this,
                    newText: "?",
                });
            }
            else {
                removeChildren({ children: [questionTokenNode] });
            }
            return this;
            function getInsertPos() {
                if (Node.hasName(this))
                    return this.getNameNode().getEnd();
                const colonNode = this.getFirstChildByKind(common.SyntaxKind.ColonToken);
                if (colonNode != null)
                    return colonNode.getStart();
                const semicolonToken = this.getLastChildByKind(common.SyntaxKind.SemicolonToken);
                if (semicolonToken != null)
                    return semicolonToken.getStart();
                return this.getEnd();
            }
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.hasQuestionToken != null)
                this.setHasQuestionToken(structure.hasQuestionToken);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                hasQuestionToken: this.hasQuestionToken(),
            });
        }
    };
}

function ReadonlyableNode(Base) {
    return class extends Base {
        isReadonly() {
            return this.getReadonlyKeyword() != null;
        }
        getReadonlyKeyword() {
            return this.getFirstModifierByKind(common.SyntaxKind.ReadonlyKeyword);
        }
        getReadonlyKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getReadonlyKeyword(), "Expected to find a readonly keyword.");
        }
        setIsReadonly(value) {
            this.toggleModifier("readonly", value);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.isReadonly != null)
                this.setIsReadonly(structure.isReadonly);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                isReadonly: this.isReadonly(),
            });
        }
    };
}

function ReturnTypedNode(Base) {
    return class extends Base {
        getReturnType() {
            return this.getSignature().getReturnType();
        }
        getReturnTypeNode() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.type);
        }
        getReturnTypeNodeOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getReturnTypeNode(), "Expected to find a return type node.");
        }
        setReturnType(textOrWriterFunction) {
            const text = getTextFromStringOrWriter(this._getWriterWithQueuedChildIndentation(), textOrWriterFunction);
            if (common.StringUtils.isNullOrWhitespace(text))
                return this.removeReturnType();
            const returnTypeNode = this.getReturnTypeNode();
            if (returnTypeNode != null) {
                if (returnTypeNode.getText() !== text)
                    returnTypeNode.replaceWithText(text);
                return this;
            }
            insertIntoParentTextRange({
                parent: this,
                insertPos: getEndNode(this).getEnd(),
                newText: `: ${text}`,
            });
            return this;
            function getEndNode(thisNode) {
                if (thisNode.getKind() === common.SyntaxKind.IndexSignature)
                    return thisNode.getFirstChildByKindOrThrow(common.SyntaxKind.CloseBracketToken);
                return thisNode.getFirstChildByKindOrThrow(common.SyntaxKind.CloseParenToken);
            }
        }
        removeReturnType() {
            const returnTypeNode = this.getReturnTypeNode();
            if (returnTypeNode == null)
                return this;
            const colonToken = returnTypeNode.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.ColonToken);
            removeChildren({ children: [colonToken, returnTypeNode], removePrecedingSpaces: true });
            return this;
        }
        getSignature() {
            const signature = this._context.typeChecker.getSignatureFromNode(this);
            if (signature == null)
                throw new common.errors.NotImplementedError("Expected the node to have a signature.");
            return signature;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.returnType != null)
                this.setReturnType(structure.returnType);
            else if (structure.hasOwnProperty("returnType"))
                this.removeReturnType();
            return this;
        }
        getStructure() {
            const returnTypeNode = this.getReturnTypeNode();
            return callBaseGetStructure(Base.prototype, this, {
                returnType: returnTypeNode ? returnTypeNode.getText({ trimLeadingIndentation: true }) : undefined,
            });
        }
    };
}

function ScopeableNode(Base) {
    return class extends Base {
        getScope() {
            const scope = getScopeForNode(this);
            if (scope != null)
                return scope;
            if (Node.isParameterDeclaration(this) && this.isReadonly())
                return exports.Scope.Public;
            return undefined;
        }
        setScope(scope) {
            setScopeForNode(this, scope);
            return this;
        }
        getScopeKeyword() {
            return this.getModifiers().find(m => {
                const text = m.getText();
                return text === "public" || text === "protected" || text === "private";
            });
        }
        hasScopeKeyword() {
            return this.getScopeKeyword() != null;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.hasOwnProperty("scope"))
                this.setScope(structure.scope);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                scope: this.getScope(),
            });
        }
    };
}
function getScopeForNode(node) {
    const modifierFlags = node.getCombinedModifierFlags();
    if ((modifierFlags & common.ts.ModifierFlags.Private) !== 0)
        return exports.Scope.Private;
    else if ((modifierFlags & common.ts.ModifierFlags.Protected) !== 0)
        return exports.Scope.Protected;
    else if ((modifierFlags & common.ts.ModifierFlags.Public) !== 0)
        return exports.Scope.Public;
    else
        return undefined;
}
function setScopeForNode(node, scope) {
    node.toggleModifier("public", scope === exports.Scope.Public);
    node.toggleModifier("protected", scope === exports.Scope.Protected);
    node.toggleModifier("private", scope === exports.Scope.Private);
}

function ScopedNode(Base) {
    return class extends Base {
        getScope() {
            return getScopeForNode(this) || exports.Scope.Public;
        }
        setScope(scope) {
            setScopeForNode(this, scope);
            return this;
        }
        hasScopeKeyword() {
            return getScopeForNode(this) != null;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.hasOwnProperty("scope"))
                this.setScope(structure.scope);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                scope: this.hasScopeKeyword() ? this.getScope() : undefined,
            });
        }
    };
}

function SignaturedDeclaration(Base) {
    return ReturnTypedNode(ParameteredNode(Base));
}

function StaticableNode(Base) {
    return class extends Base {
        isStatic() {
            return this.hasModifier(common.SyntaxKind.StaticKeyword);
        }
        getStaticKeyword() {
            return this.getFirstModifierByKind(common.SyntaxKind.StaticKeyword);
        }
        getStaticKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getStaticKeyword(), "Expected to find a static keyword.");
        }
        setIsStatic(value) {
            this.toggleModifier("static", value);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.isStatic != null)
                this.setIsStatic(structure.isStatic);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                isStatic: this.isStatic(),
            });
        }
    };
}

function TextInsertableNode(Base) {
    return class extends Base {
        insertText(pos, textOrWriterFunction) {
            this.replaceText([pos, pos], textOrWriterFunction);
            return this;
        }
        removeText(pos, end) {
            if (pos == null)
                this.replaceText(getValidRange(this), "");
            else
                this.replaceText([pos, end], "");
            return this;
        }
        replaceText(range, textOrWriterFunction) {
            const childSyntaxList = this.getChildSyntaxListOrThrow();
            const validRange = getValidRange(this);
            const pos = range[0];
            const end = range[1];
            verifyArguments();
            insertIntoParentTextRange({
                insertPos: pos,
                newText: getTextFromStringOrWriter(this._getWriter(), textOrWriterFunction),
                parent: childSyntaxList.getParentOrThrow(),
                replacing: {
                    textLength: end - pos,
                    nodes: [childSyntaxList],
                },
            });
            return this;
            function verifyArguments() {
                verifyInRange(pos);
                verifyInRange(end);
                if (pos > end)
                    throw new common.errors.ArgumentError("range", "Cannot specify a start position greater than the end position.");
            }
            function verifyInRange(i) {
                if (i >= validRange[0] && i <= validRange[1])
                    return;
                throw new common.errors.InvalidOperationError(`Cannot insert or replace text outside the bounds of the node. `
                    + `Expected a position between [${validRange[0]}, ${validRange[1]}], but received ${i}.`);
            }
        }
    };
}
function getValidRange(thisNode) {
    const rangeNode = getRangeNode();
    const openBrace = Node.isSourceFile(rangeNode) ? undefined : rangeNode.getPreviousSiblingIfKind(common.SyntaxKind.OpenBraceToken);
    const closeBrace = openBrace == null ? undefined : rangeNode.getNextSiblingIfKind(common.SyntaxKind.CloseBraceToken);
    if (openBrace != null && closeBrace != null)
        return [openBrace.getEnd(), closeBrace.getStart()];
    else
        return [rangeNode.getPos(), rangeNode.getEnd()];
    function getRangeNode() {
        if (Node.isSourceFile(thisNode))
            return thisNode;
        return thisNode.getChildSyntaxListOrThrow();
    }
}

function TypeArgumentedNode(Base) {
    return class extends Base {
        getTypeArguments() {
            if (this.compilerNode.typeArguments == null)
                return [];
            return this.compilerNode.typeArguments.map(a => this._getNodeFromCompilerNode(a));
        }
        addTypeArgument(argumentText) {
            return this.addTypeArguments([argumentText])[0];
        }
        addTypeArguments(argumentTexts) {
            return this.insertTypeArguments(this.getTypeArguments().length, argumentTexts);
        }
        insertTypeArgument(index, argumentText) {
            return this.insertTypeArguments(index, [argumentText])[0];
        }
        insertTypeArguments(index, argumentTexts) {
            if (common.ArrayUtils.isNullOrEmpty(argumentTexts))
                return [];
            const typeArguments = this.getTypeArguments();
            index = verifyAndGetIndex(index, typeArguments.length);
            if (typeArguments.length === 0) {
                const identifier = this.getFirstChildByKindOrThrow(common.SyntaxKind.Identifier);
                insertIntoParentTextRange({
                    insertPos: identifier.getEnd(),
                    parent: this,
                    newText: `<${argumentTexts.join(", ")}>`,
                });
            }
            else {
                insertIntoCommaSeparatedNodes({
                    parent: this.getFirstChildByKindOrThrow(common.SyntaxKind.LessThanToken).getNextSiblingIfKindOrThrow(common.SyntaxKind.SyntaxList),
                    currentNodes: typeArguments,
                    insertIndex: index,
                    newText: argumentTexts.join(", "),
                    useTrailingCommas: false,
                });
            }
            return getNodesToReturn(typeArguments, this.getTypeArguments(), index, false);
        }
        removeTypeArgument(typeArgOrIndex) {
            const typeArguments = this.getTypeArguments();
            if (typeArguments.length === 0)
                throw new common.errors.InvalidOperationError("Cannot remove a type argument when none exist.");
            const typeArgToRemove = typeof typeArgOrIndex === "number" ? getTypeArgFromIndex(typeArgOrIndex) : typeArgOrIndex;
            if (typeArguments.length === 1) {
                const childSyntaxList = typeArguments[0].getParentSyntaxListOrThrow();
                removeChildren({
                    children: [
                        childSyntaxList.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.LessThanToken),
                        childSyntaxList,
                        childSyntaxList.getNextSiblingIfKindOrThrow(common.SyntaxKind.GreaterThanToken),
                    ],
                });
            }
            else {
                removeCommaSeparatedChild(typeArgToRemove);
            }
            return this;
            function getTypeArgFromIndex(index) {
                return typeArguments[verifyAndGetIndex(index, typeArguments.length - 1)];
            }
        }
    };
}

function TypedNode(Base) {
    return class extends Base {
        getTypeNode() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.type);
        }
        getTypeNodeOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getTypeNode(), "Expected to find a type node.");
        }
        setType(textOrWriterFunction) {
            const text = getTextFromStringOrWriter(this._getWriterWithQueuedChildIndentation(), textOrWriterFunction);
            if (common.StringUtils.isNullOrWhitespace(text))
                return this.removeType();
            const typeNode = this.getTypeNode();
            if (typeNode != null && typeNode.getText() === text)
                return this;
            const separatorSyntaxKind = getSeparatorSyntaxKindForNode(this);
            const separatorNode = this.getFirstChildByKind(separatorSyntaxKind);
            let insertPos;
            let newText;
            if (separatorNode == null) {
                insertPos = getInsertPosWhenNoType(this);
                newText = (separatorSyntaxKind === common.SyntaxKind.EqualsToken ? " = " : ": ") + text;
            }
            else {
                insertPos = typeNode.getStart();
                newText = text;
            }
            insertIntoParentTextRange({
                parent: this,
                insertPos,
                newText,
                replacing: {
                    textLength: typeNode == null ? 0 : typeNode.getWidth(),
                },
            });
            return this;
            function getInsertPosWhenNoType(node) {
                const identifier = node.getFirstChildByKindOrThrow(common.SyntaxKind.Identifier);
                const nextSibling = identifier.getNextSibling();
                const insertAfterNode = isQuestionOrExclamation(nextSibling) ? nextSibling : identifier;
                return insertAfterNode.getEnd();
            }
            function isQuestionOrExclamation(node) {
                if (node == null)
                    return false;
                const kind = node.getKind();
                return kind === common.SyntaxKind.QuestionToken || kind === common.SyntaxKind.ExclamationToken;
            }
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.type != null)
                this.setType(structure.type);
            else if (structure.hasOwnProperty("type"))
                this.removeType();
            return this;
        }
        removeType() {
            if (this.getKind() === common.SyntaxKind.TypeAliasDeclaration)
                throw new common.errors.NotSupportedError(`Cannot remove the type of a type alias. Use ${"setType"} instead.`);
            const typeNode = this.getTypeNode();
            if (typeNode == null)
                return this;
            const separatorToken = typeNode.getPreviousSiblingIfKindOrThrow(getSeparatorSyntaxKindForNode(this));
            removeChildren({ children: [separatorToken, typeNode], removePrecedingSpaces: true });
            return this;
        }
        getStructure() {
            const typeNode = this.getTypeNode();
            return callBaseGetStructure(Base.prototype, this, {
                type: typeNode ? typeNode.getText({ trimLeadingIndentation: true }) : undefined,
            });
        }
    };
}
function getSeparatorSyntaxKindForNode(node) {
    switch (node.getKind()) {
        case common.SyntaxKind.TypeAliasDeclaration:
            return common.SyntaxKind.EqualsToken;
        default:
            return common.SyntaxKind.ColonToken;
    }
}

function TypeElementMemberedNode(Base) {
    return class extends Base {
        addMember(member) {
            return this.addMembers([member])[0];
        }
        addMembers(members) {
            return this.insertMembers(getEndIndexFromArray(this.getMembersWithComments()), members);
        }
        insertMember(index, member) {
            return this.insertMembers(index, [member])[0];
        }
        insertMembers(index, members) {
            return insertIntoBracesOrSourceFileWithGetChildrenWithComments({
                getIndexedChildren: () => this.getMembersWithComments(),
                index,
                parent: this,
                write: writer => {
                    writer.newLineIfLastNot();
                    const memberWriter = this._getWriter();
                    const memberPrinter = this._context.structurePrinterFactory.forTypeElementMember();
                    memberPrinter.printTexts(memberWriter, members);
                    writer.write(memberWriter.toString());
                    writer.newLineIfLastNot();
                },
            });
        }
        addConstructSignature(structure) {
            return this.addConstructSignatures([structure])[0];
        }
        addConstructSignatures(structures) {
            return this.insertConstructSignatures(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertConstructSignature(index, structure) {
            return this.insertConstructSignatures(index, [structure])[0];
        }
        insertConstructSignatures(index, structures) {
            return insertChildren$1({
                thisNode: this,
                index,
                structures,
                expectedKind: common.SyntaxKind.ConstructSignature,
                createStructurePrinter: () => this._context.structurePrinterFactory.forConstructSignatureDeclaration(),
            });
        }
        getConstructSignature(findFunction) {
            return this.getConstructSignatures().find(findFunction);
        }
        getConstructSignatureOrThrow(findFunction) {
            return common.errors.throwIfNullOrUndefined(this.getConstructSignature(findFunction), "Expected to find a construct signature with the provided condition.");
        }
        getConstructSignatures() {
            return this.compilerNode.members.filter(m => m.kind === common.SyntaxKind.ConstructSignature)
                .map(m => this._getNodeFromCompilerNode(m));
        }
        addCallSignature(structure) {
            return this.addCallSignatures([structure])[0];
        }
        addCallSignatures(structures) {
            return this.insertCallSignatures(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertCallSignature(index, structure) {
            return this.insertCallSignatures(index, [structure])[0];
        }
        insertCallSignatures(index, structures) {
            return insertChildren$1({
                thisNode: this,
                index,
                structures,
                expectedKind: common.SyntaxKind.CallSignature,
                createStructurePrinter: () => this._context.structurePrinterFactory.forCallSignatureDeclaration(),
            });
        }
        getCallSignature(findFunction) {
            return this.getCallSignatures().find(findFunction);
        }
        getCallSignatureOrThrow(findFunction) {
            return common.errors.throwIfNullOrUndefined(this.getCallSignature(findFunction), "Expected to find a call signature with the provided condition.");
        }
        getCallSignatures() {
            return this.compilerNode.members.filter(m => m.kind === common.SyntaxKind.CallSignature)
                .map(m => this._getNodeFromCompilerNode(m));
        }
        addIndexSignature(structure) {
            return this.addIndexSignatures([structure])[0];
        }
        addIndexSignatures(structures) {
            return this.insertIndexSignatures(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertIndexSignature(index, structure) {
            return this.insertIndexSignatures(index, [structure])[0];
        }
        insertIndexSignatures(index, structures) {
            return insertChildren$1({
                thisNode: this,
                index,
                structures,
                expectedKind: common.SyntaxKind.IndexSignature,
                createStructurePrinter: () => this._context.structurePrinterFactory.forIndexSignatureDeclaration(),
            });
        }
        getIndexSignature(findFunction) {
            return this.getIndexSignatures().find(findFunction);
        }
        getIndexSignatureOrThrow(findFunction) {
            return common.errors.throwIfNullOrUndefined(this.getIndexSignature(findFunction), "Expected to find a index signature with the provided condition.");
        }
        getIndexSignatures() {
            return this.compilerNode.members.filter(m => m.kind === common.SyntaxKind.IndexSignature)
                .map(m => this._getNodeFromCompilerNode(m));
        }
        addMethod(structure) {
            return this.addMethods([structure])[0];
        }
        addMethods(structures) {
            return this.insertMethods(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertMethod(index, structure) {
            return this.insertMethods(index, [structure])[0];
        }
        insertMethods(index, structures) {
            return insertChildren$1({
                thisNode: this,
                index,
                structures,
                expectedKind: common.SyntaxKind.MethodSignature,
                createStructurePrinter: () => this._context.structurePrinterFactory.forMethodSignature(),
            });
        }
        getMethod(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getMethods(), nameOrFindFunction);
        }
        getMethodOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getMethod(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("interface method signature", nameOrFindFunction));
        }
        getMethods() {
            return this.compilerNode.members.filter(m => m.kind === common.SyntaxKind.MethodSignature)
                .map(m => this._getNodeFromCompilerNode(m));
        }
        addProperty(structure) {
            return this.addProperties([structure])[0];
        }
        addProperties(structures) {
            return this.insertProperties(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertProperty(index, structure) {
            return this.insertProperties(index, [structure])[0];
        }
        insertProperties(index, structures) {
            return insertChildren$1({
                thisNode: this,
                index,
                structures,
                expectedKind: common.SyntaxKind.PropertySignature,
                createStructurePrinter: () => this._context.structurePrinterFactory.forPropertySignature(),
            });
        }
        getProperty(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getProperties(), nameOrFindFunction);
        }
        getPropertyOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getProperty(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("interface property signature", nameOrFindFunction));
        }
        getProperties() {
            return this.compilerNode.members.filter(m => m.kind === common.SyntaxKind.PropertySignature)
                .map(m => this._getNodeFromCompilerNode(m));
        }
        getMembers() {
            return this.compilerNode.members.map(m => this._getNodeFromCompilerNode(m));
        }
        getMembersWithComments() {
            const compilerNode = this.compilerNode;
            return ExtendedParser.getContainerArray(compilerNode, this._sourceFile.compilerNode)
                .map(m => this._getNodeFromCompilerNode(m));
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.callSignatures != null) {
                this.getCallSignatures().forEach(c => c.remove());
                this.addCallSignatures(structure.callSignatures);
            }
            if (structure.constructSignatures != null) {
                this.getConstructSignatures().forEach(c => c.remove());
                this.addConstructSignatures(structure.constructSignatures);
            }
            if (structure.indexSignatures != null) {
                this.getIndexSignatures().forEach(c => c.remove());
                this.addIndexSignatures(structure.indexSignatures);
            }
            if (structure.properties != null) {
                this.getProperties().forEach(c => c.remove());
                this.addProperties(structure.properties);
            }
            if (structure.methods != null) {
                this.getMethods().forEach(c => c.remove());
                this.addMethods(structure.methods);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                callSignatures: this.getCallSignatures().map(node => node.getStructure()),
                constructSignatures: this.getConstructSignatures().map(node => node.getStructure()),
                indexSignatures: this.getIndexSignatures().map(node => node.getStructure()),
                methods: this.getMethods().map(node => node.getStructure()),
                properties: this.getProperties().map(node => node.getStructure()),
            });
        }
    };
}
function insertChildren$1(opts) {
    return insertIntoBracesOrSourceFileWithGetChildren({
        getIndexedChildren: () => opts.thisNode.getMembersWithComments(),
        parent: opts.thisNode,
        index: opts.index,
        structures: opts.structures,
        expectedKind: opts.expectedKind,
        write: (writer, info) => {
            writer.newLineIfLastNot();
            opts.createStructurePrinter().printTexts(writer, opts.structures);
            writer.newLineIfLastNot();
        },
    });
}

function TypeParameteredNode(Base) {
    return class extends Base {
        getTypeParameter(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getTypeParameters(), nameOrFindFunction);
        }
        getTypeParameterOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getTypeParameter(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("type parameter", nameOrFindFunction));
        }
        getTypeParameters() {
            const typeParameters = this.compilerNode.typeParameters;
            if (typeParameters == null)
                return [];
            return typeParameters.map(t => this._getNodeFromCompilerNode(t));
        }
        addTypeParameter(structure) {
            return this.addTypeParameters([structure])[0];
        }
        addTypeParameters(structures) {
            return this.insertTypeParameters(getEndIndexFromArray(this.compilerNode.typeParameters), structures);
        }
        insertTypeParameter(index, structure) {
            return this.insertTypeParameters(index, [structure])[0];
        }
        insertTypeParameters(index, structures) {
            if (common.ArrayUtils.isNullOrEmpty(structures))
                return [];
            const typeParameters = this.getTypeParameters();
            const writer = this._getWriterWithQueuedChildIndentation();
            const structurePrinter = this._context.structurePrinterFactory.forTypeParameterDeclaration();
            index = verifyAndGetIndex(index, typeParameters.length);
            structurePrinter.printTexts(writer, structures);
            if (typeParameters.length === 0) {
                insertIntoParentTextRange({
                    insertPos: getInsertPos(this),
                    parent: this,
                    newText: `<${writer.toString()}>`,
                });
            }
            else {
                insertIntoCommaSeparatedNodes({
                    parent: this.getFirstChildByKindOrThrow(common.SyntaxKind.LessThanToken).getNextSiblingIfKindOrThrow(common.SyntaxKind.SyntaxList),
                    currentNodes: typeParameters,
                    insertIndex: index,
                    newText: writer.toString(),
                    useTrailingCommas: false,
                });
            }
            return getNodesToReturn(typeParameters, this.getTypeParameters(), index, false);
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.typeParameters != null) {
                this.getTypeParameters().forEach(t => t.remove());
                this.addTypeParameters(structure.typeParameters);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                typeParameters: this.getTypeParameters().map(p => p.getStructure()),
            });
        }
    };
}
function getInsertPos(node) {
    const namedNode = node;
    if (namedNode.getNameNode != null)
        return namedNode.getNameNode().getEnd();
    else if (Node.isCallSignatureDeclaration(node) || Node.isFunctionTypeNode(node))
        return node.getFirstChildByKindOrThrow(common.SyntaxKind.OpenParenToken).getStart();
    else
        throw new common.errors.NotImplementedError(`Not implemented scenario inserting type parameters for node with kind ${node.getKindName()}.`);
}

function UnwrappableNode(Base) {
    return class extends Base {
        unwrap() {
            unwrapNode(this);
        }
    };
}

class ArrayBindingPattern extends Node {
    getElements() {
        return this.compilerNode.elements.map(e => this._getNodeFromCompilerNode(e));
    }
}

const createBase$D = (ctor) => DotDotDotTokenableNode(InitializerExpressionableNode(BindingNamedNode(ctor)));
const BindingElementBase = createBase$D(Node);
class BindingElement extends BindingElementBase {
    getPropertyNameNodeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getPropertyNameNode(), "Expected to find a property name node.");
    }
    getPropertyNameNode() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.propertyName);
    }
}

class ObjectBindingPattern extends Node {
    getElements() {
        return this.compilerNode.elements.map(e => this._getNodeFromCompilerNode(e));
    }
}

function AbstractableNode(Base) {
    return class extends Base {
        isAbstract() {
            return this.getAbstractKeyword() != null;
        }
        getAbstractKeyword() {
            return this.getFirstModifierByKind(common.SyntaxKind.AbstractKeyword);
        }
        getAbstractKeywordOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getAbstractKeyword(), "Expected to find an abstract keyword.");
        }
        setIsAbstract(isAbstract) {
            this.toggleModifier("abstract", isAbstract);
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.isAbstract != null)
                this.setIsAbstract(structure.isAbstract);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                isAbstract: this.isAbstract(),
            });
        }
    };
}

class Expression extends Node {
    getContextualType() {
        return this._context.typeChecker.getContextualType(this);
    }
}

const BinaryExpressionBase = Expression;
class BinaryExpression extends BinaryExpressionBase {
    getLeft() {
        return this._getNodeFromCompilerNode(this.compilerNode.left);
    }
    getOperatorToken() {
        return this._getNodeFromCompilerNode(this.compilerNode.operatorToken);
    }
    getRight() {
        return this._getNodeFromCompilerNode(this.compilerNode.right);
    }
}

const AssignmentExpressionBase = BinaryExpression;
class AssignmentExpression extends AssignmentExpressionBase {
    getOperatorToken() {
        return this._getNodeFromCompilerNode(this.compilerNode.operatorToken);
    }
}

const ArrayDestructuringAssignmentBase = AssignmentExpression;
class ArrayDestructuringAssignment extends ArrayDestructuringAssignmentBase {
    getLeft() {
        return this._getNodeFromCompilerNode(this.compilerNode.left);
    }
}

class UnaryExpression extends Expression {
}

class UpdateExpression extends UnaryExpression {
}

class LeftHandSideExpression extends UpdateExpression {
}

class MemberExpression extends LeftHandSideExpression {
}

class PrimaryExpression extends MemberExpression {
}

class ArrayLiteralExpression extends PrimaryExpression {
    getElements() {
        return this.compilerNode.elements.map(e => this._getNodeFromCompilerNode(e));
    }
    addElement(textOrWriterFunction, options) {
        return this.addElements([textOrWriterFunction], options)[0];
    }
    addElements(textsOrWriterFunction, options) {
        return this.insertElements(this.compilerNode.elements.length, textsOrWriterFunction, options);
    }
    insertElement(index, textOrWriterFunction, options) {
        return this.insertElements(index, [textOrWriterFunction], options)[0];
    }
    insertElements(index, textsOrWriterFunction, options = {}) {
        const elements = this.getElements();
        index = verifyAndGetIndex(index, elements.length);
        const useNewLines = getUseNewLines(this);
        const writer = useNewLines ? this._getWriterWithChildIndentation() : this._getWriterWithQueuedChildIndentation();
        const stringStructurePrinter = new StringStructurePrinter();
        const structurePrinter = useNewLines
            ? new CommaNewLineSeparatedStructuresPrinter(stringStructurePrinter)
            : new CommaSeparatedStructuresPrinter(stringStructurePrinter);
        structurePrinter.printText(writer, textsOrWriterFunction);
        return insertTexts(this);
        function insertTexts(node) {
            insertIntoCommaSeparatedNodes({
                parent: node.getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
                currentNodes: elements,
                insertIndex: index,
                newText: writer.toString(),
                useNewLines,
                useTrailingCommas: useNewLines && node._context.manipulationSettings.getUseTrailingCommas(),
            });
            const newElements = node.getElements();
            return getNodesToReturn(elements, newElements, index, false);
        }
        function getUseNewLines(node) {
            if (options.useNewLines != null)
                return options.useNewLines;
            if (elements.length > 1)
                return allElementsOnDifferentLines();
            return node.getStartLineNumber() !== node.getEndLineNumber();
            function allElementsOnDifferentLines() {
                let previousLine = elements[0].getStartLineNumber();
                for (let i = 1; i < elements.length; i++) {
                    const currentLine = elements[i].getStartLineNumber();
                    if (previousLine === currentLine)
                        return false;
                    previousLine = currentLine;
                }
                return true;
            }
        }
    }
    removeElement(elementOrIndex) {
        const elements = this.getElements();
        if (elements.length === 0)
            throw new common.errors.InvalidOperationError("Cannot remove an element when none exist.");
        const elementToRemove = typeof elementOrIndex === "number" ? getElementFromIndex(elementOrIndex) : elementOrIndex;
        removeCommaSeparatedChild(elementToRemove);
        function getElementFromIndex(index) {
            return elements[verifyAndGetIndex(index, elements.length - 1)];
        }
    }
}

function ExpressionableNode(Base) {
    return class extends Base {
        getExpression() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.expression);
        }
        getExpressionOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getExpression(), "Expected to find an expression.");
        }
        getExpressionIfKind(kind) {
            const expression = this.getExpression();
            return (expression === null || expression === void 0 ? void 0 : expression.getKind()) === kind ? expression : undefined;
        }
        getExpressionIfKindOrThrow(kind) {
            return common.errors.throwIfNullOrUndefined(this.getExpressionIfKind(kind), `An expression with the kind kind ${common.getSyntaxKindName(kind)} was expected.`);
        }
    };
}

function BaseExpressionedNode(Base) {
    return class extends Base {
        getExpression() {
            return this._getNodeFromCompilerNode(this.compilerNode.expression);
        }
        getExpressionIfKind(kind) {
            const { expression } = this.compilerNode;
            return expression.kind === kind ? this._getNodeFromCompilerNode(expression) : undefined;
        }
        getExpressionIfKindOrThrow(kind) {
            return common.errors.throwIfNullOrUndefined(this.getExpressionIfKind(kind), `An expression of the kind ${common.getSyntaxKindName(kind)} was expected.`);
        }
        setExpression(textOrWriterFunction) {
            this.getExpression().replaceWithText(textOrWriterFunction, this._getWriterWithQueuedChildIndentation());
            return this;
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.expression != null)
                this.setExpression(structure.expression);
            return this;
        }
    };
}
function ExpressionedNode(Base) {
    return BaseExpressionedNode(Base);
}

function ImportExpressionedNode(Base) {
    return BaseExpressionedNode(Base);
}

function LeftHandSideExpressionedNode(Base) {
    return BaseExpressionedNode(Base);
}

function SuperExpressionedNode(Base) {
    return BaseExpressionedNode(Base);
}

function UnaryExpressionedNode(Base) {
    return BaseExpressionedNode(Base);
}

const createBase$C = (ctor) => TypedNode(ExpressionedNode(ctor));
const AsExpressionBase = createBase$C(Expression);
class AsExpression extends AsExpressionBase {
}

const AwaitExpressionBase = UnaryExpressionedNode(UnaryExpression);
class AwaitExpression extends AwaitExpressionBase {
}

const createBase$B = (ctor) => TypeArgumentedNode(ArgumentedNode(QuestionDotTokenableNode(LeftHandSideExpressionedNode(ctor))));
const CallExpressionBase = createBase$B(LeftHandSideExpression);
class CallExpression extends CallExpressionBase {
    getReturnType() {
        return this._context.typeChecker.getTypeAtLocation(this);
    }
}

const CommaListExpressionBase = Expression;
class CommaListExpression extends CommaListExpressionBase {
    getElements() {
        return this.compilerNode.elements.map(e => this._getNodeFromCompilerNode(e));
    }
}

const ConditionalExpressionBase = Expression;
class ConditionalExpression extends ConditionalExpressionBase {
    getCondition() {
        return this._getNodeFromCompilerNode(this.compilerNode.condition);
    }
    getQuestionToken() {
        return this._getNodeFromCompilerNode(this.compilerNode.questionToken);
    }
    getWhenTrue() {
        return this._getNodeFromCompilerNode(this.compilerNode.whenTrue);
    }
    getColonToken() {
        return this._getNodeFromCompilerNode(this.compilerNode.colonToken);
    }
    getWhenFalse() {
        return this._getNodeFromCompilerNode(this.compilerNode.whenFalse);
    }
}

const DeleteExpressionBase = UnaryExpressionedNode(UnaryExpression);
class DeleteExpression extends DeleteExpressionBase {
}

const createBase$A = (ctor) => QuestionDotTokenableNode(LeftHandSideExpressionedNode(ctor));
const ElementAccessExpressionBase = createBase$A(MemberExpression);
class ElementAccessExpression extends ElementAccessExpressionBase {
    getArgumentExpression() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.argumentExpression);
    }
    getArgumentExpressionOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getArgumentExpression(), "Expected to find an argument expression.");
    }
}

const ImportExpressionBase = PrimaryExpression;
class ImportExpression extends ImportExpressionBase {
}

const LiteralExpressionBase = LiteralLikeNode(PrimaryExpression);
class LiteralExpression extends LiteralExpressionBase {
}

const MetaPropertyBase = NamedNode(PrimaryExpression);
class MetaProperty extends MetaPropertyBase {
    getKeywordToken() {
        return this.compilerNode.keywordToken;
    }
}

const createBase$z = (ctor) => TypeArgumentedNode(ArgumentedNode(LeftHandSideExpressionedNode(ctor)));
const NewExpressionBase = createBase$z(PrimaryExpression);
class NewExpression extends NewExpressionBase {
}

const NonNullExpressionBase = ExpressionedNode(LeftHandSideExpression);
class NonNullExpression extends NonNullExpressionBase {
}

class ObjectLiteralElement extends Node {
    remove() {
        removeCommaSeparatedChild(this);
    }
}

class CommentObjectLiteralElement extends ObjectLiteralElement {
}

const ObjectDestructuringAssignmentBase = AssignmentExpression;
class ObjectDestructuringAssignment extends ObjectDestructuringAssignmentBase {
    getLeft() {
        return this._getNodeFromCompilerNode(this.compilerNode.left);
    }
}

const ObjectLiteralExpressionBase = PrimaryExpression;
class ObjectLiteralExpression extends ObjectLiteralExpressionBase {
    getPropertyOrThrow(nameOrFindFunction) {
        return common.errors.throwIfNullOrUndefined(this.getProperty(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("property", nameOrFindFunction));
    }
    getProperty(nameOrFindFunction) {
        let findFunc;
        if (typeof nameOrFindFunction === "string") {
            findFunc = prop => {
                if (prop["getName"] == null)
                    return false;
                return prop.getName() === nameOrFindFunction;
            };
        }
        else {
            findFunc = nameOrFindFunction;
        }
        return this.getProperties().find(findFunc);
    }
    getProperties() {
        return this.compilerNode.properties.map(p => this._getNodeFromCompilerNode(p));
    }
    getPropertiesWithComments() {
        const members = ExtendedParser.getContainerArray(this.compilerNode, this.getSourceFile().compilerNode);
        return members.map(p => this._getNodeFromCompilerNode(p));
    }
    _getAddIndex() {
        const members = ExtendedParser.getContainerArray(this.compilerNode, this.getSourceFile().compilerNode);
        return members.length;
    }
    addProperty(structure) {
        return this.insertProperties(this._getAddIndex(), [structure])[0];
    }
    addProperties(structures) {
        return this.insertProperties(this._getAddIndex(), structures);
    }
    insertProperty(index, structure) {
        return this.insertProperties(index, [structure])[0];
    }
    insertProperties(index, structures) {
        const properties = this.getPropertiesWithComments();
        index = verifyAndGetIndex(index, properties.length);
        const writer = this._getWriterWithChildIndentation();
        const structurePrinter = this._context.structurePrinterFactory.forObjectLiteralExpressionProperty();
        structurePrinter.printTexts(writer, structures);
        insertIntoCommaSeparatedNodes({
            parent: this.getChildSyntaxListOrThrow(),
            currentNodes: properties,
            insertIndex: index,
            newText: writer.toString(),
            useNewLines: true,
            useTrailingCommas: this._context.manipulationSettings.getUseTrailingCommas(),
        });
        return getNodesToReturn(properties, this.getPropertiesWithComments(), index, true);
    }
    addPropertyAssignment(structure) {
        return this.addPropertyAssignments([structure])[0];
    }
    addPropertyAssignments(structures) {
        return this.insertPropertyAssignments(this._getAddIndex(), structures);
    }
    insertPropertyAssignment(index, structure) {
        return this.insertPropertyAssignments(index, [structure])[0];
    }
    insertPropertyAssignments(index, structures) {
        return this._insertProperty(index, structures, () => this._context.structurePrinterFactory.forPropertyAssignment());
    }
    addShorthandPropertyAssignment(structure) {
        return this.addShorthandPropertyAssignments([structure])[0];
    }
    addShorthandPropertyAssignments(structures) {
        return this.insertShorthandPropertyAssignments(this._getAddIndex(), structures);
    }
    insertShorthandPropertyAssignment(index, structure) {
        return this.insertShorthandPropertyAssignments(index, [structure])[0];
    }
    insertShorthandPropertyAssignments(index, structures) {
        return this._insertProperty(index, structures, () => this._context.structurePrinterFactory.forShorthandPropertyAssignment());
    }
    addSpreadAssignment(structure) {
        return this.addSpreadAssignments([structure])[0];
    }
    addSpreadAssignments(structures) {
        return this.insertSpreadAssignments(this._getAddIndex(), structures);
    }
    insertSpreadAssignment(index, structure) {
        return this.insertSpreadAssignments(index, [structure])[0];
    }
    insertSpreadAssignments(index, structures) {
        return this._insertProperty(index, structures, () => this._context.structurePrinterFactory.forSpreadAssignment());
    }
    addMethod(structure) {
        return this.addMethods([structure])[0];
    }
    addMethods(structures) {
        return this.insertMethods(this._getAddIndex(), structures);
    }
    insertMethod(index, structure) {
        return this.insertMethods(index, [structure])[0];
    }
    insertMethods(index, structures) {
        return this._insertProperty(index, structures, () => this._context.structurePrinterFactory.forMethodDeclaration({ isAmbient: false }));
    }
    addGetAccessor(structure) {
        return this.addGetAccessors([structure])[0];
    }
    addGetAccessors(structures) {
        return this.insertGetAccessors(this._getAddIndex(), structures);
    }
    insertGetAccessor(index, structure) {
        return this.insertGetAccessors(index, [structure])[0];
    }
    insertGetAccessors(index, structures) {
        return this._insertProperty(index, structures, () => this._context.structurePrinterFactory.forGetAccessorDeclaration({ isAmbient: false }));
    }
    addSetAccessor(structure) {
        return this.addSetAccessors([structure])[0];
    }
    addSetAccessors(structures) {
        return this.insertSetAccessors(this._getAddIndex(), structures);
    }
    insertSetAccessor(index, structure) {
        return this.insertSetAccessors(index, [structure])[0];
    }
    insertSetAccessors(index, structures) {
        return this._insertProperty(index, structures, () => this._context.structurePrinterFactory.forSetAccessorDeclaration({ isAmbient: false }));
    }
    _insertProperty(index, structures, createStructurePrinter) {
        index = verifyAndGetIndex(index, this._getAddIndex());
        const writer = this._getWriterWithChildIndentation();
        const structurePrinter = new CommaNewLineSeparatedStructuresPrinter(createStructurePrinter());
        const oldProperties = this.getPropertiesWithComments();
        structurePrinter.printText(writer, structures);
        insertIntoCommaSeparatedNodes({
            parent: this.getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
            currentNodes: oldProperties,
            insertIndex: index,
            newText: writer.toString(),
            useNewLines: true,
            useTrailingCommas: this._context.manipulationSettings.getUseTrailingCommas(),
        });
        return getNodesToReturn(oldProperties, this.getPropertiesWithComments(), index, false);
    }
}

const createBase$y = (ctor) => InitializerExpressionGetableNode(QuestionTokenableNode(PropertyNamedNode(ctor)));
const PropertyAssignmentBase = createBase$y(ObjectLiteralElement);
class PropertyAssignment extends PropertyAssignmentBase {
    removeInitializer() {
        const initializer = this.getInitializerOrThrow();
        const colonToken = initializer.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.ColonToken);
        const childIndex = this.getChildIndex();
        const sourceFileText = this._sourceFile.getFullText();
        const insertPos = this.getStart();
        const newText = sourceFileText.substring(insertPos, colonToken.getPos()) + sourceFileText.substring(initializer.getEnd(), this.getEnd());
        const parent = this.getParentSyntaxList() || this.getParentOrThrow();
        insertIntoParentTextRange({
            insertPos,
            newText,
            parent,
            replacing: {
                textLength: this.getWidth(),
            },
        });
        return parent.getChildAtIndexIfKindOrThrow(childIndex, common.SyntaxKind.ShorthandPropertyAssignment);
    }
    setInitializer(textOrWriterFunction) {
        const initializer = this.getInitializerOrThrow();
        insertIntoParentTextRange({
            insertPos: initializer.getStart(),
            newText: getTextFromStringOrWriter(this._getWriterWithQueuedChildIndentation(), textOrWriterFunction),
            parent: this,
            replacing: {
                textLength: initializer.getWidth(),
            },
        });
        return this;
    }
    set(structure) {
        callBaseSet(PropertyAssignmentBase.prototype, this, structure);
        if (structure.initializer != null)
            this.setInitializer(structure.initializer);
        else if (structure.hasOwnProperty("initializer"))
            return this.removeInitializer();
        return this;
    }
    getStructure() {
        const initializer = this.getInitializerOrThrow();
        const structure = callBaseGetStructure(PropertyAssignmentBase.prototype, this, {
            kind: exports.StructureKind.PropertyAssignment,
            initializer: initializer.getText(),
        });
        delete structure.hasQuestionToken;
        return structure;
    }
}

const createBase$x = (ctor) => InitializerExpressionGetableNode(QuestionTokenableNode(NamedNode(ctor)));
const ShorthandPropertyAssignmentBase = createBase$x(ObjectLiteralElement);
class ShorthandPropertyAssignment extends ShorthandPropertyAssignmentBase {
    hasObjectAssignmentInitializer() {
        return this.compilerNode.objectAssignmentInitializer != null;
    }
    getObjectAssignmentInitializerOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getObjectAssignmentInitializer(), "Expected to find an object assignment initializer.");
    }
    getObjectAssignmentInitializer() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.objectAssignmentInitializer);
    }
    getEqualsTokenOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getEqualsToken(), "Expected to find an equals token.");
    }
    getEqualsToken() {
        const equalsToken = this.compilerNode.equalsToken;
        if (equalsToken == null)
            return undefined;
        return this._getNodeFromCompilerNode(equalsToken);
    }
    removeObjectAssignmentInitializer() {
        if (!this.hasObjectAssignmentInitializer())
            return this;
        removeChildren({
            children: [this.getEqualsTokenOrThrow(), this.getObjectAssignmentInitializerOrThrow()],
            removePrecedingSpaces: true,
        });
        return this;
    }
    setInitializer(text) {
        const parent = this.getParentSyntaxList() || this.getParentOrThrow();
        const childIndex = this.getChildIndex();
        insertIntoParentTextRange({
            insertPos: this.getStart(),
            newText: this.getText() + `: ${text}`,
            parent,
            replacing: {
                textLength: this.getWidth(),
            },
        });
        return parent.getChildAtIndexIfKindOrThrow(childIndex, common.SyntaxKind.PropertyAssignment);
    }
    set(structure) {
        callBaseSet(ShorthandPropertyAssignmentBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        const structure = callBaseGetStructure(ShorthandPropertyAssignmentBase.prototype, this, {
            kind: exports.StructureKind.ShorthandPropertyAssignment,
        });
        delete structure.hasQuestionToken;
        return structure;
    }
}

const SpreadAssignmentBase = ExpressionedNode(ObjectLiteralElement);
class SpreadAssignment extends SpreadAssignmentBase {
    set(structure) {
        callBaseSet(SpreadAssignmentBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(SpreadAssignmentBase.prototype, this, {
            kind: exports.StructureKind.SpreadAssignment,
            expression: this.getExpression().getText(),
        });
    }
}

const OmittedExpressionBase = Expression;
class OmittedExpression extends OmittedExpressionBase {
}

const ParenthesizedExpressionBase = ExpressionedNode(Expression);
class ParenthesizedExpression extends ParenthesizedExpressionBase {
}

const PartiallyEmittedExpressionBase = ExpressionedNode(Expression);
class PartiallyEmittedExpression extends PartiallyEmittedExpressionBase {
}

const PostfixUnaryExpressionBase = UnaryExpression;
class PostfixUnaryExpression extends PostfixUnaryExpressionBase {
    getOperatorToken() {
        return this.compilerNode.operator;
    }
    getOperand() {
        return this._getNodeFromCompilerNode(this.compilerNode.operand);
    }
}

const PrefixUnaryExpressionBase = UnaryExpression;
class PrefixUnaryExpression extends PrefixUnaryExpressionBase {
    getOperatorToken() {
        return this.compilerNode.operator;
    }
    getOperand() {
        return this._getNodeFromCompilerNode(this.compilerNode.operand);
    }
}

const createBase$w = (ctor) => NamedNode(QuestionDotTokenableNode(LeftHandSideExpressionedNode(ctor)));
const PropertyAccessExpressionBase = createBase$w(MemberExpression);
class PropertyAccessExpression extends PropertyAccessExpressionBase {
}

const SpreadElementBase = ExpressionedNode(Expression);
class SpreadElement extends SpreadElementBase {
}

const SuperElementAccessExpressionBase = SuperExpressionedNode(ElementAccessExpression);
class SuperElementAccessExpression extends SuperElementAccessExpressionBase {
}

const SuperExpressionBase = PrimaryExpression;
class SuperExpression extends SuperExpressionBase {
}

const SuperPropertyAccessExpressionBase = SuperExpressionedNode(PropertyAccessExpression);
class SuperPropertyAccessExpression extends SuperPropertyAccessExpressionBase {
}

const ThisExpressionBase = PrimaryExpression;
class ThisExpression extends ThisExpressionBase {
}

const createBase$v = (ctor) => TypedNode(UnaryExpressionedNode(ctor));
const TypeAssertionBase = createBase$v(UnaryExpression);
class TypeAssertion extends TypeAssertionBase {
}

const TypeOfExpressionBase = UnaryExpressionedNode(UnaryExpression);
class TypeOfExpression extends TypeOfExpressionBase {
}

const VoidExpressionBase = UnaryExpressionedNode(UnaryExpression);
class VoidExpression extends VoidExpressionBase {
}

const YieldExpressionBase = ExpressionableNode(GeneratorableNode(Expression));
class YieldExpression extends YieldExpressionBase {
}

const StatementBase = ChildOrderableNode(Node);
class Statement extends StatementBase {
    remove() {
        removeStatementedNodeChild(this);
    }
}

function StatementedNode(Base) {
    return class extends Base {
        getStatements() {
            var _a;
            const statementsContainer = this._getCompilerStatementsContainer();
            const statements = (_a = statementsContainer === null || statementsContainer === void 0 ? void 0 : statementsContainer.statements) !== null && _a !== void 0 ? _a : [];
            return statements.map(s => this._getNodeFromCompilerNode(s));
        }
        getStatementsWithComments() {
            return this._getCompilerStatementsWithComments().map(s => this._getNodeFromCompilerNode(s));
        }
        getStatement(findFunction) {
            return this.getStatements().find(findFunction);
        }
        getStatementOrThrow(findFunction) {
            return common.errors.throwIfNullOrUndefined(this.getStatement(findFunction), "Expected to find a statement matching the provided condition.");
        }
        getStatementByKind(kind) {
            const statement = this._getCompilerStatementsWithComments().find(s => s.kind === kind);
            return this._getNodeFromCompilerNodeIfExists(statement);
        }
        getStatementByKindOrThrow(kind) {
            return common.errors.throwIfNullOrUndefined(this.getStatementByKind(kind), `Expected to find a statement with syntax kind ${common.getSyntaxKindName(kind)}.`);
        }
        addStatements(textOrWriterFunction) {
            return this.insertStatements(this._getCompilerStatementsWithComments().length, textOrWriterFunction);
        }
        insertStatements(index, statements) {
            addBodyIfNotExists(this);
            const writerFunction = (writer) => {
                const statementsPrinter = this._context.structurePrinterFactory.forStatement({ isAmbient: isNodeAmbientOrInAmbientContext(this) });
                statementsPrinter.printTexts(writer, statements);
            };
            return getChildSyntaxList.call(this).insertChildText(index, writerFunction);
            function getChildSyntaxList() {
                const childSyntaxList = this.getChildSyntaxListOrThrow();
                if (Node.isCaseClause(this) || Node.isDefaultClause(this)) {
                    const block = childSyntaxList.getFirstChildIfKind(common.SyntaxKind.Block);
                    if (block != null)
                        return block.getChildSyntaxListOrThrow();
                }
                return childSyntaxList;
            }
        }
        removeStatement(index) {
            index = verifyAndGetIndex(index, this._getCompilerStatementsWithComments().length - 1);
            return this.removeStatements([index, index]);
        }
        removeStatements(indexRange) {
            const statements = this.getStatementsWithComments();
            common.errors.throwIfRangeOutOfRange(indexRange, [0, statements.length], "indexRange");
            removeStatementedNodeChildren(statements.slice(indexRange[0], indexRange[1] + 1));
            return this;
        }
        addClass(structure) {
            return this.addClasses([structure])[0];
        }
        addClasses(structures) {
            return this.insertClasses(this._getCompilerStatementsWithComments().length, structures);
        }
        insertClass(index, structure) {
            return this.insertClasses(index, [structure])[0];
        }
        insertClasses(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.ClassDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forClassDeclaration({ isAmbient: isNodeAmbientOrInAmbientContext(this) })
                            .printTexts(writer, structures);
                    });
                },
            });
        }
        getClasses() {
            return this.getStatements().filter(Node.isClassDeclaration);
        }
        getClass(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getClasses(), nameOrFindFunction);
        }
        getClassOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getClass(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class", nameOrFindFunction));
        }
        addEnum(structure) {
            return this.addEnums([structure])[0];
        }
        addEnums(structures) {
            return this.insertEnums(this._getCompilerStatementsWithComments().length, structures);
        }
        insertEnum(index, structure) {
            return this.insertEnums(index, [structure])[0];
        }
        insertEnums(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.EnumDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forEnumDeclaration().printTexts(writer, structures);
                    });
                },
            });
        }
        getEnums() {
            return this.getStatements().filter(Node.isEnumDeclaration);
        }
        getEnum(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getEnums(), nameOrFindFunction);
        }
        getEnumOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getEnum(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("enum", nameOrFindFunction));
        }
        addFunction(structure) {
            return this.addFunctions([structure])[0];
        }
        addFunctions(structures) {
            return this.insertFunctions(this._getCompilerStatementsWithComments().length, structures);
        }
        insertFunction(index, structure) {
            return this.insertFunctions(index, [structure])[0];
        }
        insertFunctions(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.FunctionDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forFunctionDeclaration({
                            isAmbient: isNodeAmbientOrInAmbientContext(this),
                        }).printTexts(writer, structures);
                    }, {
                        previousNewLine: previousMember => structures[0].hasDeclareKeyword === true
                            && Node.isFunctionDeclaration(previousMember)
                            && previousMember.getBody() == null,
                        nextNewLine: nextMember => structures[structures.length - 1].hasDeclareKeyword === true
                            && Node.isFunctionDeclaration(nextMember)
                            && nextMember.getBody() == null,
                    });
                },
            });
        }
        getFunctions() {
            return this.getStatements().filter(Node.isFunctionDeclaration).filter(f => f.isAmbient() || f.isImplementation());
        }
        getFunction(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getFunctions(), nameOrFindFunction);
        }
        getFunctionOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getFunction(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("function", nameOrFindFunction));
        }
        addInterface(structure) {
            return this.addInterfaces([structure])[0];
        }
        addInterfaces(structures) {
            return this.insertInterfaces(this._getCompilerStatementsWithComments().length, structures);
        }
        insertInterface(index, structure) {
            return this.insertInterfaces(index, [structure])[0];
        }
        insertInterfaces(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.InterfaceDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forInterfaceDeclaration().printTexts(writer, structures);
                    });
                },
            });
        }
        getInterfaces() {
            return this.getStatements().filter(Node.isInterfaceDeclaration);
        }
        getInterface(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getInterfaces(), nameOrFindFunction);
        }
        getInterfaceOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getInterface(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("interface", nameOrFindFunction));
        }
        addModule(structure) {
            return this.addModules([structure])[0];
        }
        addModules(structures) {
            return this.insertModules(this._getCompilerStatementsWithComments().length, structures);
        }
        insertModule(index, structure) {
            return this.insertModules(index, [structure])[0];
        }
        insertModules(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.ModuleDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forModuleDeclaration({ isAmbient: isNodeAmbientOrInAmbientContext(this) })
                            .printTexts(writer, structures);
                    });
                },
            });
        }
        getModules() {
            return this.getStatements().filter(Node.isModuleDeclaration);
        }
        getModule(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getModules(), nameOrFindFunction);
        }
        getModuleOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getModule(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("namespace", nameOrFindFunction));
        }
        addTypeAlias(structure) {
            return this.addTypeAliases([structure])[0];
        }
        addTypeAliases(structures) {
            return this.insertTypeAliases(this._getCompilerStatementsWithComments().length, structures);
        }
        insertTypeAlias(index, structure) {
            return this.insertTypeAliases(index, [structure])[0];
        }
        insertTypeAliases(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.TypeAliasDeclaration,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forTypeAliasDeclaration().printTexts(writer, structures);
                    }, {
                        previousNewLine: previousMember => Node.isTypeAliasDeclaration(previousMember),
                        nextNewLine: nextMember => Node.isTypeAliasDeclaration(nextMember),
                    });
                },
            });
        }
        getTypeAliases() {
            return this.getStatements().filter(Node.isTypeAliasDeclaration);
        }
        getTypeAlias(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getTypeAliases(), nameOrFindFunction);
        }
        getTypeAliasOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getTypeAlias(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("type alias", nameOrFindFunction));
        }
        getVariableStatements() {
            return this.getStatements().filter(Node.isVariableStatement);
        }
        getVariableStatement(nameOrFindFunction) {
            return this.getVariableStatements().find(getFindFunction());
            function getFindFunction() {
                if (typeof nameOrFindFunction === "string")
                    return (statement) => statement.getDeclarations().some(d => nodeHasName(d, nameOrFindFunction));
                return nameOrFindFunction;
            }
        }
        getVariableStatementOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getVariableStatement(nameOrFindFunction), "Expected to find a variable statement that matched the provided condition.");
        }
        addVariableStatement(structure) {
            return this.addVariableStatements([structure])[0];
        }
        addVariableStatements(structures) {
            return this.insertVariableStatements(this._getCompilerStatementsWithComments().length, structures);
        }
        insertVariableStatement(index, structure) {
            return this.insertVariableStatements(index, [structure])[0];
        }
        insertVariableStatements(index, structures) {
            return this._insertChildren({
                expectedKind: common.SyntaxKind.VariableStatement,
                index,
                structures,
                write: (writer, info) => {
                    this._standardWrite(writer, info, () => {
                        this._context.structurePrinterFactory.forVariableStatement().printTexts(writer, structures);
                    }, {
                        previousNewLine: previousMember => Node.isVariableStatement(previousMember),
                        nextNewLine: nextMember => Node.isVariableStatement(nextMember),
                    });
                },
            });
        }
        getVariableDeclarations() {
            const variables = [];
            for (const list of this.getVariableStatements())
                variables.push(...list.getDeclarations());
            return variables;
        }
        getVariableDeclaration(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getVariableDeclarations(), nameOrFindFunction);
        }
        getVariableDeclarationOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getVariableDeclaration(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("variable declaration", nameOrFindFunction));
        }
        getStructure() {
            const structure = {};
            if (Node.isBodyableNode(this) && !this.hasBody())
                structure.statements = undefined;
            else {
                structure.statements = this.getStatements().map(s => {
                    if (Node._hasStructure(s))
                        return s.getStructure();
                    return s.getText({ trimLeadingIndentation: true });
                });
            }
            return callBaseGetStructure(Base.prototype, this, structure);
        }
        set(structure) {
            if (Node.isBodyableNode(this) && structure.statements == null && structure.hasOwnProperty("statements"))
                this.removeBody();
            else if (structure.statements != null) {
                const statementCount = this._getCompilerStatementsWithComments().length;
                if (statementCount > 0)
                    this.removeStatements([0, statementCount - 1]);
            }
            callBaseSet(Base.prototype, this, structure);
            if (structure.statements != null)
                this.addStatements(structure.statements);
            return this;
        }
        _getCompilerStatementsWithComments() {
            const statementsContainer = this._getCompilerStatementsContainer();
            if (statementsContainer == null)
                return [];
            else {
                return ExtendedParser.getContainerArray(statementsContainer, this._sourceFile.compilerNode);
            }
        }
        _getCompilerStatementsContainer() {
            var _a;
            if (Node.isSourceFile(this) || Node.isCaseClause(this) || Node.isDefaultClause(this))
                return this.compilerNode;
            else if (Node.isModuleDeclaration(this)) {
                const body = this._getInnerBody();
                if (body == null)
                    return undefined;
                else
                    return body.compilerNode;
            }
            else if (Node.isBodyableNode(this) || Node.isBodiedNode(this))
                return (_a = this.getBody()) === null || _a === void 0 ? void 0 : _a.compilerNode;
            else if (Node.isBlock(this) || Node.isModuleBlock(this))
                return this.compilerNode;
            else
                throw new common.errors.NotImplementedError(`Could not find the statements for node kind: ${this.getKindName()}, text: ${this.getText()}`);
        }
        _insertChildren(opts) {
            addBodyIfNotExists(this);
            return insertIntoBracesOrSourceFileWithGetChildren({
                expectedKind: opts.expectedKind,
                getIndexedChildren: () => this.getStatementsWithComments(),
                index: opts.index,
                parent: this,
                structures: opts.structures,
                write: (writer, info) => opts.write(writer, info),
            });
        }
        _standardWrite(writer, info, writeStructures, opts = {}) {
            if (info.previousMember != null && (opts.previousNewLine == null || !opts.previousNewLine(info.previousMember))
                && !Node.isCommentNode(info.previousMember)) {
                writer.blankLine();
            }
            else if (!info.isStartOfFile) {
                writer.newLineIfLastNot();
            }
            writeStructures();
            if (info.nextMember != null && (opts.nextNewLine == null || !opts.nextNewLine(info.nextMember)))
                writer.blankLine();
            else
                writer.newLineIfLastNot();
        }
    };
}
function addBodyIfNotExists(node) {
    if (Node.isBodyableNode(node) && !node.hasBody())
        node.addBody();
}

const createBase$u = (ctor) => TextInsertableNode(StatementedNode(ctor));
const BlockBase = createBase$u(Statement);
class Block extends BlockBase {
}

class BreakStatement extends Statement {
    getLabel() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.label);
    }
    getLabelOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getLabel(), "Expected to find a label.");
    }
}

const CaseBlockBase = TextInsertableNode(Node);
class CaseBlock extends CaseBlockBase {
    getClauses() {
        const clauses = this.compilerNode.clauses || [];
        return clauses.map(s => this._getNodeFromCompilerNode(s));
    }
    removeClause(index) {
        index = verifyAndGetIndex(index, this.getClauses().length - 1);
        return this.removeClauses([index, index]);
    }
    removeClauses(indexRange) {
        const clauses = this.getClauses();
        common.errors.throwIfRangeOutOfRange(indexRange, [0, clauses.length], "indexRange");
        removeClausedNodeChildren(clauses.slice(indexRange[0], indexRange[1] + 1));
        return this;
    }
}

const createBase$t = (ctor) => ExpressionedNode(TextInsertableNode(StatementedNode(ctor)));
const CaseClauseBase = createBase$t(Node);
class CaseClause extends CaseClauseBase {
    remove() {
        removeClausedNodeChild(this);
    }
}

const CatchClauseBase = Node;
class CatchClause extends CatchClauseBase {
    getBlock() {
        return this._getNodeFromCompilerNode(this.compilerNode.block);
    }
    getVariableDeclaration() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.variableDeclaration);
    }
    getVariableDeclarationOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getVariableDeclaration(), "Expected to find a variable declaration.");
    }
}

class CommentStatement extends Statement {
}

class ContinueStatement extends Statement {
    getLabel() {
        return this.compilerNode.label == null
            ? undefined
            : this._getNodeFromCompilerNode(this.compilerNode.label);
    }
    getLabelOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getLabel(), "Expected to find a label.");
    }
}

const DebuggerStatementBase = Statement;
class DebuggerStatement extends DebuggerStatementBase {
}

const createBase$s = (ctor) => TextInsertableNode(StatementedNode(ctor));
const DefaultClauseBase = createBase$s(Node);
class DefaultClause extends DefaultClauseBase {
    remove() {
        removeClausedNodeChild(this);
    }
}

class IterationStatement extends Statement {
    getStatement() {
        return this._getNodeFromCompilerNode(this.compilerNode.statement);
    }
}

const DoStatementBase = ExpressionedNode(IterationStatement);
class DoStatement extends DoStatementBase {
}

const EmptyStatementBase = Statement;
class EmptyStatement extends EmptyStatementBase {
}

const ExpressionStatementBase = ExpressionedNode(JSDocableNode(Statement));
class ExpressionStatement extends ExpressionStatementBase {
}

const ForInStatementBase = ExpressionedNode(IterationStatement);
class ForInStatement extends ForInStatementBase {
    getInitializer() {
        return this._getNodeFromCompilerNode(this.compilerNode.initializer);
    }
}

const ForOfStatementBase = ExpressionedNode(AwaitableNode(IterationStatement));
class ForOfStatement extends ForOfStatementBase {
    getInitializer() {
        return this._getNodeFromCompilerNode(this.compilerNode.initializer);
    }
}

const ForStatementBase = IterationStatement;
class ForStatement extends ForStatementBase {
    getInitializer() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.initializer);
    }
    getInitializerOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getInitializer(), "Expected to find an initializer.");
    }
    getCondition() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.condition);
    }
    getConditionOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getCondition(), "Expected to find a condition.");
    }
    getIncrementor() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.incrementor);
    }
    getIncrementorOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getIncrementor(), "Expected to find an incrementor.");
    }
}

const IfStatementBase = ExpressionedNode(Statement);
class IfStatement extends IfStatementBase {
    getThenStatement() {
        return this._getNodeFromCompilerNode(this.compilerNode.thenStatement);
    }
    getElseStatement() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.elseStatement);
    }
    remove() {
        const nodes = [];
        if (Node.isIfStatement(this.getParentOrThrow()))
            nodes.push(this.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.ElseKeyword));
        nodes.push(this);
        removeStatementedNodeChildren(nodes);
    }
}

const LabeledStatementBase = JSDocableNode(Statement);
class LabeledStatement extends LabeledStatementBase {
    getLabel() {
        return this._getNodeFromCompilerNode(this.compilerNode.label);
    }
    getStatement() {
        return this._getNodeFromCompilerNode(this.compilerNode.statement);
    }
}

const NotEmittedStatementBase = Statement;
class NotEmittedStatement extends NotEmittedStatementBase {
}

const ReturnStatementBase = ExpressionableNode(Statement);
class ReturnStatement extends ReturnStatementBase {
}

const SwitchStatementBase = ExpressionedNode(Statement);
class SwitchStatement extends SwitchStatementBase {
    getCaseBlock() {
        return this._getNodeFromCompilerNode(this.compilerNode.caseBlock);
    }
    getClauses() {
        return this.getCaseBlock().getClauses();
    }
    removeClause(index) {
        return this.getCaseBlock().removeClause(index);
    }
    removeClauses(indexRange) {
        return this.getCaseBlock().removeClauses(indexRange);
    }
}

const ThrowStatementBase = ExpressionedNode(Statement);
class ThrowStatement extends ThrowStatementBase {
}

const TryStatementBase = Statement;
class TryStatement extends TryStatementBase {
    getTryBlock() {
        return this._getNodeFromCompilerNode(this.compilerNode.tryBlock);
    }
    getCatchClause() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.catchClause);
    }
    getCatchClauseOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getCatchClause(), "Expected to find a catch clause.");
    }
    getFinallyBlock() {
        if (this.compilerNode.finallyBlock == null || this.compilerNode.finallyBlock.getFullWidth() === 0)
            return undefined;
        return this._getNodeFromCompilerNode(this.compilerNode.finallyBlock);
    }
    getFinallyBlockOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getFinallyBlock(), "Expected to find a finally block.");
    }
}

const ExportAssignmentBase = ExpressionedNode(Statement);
class ExportAssignment extends ExportAssignmentBase {
    isExportEquals() {
        return this.compilerNode.isExportEquals || false;
    }
    setIsExportEquals(value) {
        if (this.isExportEquals() === value)
            return this;
        if (value)
            this.getFirstChildByKindOrThrow(common.SyntaxKind.DefaultKeyword).replaceWithText("=");
        else
            this.getFirstChildByKindOrThrow(common.SyntaxKind.EqualsToken).replaceWithText("default");
        return this;
    }
    set(structure) {
        callBaseSet(ExportAssignmentBase.prototype, this, structure);
        if (structure.expression != null)
            this.setExpression(structure.expression);
        if (structure.isExportEquals != null)
            this.setIsExportEquals(structure.isExportEquals);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(Statement.prototype, this, {
            kind: exports.StructureKind.ExportAssignment,
            expression: this.getExpression().getText(),
            isExportEquals: this.isExportEquals(),
        });
    }
}

const ExportDeclarationBase = Statement;
class ExportDeclaration extends ExportDeclarationBase {
    isTypeOnly() {
        return this.compilerNode.isTypeOnly;
    }
    setIsTypeOnly(value) {
        var _a;
        if (this.isTypeOnly() === value)
            return this;
        if (value) {
            insertIntoParentTextRange({
                parent: this,
                insertPos: ((_a = this.getNodeProperty("exportClause")) !== null && _a !== void 0 ? _a : this.getFirstChildByKindOrThrow(common.SyntaxKind.AsteriskToken)).getStart(),
                newText: "type ",
            });
        }
        else {
            const typeKeyword = this.getFirstChildByKindOrThrow(common.ts.SyntaxKind.TypeKeyword);
            removeChildren({
                children: [typeKeyword],
                removeFollowingSpaces: true,
            });
        }
        return this;
    }
    getNamespaceExport() {
        const exportClause = this.getNodeProperty("exportClause");
        return exportClause != null && Node.isNamespaceExport(exportClause) ? exportClause : undefined;
    }
    getNamespaceExportOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getNamespaceExport(), "Expected to find a namespace export.");
    }
    setNamespaceExport(name) {
        const exportClause = this.getNodeProperty("exportClause");
        const newText = common.StringUtils.isNullOrWhitespace(name) ? "*" : `* as ${name}`;
        if (exportClause == null) {
            const asteriskToken = this.getFirstChildByKindOrThrow(common.SyntaxKind.AsteriskToken);
            insertIntoParentTextRange({
                insertPos: asteriskToken.getStart(),
                parent: this,
                newText,
                replacing: {
                    textLength: 1,
                },
            });
        }
        else if (Node.isNamespaceExport(exportClause))
            exportClause.getNameNode().replaceWithText(name);
        else {
            insertIntoParentTextRange({
                insertPos: exportClause.getStart(),
                parent: this,
                newText,
                replacing: {
                    textLength: exportClause.getWidth(),
                },
            });
        }
        return this;
    }
    setModuleSpecifier(textOrSourceFile) {
        const text = typeof textOrSourceFile === "string" ? textOrSourceFile : this._sourceFile.getRelativePathAsModuleSpecifierTo(textOrSourceFile);
        if (common.StringUtils.isNullOrEmpty(text)) {
            this.removeModuleSpecifier();
            return this;
        }
        const stringLiteral = this.getModuleSpecifier();
        if (stringLiteral == null) {
            const semiColonToken = this.getLastChildIfKind(common.SyntaxKind.SemicolonToken);
            const quoteKind = this._context.manipulationSettings.getQuoteKind();
            insertIntoParentTextRange({
                insertPos: semiColonToken != null ? semiColonToken.getPos() : this.getEnd(),
                parent: this,
                newText: ` from ${quoteKind}${text}${quoteKind}`,
            });
        }
        else {
            stringLiteral.setLiteralValue(text);
        }
        return this;
    }
    getModuleSpecifier() {
        const moduleSpecifier = this._getNodeFromCompilerNodeIfExists(this.compilerNode.moduleSpecifier);
        if (moduleSpecifier == null)
            return undefined;
        if (!Node.isStringLiteral(moduleSpecifier))
            throw new common.errors.InvalidOperationError("Expected the module specifier to be a string literal.");
        return moduleSpecifier;
    }
    getModuleSpecifierValue() {
        const moduleSpecifier = this.getModuleSpecifier();
        return moduleSpecifier === null || moduleSpecifier === void 0 ? void 0 : moduleSpecifier.getLiteralValue();
    }
    getModuleSpecifierSourceFileOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getModuleSpecifierSourceFile(), `A module specifier source file was expected.`);
    }
    getModuleSpecifierSourceFile() {
        const stringLiteral = this.getLastChildByKind(common.SyntaxKind.StringLiteral);
        if (stringLiteral == null)
            return undefined;
        const symbol = stringLiteral.getSymbol();
        if (symbol == null)
            return undefined;
        const declaration = symbol.getDeclarations()[0];
        return declaration != null && Node.isSourceFile(declaration) ? declaration : undefined;
    }
    isModuleSpecifierRelative() {
        const moduleSpecifierValue = this.getModuleSpecifierValue();
        if (moduleSpecifierValue == null)
            return false;
        return ModuleUtils.isModuleSpecifierRelative(moduleSpecifierValue);
    }
    removeModuleSpecifier() {
        const moduleSpecifier = this.getModuleSpecifier();
        if (moduleSpecifier == null)
            return this;
        if (!this.hasNamedExports())
            throw new common.errors.InvalidOperationError(`Cannot remove the module specifier from an export declaration that has no named exports.`);
        removeChildren({
            children: [this.getFirstChildByKindOrThrow(common.SyntaxKind.FromKeyword), moduleSpecifier],
            removePrecedingNewLines: true,
            removePrecedingSpaces: true,
        });
        return this;
    }
    hasModuleSpecifier() {
        return this.getLastChildByKind(common.SyntaxKind.StringLiteral) != null;
    }
    isNamespaceExport() {
        return !this.hasNamedExports();
    }
    hasNamedExports() {
        var _a;
        return ((_a = this.compilerNode.exportClause) === null || _a === void 0 ? void 0 : _a.kind) === common.SyntaxKind.NamedExports;
    }
    addNamedExport(namedExport) {
        return this.addNamedExports([namedExport])[0];
    }
    addNamedExports(namedExports) {
        return this.insertNamedExports(this.getNamedExports().length, namedExports);
    }
    insertNamedExport(index, namedExport) {
        return this.insertNamedExports(index, [namedExport])[0];
    }
    insertNamedExports(index, namedExports) {
        if (!(namedExports instanceof Function) && common.ArrayUtils.isNullOrEmpty(namedExports))
            return [];
        const originalNamedExports = this.getNamedExports();
        const writer = this._getWriterWithIndentation();
        const namedExportStructurePrinter = this._context.structurePrinterFactory.forNamedImportExportSpecifier();
        index = verifyAndGetIndex(index, originalNamedExports.length);
        const exportClause = this.getNodeProperty("exportClause");
        if (exportClause == null) {
            namedExportStructurePrinter.printTextsWithBraces(writer, namedExports);
            const asteriskToken = this.getFirstChildByKindOrThrow(common.SyntaxKind.AsteriskToken);
            insertIntoParentTextRange({
                insertPos: asteriskToken.getStart(),
                parent: this,
                newText: writer.toString(),
                replacing: {
                    textLength: 1,
                },
            });
        }
        else if (exportClause.getKind() === common.SyntaxKind.NamespaceExport) {
            namedExportStructurePrinter.printTextsWithBraces(writer, namedExports);
            insertIntoParentTextRange({
                insertPos: exportClause.getStart(),
                parent: this,
                newText: writer.toString(),
                replacing: {
                    textLength: exportClause.getWidth(),
                },
            });
        }
        else {
            namedExportStructurePrinter.printTexts(writer, namedExports);
            insertIntoCommaSeparatedNodes({
                parent: this.getFirstChildByKindOrThrow(common.SyntaxKind.NamedExports).getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
                currentNodes: originalNamedExports,
                insertIndex: index,
                newText: writer.toString(),
                surroundWithSpaces: this._context.getFormatCodeSettings().insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces,
                useTrailingCommas: false,
            });
        }
        const newNamedExports = this.getNamedExports();
        return getNodesToReturn(originalNamedExports, newNamedExports, index, false);
    }
    getNamedExports() {
        const namedExports = this.compilerNode.exportClause;
        if (namedExports == null || common.ts.isNamespaceExport(namedExports))
            return [];
        return namedExports.elements.map(e => this._getNodeFromCompilerNode(e));
    }
    toNamespaceExport() {
        if (!this.hasModuleSpecifier())
            throw new common.errors.InvalidOperationError("Cannot change to a namespace export when no module specifier exists.");
        const namedExportsNode = this.getNodeProperty("exportClause");
        if (namedExportsNode == null)
            return this;
        insertIntoParentTextRange({
            parent: this,
            newText: "*",
            insertPos: namedExportsNode.getStart(),
            replacing: {
                textLength: namedExportsNode.getWidth(),
            },
        });
        return this;
    }
    set(structure) {
        callBaseSet(ExportDeclarationBase.prototype, this, structure);
        if (structure.namedExports != null) {
            setEmptyNamedExport(this);
            this.addNamedExports(structure.namedExports);
        }
        else if (structure.hasOwnProperty("namedExports") && structure.moduleSpecifier == null) {
            this.toNamespaceExport();
        }
        if (structure.moduleSpecifier != null)
            this.setModuleSpecifier(structure.moduleSpecifier);
        else if (structure.hasOwnProperty("moduleSpecifier"))
            this.removeModuleSpecifier();
        if (structure.namedExports == null && structure.hasOwnProperty("namedExports"))
            this.toNamespaceExport();
        if (structure.namespaceExport != null)
            this.setNamespaceExport(structure.namespaceExport);
        if (structure.isTypeOnly != null)
            this.setIsTypeOnly(structure.isTypeOnly);
        return this;
    }
    getStructure() {
        var _a;
        const moduleSpecifier = this.getModuleSpecifier();
        return callBaseGetStructure(ExportDeclarationBase.prototype, this, {
            kind: exports.StructureKind.ExportDeclaration,
            isTypeOnly: this.isTypeOnly(),
            moduleSpecifier: moduleSpecifier === null || moduleSpecifier === void 0 ? void 0 : moduleSpecifier.getLiteralText(),
            namedExports: this.getNamedExports().map(node => node.getStructure()),
            namespaceExport: (_a = this.getNamespaceExport()) === null || _a === void 0 ? void 0 : _a.getName(),
        });
    }
}
function setEmptyNamedExport(node) {
    const namedExportsNode = node.getNodeProperty("exportClause");
    let replaceNode;
    if (namedExportsNode != null) {
        if (node.getNamedExports().length === 0)
            return;
        replaceNode = namedExportsNode;
    }
    else {
        replaceNode = node.getFirstChildByKindOrThrow(common.SyntaxKind.AsteriskToken);
    }
    insertIntoParentTextRange({
        parent: node,
        newText: "{ }",
        insertPos: replaceNode.getStart(),
        replacing: {
            textLength: replaceNode.getWidth(),
        },
    });
}

const ExportSpecifierBase = Node;
class ExportSpecifier extends ExportSpecifierBase {
    setName(name) {
        const nameNode = this.getNameNode();
        if (nameNode.getText() === name)
            return this;
        nameNode.replaceWithText(name);
        return this;
    }
    getName() {
        return this.getNameNode().getText();
    }
    getNameNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.propertyName || this.compilerNode.name);
    }
    renameAlias(alias) {
        if (common.StringUtils.isNullOrWhitespace(alias)) {
            this.removeAliasWithRename();
            return this;
        }
        let aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null) {
            this.setAlias(this.getName());
            aliasIdentifier = this.getAliasNode();
        }
        aliasIdentifier.rename(alias);
        return this;
    }
    setAlias(alias) {
        if (common.StringUtils.isNullOrWhitespace(alias)) {
            this.removeAlias();
            return this;
        }
        const aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null) {
            insertIntoParentTextRange({
                insertPos: this.getNameNode().getEnd(),
                parent: this,
                newText: ` as ${alias}`,
            });
        }
        else {
            aliasIdentifier.replaceWithText(alias);
        }
        return this;
    }
    removeAlias() {
        const aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null)
            return this;
        removeChildren({
            children: [this.getFirstChildByKindOrThrow(common.SyntaxKind.AsKeyword), aliasIdentifier],
            removePrecedingSpaces: true,
            removePrecedingNewLines: true,
        });
        return this;
    }
    removeAliasWithRename() {
        const aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null)
            return this;
        aliasIdentifier.rename(this.getName());
        this.removeAlias();
        return this;
    }
    getAliasNode() {
        if (this.compilerNode.propertyName == null)
            return undefined;
        return this._getNodeFromCompilerNode(this.compilerNode.name);
    }
    getExportDeclaration() {
        return this.getFirstAncestorByKindOrThrow(common.SyntaxKind.ExportDeclaration);
    }
    getLocalTargetSymbolOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getLocalTargetSymbol(), `The export specifier's local target symbol was expected.`);
    }
    getLocalTargetSymbol() {
        return this._context.typeChecker.getExportSpecifierLocalTargetSymbol(this);
    }
    getLocalTargetDeclarations() {
        var _a, _b;
        return (_b = (_a = this.getLocalTargetSymbol()) === null || _a === void 0 ? void 0 : _a.getDeclarations()) !== null && _b !== void 0 ? _b : [];
    }
    remove() {
        const exportDeclaration = this.getExportDeclaration();
        const exports = exportDeclaration.getNamedExports();
        if (exports.length > 1)
            removeCommaSeparatedChild(this);
        else if (exportDeclaration.hasModuleSpecifier())
            exportDeclaration.toNamespaceExport();
        else
            exportDeclaration.remove();
    }
    set(structure) {
        callBaseSet(ExportSpecifierBase.prototype, this, structure);
        if (structure.name != null)
            this.setName(structure.name);
        if (structure.alias != null)
            this.setAlias(structure.alias);
        else if (structure.hasOwnProperty("alias"))
            this.removeAlias();
        return this;
    }
    getStructure() {
        const alias = this.getAliasNode();
        return callBaseGetStructure(Node.prototype, this, {
            kind: exports.StructureKind.ExportSpecifier,
            alias: alias ? alias.getText() : undefined,
            name: this.getNameNode().getText(),
        });
    }
}

const ExternalModuleReferenceBase = ExpressionableNode(Node);
class ExternalModuleReference extends ExternalModuleReferenceBase {
    getReferencedSourceFileOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getReferencedSourceFile(), "Expected to find the referenced source file.");
    }
    isRelative() {
        const expression = this.getExpression();
        if (expression == null || !Node.isStringLiteral(expression))
            return false;
        return ModuleUtils.isModuleSpecifierRelative(expression.getLiteralText());
    }
    getReferencedSourceFile() {
        const expression = this.getExpression();
        if (expression == null)
            return undefined;
        const symbol = expression.getSymbol();
        if (symbol == null)
            return undefined;
        return ModuleUtils.getReferencedSourceFileFromSymbol(symbol);
    }
}

const ImportClauseBase = Node;
class ImportClause extends ImportClauseBase {
    isTypeOnly() {
        return this.compilerNode.isTypeOnly;
    }
    setIsTypeOnly(value) {
        if (this.isTypeOnly() === value)
            return this;
        if (value) {
            insertIntoParentTextRange({
                parent: this,
                insertPos: this.getStart(),
                newText: "type ",
            });
        }
        else {
            const typeKeyword = this.getFirstChildByKindOrThrow(common.ts.SyntaxKind.TypeKeyword);
            removeChildren({
                children: [typeKeyword],
                removeFollowingSpaces: true,
            });
        }
        return this;
    }
    getDefaultImportOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getDefaultImport(), "Expected to find a default import.");
    }
    getDefaultImport() {
        return this.getNodeProperty("name");
    }
    getNamedBindingsOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getNamedBindings(), "Expected to find an import declaration's named bindings.");
    }
    getNamedBindings() {
        return this.getNodeProperty("namedBindings");
    }
    getNamespaceImportOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getNamespaceImport(), "Expected to find a namespace import.");
    }
    getNamespaceImport() {
        const namedBindings = this.getNamedBindings();
        if (namedBindings == null || !Node.isNamespaceImport(namedBindings))
            return undefined;
        return namedBindings.getNameNode();
    }
    getNamedImports() {
        const namedBindings = this.getNamedBindings();
        if (namedBindings == null || !Node.isNamedImports(namedBindings))
            return [];
        return namedBindings.getElements();
    }
}

const ImportDeclarationBase = Statement;
class ImportDeclaration extends ImportDeclarationBase {
    isTypeOnly() {
        var _a, _b;
        return (_b = (_a = this.getImportClause()) === null || _a === void 0 ? void 0 : _a.isTypeOnly()) !== null && _b !== void 0 ? _b : false;
    }
    setIsTypeOnly(value) {
        const importClause = this.getImportClause();
        if (importClause == null) {
            if (!value)
                return this;
            else
                throw new common.errors.InvalidOperationError("Cannot set an import as type only when there is no import clause.");
        }
        importClause.setIsTypeOnly(value);
        return this;
    }
    setModuleSpecifier(textOrSourceFile) {
        const text = typeof textOrSourceFile === "string" ? textOrSourceFile : this._sourceFile.getRelativePathAsModuleSpecifierTo(textOrSourceFile);
        this.getModuleSpecifier().setLiteralValue(text);
        return this;
    }
    getModuleSpecifier() {
        const moduleSpecifier = this._getNodeFromCompilerNode(this.compilerNode.moduleSpecifier);
        if (!Node.isStringLiteral(moduleSpecifier))
            throw new common.errors.InvalidOperationError("Expected the module specifier to be a string literal.");
        return moduleSpecifier;
    }
    getModuleSpecifierValue() {
        return this.getModuleSpecifier().getLiteralValue();
    }
    getModuleSpecifierSourceFileOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getModuleSpecifierSourceFile(), `A module specifier source file was expected.`);
    }
    getModuleSpecifierSourceFile() {
        const symbol = this.getModuleSpecifier().getSymbol();
        if (symbol == null)
            return undefined;
        return ModuleUtils.getReferencedSourceFileFromSymbol(symbol);
    }
    isModuleSpecifierRelative() {
        return ModuleUtils.isModuleSpecifierRelative(this.getModuleSpecifierValue());
    }
    setDefaultImport(text) {
        if (common.StringUtils.isNullOrWhitespace(text))
            return this.removeDefaultImport();
        const defaultImport = this.getDefaultImport();
        if (defaultImport != null) {
            defaultImport.replaceWithText(text);
            return this;
        }
        const importKeyword = this.getFirstChildByKindOrThrow(common.SyntaxKind.ImportKeyword);
        const importClause = this.getImportClause();
        if (importClause == null) {
            insertIntoParentTextRange({
                insertPos: importKeyword.getEnd(),
                parent: this,
                newText: ` ${text} from`,
            });
            return this;
        }
        insertIntoParentTextRange({
            insertPos: importKeyword.getEnd(),
            parent: importClause,
            newText: ` ${text},`,
        });
        return this;
    }
    renameDefaultImport(text) {
        if (common.StringUtils.isNullOrWhitespace(text))
            return this.removeDefaultImport();
        const defaultImport = this.getDefaultImport();
        if (defaultImport != null) {
            defaultImport.rename(text);
            return this;
        }
        this.setDefaultImport(text);
        return this;
    }
    getDefaultImportOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getDefaultImport(), "Expected to find a default import.");
    }
    getDefaultImport() {
        var _a, _b;
        return (_b = (_a = this.getImportClause()) === null || _a === void 0 ? void 0 : _a.getDefaultImport()) !== null && _b !== void 0 ? _b : undefined;
    }
    setNamespaceImport(text) {
        if (common.StringUtils.isNullOrWhitespace(text))
            return this.removeNamespaceImport();
        const namespaceImport = this.getNamespaceImport();
        if (namespaceImport != null) {
            namespaceImport.rename(text);
            return this;
        }
        if (this.getNamedImports().length > 0)
            throw new common.errors.InvalidOperationError("Cannot add a namespace import to an import declaration that has named imports.");
        const defaultImport = this.getDefaultImport();
        if (defaultImport != null) {
            insertIntoParentTextRange({
                insertPos: defaultImport.getEnd(),
                parent: this.getImportClause(),
                newText: `, * as ${text}`,
            });
            return this;
        }
        insertIntoParentTextRange({
            insertPos: this.getFirstChildByKindOrThrow(common.SyntaxKind.ImportKeyword).getEnd(),
            parent: this,
            newText: ` * as ${text} from`,
        });
        return this;
    }
    removeNamespaceImport() {
        const namespaceImport = this.getNamespaceImport();
        if (namespaceImport == null)
            return this;
        removeChildren({
            children: getChildrenToRemove.call(this),
            removePrecedingSpaces: true,
            removePrecedingNewLines: true,
        });
        return this;
        function getChildrenToRemove() {
            const defaultImport = this.getDefaultImport();
            if (defaultImport == null)
                return [this.getImportClauseOrThrow(), this.getLastChildByKindOrThrow(common.SyntaxKind.FromKeyword)];
            else
                return [defaultImport.getNextSiblingIfKindOrThrow(common.SyntaxKind.CommaToken), namespaceImport];
        }
    }
    removeDefaultImport() {
        const importClause = this.getImportClause();
        if (importClause == null)
            return this;
        const defaultImport = importClause.getDefaultImport();
        if (defaultImport == null)
            return this;
        const hasOnlyDefaultImport = importClause.getChildCount() === 1;
        if (hasOnlyDefaultImport) {
            removeChildren({
                children: [importClause, importClause.getNextSiblingIfKindOrThrow(common.SyntaxKind.FromKeyword)],
                removePrecedingSpaces: true,
                removePrecedingNewLines: true,
            });
        }
        else {
            removeChildren({
                children: [defaultImport, defaultImport.getNextSiblingIfKindOrThrow(common.SyntaxKind.CommaToken)],
                removePrecedingSpaces: true,
                removePrecedingNewLines: true,
            });
        }
        return this;
    }
    getNamespaceImportOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getNamespaceImport(), "Expected to find a namespace import.");
    }
    getNamespaceImport() {
        var _a, _b;
        return (_b = (_a = this.getImportClause()) === null || _a === void 0 ? void 0 : _a.getNamespaceImport()) !== null && _b !== void 0 ? _b : undefined;
    }
    addNamedImport(namedImport) {
        return this.addNamedImports([namedImport])[0];
    }
    addNamedImports(namedImports) {
        return this.insertNamedImports(this.getNamedImports().length, namedImports);
    }
    insertNamedImport(index, namedImport) {
        return this.insertNamedImports(index, [namedImport])[0];
    }
    insertNamedImports(index, namedImports) {
        if (!(namedImports instanceof Function) && common.ArrayUtils.isNullOrEmpty(namedImports))
            return [];
        const originalNamedImports = this.getNamedImports();
        const writer = this._getWriterWithQueuedIndentation();
        const namedImportStructurePrinter = this._context.structurePrinterFactory.forNamedImportExportSpecifier();
        const importClause = this.getImportClause();
        index = verifyAndGetIndex(index, originalNamedImports.length);
        if (originalNamedImports.length === 0) {
            namedImportStructurePrinter.printTextsWithBraces(writer, namedImports);
            if (importClause == null) {
                insertIntoParentTextRange({
                    insertPos: this.getFirstChildByKindOrThrow(common.SyntaxKind.ImportKeyword).getEnd(),
                    parent: this,
                    newText: ` ${writer.toString()} from`,
                });
            }
            else if (this.getNamespaceImport() != null)
                throw getErrorWhenNamespaceImportsExist();
            else if (importClause.getNamedBindings() != null) {
                const namedBindings = importClause.getNamedBindingsOrThrow();
                insertIntoParentTextRange({
                    insertPos: namedBindings.getStart(),
                    replacing: {
                        textLength: namedBindings.getWidth(),
                    },
                    parent: importClause,
                    newText: writer.toString(),
                });
            }
            else {
                insertIntoParentTextRange({
                    insertPos: this.getDefaultImport().getEnd(),
                    parent: importClause,
                    newText: `, ${writer.toString()}`,
                });
            }
        }
        else {
            if (importClause == null)
                throw new common.errors.NotImplementedError("Expected to have an import clause.");
            namedImportStructurePrinter.printTexts(writer, namedImports);
            insertIntoCommaSeparatedNodes({
                parent: importClause.getFirstChildByKindOrThrow(common.SyntaxKind.NamedImports).getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
                currentNodes: originalNamedImports,
                insertIndex: index,
                newText: writer.toString(),
                surroundWithSpaces: this._context.getFormatCodeSettings().insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces,
                useTrailingCommas: false,
            });
        }
        const newNamedImports = this.getNamedImports();
        return getNodesToReturn(originalNamedImports, newNamedImports, index, false);
    }
    getNamedImports() {
        var _a, _b;
        return (_b = (_a = this.getImportClause()) === null || _a === void 0 ? void 0 : _a.getNamedImports()) !== null && _b !== void 0 ? _b : [];
    }
    removeNamedImports() {
        const importClause = this.getImportClause();
        if (importClause == null)
            return this;
        const namedImportsNode = importClause.getNamedBindings();
        if (namedImportsNode == null || namedImportsNode.getKind() !== common.SyntaxKind.NamedImports)
            return this;
        const defaultImport = this.getDefaultImport();
        if (defaultImport != null) {
            const commaToken = defaultImport.getNextSiblingIfKindOrThrow(common.SyntaxKind.CommaToken);
            removeChildren({ children: [commaToken, namedImportsNode] });
            return this;
        }
        const fromKeyword = importClause.getNextSiblingIfKindOrThrow(common.SyntaxKind.FromKeyword);
        removeChildren({ children: [importClause, fromKeyword], removePrecedingSpaces: true });
        return this;
    }
    getImportClauseOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getImportClause(), "Expected to find an import clause.");
    }
    getImportClause() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.importClause);
    }
    set(structure) {
        callBaseSet(ImportDeclarationBase.prototype, this, structure);
        if (structure.defaultImport != null)
            this.setDefaultImport(structure.defaultImport);
        else if (structure.hasOwnProperty("defaultImport"))
            this.removeDefaultImport();
        if (structure.hasOwnProperty("namedImports"))
            this.removeNamedImports();
        if (structure.namespaceImport != null)
            this.setNamespaceImport(structure.namespaceImport);
        else if (structure.hasOwnProperty("namespaceImport"))
            this.removeNamespaceImport();
        if (structure.namedImports != null) {
            setEmptyNamedImport(this);
            this.addNamedImports(structure.namedImports);
        }
        if (structure.moduleSpecifier != null)
            this.setModuleSpecifier(structure.moduleSpecifier);
        if (structure.isTypeOnly != null)
            this.setIsTypeOnly(structure.isTypeOnly);
        return this;
    }
    getStructure() {
        const namespaceImport = this.getNamespaceImport();
        const defaultImport = this.getDefaultImport();
        return callBaseGetStructure(ImportDeclarationBase.prototype, this, {
            kind: exports.StructureKind.ImportDeclaration,
            isTypeOnly: this.isTypeOnly(),
            defaultImport: defaultImport ? defaultImport.getText() : undefined,
            moduleSpecifier: this.getModuleSpecifier().getLiteralText(),
            namedImports: this.getNamedImports().map(node => node.getStructure()),
            namespaceImport: namespaceImport ? namespaceImport.getText() : undefined,
        });
    }
}
function setEmptyNamedImport(node) {
    const importClause = node.getNodeProperty("importClause");
    const writer = node._getWriterWithQueuedChildIndentation();
    const namedImportStructurePrinter = node._context.structurePrinterFactory.forNamedImportExportSpecifier();
    namedImportStructurePrinter.printTextsWithBraces(writer, []);
    const emptyBracesText = writer.toString();
    if (node.getNamespaceImport() != null)
        throw getErrorWhenNamespaceImportsExist();
    if (importClause == null) {
        insertIntoParentTextRange({
            insertPos: node.getFirstChildByKindOrThrow(common.SyntaxKind.ImportKeyword).getEnd(),
            parent: node,
            newText: ` ${emptyBracesText} from`,
        });
        return;
    }
    const replaceNode = importClause.getNamedBindings();
    if (replaceNode != null) {
        insertIntoParentTextRange({
            parent: importClause,
            newText: emptyBracesText,
            insertPos: replaceNode.getStart(),
            replacing: {
                textLength: replaceNode.getWidth(),
            },
        });
        return;
    }
    const defaultImport = importClause.getDefaultImport();
    if (defaultImport != null) {
        insertIntoParentTextRange({
            insertPos: defaultImport.getEnd(),
            parent: importClause,
            newText: `, ${emptyBracesText}`,
        });
        return;
    }
}
function getErrorWhenNamespaceImportsExist() {
    return new common.errors.InvalidOperationError("Cannot add a named import to an import declaration that has a namespace import.");
}

const createBase$r = (ctor) => JSDocableNode(NamedNode(ctor));
const ImportEqualsDeclarationBase = createBase$r(Statement);
class ImportEqualsDeclaration extends ImportEqualsDeclarationBase {
    isTypeOnly() {
        var _a;
        return (_a = this.compilerNode.isTypeOnly) !== null && _a !== void 0 ? _a : false;
    }
    setIsTypeOnly(value) {
        if (this.isTypeOnly() === value)
            return this;
        if (value) {
            insertIntoParentTextRange({
                parent: this,
                insertPos: this.getNameNode().getStart(),
                newText: "type ",
            });
        }
        else {
            const typeKeyword = this.getFirstChildByKindOrThrow(common.ts.SyntaxKind.TypeKeyword);
            removeChildren({
                children: [typeKeyword],
                removeFollowingSpaces: true,
            });
        }
        return this;
    }
    getModuleReference() {
        return this._getNodeFromCompilerNode(this.compilerNode.moduleReference);
    }
    isExternalModuleReferenceRelative() {
        const moduleReference = this.getModuleReference();
        if (!Node.isExternalModuleReference(moduleReference))
            return false;
        return moduleReference.isRelative();
    }
    setExternalModuleReference(textOrSourceFile) {
        const text = typeof textOrSourceFile === "string" ? textOrSourceFile : this._sourceFile.getRelativePathAsModuleSpecifierTo(textOrSourceFile);
        const moduleReference = this.getModuleReference();
        if (Node.isExternalModuleReference(moduleReference) && moduleReference.getExpression() != null)
            moduleReference.getExpressionOrThrow().replaceWithText(writer => writer.quote(text));
        else
            moduleReference.replaceWithText(writer => writer.write("require(").quote(text).write(")"));
        return this;
    }
    getExternalModuleReferenceSourceFileOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getExternalModuleReferenceSourceFile(), "Expected to find an external module reference's referenced source file.");
    }
    getExternalModuleReferenceSourceFile() {
        const moduleReference = this.getModuleReference();
        if (!Node.isExternalModuleReference(moduleReference))
            return undefined;
        return moduleReference.getReferencedSourceFile();
    }
}

const ImportSpecifierBase = Node;
class ImportSpecifier extends ImportSpecifierBase {
    setName(name) {
        const nameNode = this.getNameNode();
        if (nameNode.getText() === name)
            return this;
        nameNode.replaceWithText(name);
        return this;
    }
    getName() {
        return this.getNameNode().getText();
    }
    getNameNode() {
        var _a;
        return this._getNodeFromCompilerNode((_a = this.compilerNode.propertyName) !== null && _a !== void 0 ? _a : this.compilerNode.name);
    }
    renameAlias(alias) {
        if (common.StringUtils.isNullOrWhitespace(alias)) {
            this.removeAliasWithRename();
            return this;
        }
        let aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null) {
            this.setAlias(this.getName());
            aliasIdentifier = this.getAliasNode();
        }
        aliasIdentifier.rename(alias);
        return this;
    }
    setAlias(alias) {
        if (common.StringUtils.isNullOrWhitespace(alias)) {
            this.removeAlias();
            return this;
        }
        const aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null) {
            insertIntoParentTextRange({
                insertPos: this.getNameNode().getEnd(),
                parent: this,
                newText: ` as ${alias}`,
            });
        }
        else {
            aliasIdentifier.replaceWithText(alias);
        }
        return this;
    }
    removeAlias() {
        const aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null)
            return this;
        removeChildren({
            children: [this.getFirstChildByKindOrThrow(common.SyntaxKind.AsKeyword), aliasIdentifier],
            removePrecedingSpaces: true,
            removePrecedingNewLines: true,
        });
        return this;
    }
    removeAliasWithRename() {
        const aliasIdentifier = this.getAliasNode();
        if (aliasIdentifier == null)
            return this;
        aliasIdentifier.rename(this.getName());
        this.removeAlias();
        return this;
    }
    getAliasNode() {
        if (this.compilerNode.propertyName == null)
            return undefined;
        return this._getNodeFromCompilerNode(this.compilerNode.name);
    }
    getImportDeclaration() {
        return this.getFirstAncestorByKindOrThrow(common.SyntaxKind.ImportDeclaration);
    }
    remove() {
        const importDeclaration = this.getImportDeclaration();
        const namedImports = importDeclaration.getNamedImports();
        if (namedImports.length > 1)
            removeCommaSeparatedChild(this);
        else
            importDeclaration.removeNamedImports();
    }
    set(structure) {
        callBaseSet(ImportSpecifierBase.prototype, this, structure);
        if (structure.name != null)
            this.setName(structure.name);
        if (structure.alias != null)
            this.setAlias(structure.alias);
        else if (structure.hasOwnProperty("alias"))
            this.removeAlias();
        return this;
    }
    getStructure() {
        const alias = this.getAliasNode();
        return callBaseGetStructure(ImportSpecifierBase.prototype, this, {
            kind: exports.StructureKind.ImportSpecifier,
            name: this.getName(),
            alias: alias ? alias.getText() : undefined,
        });
    }
}

const ModuleBlockBase = StatementedNode(Statement);
class ModuleBlock extends ModuleBlockBase {
}

function ModuleChildableNode(Base) {
    return class extends Base {
        getParentModuleOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getParentModule(), "Expected to find the parent module declaration.");
        }
        getParentModule() {
            let parent = this.getParentOrThrow();
            if (!Node.isModuleBlock(parent))
                return undefined;
            while (parent.getParentOrThrow().getKind() === common.SyntaxKind.ModuleDeclaration)
                parent = parent.getParentOrThrow();
            return parent;
        }
    };
}

exports.ModuleDeclarationKind = void 0;
(function (ModuleDeclarationKind) {
    ModuleDeclarationKind["Namespace"] = "namespace";
    ModuleDeclarationKind["Module"] = "module";
    ModuleDeclarationKind["Global"] = "global";
})(exports.ModuleDeclarationKind || (exports.ModuleDeclarationKind = {}));

const createBase$q = (ctor) => ModuledNode(UnwrappableNode(TextInsertableNode(BodyableNode(ModuleChildableNode(StatementedNode(JSDocableNode(AmbientableNode(ExportableNode(ModifierableNode(ModuleNamedNode(ctor)))))))))));
const ModuleDeclarationBase = createBase$q(Statement);
class ModuleDeclaration extends ModuleDeclarationBase {
    getName() {
        const nameNodesOrStringLit = this.getNameNodes();
        if (nameNodesOrStringLit instanceof Array)
            return nameNodesOrStringLit.map(n => n.getText()).join(".");
        return nameNodesOrStringLit.getText();
    }
    setName(newName) {
        const openIssueText = `Please open an issue if you really need this and I'll up the priority.`;
        if (newName.indexOf(".") >= 0)
            throw new common.errors.NotImplementedError(`Not implemented to set a namespace name to a name containing a period. ${openIssueText}`);
        const moduleName = this.getNameNodes();
        if (moduleName instanceof Array) {
            if (moduleName.length > 1)
                throw new common.errors.NotImplementedError(`Not implemented to set a namespace name that uses dot notation. ${openIssueText}`);
            if (newName !== "global")
                addNamespaceKeywordIfNecessary(this);
            if (common.StringUtils.isQuoted(newName))
                changeToAmbientModuleIfNecessary(this);
            moduleName[0].replaceWithText(newName);
        }
        else {
            moduleName.replaceWithText(newName);
        }
        return this;
    }
    rename(newName, options) {
        if (newName.indexOf(".") >= 0)
            throw new common.errors.NotSupportedError(`Cannot rename a namespace name to a name containing a period.`);
        const nameNodes = this.getNameNodes();
        if (nameNodes instanceof Array) {
            if (nameNodes.length > 1) {
                throw new common.errors.NotSupportedError(`Cannot rename a namespace name that uses dot notation. Rename the individual nodes via .${"getNameNodes"}()`);
            }
            if (newName !== "global")
                addNamespaceKeywordIfNecessary(this);
            nameNodes[0].rename(newName, options);
        }
        else {
            renameNode(nameNodes, common.StringUtils.stripQuotes(newName), options);
        }
        return this;
    }
    getNameNodes() {
        const name = this.getNameNode();
        if (Node.isStringLiteral(name))
            return name;
        else {
            const nodes = [];
            let current = this;
            do {
                nodes.push(this._getNodeFromCompilerNode(current.compilerNode.name));
                current = current.getFirstChildByKind(common.SyntaxKind.ModuleDeclaration);
            } while (current != null);
            return nodes;
        }
    }
    hasNamespaceKeyword() {
        return this.getDeclarationKind() === exports.ModuleDeclarationKind.Namespace;
    }
    hasModuleKeyword() {
        return this.getDeclarationKind() === exports.ModuleDeclarationKind.Module;
    }
    setDeclarationKind(kind) {
        if (this.getDeclarationKind() === kind)
            return this;
        if (kind === exports.ModuleDeclarationKind.Global) {
            const declarationKindKeyword = this.getDeclarationKindKeyword();
            this.getNameNode().replaceWithText("global");
            if (declarationKindKeyword != null) {
                removeChildren({
                    children: [declarationKindKeyword],
                    removeFollowingNewLines: true,
                    removeFollowingSpaces: true,
                });
            }
        }
        else {
            const declarationKindKeyword = this.getDeclarationKindKeyword();
            if (declarationKindKeyword != null)
                declarationKindKeyword.replaceWithText(kind);
            else {
                insertIntoParentTextRange({
                    parent: this,
                    insertPos: this.getNameNode().getStart(),
                    newText: kind + " ",
                });
            }
        }
        return this;
    }
    getDeclarationKind() {
        const nodeFlags = this.getFlags();
        if ((nodeFlags & common.ts.NodeFlags.GlobalAugmentation) !== 0)
            return exports.ModuleDeclarationKind.Global;
        if ((nodeFlags & common.ts.NodeFlags.Namespace) !== 0)
            return exports.ModuleDeclarationKind.Namespace;
        return exports.ModuleDeclarationKind.Module;
    }
    getDeclarationKindKeyword() {
        return this.getFirstChild(child => child.getKind() === common.SyntaxKind.NamespaceKeyword
            || child.getKind() === common.SyntaxKind.ModuleKeyword);
    }
    set(structure) {
        if (structure.name != null && structure.name !== "global")
            addNamespaceKeywordIfNecessary(this);
        callBaseSet(ModuleDeclarationBase.prototype, this, structure);
        if (structure.declarationKind != null)
            this.setDeclarationKind(structure.declarationKind);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(ModuleDeclarationBase.prototype, this, {
            kind: exports.StructureKind.Module,
            declarationKind: this.getDeclarationKind(),
        });
    }
    _getInnerBody() {
        let node = this.getBody();
        while (node != null && Node.isBodyableNode(node) && node.compilerNode.statements == null)
            node = node.getBody();
        return node;
    }
}
function addNamespaceKeywordIfNecessary(namespaceDec) {
    if (namespaceDec.getDeclarationKind() === exports.ModuleDeclarationKind.Global)
        namespaceDec.setDeclarationKind(exports.ModuleDeclarationKind.Namespace);
}
function changeToAmbientModuleIfNecessary(namespaceDec) {
    if (namespaceDec.hasNamespaceKeyword())
        namespaceDec.setDeclarationKind(exports.ModuleDeclarationKind.Module);
    if (!namespaceDec.hasDeclareKeyword())
        namespaceDec.setHasDeclareKeyword(true);
}

const NamedExportsBase = Node;
class NamedExports extends NamedExportsBase {
    getElements() {
        return this.compilerNode.elements.map(e => this._getNodeFromCompilerNode(e));
    }
}

const NamedImportsBase = Node;
class NamedImports extends NamedImportsBase {
    getElements() {
        return this.compilerNode.elements.map(e => this._getNodeFromCompilerNode(e));
    }
}

const NamespaceExportBase = RenameableNode(Node);
class NamespaceExport extends NamespaceExportBase {
    setName(name) {
        const nameNode = this.getNameNode();
        if (nameNode.getText() === name)
            return this;
        nameNode.replaceWithText(name);
        return this;
    }
    getName() {
        return this.getNameNode().getText();
    }
    getNameNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.name);
    }
}

const NamespaceImportBase = RenameableNode(Node);
class NamespaceImport extends NamespaceImportBase {
    setName(name) {
        const nameNode = this.getNameNode();
        if (nameNode.getText() === name)
            return this;
        nameNode.replaceWithText(name);
        return this;
    }
    getName() {
        return this.getNameNode().getText();
    }
    getNameNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.name);
    }
}

class FileReference extends TextRange {
    constructor(compilerObject, sourceFile) {
        super(compilerObject, sourceFile);
    }
    getFileName() {
        return this.compilerObject.fileName;
    }
}

exports.FileSystemRefreshResult = void 0;
(function (FileSystemRefreshResult) {
    FileSystemRefreshResult[FileSystemRefreshResult["NoChange"] = 0] = "NoChange";
    FileSystemRefreshResult[FileSystemRefreshResult["Updated"] = 1] = "Updated";
    FileSystemRefreshResult[FileSystemRefreshResult["Deleted"] = 2] = "Deleted";
})(exports.FileSystemRefreshResult || (exports.FileSystemRefreshResult = {}));

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

const SourceFileBase = ModuledNode(TextInsertableNode(StatementedNode(Node)));
class SourceFile extends SourceFileBase {
    constructor(context, node) {
        super(context, node, undefined);
        this._isSaved = false;
        this._modifiedEventContainer = new common.EventContainer();
        this._preModifiedEventContainer = new common.EventContainer();
        this._referenceContainer = new SourceFileReferenceContainer(this);
        this.__sourceFile = this;
        const onPreModified = () => {
            this.isFromExternalLibrary();
            this._preModifiedEventContainer.unsubscribe(onPreModified);
        };
        this._preModifiedEventContainer.subscribe(onPreModified);
    }
    _replaceCompilerNodeFromFactory(compilerNode) {
        super._replaceCompilerNodeFromFactory(compilerNode);
        this._context.resetProgram();
        this._isSaved = false;
        this._modifiedEventContainer.fire(this);
    }
    _clearInternals() {
        super._clearInternals();
        clearTextRanges(this._referencedFiles);
        clearTextRanges(this._typeReferenceDirectives);
        clearTextRanges(this._libReferenceDirectives);
        delete this._referencedFiles;
        delete this._typeReferenceDirectives;
        delete this._libReferenceDirectives;
        function clearTextRanges(textRanges) {
            textRanges === null || textRanges === void 0 ? void 0 : textRanges.forEach(r => r._forget());
        }
    }
    getFilePath() {
        return this.compilerNode.fileName;
    }
    getBaseName() {
        return common.FileUtils.getBaseName(this.getFilePath());
    }
    getBaseNameWithoutExtension() {
        const baseName = this.getBaseName();
        const extension = this.getExtension();
        return baseName.substring(0, baseName.length - extension.length);
    }
    getExtension() {
        return common.FileUtils.getExtension(this.getFilePath());
    }
    getDirectory() {
        return this._context.compilerFactory.getDirectoryFromCache(this.getDirectoryPath());
    }
    getDirectoryPath() {
        return this._context.fileSystemWrapper.getStandardizedAbsolutePath(common.FileUtils.getDirPath(this.compilerNode.fileName));
    }
    getFullText() {
        return this.compilerNode.text;
    }
    getLineAndColumnAtPos(pos) {
        const fullText = this.getFullText();
        return {
            line: common.StringUtils.getLineNumberAtPos(fullText, pos),
            column: common.StringUtils.getLengthFromLineStartAtPos(fullText, pos) + 1,
        };
    }
    getLengthFromLineStartAtPos(pos) {
        return common.StringUtils.getLengthFromLineStartAtPos(this.getFullText(), pos);
    }
    copyToDirectory(dirPathOrDirectory, options) {
        const dirPath = typeof dirPathOrDirectory === "string" ? dirPathOrDirectory : dirPathOrDirectory.getPath();
        return this.copy(common.FileUtils.pathJoin(dirPath, this.getBaseName()), options);
    }
    copy(filePath, options = {}) {
        const result = this._copyInternal(filePath, options);
        if (result === false)
            return this;
        const copiedSourceFile = result;
        if (copiedSourceFile.getDirectoryPath() !== this.getDirectoryPath())
            copiedSourceFile._updateReferencesForCopyInternal(this._getReferencesForCopyInternal());
        return copiedSourceFile;
    }
    _copyInternal(fileAbsoluteOrRelativePath, options = {}) {
        const { overwrite = false } = options;
        const { compilerFactory, fileSystemWrapper } = this._context;
        const standardizedFilePath = fileSystemWrapper.getStandardizedAbsolutePath(fileAbsoluteOrRelativePath, this.getDirectoryPath());
        if (standardizedFilePath === this.getFilePath())
            return false;
        return getCopiedSourceFile(this);
        function getCopiedSourceFile(currentFile) {
            try {
                return compilerFactory.createSourceFileFromText(standardizedFilePath, currentFile.getFullText(), { overwrite, markInProject: getShouldBeInProject() });
            }
            catch (err) {
                if (err instanceof common.errors.InvalidOperationError)
                    throw new common.errors.InvalidOperationError(`Did you mean to provide the overwrite option? ` + err.message);
                else
                    throw err;
            }
            function getShouldBeInProject() {
                if (currentFile._isInProject())
                    return true;
                const destinationFile = compilerFactory.getSourceFileFromCacheFromFilePath(standardizedFilePath);
                return destinationFile != null && destinationFile._isInProject();
            }
        }
    }
    _getReferencesForCopyInternal() {
        return Array.from(this._referenceContainer.getLiteralsReferencingOtherSourceFilesEntries());
    }
    _updateReferencesForCopyInternal(literalReferences) {
        for (const reference of literalReferences)
            reference[0] = this.getChildSyntaxListOrThrow().getDescendantAtStartWithWidth(reference[0].getStart(), reference[0].getWidth());
        updateStringLiteralReferences(literalReferences);
    }
    copyImmediately(filePath, options) {
        return __awaiter(this, void 0, void 0, function* () {
            const newSourceFile = this.copy(filePath, options);
            yield newSourceFile.save();
            return newSourceFile;
        });
    }
    copyImmediatelySync(filePath, options) {
        const newSourceFile = this.copy(filePath, options);
        newSourceFile.saveSync();
        return newSourceFile;
    }
    moveToDirectory(dirPathOrDirectory, options) {
        const dirPath = typeof dirPathOrDirectory === "string" ? dirPathOrDirectory : dirPathOrDirectory.getPath();
        return this.move(common.FileUtils.pathJoin(dirPath, this.getBaseName()), options);
    }
    move(filePath, options = {}) {
        const oldDirPath = this.getDirectoryPath();
        const sourceFileReferences = this._getReferencesForMoveInternal();
        const oldFilePath = this.getFilePath();
        if (!this._moveInternal(filePath, options))
            return this;
        this._context.fileSystemWrapper.queueFileDelete(oldFilePath);
        this._updateReferencesForMoveInternal(sourceFileReferences, oldDirPath);
        this._context.lazyReferenceCoordinator.clearDirtySourceFiles();
        this._context.lazyReferenceCoordinator.addDirtySourceFile(this);
        return this;
    }
    _moveInternal(fileRelativeOrAbsolutePath, options = {}) {
        const { overwrite = false } = options;
        const filePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(fileRelativeOrAbsolutePath, this.getDirectoryPath());
        if (filePath === this.getFilePath())
            return false;
        let markAsInProject = false;
        if (overwrite) {
            const existingSourceFile = this._context.compilerFactory.getSourceFileFromCacheFromFilePath(filePath);
            if (existingSourceFile != null) {
                markAsInProject = existingSourceFile._isInProject();
                existingSourceFile.forget();
            }
        }
        else {
            this._context.compilerFactory.throwIfFileExists(filePath, "Did you mean to provide the overwrite option?");
        }
        replaceSourceFileForFilePathMove({
            newFilePath: filePath,
            sourceFile: this,
        });
        if (markAsInProject)
            this._markAsInProject();
        if (this._isInProject())
            this.getDirectory()._markAsInProject();
        return true;
    }
    _getReferencesForMoveInternal() {
        return {
            literalReferences: Array.from(this._referenceContainer.getLiteralsReferencingOtherSourceFilesEntries()),
            referencingLiterals: Array.from(this._referenceContainer.getReferencingLiteralsInOtherSourceFiles()),
        };
    }
    _updateReferencesForMoveInternal(sourceFileReferences, oldDirPath) {
        const { literalReferences, referencingLiterals } = sourceFileReferences;
        if (oldDirPath !== this.getDirectoryPath())
            updateStringLiteralReferences(literalReferences);
        updateStringLiteralReferences(referencingLiterals.map(node => ([node, this])));
    }
    moveImmediately(filePath, options) {
        return __awaiter(this, void 0, void 0, function* () {
            const oldFilePath = this.getFilePath();
            const newFilePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePath, this.getDirectoryPath());
            this.move(filePath, options);
            if (oldFilePath !== newFilePath) {
                yield this._context.fileSystemWrapper.moveFileImmediately(oldFilePath, newFilePath, this.getFullText());
                this._isSaved = true;
            }
            else {
                yield this.save();
            }
            return this;
        });
    }
    moveImmediatelySync(filePath, options) {
        const oldFilePath = this.getFilePath();
        const newFilePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePath, this.getDirectoryPath());
        this.move(filePath, options);
        if (oldFilePath !== newFilePath) {
            this._context.fileSystemWrapper.moveFileImmediatelySync(oldFilePath, newFilePath, this.getFullText());
            this._isSaved = true;
        }
        else {
            this.saveSync();
        }
        return this;
    }
    delete() {
        const filePath = this.getFilePath();
        this.forget();
        this._context.fileSystemWrapper.queueFileDelete(filePath);
    }
    deleteImmediately() {
        return __awaiter(this, void 0, void 0, function* () {
            const filePath = this.getFilePath();
            this.forget();
            yield this._context.fileSystemWrapper.deleteFileImmediately(filePath);
        });
    }
    deleteImmediatelySync() {
        const filePath = this.getFilePath();
        this.forget();
        this._context.fileSystemWrapper.deleteFileImmediatelySync(filePath);
    }
    save() {
        return __awaiter(this, void 0, void 0, function* () {
            yield this._context.fileSystemWrapper.writeFile(this.getFilePath(), this._getTextForSave());
            this._isSaved = true;
        });
    }
    saveSync() {
        this._context.fileSystemWrapper.writeFileSync(this.getFilePath(), this._getTextForSave());
        this._isSaved = true;
    }
    _getTextForSave() {
        const text = this.getFullText();
        return this._hasBom ? "\uFEFF" + text : text;
    }
    getPathReferenceDirectives() {
        if (this._referencedFiles == null) {
            this._referencedFiles = (this.compilerNode.referencedFiles || [])
                .map(f => new FileReference(f, this));
        }
        return this._referencedFiles;
    }
    getTypeReferenceDirectives() {
        if (this._typeReferenceDirectives == null) {
            this._typeReferenceDirectives = (this.compilerNode.typeReferenceDirectives || [])
                .map(f => new FileReference(f, this));
        }
        return this._typeReferenceDirectives;
    }
    getLibReferenceDirectives() {
        if (this._libReferenceDirectives == null) {
            this._libReferenceDirectives = (this.compilerNode.libReferenceDirectives || [])
                .map(f => new FileReference(f, this));
        }
        return this._libReferenceDirectives;
    }
    getReferencingSourceFiles() {
        return Array.from(this._referenceContainer.getDependentSourceFiles());
    }
    getReferencingNodesInOtherSourceFiles() {
        const literals = this.getReferencingLiteralsInOtherSourceFiles();
        return Array.from(getNodes());
        function* getNodes() {
            for (const literal of literals)
                yield getReferencingNodeFromStringLiteral(literal);
        }
    }
    getReferencingLiteralsInOtherSourceFiles() {
        return Array.from(this._referenceContainer.getReferencingLiteralsInOtherSourceFiles());
    }
    getReferencedSourceFiles() {
        const entries = this._referenceContainer.getLiteralsReferencingOtherSourceFilesEntries();
        return Array.from(new Set(getSourceFilesFromEntries()).values());
        function* getSourceFilesFromEntries() {
            for (const [, sourceFile] of entries)
                yield sourceFile;
        }
    }
    getNodesReferencingOtherSourceFiles() {
        const entries = this._referenceContainer.getLiteralsReferencingOtherSourceFilesEntries();
        return Array.from(getNodes());
        function* getNodes() {
            for (const [literal] of entries)
                yield getReferencingNodeFromStringLiteral(literal);
        }
    }
    getLiteralsReferencingOtherSourceFiles() {
        const entries = this._referenceContainer.getLiteralsReferencingOtherSourceFilesEntries();
        return Array.from(getLiteralsFromEntries());
        function* getLiteralsFromEntries() {
            for (const [literal] of entries)
                yield literal;
        }
    }
    getImportStringLiterals() {
        this._ensureBound();
        const literals = (this.compilerNode.imports || []);
        return literals.filter(l => l.pos !== -1).map(l => this._getNodeFromCompilerNode(l));
    }
    getLanguageVersion() {
        return this.compilerNode.languageVersion;
    }
    getLanguageVariant() {
        return this.compilerNode.languageVariant;
    }
    getScriptKind() {
        return this.compilerNode.scriptKind;
    }
    isDeclarationFile() {
        return this.compilerNode.isDeclarationFile;
    }
    isFromExternalLibrary() {
        if (!this._context.program._isCompilerProgramCreated())
            return false;
        const compilerProgram = this._context.program.compilerObject;
        return compilerProgram.isSourceFileFromExternalLibrary(this.compilerNode);
    }
    isInNodeModules() {
        return this.getFilePath().indexOf("/node_modules/") >= 0;
    }
    isSaved() {
        return this._isSaved;
    }
    _setIsSaved(value) {
        this._isSaved = value;
    }
    getPreEmitDiagnostics() {
        return this._context.getPreEmitDiagnostics(this);
    }
    unindent(positionRangeOrPos, times = 1) {
        return this.indent(positionRangeOrPos, times * -1);
    }
    indent(positionRangeOrPos, times = 1) {
        if (times === 0)
            return this;
        const sourceFileText = this.getFullText();
        const positionRange = typeof positionRangeOrPos === "number" ? [positionRangeOrPos, positionRangeOrPos] : positionRangeOrPos;
        common.errors.throwIfRangeOutOfRange(positionRange, [0, sourceFileText.length], "positionRange");
        const startLinePos = getPreviousMatchingPos(sourceFileText, positionRange[0], char => char === CharCodes.NEWLINE);
        const endLinePos = getNextMatchingPos(sourceFileText, positionRange[1], char => char === CharCodes.CARRIAGE_RETURN || char === CharCodes.NEWLINE);
        const correctedText = common.StringUtils.indent(sourceFileText.substring(startLinePos, endLinePos), times, {
            indentText: this._context.manipulationSettings.getIndentationText(),
            indentSizeInSpaces: this._context.manipulationSettings._getIndentSizeInSpaces(),
            isInStringAtPos: pos => this.isInStringAtPos(pos + startLinePos),
        });
        replaceSourceFileTextForFormatting({
            sourceFile: this,
            newText: sourceFileText.substring(0, startLinePos) + correctedText + sourceFileText.substring(endLinePos),
        });
        return this;
    }
    emit(options) {
        return this._context.program.emit(Object.assign({ targetSourceFile: this }, options));
    }
    emitSync(options) {
        return this._context.program.emitSync(Object.assign({ targetSourceFile: this }, options));
    }
    getEmitOutput(options = {}) {
        return this._context.languageService.getEmitOutput(this, options.emitOnlyDtsFiles || false);
    }
    formatText(settings = {}) {
        replaceSourceFileTextForFormatting({
            sourceFile: this,
            newText: this._context.languageService.getFormattedDocumentText(this.getFilePath(), settings),
        });
    }
    refreshFromFileSystem() {
        return __awaiter(this, void 0, void 0, function* () {
            const fileReadResult = yield this._context.fileSystemWrapper.readFileOrNotExists(this.getFilePath(), this._context.getEncoding());
            return this._refreshFromFileSystemInternal(fileReadResult);
        });
    }
    refreshFromFileSystemSync() {
        const fileReadResult = this._context.fileSystemWrapper.readFileOrNotExistsSync(this.getFilePath(), this._context.getEncoding());
        return this._refreshFromFileSystemInternal(fileReadResult);
    }
    getRelativePathTo(sourceFileDirOrPath) {
        return this.getDirectory().getRelativePathTo(sourceFileDirOrPath);
    }
    getRelativePathAsModuleSpecifierTo(sourceFileDirOrFilePath) {
        return this.getDirectory().getRelativePathAsModuleSpecifierTo(sourceFileDirOrFilePath);
    }
    onModified(subscription, subscribe = true) {
        if (subscribe)
            this._modifiedEventContainer.subscribe(subscription);
        else
            this._modifiedEventContainer.unsubscribe(subscription);
        return this;
    }
    _doActionPreNextModification(action) {
        const wrappedSubscription = () => {
            action();
            this._preModifiedEventContainer.unsubscribe(wrappedSubscription);
        };
        this._preModifiedEventContainer.subscribe(wrappedSubscription);
        return this;
    }
    _firePreModified() {
        this._preModifiedEventContainer.fire(this);
    }
    organizeImports(formatSettings = {}, userPreferences = {}) {
        this._context.languageService.organizeImports(this, formatSettings, userPreferences).forEach(fileTextChanges => fileTextChanges.applyChanges());
        return this;
    }
    fixUnusedIdentifiers(formatSettings = {}, userPreferences = {}) {
        this._context.languageService.getCombinedCodeFix(this, "unusedIdentifier_delete", formatSettings, userPreferences).applyChanges();
        this._context.languageService.getCombinedCodeFix(this, "unusedIdentifier_deleteImports", formatSettings, userPreferences).applyChanges();
        return this;
    }
    fixMissingImports(formatSettings = {}, userPreferences = {}) {
        const combinedCodeFix = this._context.languageService.getCombinedCodeFix(this, "fixMissingImport", formatSettings, userPreferences);
        const sourceFile = this;
        for (const fileTextChanges of combinedCodeFix.getChanges()) {
            const changes = fileTextChanges.getTextChanges();
            removeUnnecessaryDoubleBlankLines(changes);
            applyTextChanges(changes);
        }
        return this;
        function removeUnnecessaryDoubleBlankLines(changes) {
            changes.sort((a, b) => a.getSpan().getStart() - b.getSpan().getStart());
            for (let i = 0; i < changes.length - 1; i++) {
                const { compilerObject } = changes[i];
                compilerObject.newText = compilerObject.newText.replace(/(\r?)\n\r?\n$/, "$1\n");
            }
        }
        function applyTextChanges(changes) {
            const groups = common.ArrayUtils.groupBy(changes, change => change.getSpan().getStart());
            let addedLength = 0;
            for (const group of groups) {
                const insertPos = group[0].getSpan().getStart() + addedLength;
                const newText = group.map(item => item.getNewText()).join("");
                insertIntoTextRange({
                    sourceFile,
                    insertPos,
                    newText,
                });
                addedLength += newText.length;
            }
        }
    }
    applyTextChanges(textChanges) {
        if (textChanges.length === 0)
            return this;
        this.forgetDescendants();
        replaceNodeText({
            sourceFile: this._sourceFile,
            start: 0,
            replacingLength: this.getFullWidth(),
            newText: getTextFromTextChanges(this, textChanges),
        });
        return this;
    }
    set(structure) {
        callBaseSet(SourceFileBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(SourceFileBase.prototype, this, {
            kind: exports.StructureKind.SourceFile,
        });
    }
    _refreshFromFileSystemInternal(fileReadResult) {
        if (fileReadResult === false) {
            this.forget();
            return exports.FileSystemRefreshResult.Deleted;
        }
        const fileText = fileReadResult;
        if (fileText === this.getFullText())
            return exports.FileSystemRefreshResult.NoChange;
        this.replaceText([0, this.getEnd()], fileText);
        this._setIsSaved(true);
        return exports.FileSystemRefreshResult.Updated;
    }
    _isInProject() {
        return this._context.inProjectCoordinator.isSourceFileInProject(this);
    }
    _markAsInProject() {
        this._context.inProjectCoordinator.markSourceFileAsInProject(this);
    }
}
__decorate([
    common.Memoize
], SourceFile.prototype, "isFromExternalLibrary", null);
function updateStringLiteralReferences(nodeReferences) {
    for (const [stringLiteral, sourceFile] of nodeReferences) {
        if (ModuleUtils.isModuleSpecifierRelative(stringLiteral.getLiteralText()))
            stringLiteral.setLiteralValue(stringLiteral._sourceFile.getRelativePathAsModuleSpecifierTo(sourceFile));
    }
}
function getReferencingNodeFromStringLiteral(literal) {
    const parent = literal.getParentOrThrow();
    const grandParent = parent.getParent();
    if (grandParent != null && Node.isImportEqualsDeclaration(grandParent))
        return grandParent;
    else
        return parent;
}

const createBase$p = (ctor) => ModuleChildableNode(JSDocableNode(AmbientableNode(ExportableNode(ModifierableNode(ctor)))));
const VariableStatementBase = createBase$p(Statement);
class VariableStatement extends VariableStatementBase {
    getDeclarationList() {
        return this._getNodeFromCompilerNode(this.compilerNode.declarationList);
    }
    getDeclarations() {
        return this.getDeclarationList().getDeclarations();
    }
    getDeclarationKind() {
        return this.getDeclarationList().getDeclarationKind();
    }
    getDeclarationKindKeyword() {
        return this.getDeclarationList().getDeclarationKindKeyword();
    }
    setDeclarationKind(type) {
        return this.getDeclarationList().setDeclarationKind(type);
    }
    addDeclaration(structure) {
        return this.getDeclarationList().addDeclaration(structure);
    }
    addDeclarations(structures) {
        return this.getDeclarationList().addDeclarations(structures);
    }
    insertDeclaration(index, structure) {
        return this.getDeclarationList().insertDeclaration(index, structure);
    }
    insertDeclarations(index, structures) {
        return this.getDeclarationList().insertDeclarations(index, structures);
    }
    set(structure) {
        callBaseSet(VariableStatementBase.prototype, this, structure);
        if (structure.declarationKind != null)
            this.setDeclarationKind(structure.declarationKind);
        if (structure.declarations != null) {
            const existingDeclarations = this.getDeclarations();
            this.addDeclarations(structure.declarations);
            existingDeclarations.forEach(d => d.remove());
        }
        return this;
    }
    getStructure() {
        return callBaseGetStructure(VariableStatementBase.prototype, this, {
            kind: exports.StructureKind.VariableStatement,
            declarationKind: this.getDeclarationKind(),
            declarations: this.getDeclarations().map(declaration => declaration.getStructure()),
        });
    }
}

const WhileStatementBase = ExpressionedNode(IterationStatement);
class WhileStatement extends WhileStatementBase {
}

const WithStatementBase = ExpressionedNode(Statement);
class WithStatement extends WithStatementBase {
    getStatement() {
        return this._getNodeFromCompilerNode(this.compilerNode.statement);
    }
}

function FunctionLikeDeclaration(Base) {
    return JSDocableNode(TypeParameteredNode(SignaturedDeclaration(StatementedNode(ModifierableNode(Base)))));
}

const createBase$o = (ctor) => TextInsertableNode(BodiedNode(AsyncableNode(FunctionLikeDeclaration(ctor))));
const ArrowFunctionBase = createBase$o(Expression);
class ArrowFunction extends ArrowFunctionBase {
    getEqualsGreaterThan() {
        return this._getNodeFromCompilerNode(this.compilerNode.equalsGreaterThanToken);
    }
}

function OverloadableNode(Base) {
    return class extends Base {
        getOverloads() {
            return getOverloadsAndImplementation(this).filter(n => n.isOverload());
        }
        getImplementation() {
            if (this.isImplementation())
                return this;
            return getOverloadsAndImplementation(this).find(n => n.isImplementation());
        }
        getImplementationOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getImplementation(), "Expected to find a corresponding implementation for the overload.");
        }
        isOverload() {
            return !this.isImplementation();
        }
        isImplementation() {
            return this.getBody() != null;
        }
    };
}
function getOverloadsAndImplementation(node) {
    const parent = node.getParentOrThrow();
    const name = getNameIfNamedNode(node);
    const kind = node.getKind();
    return parent.forEachChildAsArray().filter(n => {
        const hasSameName = getNameIfNamedNode(n) === name;
        const hasSameKind = n.getKind() === kind;
        return hasSameName && hasSameKind;
    });
}
function getNameIfNamedNode(node) {
    const nodeAsNamedNode = node;
    if (nodeAsNamedNode.getName instanceof Function)
        return nodeAsNamedNode.getName();
    return undefined;
}
function insertOverloads(opts) {
    if (opts.structures.length === 0)
        return [];
    const parentSyntaxList = opts.node.getParentSyntaxListOrThrow();
    const implementationNode = opts.node.getImplementation() || opts.node;
    const overloads = opts.node.getOverloads();
    const overloadsCount = overloads.length;
    const firstIndex = overloads.length > 0 ? overloads[0].getChildIndex() : implementationNode.getChildIndex();
    const index = verifyAndGetIndex(opts.index, overloadsCount);
    const mainIndex = firstIndex + index;
    const thisStructure = opts.getThisStructure(implementationNode);
    const structures = opts.structures.map(structure => common.ObjectUtils.assign(common.ObjectUtils.assign({}, thisStructure), structure));
    const writer = implementationNode._getWriterWithQueuedIndentation();
    for (const structure of structures) {
        if (writer.getLength() > 0)
            writer.newLine();
        opts.printStructure(writer, structure);
    }
    writer.newLine();
    writer.write("");
    insertIntoParentTextRange({
        parent: parentSyntaxList,
        insertPos: (overloads[index] || implementationNode).getNonWhitespaceStart(),
        newText: writer.toString(),
    });
    return getRangeWithoutCommentsFromArray(parentSyntaxList.getChildren(), mainIndex, structures.length, opts.expectedSyntaxKind);
}

const createBase$n = (ctor) => UnwrappableNode(TextInsertableNode(OverloadableNode(BodyableNode(AsyncableNode(GeneratorableNode(AmbientableNode(ExportableNode(FunctionLikeDeclaration(ModuleChildableNode(NameableNode(ctor)))))))))));
const FunctionDeclarationBase = createBase$n(Statement);
const createOverloadBase$2 = (ctor) => UnwrappableNode(TextInsertableNode(AsyncableNode(GeneratorableNode(SignaturedDeclaration(AmbientableNode(ModuleChildableNode(JSDocableNode(TypeParameteredNode(ExportableNode(ModifierableNode(ctor)))))))))));
const FunctionDeclarationOverloadBase = createOverloadBase$2(Statement);
class FunctionDeclaration extends FunctionDeclarationBase {
    addOverload(structure) {
        return this.addOverloads([structure])[0];
    }
    addOverloads(structures) {
        return this.insertOverloads(this.getOverloads().length, structures);
    }
    insertOverload(index, structure) {
        return this.insertOverloads(index, [structure])[0];
    }
    insertOverloads(index, structures) {
        const thisName = this.getName();
        const printer = this._context.structurePrinterFactory.forFunctionDeclaration({
            isAmbient: this.isAmbient(),
        });
        return insertOverloads({
            node: this,
            index,
            structures,
            printStructure: (writer, structure) => {
                printer.printOverload(writer, thisName, structure);
            },
            getThisStructure: fromFunctionDeclarationOverload,
            expectedSyntaxKind: common.SyntaxKind.FunctionDeclaration,
        });
    }
    remove() {
        removeOverloadableStatementedNodeChild(this);
    }
    set(structure) {
        callBaseSet(FunctionDeclarationBase.prototype, this, structure);
        if (structure.overloads != null) {
            this.getOverloads().forEach(o => o.remove());
            this.addOverloads(structure.overloads);
        }
        return this;
    }
    getStructure() {
        const isOverload = this.isOverload();
        const hasImplementation = this.getImplementation();
        const basePrototype = isOverload && hasImplementation ? FunctionDeclarationOverloadBase.prototype : FunctionDeclarationBase.prototype;
        return callBaseGetStructure(basePrototype, this, getStructure(this));
        function getStructure(thisNode) {
            if (hasImplementation && isOverload)
                return getOverloadSpecificStructure();
            return getSpecificStructure();
            function getOverloadSpecificStructure() {
                return { kind: exports.StructureKind.FunctionOverload };
            }
            function getSpecificStructure() {
                if (!hasImplementation)
                    return { kind: exports.StructureKind.Function };
                else {
                    return {
                        kind: exports.StructureKind.Function,
                        overloads: thisNode.getOverloads().map(o => o.getStructure()),
                    };
                }
            }
        }
    }
}

const createBase$m = (ctor) => JSDocableNode(TextInsertableNode(BodiedNode(AsyncableNode(GeneratorableNode(StatementedNode(TypeParameteredNode(SignaturedDeclaration(ModifierableNode(NameableNode(ctor))))))))));
const FunctionExpressionBase = createBase$m(PrimaryExpression);
class FunctionExpression extends FunctionExpressionBase {
}

const createBase$l = (ctor) => OverrideableNode(QuestionTokenableNode(DecoratableNode(ScopeableNode(ReadonlyableNode(ModifierableNode(DotDotDotTokenableNode(TypedNode(InitializerExpressionableNode(BindingNamedNode(ctor))))))))));
const ParameterDeclarationBase = createBase$l(Node);
class ParameterDeclaration extends ParameterDeclarationBase {
    isRestParameter() {
        return this.compilerNode.dotDotDotToken != null;
    }
    isParameterProperty() {
        return this.getScope() != null || this.isReadonly() || this.hasOverrideKeyword();
    }
    setIsRestParameter(value) {
        if (this.isRestParameter() === value)
            return this;
        if (value) {
            addParensIfNecessary(this);
            insertIntoParentTextRange({
                insertPos: this.getNameNode().getStart(),
                parent: this,
                newText: "...",
            });
        }
        else {
            removeChildren({ children: [this.getDotDotDotTokenOrThrow()] });
        }
        return this;
    }
    isOptional() {
        return this.compilerNode.questionToken != null || this.isRestParameter() || this.hasInitializer();
    }
    remove() {
        removeCommaSeparatedChild(this);
    }
    set(structure) {
        callBaseSet(ParameterDeclarationBase.prototype, this, structure);
        if (structure.isRestParameter != null)
            this.setIsRestParameter(structure.isRestParameter);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(ParameterDeclarationBase.prototype, this, {
            kind: exports.StructureKind.Parameter,
            isRestParameter: this.isRestParameter(),
        });
    }
    setHasQuestionToken(value) {
        if (value)
            addParensIfNecessary(this);
        super.setHasQuestionToken(value);
        return this;
    }
    setInitializer(textOrWriterFunction) {
        addParensIfNecessary(this);
        super.setInitializer(textOrWriterFunction);
        return this;
    }
    setType(textOrWriterFunction) {
        addParensIfNecessary(this);
        super.setType.call(this, textOrWriterFunction);
        return this;
    }
}
function addParensIfNecessary(parameter) {
    const parent = parameter.getParentOrThrow();
    if (isParameterWithoutParens())
        addParens();
    function isParameterWithoutParens() {
        return Node.isArrowFunction(parent)
            && parent.compilerNode.parameters.length === 1
            && parameter.getParentSyntaxListOrThrow().getPreviousSiblingIfKind(common.SyntaxKind.OpenParenToken) == null;
    }
    function addParens() {
        const paramText = parameter.getText();
        insertIntoParentTextRange({
            parent,
            insertPos: parameter.getStart(),
            newText: `(${paramText})`,
            replacing: {
                textLength: paramText.length,
            },
            customMappings: newParent => {
                return [{ currentNode: parameter, newNode: newParent.parameters[0] }];
            },
        });
    }
}

class ClassElement extends Node {
    remove() {
        const parent = this.getParentOrThrow();
        if (Node.isClassDeclaration(parent) || Node.isClassExpression(parent))
            removeClassMember(this);
        else if (Node.isObjectLiteralExpression(parent))
            removeCommaSeparatedChild(this);
        else
            common.errors.throwNotImplementedForSyntaxKindError(parent.getKind());
    }
}

const createBase$k = (ctor) => ChildOrderableNode(TextInsertableNode(OverrideableNode(OverloadableNode(BodyableNode(DecoratableNode(AbstractableNode(ScopedNode(QuestionTokenableNode(StaticableNode(AsyncableNode(GeneratorableNode(FunctionLikeDeclaration(PropertyNamedNode(ctor))))))))))))));
const MethodDeclarationBase = createBase$k(ClassElement);
const createOverloadBase$1 = (ctor) => JSDocableNode(ChildOrderableNode(TextInsertableNode(OverrideableNode(ScopedNode(TypeParameteredNode(AbstractableNode(QuestionTokenableNode(StaticableNode(AsyncableNode(ModifierableNode(GeneratorableNode(SignaturedDeclaration(ctor)))))))))))));
const MethodDeclarationOverloadBase = createOverloadBase$1(ClassElement);
class MethodDeclaration extends MethodDeclarationBase {
    set(structure) {
        callBaseSet(MethodDeclarationBase.prototype, this, structure);
        if (structure.overloads != null) {
            this.getOverloads().forEach(o => o.remove());
            this.addOverloads(structure.overloads);
        }
        return this;
    }
    addOverload(structure) {
        return this.addOverloads([structure])[0];
    }
    addOverloads(structures) {
        return this.insertOverloads(this.getOverloads().length, structures);
    }
    insertOverload(index, structure) {
        return this.insertOverloads(index, [structure])[0];
    }
    insertOverloads(index, structures) {
        const thisName = this.getName();
        const printer = this._context.structurePrinterFactory.forMethodDeclaration({
            isAmbient: isNodeAmbientOrInAmbientContext(this),
        });
        return insertOverloads({
            node: this,
            index,
            structures,
            printStructure: (writer, structure) => {
                printer.printOverload(writer, thisName, structure);
            },
            getThisStructure: fromMethodDeclarationOverload,
            expectedSyntaxKind: common.SyntaxKind.MethodDeclaration,
        });
    }
    getStructure() {
        const hasImplementation = this.getImplementation() != null;
        const isOverload = this.isOverload();
        const basePrototype = isOverload && hasImplementation ? MethodDeclarationOverloadBase.prototype : MethodDeclarationBase.prototype;
        return callBaseGetStructure(basePrototype, this, getStructure(this));
        function getStructure(thisNode) {
            if (hasImplementation && isOverload)
                return getOverloadSpecificStructure();
            return getSpecificStructure();
            function getOverloadSpecificStructure() {
                return { kind: exports.StructureKind.MethodOverload };
            }
            function getSpecificStructure() {
                if (!hasImplementation)
                    return { kind: exports.StructureKind.Method };
                else {
                    return {
                        kind: exports.StructureKind.Method,
                        overloads: thisNode.getOverloads().map(o => o.getStructure()),
                    };
                }
            }
        }
    }
}

function ClassLikeDeclarationBase(Base) {
    return ClassLikeDeclarationBaseSpecific(NameableNode(TextInsertableNode(ImplementsClauseableNode(HeritageClauseableNode(AbstractableNode(JSDocableNode(TypeParameteredNode(DecoratableNode(ModifierableNode(Base))))))))));
}
function ClassLikeDeclarationBaseSpecific(Base) {
    return class extends Base {
        setExtends(text) {
            text = this._getTextWithQueuedChildIndentation(text);
            if (common.StringUtils.isNullOrWhitespace(text))
                return this.removeExtends();
            const extendsClause = this.getHeritageClauseByKind(common.SyntaxKind.ExtendsKeyword);
            if (extendsClause != null) {
                const childSyntaxList = extendsClause.getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList);
                const childSyntaxListStart = childSyntaxList.getStart();
                insertIntoParentTextRange({
                    parent: extendsClause,
                    newText: text,
                    insertPos: childSyntaxListStart,
                    replacing: {
                        textLength: childSyntaxList.getEnd() - childSyntaxListStart,
                    },
                });
            }
            else {
                const implementsClause = this.getHeritageClauseByKind(common.SyntaxKind.ImplementsKeyword);
                let insertPos;
                if (implementsClause != null)
                    insertPos = implementsClause.getStart();
                else
                    insertPos = this.getFirstChildByKindOrThrow(common.SyntaxKind.OpenBraceToken).getStart();
                const isLastSpace = /\s/.test(this.getSourceFile().getFullText()[insertPos - 1]);
                let newText = `extends ${text} `;
                if (!isLastSpace)
                    newText = " " + newText;
                insertIntoParentTextRange({
                    parent: implementsClause == null ? this : implementsClause.getParentSyntaxListOrThrow(),
                    insertPos,
                    newText,
                });
            }
            return this;
        }
        removeExtends() {
            const extendsClause = this.getHeritageClauseByKind(common.SyntaxKind.ExtendsKeyword);
            if (extendsClause == null)
                return this;
            extendsClause.removeExpression(0);
            return this;
        }
        getExtendsOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getExtends(), `Expected to find the extends expression for the class ${this.getName()}.`);
        }
        getExtends() {
            const extendsClause = this.getHeritageClauseByKind(common.SyntaxKind.ExtendsKeyword);
            if (extendsClause == null)
                return undefined;
            const types = extendsClause.getTypeNodes();
            return types.length === 0 ? undefined : types[0];
        }
        addMembers(members) {
            return this.insertMembers(getEndIndexFromArray(this.getMembersWithComments()), members);
        }
        addMember(member) {
            return this.insertMember(getEndIndexFromArray(this.getMembersWithComments()), member);
        }
        insertMember(index, member) {
            return this.insertMembers(index, [member])[0];
        }
        insertMembers(index, members) {
            const isAmbient = isNodeAmbientOrInAmbientContext(this);
            return insertIntoBracesOrSourceFileWithGetChildrenWithComments({
                getIndexedChildren: () => this.getMembersWithComments(),
                index,
                parent: this,
                write: (writer, info) => {
                    const previousMemberHasBody = !isAmbient && info.previousMember != null && Node.isBodyableNode(info.previousMember)
                        && info.previousMember.hasBody();
                    const firstStructureHasBody = !isAmbient && members instanceof Array && structureHasBody(members[0]);
                    if (previousMemberHasBody || info.previousMember != null && firstStructureHasBody)
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                    const memberWriter = this._getWriter();
                    const memberPrinter = this._context.structurePrinterFactory.forClassMember({ isAmbient });
                    memberPrinter.printTexts(memberWriter, members);
                    writer.write(memberWriter.toString());
                    const lastStructureHasBody = !isAmbient && members instanceof Array && structureHasBody(members[members.length - 1]);
                    const nextMemberHasBody = !isAmbient && info.nextMember != null && Node.isBodyableNode(info.nextMember) && info.nextMember.hasBody();
                    if (info.nextMember != null && lastStructureHasBody || nextMemberHasBody)
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                },
            });
            function structureHasBody(value) {
                if (isAmbient || value == null || typeof value.kind !== "number")
                    return false;
                const structure = value;
                return Structure.isMethod(structure)
                    || Structure.isGetAccessor(structure)
                    || Structure.isSetAccessor(structure)
                    || Structure.isConstructor(structure);
            }
        }
        addConstructor(structure = {}) {
            return this.insertConstructor(getEndIndexFromArray(this.getMembersWithComments()), structure);
        }
        addConstructors(structures) {
            return this.insertConstructors(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertConstructor(index, structure = {}) {
            return this.insertConstructors(index, [structure])[0];
        }
        insertConstructors(index, structures) {
            const isAmbient = isNodeAmbientOrInAmbientContext(this);
            return insertChildren(this, {
                index,
                structures,
                expectedKind: common.SyntaxKind.Constructor,
                write: (writer, info) => {
                    if (!isAmbient && info.previousMember != null && !Node.isCommentNode(info.previousMember))
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                    this._context.structurePrinterFactory.forConstructorDeclaration({ isAmbient }).printTexts(writer, structures);
                    if (!isAmbient && info.nextMember != null)
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                },
            });
        }
        getConstructors() {
            return this.getMembers().filter(m => Node.isConstructorDeclaration(m));
        }
        addStaticBlock(structure = {}) {
            return this.insertStaticBlock(getEndIndexFromArray(this.getMembersWithComments()), structure);
        }
        addStaticBlocks(structures) {
            return this.insertStaticBlocks(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertStaticBlock(index, structure = {}) {
            return this.insertStaticBlocks(index, [structure])[0];
        }
        insertStaticBlocks(index, structures) {
            const isAmbient = isNodeAmbientOrInAmbientContext(this);
            return insertChildren(this, {
                index,
                structures,
                expectedKind: common.SyntaxKind.ClassStaticBlockDeclaration,
                write: (writer, info) => {
                    if (!isAmbient && info.previousMember != null && !Node.isCommentNode(info.previousMember))
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                    this._context.structurePrinterFactory.forClassStaticBlockDeclaration().printTexts(writer, structures);
                    if (!isAmbient && info.nextMember != null)
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                },
            });
        }
        getStaticBlocks() {
            return this.getMembers().filter(m => Node.isClassStaticBlockDeclaration(m));
        }
        addGetAccessor(structure) {
            return this.addGetAccessors([structure])[0];
        }
        addGetAccessors(structures) {
            return this.insertGetAccessors(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertGetAccessor(index, structure) {
            return this.insertGetAccessors(index, [structure])[0];
        }
        insertGetAccessors(index, structures) {
            return insertChildren(this, {
                index,
                structures,
                expectedKind: common.SyntaxKind.GetAccessor,
                write: (writer, info) => {
                    if (info.previousMember != null && !Node.isCommentNode(info.previousMember))
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                    this._context.structurePrinterFactory.forGetAccessorDeclaration({
                        isAmbient: isNodeAmbientOrInAmbientContext(this),
                    }).printTexts(writer, structures);
                    if (info.nextMember != null)
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                },
            });
        }
        addSetAccessor(structure) {
            return this.addSetAccessors([structure])[0];
        }
        addSetAccessors(structures) {
            return this.insertSetAccessors(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertSetAccessor(index, structure) {
            return this.insertSetAccessors(index, [structure])[0];
        }
        insertSetAccessors(index, structures) {
            return insertChildren(this, {
                index,
                structures,
                expectedKind: common.SyntaxKind.SetAccessor,
                write: (writer, info) => {
                    if (info.previousMember != null && !Node.isCommentNode(info.previousMember))
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                    this._context.structurePrinterFactory.forSetAccessorDeclaration({
                        isAmbient: isNodeAmbientOrInAmbientContext(this),
                    }).printTexts(writer, structures);
                    if (info.nextMember != null)
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                },
            });
        }
        addProperty(structure) {
            return this.addProperties([structure])[0];
        }
        addProperties(structures) {
            return this.insertProperties(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertProperty(index, structure) {
            return this.insertProperties(index, [structure])[0];
        }
        insertProperties(index, structures) {
            return insertChildren(this, {
                index,
                structures,
                expectedKind: common.SyntaxKind.PropertyDeclaration,
                write: (writer, info) => {
                    if (info.previousMember != null && Node.hasBody(info.previousMember))
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                    this._context.structurePrinterFactory.forPropertyDeclaration().printTexts(writer, structures);
                    if (info.nextMember != null && Node.hasBody(info.nextMember))
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                },
            });
        }
        addMethod(structure) {
            return this.addMethods([structure])[0];
        }
        addMethods(structures) {
            return this.insertMethods(getEndIndexFromArray(this.getMembersWithComments()), structures);
        }
        insertMethod(index, structure) {
            return this.insertMethods(index, [structure])[0];
        }
        insertMethods(index, structures) {
            const isAmbient = isNodeAmbientOrInAmbientContext(this);
            structures = structures.map(s => (Object.assign({}, s)));
            return insertChildren(this, {
                index,
                write: (writer, info) => {
                    if (!isAmbient && info.previousMember != null && !Node.isCommentNode(info.previousMember))
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                    this._context.structurePrinterFactory.forMethodDeclaration({ isAmbient }).printTexts(writer, structures);
                    if (!isAmbient && info.nextMember != null)
                        writer.blankLineIfLastNot();
                    else
                        writer.newLineIfLastNot();
                },
                structures,
                expectedKind: common.SyntaxKind.MethodDeclaration,
            });
        }
        getInstanceProperty(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getInstanceProperties(), nameOrFindFunction);
        }
        getInstancePropertyOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getInstanceProperty(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class instance property", nameOrFindFunction));
        }
        getInstanceProperties() {
            return this.getInstanceMembers()
                .filter(m => isClassPropertyType(m));
        }
        getStaticProperty(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getStaticProperties(), nameOrFindFunction);
        }
        getStaticPropertyOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getStaticProperty(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class static property", nameOrFindFunction));
        }
        getStaticProperties() {
            return this.getStaticMembers()
                .filter(m => isClassPropertyType(m));
        }
        getProperty(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getProperties(), nameOrFindFunction);
        }
        getPropertyOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getProperty(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class property declaration", nameOrFindFunction));
        }
        getProperties() {
            return this.getMembers()
                .filter(m => Node.isPropertyDeclaration(m));
        }
        getGetAccessor(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getGetAccessors(), nameOrFindFunction);
        }
        getGetAccessorOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getGetAccessor(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class getAccessor declaration", nameOrFindFunction));
        }
        getGetAccessors() {
            return this.getMembers()
                .filter(m => Node.isGetAccessorDeclaration(m));
        }
        getSetAccessor(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getSetAccessors(), nameOrFindFunction);
        }
        getSetAccessorOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getSetAccessor(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class setAccessor declaration", nameOrFindFunction));
        }
        getSetAccessors() {
            return this.getMembers()
                .filter(m => Node.isSetAccessorDeclaration(m));
        }
        getMethod(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getMethods(), nameOrFindFunction);
        }
        getMethodOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getMethod(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class method declaration", nameOrFindFunction));
        }
        getMethods() {
            return this.getMembers()
                .filter(m => Node.isMethodDeclaration(m));
        }
        getInstanceMethod(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getInstanceMethods(), nameOrFindFunction);
        }
        getInstanceMethodOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getInstanceMethod(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class instance method", nameOrFindFunction));
        }
        getInstanceMethods() {
            return this.getInstanceMembers().filter(m => m instanceof MethodDeclaration);
        }
        getStaticMethod(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getStaticMethods(), nameOrFindFunction);
        }
        getStaticMethodOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getStaticMethod(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class static method", nameOrFindFunction));
        }
        getStaticMethods() {
            return this.getStaticMembers().filter(m => m instanceof MethodDeclaration);
        }
        getInstanceMember(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getInstanceMembers(), nameOrFindFunction);
        }
        getInstanceMemberOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getInstanceMember(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class instance member", nameOrFindFunction));
        }
        getInstanceMembers() {
            return this.getMembersWithParameterProperties().filter(m => {
                if (Node.isConstructorDeclaration(m))
                    return false;
                return Node.isParameterDeclaration(m) || !m.isStatic();
            });
        }
        getStaticMember(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getStaticMembers(), nameOrFindFunction);
        }
        getStaticMemberOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getStaticMember(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class static member", nameOrFindFunction));
        }
        getStaticMembers() {
            return this.getMembers().filter(m => {
                if (Node.isConstructorDeclaration(m))
                    return false;
                return !Node.isParameterDeclaration(m) && m.isStatic();
            });
        }
        getMembersWithParameterProperties() {
            const members = this.getMembers();
            const implementationCtors = members.filter(c => Node.isConstructorDeclaration(c) && c.isImplementation());
            for (const ctor of implementationCtors) {
                let insertIndex = members.indexOf(ctor) + 1;
                for (const param of ctor.getParameters()) {
                    if (param.isParameterProperty()) {
                        members.splice(insertIndex, 0, param);
                        insertIndex++;
                    }
                }
            }
            return members;
        }
        getMembers() {
            return getAllMembers(this, this.compilerNode.members).filter(m => isSupportedClassMember(m));
        }
        getMembersWithComments() {
            const compilerNode = this.compilerNode;
            const members = ExtendedParser.getContainerArray(compilerNode, this.getSourceFile().compilerNode);
            return getAllMembers(this, members)
                .filter(m => isSupportedClassMember(m) || Node.isCommentClassElement(m));
        }
        getMember(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getMembers(), nameOrFindFunction);
        }
        getMemberOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getMember(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("class member", nameOrFindFunction));
        }
        getBaseTypes() {
            return this.getType().getBaseTypes();
        }
        getBaseClassOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getBaseClass(), `Expected to find the base class of ${this.getName()}.`);
        }
        getBaseClass() {
            const baseTypes = common.ArrayUtils.flatten(this.getBaseTypes().map(t => t.isIntersection() ? t.getIntersectionTypes() : [t]));
            const declarations = baseTypes
                .map(t => t.getSymbol())
                .filter(s => s != null)
                .map(s => s.getDeclarations())
                .reduce((a, b) => a.concat(b), [])
                .filter(d => d.getKind() === common.SyntaxKind.ClassDeclaration);
            if (declarations.length !== 1)
                return undefined;
            return declarations[0];
        }
        getDerivedClasses() {
            const classes = getImmediateDerivedClasses(this);
            for (let i = 0; i < classes.length; i++) {
                const derivedClasses = getImmediateDerivedClasses(classes[i]);
                for (const derivedClass of derivedClasses) {
                    if (derivedClass !== this && classes.indexOf(derivedClass) === -1)
                        classes.push(derivedClass);
                }
            }
            return classes;
        }
    };
}
function getAllMembers(classDec, compilerMembers) {
    const isAmbient = isNodeAmbientOrInAmbientContext(classDec);
    const members = compilerMembers.map(m => classDec._getNodeFromCompilerNode(m));
    return isAmbient ? members : members.filter(m => {
        if (!(Node.isConstructorDeclaration(m) || Node.isMethodDeclaration(m)))
            return true;
        if (Node.isMethodDeclaration(m) && m.isAbstract())
            return true;
        return m.isImplementation();
    });
}
function getImmediateDerivedClasses(classDec) {
    const classes = [];
    const nameNode = classDec.getNameNode();
    if (nameNode == null)
        return classes;
    for (const node of nameNode.findReferencesAsNodes()) {
        const nodeParent = node.getParentIfKind(common.SyntaxKind.ExpressionWithTypeArguments);
        if (nodeParent == null)
            continue;
        const heritageClause = nodeParent.getParentIfKind(common.SyntaxKind.HeritageClause);
        if (heritageClause == null || heritageClause.getToken() !== common.SyntaxKind.ExtendsKeyword)
            continue;
        const derivedClass = heritageClause.getParentIfKind(common.SyntaxKind.ClassDeclaration);
        if (derivedClass == null)
            continue;
        classes.push(derivedClass);
    }
    return classes;
}
function isClassPropertyType(m) {
    return Node.isPropertyDeclaration(m)
        || Node.isSetAccessorDeclaration(m)
        || Node.isGetAccessorDeclaration(m)
        || Node.isParameterDeclaration(m);
}
function isSupportedClassMember(m) {
    return Node.isMethodDeclaration(m)
        || Node.isPropertyDeclaration(m)
        || Node.isGetAccessorDeclaration(m)
        || Node.isSetAccessorDeclaration(m)
        || Node.isConstructorDeclaration(m)
        || Node.isClassStaticBlockDeclaration(m);
}
function insertChildren(classDeclaration, opts) {
    return insertIntoBracesOrSourceFileWithGetChildren(Object.assign({ getIndexedChildren: () => classDeclaration.getMembersWithComments(), parent: classDeclaration }, opts));
}

const createBase$j = (ctor) => ModuleChildableNode(AmbientableNode(ExportableNode(ClassLikeDeclarationBase(ctor))));
const ClassDeclarationBase = createBase$j(Statement);
class ClassDeclaration extends ClassDeclarationBase {
    set(structure) {
        callBaseSet(ClassDeclarationBase.prototype, this, structure);
        if (structure.extends != null)
            this.setExtends(structure.extends);
        else if (structure.hasOwnProperty("extends"))
            this.removeExtends();
        if (structure.ctors != null) {
            this.getConstructors().forEach(c => c.remove());
            this.addConstructors(structure.ctors);
        }
        if (structure.properties != null) {
            this.getProperties().forEach(p => p.remove());
            this.addProperties(structure.properties);
        }
        if (structure.getAccessors != null) {
            this.getGetAccessors().forEach(a => a.remove());
            this.addGetAccessors(structure.getAccessors);
        }
        if (structure.setAccessors != null) {
            this.getSetAccessors().forEach(a => a.remove());
            this.addSetAccessors(structure.setAccessors);
        }
        if (structure.methods != null) {
            this.getMethods().forEach(m => m.remove());
            this.addMethods(structure.methods);
        }
        return this;
    }
    getStructure() {
        const getExtends = this.getExtends();
        const isAmbient = this.isAmbient();
        return callBaseGetStructure(ClassDeclarationBase.prototype, this, {
            kind: exports.StructureKind.Class,
            ctors: this.getConstructors().filter(ctor => isAmbient || !ctor.isOverload()).map(ctor => ctor.getStructure()),
            methods: this.getMethods().filter(method => isAmbient || !method.isOverload()).map(method => method.getStructure()),
            properties: this.getProperties().map(property => property.getStructure()),
            extends: getExtends ? getExtends.getText() : undefined,
            getAccessors: this.getGetAccessors().map(getAccessor => getAccessor.getStructure()),
            setAccessors: this.getSetAccessors().map(accessor => accessor.getStructure()),
        });
    }
    extractInterface(name) {
        const { constructors, properties, methods, accessors } = getExtractedClassDetails(this, false);
        const parameterProperties = common.ArrayUtils.flatten(constructors.map(c => c.getParameters().filter(p => p.isParameterProperty())))
            .filter(p => p.getName() != null && p.getScope() === exports.Scope.Public);
        return {
            kind: exports.StructureKind.Interface,
            name: getDefaultExtractedName(name, this),
            docs: this.getJsDocs().map(d => d.getStructure()),
            typeParameters: this.getTypeParameters().map(p => p.getStructure()),
            properties: [
                ...parameterProperties.map(p => {
                    const jsDocComment = common.ArrayUtils.flatten(p.getParentOrThrow().getJsDocs().map(j => j.getTags()))
                        .filter(Node.isJSDocParameterTag)
                        .filter(t => t.getTagName() === "param" && t.getName() === p.getName() && t.getComment() != null)
                        .map(t => t.getCommentText().trim())[0];
                    return {
                        kind: exports.StructureKind.PropertySignature,
                        docs: jsDocComment == null ? [] : [{ kind: exports.StructureKind.JSDoc, description: jsDocComment }],
                        name: p.getName(),
                        type: p.getType().getText(p),
                        hasQuestionToken: p.hasQuestionToken(),
                        isReadonly: p.isReadonly(),
                    };
                }),
                ...properties.map(getExtractedInterfacePropertyStructure),
                ...accessors.map(getExtractedInterfaceAccessorStructure),
            ],
            methods: methods.map(getExtractedInterfaceMethodStructure),
        };
    }
    extractStaticInterface(name) {
        const { constructors, properties, methods, accessors } = getExtractedClassDetails(this, true);
        const instanceName = getDefaultExtractedName(undefined, this);
        return {
            kind: exports.StructureKind.Interface,
            name,
            properties: [
                ...properties.map(getExtractedInterfacePropertyStructure),
                ...accessors.map(getExtractedInterfaceAccessorStructure),
            ],
            methods: methods.map(getExtractedInterfaceMethodStructure),
            constructSignatures: constructors.map(c => ({
                kind: exports.StructureKind.ConstructSignature,
                docs: c.getJsDocs().map(d => d.getStructure()),
                parameters: c.getParameters().map(p => (Object.assign(Object.assign({}, getExtractedInterfaceParameterStructure(p)), { scope: undefined, isReadonly: false }))),
                returnType: instanceName,
            })),
        };
    }
}
function getExtractedClassDetails(classDec, isStatic) {
    const constructors = common.ArrayUtils.flatten(classDec.getConstructors().map(c => c.getOverloads().length > 0 ? c.getOverloads() : [c]));
    const properties = classDec.getProperties().filter(p => p.isStatic() === isStatic && p.getScope() === exports.Scope.Public);
    const methods = common.ArrayUtils.flatten(classDec.getMethods()
        .filter(p => p.isStatic() === isStatic && p.getScope() === exports.Scope.Public)
        .map(m => m.getOverloads().length > 0 ? m.getOverloads() : [m]));
    return { constructors, properties, methods, accessors: getAccessors() };
    function getAccessors() {
        const result = new common.KeyValueCache();
        for (const accessor of [...classDec.getGetAccessors(), ...classDec.getSetAccessors()]) {
            if (accessor.isStatic() === isStatic && accessor.getScope() === exports.Scope.Public)
                result.getOrCreate(accessor.getName(), () => []).push(accessor);
        }
        return result.getValuesAsArray();
    }
}
function getDefaultExtractedName(name, classDec) {
    name = common.StringUtils.isNullOrWhitespace(name) ? undefined : name;
    return name || classDec.getName() || classDec.getSourceFile().getBaseNameWithoutExtension().replace(/[^a-zA-Z0-9_$]/g, "");
}
function getExtractedInterfacePropertyStructure(prop) {
    return {
        kind: exports.StructureKind.PropertySignature,
        docs: prop.getJsDocs().map(d => d.getStructure()),
        name: prop.getName(),
        type: prop.getType().getText(prop),
        hasQuestionToken: prop.hasQuestionToken(),
        isReadonly: prop.isReadonly(),
    };
}
function getExtractedInterfaceAccessorStructure(getAndSet) {
    return {
        kind: exports.StructureKind.PropertySignature,
        docs: getAndSet[0].getJsDocs().map(d => d.getStructure()),
        name: getAndSet[0].getName(),
        type: getAndSet[0].getType().getText(getAndSet[0]),
        hasQuestionToken: false,
        isReadonly: getAndSet.every(Node.isGetAccessorDeclaration),
    };
}
function getExtractedInterfaceMethodStructure(method) {
    return {
        kind: exports.StructureKind.MethodSignature,
        docs: method.getJsDocs().map(d => d.getStructure()),
        name: method.getName(),
        hasQuestionToken: method.hasQuestionToken(),
        returnType: method.getReturnType().getText(method),
        parameters: method.getParameters().map(getExtractedInterfaceParameterStructure),
        typeParameters: method.getTypeParameters().map(p => p.getStructure()),
    };
}
function getExtractedInterfaceParameterStructure(param) {
    return Object.assign(Object.assign({}, param.getStructure()), { decorators: [] });
}

const ClassExpressionBase = ClassLikeDeclarationBase(PrimaryExpression);
class ClassExpression extends ClassExpressionBase {
}

const createBase$i = (ctor) => ChildOrderableNode(TextInsertableNode(StatementedNode(JSDocableNode(BodiedNode(ctor)))));
const ClassStaticBlockDeclarationBase = createBase$i(ClassElement);
class ClassStaticBlockDeclaration extends ClassStaticBlockDeclarationBase {
    getName() {
        return "static";
    }
    isStatic() {
        return true;
    }
    set(structure) {
        callBaseSet(ClassStaticBlockDeclarationBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(ClassStaticBlockDeclarationBase.prototype, this, {
            kind: exports.StructureKind.ClassStaticBlock,
        });
    }
}

class CommentClassElement extends ClassElement {
}

const createBase$h = (ctor) => ReferenceFindableNode(ChildOrderableNode(TextInsertableNode(OverloadableNode(ScopedNode(FunctionLikeDeclaration(BodyableNode(ctor)))))));
const ConstructorDeclarationBase = createBase$h(ClassElement);
const createOverloadBase = (ctor) => TypeParameteredNode(JSDocableNode(ChildOrderableNode(TextInsertableNode(ScopedNode(ModifierableNode(SignaturedDeclaration(ctor)))))));
const ConstructorDeclarationOverloadBase = createOverloadBase(ClassElement);
class ConstructorDeclaration extends ConstructorDeclarationBase {
    set(structure) {
        callBaseSet(ConstructorDeclarationBase.prototype, this, structure);
        if (structure.overloads != null) {
            this.getOverloads().forEach(o => o.remove());
            this.addOverloads(structure.overloads);
        }
        return this;
    }
    addOverload(structure) {
        return this.addOverloads([structure])[0];
    }
    addOverloads(structures) {
        return this.insertOverloads(this.getOverloads().length, structures);
    }
    insertOverload(index, structure) {
        return this.insertOverloads(index, [structure])[0];
    }
    insertOverloads(index, structures) {
        const printer = this._context.structurePrinterFactory.forConstructorDeclaration({
            isAmbient: isNodeAmbientOrInAmbientContext(this),
        });
        return insertOverloads({
            node: this,
            index,
            structures,
            printStructure: (writer, structure) => {
                printer.printOverload(writer, structure);
            },
            getThisStructure: fromConstructorDeclarationOverload,
            expectedSyntaxKind: common.SyntaxKind.Constructor,
        });
    }
    getStructure() {
        const hasImplementation = this.getImplementation() != null;
        const isOverload = this.isOverload();
        const basePrototype = isOverload && hasImplementation ? ConstructorDeclarationOverloadBase.prototype : ConstructorDeclarationBase.prototype;
        return callBaseGetStructure(basePrototype, this, getStructure(this));
        function getStructure(thisNode) {
            if (hasImplementation && isOverload)
                return getSpecificOverloadStructure();
            return getSpecificStructure();
            function getSpecificOverloadStructure() {
                return { kind: exports.StructureKind.ConstructorOverload };
            }
            function getSpecificStructure() {
                if (!hasImplementation)
                    return { kind: exports.StructureKind.Constructor };
                else {
                    return {
                        kind: exports.StructureKind.Constructor,
                        overloads: thisNode.getOverloads().map(o => o.getStructure()),
                    };
                }
            }
        }
    }
}

const createBase$g = (ctor) => ChildOrderableNode(TextInsertableNode(DecoratableNode(AbstractableNode(ScopedNode(StaticableNode(FunctionLikeDeclaration(BodyableNode(PropertyNamedNode(ctor)))))))));
const GetAccessorDeclarationBase = createBase$g(ClassElement);
class GetAccessorDeclaration extends GetAccessorDeclarationBase {
    set(structure) {
        callBaseSet(GetAccessorDeclarationBase.prototype, this, structure);
        return this;
    }
    getSetAccessor() {
        const thisName = this.getName();
        const isStatic = this.isStatic();
        return this.getParentOrThrow().forEachChild(sibling => {
            if (Node.isSetAccessorDeclaration(sibling) && sibling.getName() === thisName && sibling.isStatic() === isStatic)
                return sibling;
            return undefined;
        });
    }
    getSetAccessorOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getSetAccessor(), () => `Expected to find a corresponding set accessor for ${this.getName()}.`);
    }
    getStructure() {
        return callBaseGetStructure(GetAccessorDeclarationBase.prototype, this, {
            kind: exports.StructureKind.GetAccessor,
        });
    }
}

const createBase$f = (ctor) => ChildOrderableNode(OverrideableNode(AmbientableNode(DecoratableNode(AbstractableNode(ScopedNode(StaticableNode(JSDocableNode(ReadonlyableNode(ExclamationTokenableNode(QuestionTokenableNode(InitializerExpressionableNode(TypedNode(PropertyNamedNode(ModifierableNode(ctor)))))))))))))));
const PropertyDeclarationBase = createBase$f(ClassElement);
class PropertyDeclaration extends PropertyDeclarationBase {
    set(structure) {
        callBaseSet(PropertyDeclarationBase.prototype, this, structure);
        return this;
    }
    remove() {
        const parent = this.getParentOrThrow();
        switch (parent.getKind()) {
            case common.SyntaxKind.ClassDeclaration:
                super.remove();
                break;
            default:
                throw new common.errors.NotImplementedError(`Not implemented parent syntax kind: ${parent.getKindName()}`);
        }
    }
    getStructure() {
        return callBaseGetStructure(PropertyDeclarationBase.prototype, this, {
            kind: exports.StructureKind.Property,
        });
    }
}

const createBase$e = (ctor) => ChildOrderableNode(TextInsertableNode(DecoratableNode(AbstractableNode(ScopedNode(StaticableNode(FunctionLikeDeclaration(BodyableNode(PropertyNamedNode(ctor)))))))));
const SetAccessorDeclarationBase = createBase$e(ClassElement);
class SetAccessorDeclaration extends SetAccessorDeclarationBase {
    set(structure) {
        callBaseSet(SetAccessorDeclarationBase.prototype, this, structure);
        return this;
    }
    getGetAccessor() {
        const thisName = this.getName();
        const isStatic = this.isStatic();
        return this.getParentOrThrow().forEachChild(sibling => {
            if (Node.isGetAccessorDeclaration(sibling) && sibling.getName() === thisName && sibling.isStatic() === isStatic)
                return sibling;
            return undefined;
        });
    }
    getGetAccessorOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getGetAccessor(), () => `Expected to find a corresponding get accessor for ${this.getName()}.`);
    }
    getStructure() {
        return callBaseGetStructure(SetAccessorDeclarationBase.prototype, this, {
            kind: exports.StructureKind.SetAccessor,
        });
    }
}

const DecoratorBase = LeftHandSideExpressionedNode(Node);
class Decorator extends DecoratorBase {
    getName() {
        return this.getNameNode().getText();
    }
    getNameNode() {
        if (this.isDecoratorFactory()) {
            const callExpression = this.getCallExpression();
            return getIdentifierFromName(callExpression.getExpression());
        }
        return getIdentifierFromName(this.getExpression());
        function getIdentifierFromName(expression) {
            const identifier = getNameFromExpression(expression);
            if (!Node.isIdentifier(identifier)) {
                throw new common.errors.NotImplementedError(`Expected the decorator expression '${identifier.getText()}' to be an identifier, `
                    + `but it wasn't. Please report this as a bug.`);
            }
            return identifier;
        }
        function getNameFromExpression(expression) {
            if (Node.isPropertyAccessExpression(expression))
                return expression.getNameNode();
            return expression;
        }
    }
    getFullName() {
        const sourceFile = this.getSourceFile();
        if (this.isDecoratorFactory())
            return this.getCallExpression().getExpression().getText();
        return this.compilerNode.expression.getText(sourceFile.compilerNode);
    }
    isDecoratorFactory() {
        return this.compilerNode.expression.kind === common.SyntaxKind.CallExpression;
    }
    setIsDecoratorFactory(isDecoratorFactory) {
        if (this.isDecoratorFactory() === isDecoratorFactory)
            return this;
        if (isDecoratorFactory) {
            const expression = this.getExpression();
            const expressionText = expression.getText();
            insertIntoParentTextRange({
                parent: this,
                insertPos: expression.getStart(),
                newText: `${expressionText}()`,
                replacing: {
                    textLength: expressionText.length,
                },
                customMappings: newParent => {
                    return [{ currentNode: expression, newNode: newParent.expression.expression }];
                },
            });
        }
        else {
            const callExpression = this.getCallExpressionOrThrow();
            const expression = callExpression.getExpression();
            const expressionText = expression.getText();
            insertIntoParentTextRange({
                parent: this,
                insertPos: callExpression.getStart(),
                newText: `${expressionText}`,
                replacing: {
                    textLength: callExpression.getWidth(),
                },
                customMappings: newParent => {
                    return [{ currentNode: expression, newNode: newParent.expression }];
                },
            });
        }
        return this;
    }
    getCallExpressionOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getCallExpression(), "Expected to find a call expression.");
    }
    getCallExpression() {
        if (!this.isDecoratorFactory())
            return undefined;
        return this.getExpression();
    }
    getArguments() {
        var _a, _b;
        return (_b = (_a = this.getCallExpression()) === null || _a === void 0 ? void 0 : _a.getArguments()) !== null && _b !== void 0 ? _b : [];
    }
    getTypeArguments() {
        var _a, _b;
        return (_b = (_a = this.getCallExpression()) === null || _a === void 0 ? void 0 : _a.getTypeArguments()) !== null && _b !== void 0 ? _b : [];
    }
    addTypeArgument(argumentText) {
        return this.getCallExpressionOrThrow().addTypeArgument(argumentText);
    }
    addTypeArguments(argumentTexts) {
        return this.getCallExpressionOrThrow().addTypeArguments(argumentTexts);
    }
    insertTypeArgument(index, argumentText) {
        return this.getCallExpressionOrThrow().insertTypeArgument(index, argumentText);
    }
    insertTypeArguments(index, argumentTexts) {
        return this.getCallExpressionOrThrow().insertTypeArguments(index, argumentTexts);
    }
    removeTypeArgument(typeArgOrIndex) {
        const callExpression = this.getCallExpression();
        if (callExpression == null)
            throw new common.errors.InvalidOperationError("Cannot remove a type argument from a decorator that has no type arguments.");
        callExpression.removeTypeArgument(typeArgOrIndex);
        return this;
    }
    addArgument(argumentText) {
        return this.addArguments([argumentText])[0];
    }
    addArguments(argumentTexts) {
        return this.insertArguments(this.getArguments().length, argumentTexts);
    }
    insertArgument(index, argumentText) {
        return this.insertArguments(index, [argumentText])[0];
    }
    insertArguments(index, argumentTexts) {
        this.setIsDecoratorFactory(true);
        return this.getCallExpressionOrThrow().insertArguments(index, argumentTexts);
    }
    removeArgument(argOrIndex) {
        const callExpression = this.getCallExpression();
        if (callExpression == null)
            throw new common.errors.InvalidOperationError("Cannot remove an argument from a decorator that has no arguments.");
        callExpression.removeArgument(argOrIndex);
        return this;
    }
    remove() {
        const thisStartLinePos = this.getStartLinePos();
        const previousDecorator = this.getPreviousSiblingIfKind(common.SyntaxKind.Decorator);
        if (previousDecorator != null && previousDecorator.getStartLinePos() === thisStartLinePos) {
            removeChildren({
                children: [this],
                removePrecedingSpaces: true,
            });
        }
        else {
            removeChildrenWithFormattingFromCollapsibleSyntaxList({
                children: [this],
                getSiblingFormatting: (parent, sibling) => sibling.getStartLinePos() === thisStartLinePos ? FormattingKind.Space : FormattingKind.Newline,
            });
        }
    }
    set(structure) {
        callBaseSet(DecoratorBase.prototype, this, structure);
        if (structure.name != null)
            this.getNameNode().replaceWithText(structure.name);
        if (structure.arguments != null) {
            this.setIsDecoratorFactory(true);
            this.getArguments().map(a => this.removeArgument(a));
            this.addArguments(structure.arguments);
        }
        if (structure.typeArguments != null && structure.typeArguments.length > 0) {
            this.setIsDecoratorFactory(true);
            this.getTypeArguments().map(a => this.removeTypeArgument(a));
            this.addTypeArguments(structure.typeArguments);
        }
        return this;
    }
    getStructure() {
        const isDecoratorFactory = this.isDecoratorFactory();
        return callBaseGetStructure(DecoratorBase.prototype, this, {
            kind: exports.StructureKind.Decorator,
            name: this.getName(),
            arguments: isDecoratorFactory ? this.getArguments().map(arg => arg.getText()) : undefined,
            typeArguments: isDecoratorFactory ? this.getTypeArguments().map(arg => arg.getText()) : undefined,
        });
    }
}

function JSDocPropertyLikeTag(Base) {
    return class extends Base {
        getTypeExpression() {
            return this._getNodeFromCompilerNodeIfExists(this.compilerNode.typeExpression);
        }
        getTypeExpressionOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getTypeExpression(), `Expected to find a JS doc type expression.`);
        }
        getName() {
            return this.getNameNode().getText();
        }
        getNameNode() {
            return this._getNodeFromCompilerNode(this.compilerNode.name);
        }
        isBracketed() {
            return this.compilerNode.isBracketed;
        }
    };
}

function JSDocTypeExpressionableTag(Base) {
    return class extends Base {
        getTypeExpression() {
            const result = this._getNodeFromCompilerNodeIfExists(this.compilerNode.typeExpression);
            if (result != null && result.getWidth() === 0)
                return undefined;
            return result;
        }
        getTypeExpressionOrThrow() {
            return common.errors.throwIfNullOrUndefined(this.getTypeExpression(), `Expected to find the JS doc tag's type expression.`);
        }
    };
}

function JSDocTypeParameteredTag(Base) {
    return class extends Base {
        getTypeParameters() {
            return this.compilerNode.typeParameters
                .map(p => this._getNodeFromCompilerNode(p))
                .filter(p => p.getWidth() > 0);
        }
    };
}

function getTextWithoutStars(inputText) {
    const innerTextWithStars = inputText.replace(/^\/\*\*[^\S\n]*\n?/, "").replace(/(\r?\n)?[^\S\n]*\*\/$/, "");
    return innerTextWithStars.split(/\n/).map(line => {
        const starPos = getStarPosIfFirstNonWhitespaceChar(line);
        if (starPos === -1)
            return line;
        const substringStart = line[starPos + 1] === " " ? starPos + 2 : starPos + 1;
        return line.substring(substringStart);
    }).join("\n");
    function getStarPosIfFirstNonWhitespaceChar(text) {
        for (let i = 0; i < text.length; i++) {
            const charCode = text.charCodeAt(i);
            if (charCode === CharCodes.ASTERISK)
                return i;
            else if (!common.StringUtils.isWhitespaceCharCode(charCode))
                break;
        }
        return -1;
    }
}

const JSDocBase = Node;
class JSDoc extends JSDocBase {
    isMultiLine() {
        return this.getText().includes("\n");
    }
    getTags() {
        var _a, _b;
        return (_b = (_a = this.compilerNode.tags) === null || _a === void 0 ? void 0 : _a.map(t => this._getNodeFromCompilerNode(t))) !== null && _b !== void 0 ? _b : [];
    }
    getInnerText() {
        return getTextWithoutStars(this.getText());
    }
    getComment() {
        if (this.compilerNode.comment == null)
            return undefined;
        else if (typeof this.compilerNode.comment === "string")
            return this.compilerNode.comment;
        else
            return this.compilerNode.comment.map(n => this._getNodeFromCompilerNodeIfExists(n));
    }
    getCommentText() {
        if (typeof this.compilerNode.comment === "string")
            return this.compilerNode.comment;
        else
            return common.ts.getTextOfJSDocComment(this.compilerNode.comment);
    }
    getDescription() {
        var _a, _b;
        const sourceFileText = this.getSourceFile().getFullText();
        const endSearchStart = (_b = (_a = this.getTags()[0]) === null || _a === void 0 ? void 0 : _a.getStart()) !== null && _b !== void 0 ? _b : this.getEnd() - 2;
        const start = getStart(this);
        return getTextWithoutStars(sourceFileText.substring(start, Math.max(start, getEndPos())));
        function getStart(jsDoc) {
            const startOrSpacePos = jsDoc.getStart() + 3;
            if (sourceFileText.charCodeAt(startOrSpacePos) === CharCodes.SPACE)
                return startOrSpacePos + 1;
            return startOrSpacePos;
        }
        function getEndPos() {
            const endOrNewLinePos = getPreviousMatchingPos(sourceFileText, endSearchStart, charCode => charCode === CharCodes.NEWLINE || !common.StringUtils.isWhitespaceCharCode(charCode) && charCode !== CharCodes.ASTERISK);
            return getPreviousMatchingPos(sourceFileText, endOrNewLinePos, charCode => charCode !== CharCodes.NEWLINE && charCode !== CharCodes.CARRIAGE_RETURN);
        }
    }
    setDescription(textOrWriterFunction) {
        const tags = this.getTags();
        const startEditPos = this.getStart() + 3;
        const endEditPos = tags.length > 0
            ? getPreviousMatchingPos(this._sourceFile.getFullText(), tags[0].getStart(), c => c === CharCodes.ASTERISK) - 1
            : this.getEnd() - 2;
        replaceTextPossiblyCreatingChildNodes({
            parent: this,
            newText: getNewText.call(this),
            replacePos: startEditPos,
            replacingLength: endEditPos - startEditPos,
        });
        return this;
        function getNewText() {
            var _a, _b;
            const indentationText = this.getIndentationText();
            const newLineKind = this._context.manipulationSettings.getNewLineKindAsString();
            const rawLines = getTextFromStringOrWriter(this._getWriter(), textOrWriterFunction).split(/\r?\n/);
            const startsWithNewLine = rawLines[0].length === 0;
            const isSingleLine = rawLines.length === 1 && ((_b = (_a = this.compilerNode.tags) === null || _a === void 0 ? void 0 : _a.length) !== null && _b !== void 0 ? _b : 0) === 0;
            const linesText = isSingleLine ? rawLines[0] : rawLines.map(l => l.length === 0 ? `${indentationText} *` : `${indentationText} * ${l}`)
                .slice(startsWithNewLine ? 1 : 0)
                .join(newLineKind);
            return isSingleLine ? " " + linesText + " " : newLineKind + linesText + newLineKind + indentationText + " ";
        }
    }
    addTag(structure) {
        return this.addTags([structure])[0];
    }
    addTags(structures) {
        var _a, _b;
        return this.insertTags((_b = (_a = this.compilerNode.tags) === null || _a === void 0 ? void 0 : _a.length) !== null && _b !== void 0 ? _b : 0, structures);
    }
    insertTag(index, structure) {
        return this.insertTags(index, [structure])[0];
    }
    insertTags(index, structures) {
        if (common.ArrayUtils.isNullOrEmpty(structures))
            return [];
        const writer = this._getWriterWithQueuedIndentation();
        const tags = this.getTags();
        index = verifyAndGetIndex(index, tags.length);
        if (tags.length === 0 && !this.isMultiLine()) {
            const structurePrinter = this._context.structurePrinterFactory.forJSDoc();
            this.replaceWithText(writer => {
                structurePrinter.printText(writer, {
                    description: this.getDescription(),
                    tags: structures,
                });
            });
        }
        else {
            const structurePrinter = this._context.structurePrinterFactory.forJSDocTag({ printStarsOnNewLine: true });
            writer.newLine().write(" * ");
            structurePrinter.printTexts(writer, structures);
            writer.newLine().write(" *");
            writer.conditionalWrite(index < tags.length, " ");
            const replaceStart = getReplaceStart.call(this);
            const replaceEnd = getReplaceEnd.call(this);
            insertIntoParentTextRange({
                parent: this,
                insertPos: replaceStart,
                replacing: { textLength: replaceEnd - replaceStart },
                newText: writer.toString(),
            });
        }
        return getNodesToReturn(tags, this.getTags(), index, false);
        function getReplaceStart() {
            const searchStart = index < tags.length ? tags[index].getStart() : this.getEnd() - 2;
            const maxMin = this.getStart() + 3;
            return Math.max(maxMin, getPreviousMatchingPos(this.getSourceFile().getFullText(), searchStart, charCode => !common.StringUtils.isWhitespaceCharCode(charCode) && charCode !== CharCodes.ASTERISK));
        }
        function getReplaceEnd() {
            if (index < tags.length)
                return tags[index].getStart();
            return this.getEnd() - 1;
        }
    }
    remove() {
        removeChildren({
            children: [this],
            removeFollowingSpaces: true,
            removeFollowingNewLines: true,
        });
    }
    set(structure) {
        callBaseSet(JSDocBase.prototype, this, structure);
        if (structure.tags != null) {
            return this.replaceWithText(writer => {
                var _a;
                this._context.structurePrinterFactory.forJSDoc().printText(writer, {
                    description: (_a = structure.description) !== null && _a !== void 0 ? _a : this.getDescription(),
                    tags: structure.tags,
                });
            });
        }
        else if (structure.description != null) {
            this.setDescription(structure.description);
        }
        return this;
    }
    getStructure() {
        return callBaseGetStructure(JSDocBase.prototype, this, {
            kind: exports.StructureKind.JSDoc,
            description: this.getDescription(),
            tags: this.getTags().map(t => t.getStructure()),
        });
    }
}

const JSDocTagBase = Node;
class JSDocTag extends JSDocTagBase {
    getTagName() {
        return this.getTagNameNode().getText();
    }
    getTagNameNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.tagName);
    }
    setTagName(tagName) {
        return this.set({ tagName });
    }
    getComment() {
        if (this.compilerNode.comment == null)
            return undefined;
        else if (typeof this.compilerNode.comment === "string")
            return this.compilerNode.comment;
        else
            return this.compilerNode.comment.map(n => this._getNodeFromCompilerNodeIfExists(n));
    }
    getCommentText() {
        if (typeof this.compilerNode.comment === "string")
            return this.compilerNode.comment;
        else
            return common.ts.getTextOfJSDocComment(this.compilerNode.comment);
    }
    remove() {
        const jsDocBodyStart = this.getParentOrThrow().getStart() + 3;
        const nextJsDocTag = getNextJsDocTag(this);
        const isLastJsDoc = nextJsDocTag == null;
        const removalStart = getRemovalStart.call(this);
        removeChildren({
            children: [this],
            customRemovalPos: removalStart,
            customRemovalEnd: getNextTagStartOrDocEnd(this, nextJsDocTag),
            replaceTrivia: getReplaceTrivia.call(this),
        });
        function getRemovalStart() {
            return Math.max(jsDocBodyStart, getPreviousNonWhiteSpacePos(this, this.getStart()));
        }
        function getReplaceTrivia() {
            if (removalStart === jsDocBodyStart && isLastJsDoc)
                return "";
            const newLineKind = this._context.manipulationSettings.getNewLineKindAsString();
            const indentationText = this.getParentOrThrow().getIndentationText();
            return `${newLineKind}${indentationText} ` + (isLastJsDoc ? "" : "* ");
        }
    }
    set(structure) {
        callBaseSet(JSDocTagBase.prototype, this, structure);
        if (structure.text != null || structure.tagName != null) {
            return this.replaceWithText(writer => {
                var _a;
                this._context.structurePrinterFactory.forJSDocTag({ printStarsOnNewLine: true }).printText(writer, {
                    tagName: (_a = structure.tagName) !== null && _a !== void 0 ? _a : this.getTagName(),
                    text: structure.text != null ? structure.text : getText(this),
                });
            });
        }
        return this;
    }
    replaceWithText(textOrWriterFunction) {
        const newText = getTextFromStringOrWriter(this._getWriterWithQueuedIndentation(), textOrWriterFunction);
        const parent = this.getParentOrThrow();
        const childIndex = this.getChildIndex();
        const start = this.getStart();
        insertIntoParentTextRange({
            parent,
            insertPos: start,
            newText,
            replacing: {
                textLength: getTagEnd(this) - start,
            },
        });
        return parent.getChildren()[childIndex];
    }
    getStructure() {
        const text = getText(this);
        return callBaseGetStructure(JSDocTagBase.prototype, this, {
            kind: exports.StructureKind.JSDocTag,
            tagName: this.getTagName(),
            text: text.length === 0 ? undefined : text,
        });
    }
}
function getText(jsDocTag) {
    const text = jsDocTag.getSourceFile().getFullText();
    const nameEnd = jsDocTag.getTagNameNode().getEnd();
    const tagEnd = getTagEnd(jsDocTag);
    const startPos = Math.min(text.charCodeAt(nameEnd) === CharCodes.SPACE ? nameEnd + 1 : nameEnd, tagEnd);
    return getTextWithoutStars(text.substring(startPos, tagEnd));
}
function getTagEnd(jsDocTag) {
    return getPreviousNonWhiteSpacePos(jsDocTag, getNextTagStartOrDocEnd(jsDocTag));
}
function getNextTagStartOrDocEnd(jsDocTag, nextJsDocTag) {
    nextJsDocTag = nextJsDocTag !== null && nextJsDocTag !== void 0 ? nextJsDocTag : getNextJsDocTag(jsDocTag);
    return nextJsDocTag != null
        ? nextJsDocTag.getStart()
        : jsDocTag.getParentOrThrow().getEnd() - 2;
}
function getNextJsDocTag(jsDocTag) {
    const parent = jsDocTag.getParentIfKindOrThrow(common.SyntaxKind.JSDocComment);
    const tags = parent.getTags();
    const thisIndex = tags.indexOf(jsDocTag);
    return tags[thisIndex + 1];
}
function getPreviousNonWhiteSpacePos(jsDocTag, pos) {
    const sourceFileText = jsDocTag.getSourceFile().getFullText();
    return getPreviousMatchingPos(sourceFileText, pos, charCode => charCode !== CharCodes.ASTERISK && !common.StringUtils.isWhitespaceCharCode(charCode));
}

class JSDocAugmentsTag extends JSDocTag {
}

class JSDocAuthorTag extends JSDocTag {
}

class JSDocCallbackTag extends JSDocTag {
}

class JSDocClassTag extends JSDocTag {
}

class JSDocDeprecatedTag extends JSDocTag {
}

class JSDocEnumTag extends JSDocTag {
}

class TypeNode extends Node {
}

class ArrayTypeNode extends TypeNode {
    getElementTypeNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.elementType);
    }
}

class ConditionalTypeNode extends TypeNode {
    getCheckType() {
        return this._getNodeFromCompilerNode(this.compilerNode.checkType);
    }
    getExtendsType() {
        return this._getNodeFromCompilerNode(this.compilerNode.extendsType);
    }
    getTrueType() {
        return this._getNodeFromCompilerNode(this.compilerNode.trueType);
    }
    getFalseType() {
        return this._getNodeFromCompilerNode(this.compilerNode.falseType);
    }
}

const FunctionOrConstructorTypeNodeBaseBase = SignaturedDeclaration(TypeNode);
class FunctionOrConstructorTypeNodeBase extends FunctionOrConstructorTypeNodeBaseBase {
}

const ConstructorTypeNodeBase = AbstractableNode(ModifierableNode(FunctionOrConstructorTypeNodeBase));
class ConstructorTypeNode extends ConstructorTypeNodeBase {
}

const ExpressionWithTypeArgumentsBase = LeftHandSideExpressionedNode(TypeNode);
class ExpressionWithTypeArguments extends ExpressionWithTypeArgumentsBase {
    getTypeArguments() {
        var _a, _b;
        return (_b = (_a = this.compilerNode.typeArguments) === null || _a === void 0 ? void 0 : _a.map(a => this._getNodeFromCompilerNode(a))) !== null && _b !== void 0 ? _b : [];
    }
}

const FunctionTypeNodeBase = TypeParameteredNode(FunctionOrConstructorTypeNodeBase);
class FunctionTypeNode extends FunctionTypeNodeBase {
}

const ImportTypeNodeBase = TypeArgumentedNode(TypeNode);
class ImportTypeNode extends ImportTypeNodeBase {
    setArgument(text) {
        const arg = this.getArgument();
        if (Node.isLiteralTypeNode(arg)) {
            const literal = arg.getLiteral();
            if (Node.isStringLiteral(literal)) {
                literal.setLiteralValue(text);
                return this;
            }
        }
        arg.replaceWithText(writer => writer.quote(text), this._getWriterWithQueuedChildIndentation());
        return this;
    }
    getArgument() {
        return this._getNodeFromCompilerNode(this.compilerNode.argument);
    }
    setQualifier(text) {
        const qualifier = this.getQualifier();
        if (qualifier != null)
            qualifier.replaceWithText(text, this._getWriterWithQueuedChildIndentation());
        else {
            const paren = this.getFirstChildByKindOrThrow(common.SyntaxKind.CloseParenToken);
            insertIntoParentTextRange({
                insertPos: paren.getEnd(),
                parent: this,
                newText: this._getWriterWithQueuedIndentation().write(".").write(text).toString(),
            });
        }
        return this;
    }
    getQualifierOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getQualifier(), () => `Expected to find a qualifier for the import type: ${this.getText()}`);
    }
    getQualifier() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.qualifier);
    }
}

class IndexedAccessTypeNode extends TypeNode {
    getObjectTypeNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.objectType);
    }
    getIndexTypeNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.indexType);
    }
}

class InferTypeNode extends TypeNode {
    getTypeParameter() {
        return this._getNodeFromCompilerNode(this.compilerNode.typeParameter);
    }
}

class IntersectionTypeNode extends TypeNode {
    getTypeNodes() {
        return this.compilerNode.types.map(t => this._getNodeFromCompilerNode(t));
    }
}

class LiteralTypeNode extends TypeNode {
    getLiteral() {
        const tsLiteral = this.compilerNode.literal;
        return this._getNodeFromCompilerNode(tsLiteral);
    }
}

class MappedTypeNode extends TypeNode {
    getNameTypeNode() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.nameType);
    }
    getNameTypeNodeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getNameTypeNode(), "Type did not exist.");
    }
    getReadonlyToken() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.readonlyToken);
    }
    getReadonlyTokenOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getReadonlyToken(), "Readonly token did not exist.");
    }
    getQuestionToken() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.questionToken);
    }
    getQuestionTokenOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getQuestionToken(), "Question token did not exist.");
    }
    getTypeParameter() {
        return this._getNodeFromCompilerNode(this.compilerNode.typeParameter);
    }
    getTypeNode() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.type);
    }
    getTypeNodeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getTypeNode(), "Type did not exist, but was expected to exist.");
    }
}

const createBase$d = (ctor) => TypedNode(QuestionTokenableNode(DotDotDotTokenableNode(JSDocableNode(NamedNode(ctor)))));
const NamedTupleMemberBase = createBase$d(TypeNode);
class NamedTupleMember extends NamedTupleMemberBase {
    getTypeNode() {
        return super.getTypeNode();
    }
    removeType() {
        throw new common.errors.InvalidOperationError("Cannot remove the type of a named tuple member.");
    }
}

class ParenthesizedTypeNode extends TypeNode {
    getTypeNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.type);
    }
    setType(textOrWriterFunction) {
        this.getTypeNode().replaceWithText(textOrWriterFunction);
        return this;
    }
}

class TemplateLiteralTypeNode extends TypeNode {
}

class ThisTypeNode extends TypeNode {
}

class TupleTypeNode extends TypeNode {
    getElements() {
        return this.compilerNode.elements.map(t => this._getNodeFromCompilerNode(t));
    }
}

const createBase$c = (ctor) => TypeParameteredNode(TypedNode(JSDocableNode(AmbientableNode(ExportableNode(ModifierableNode(NamedNode(ctor)))))));
const TypeAliasDeclarationBase = createBase$c(Statement);
class TypeAliasDeclaration extends TypeAliasDeclarationBase {
    set(structure) {
        callBaseSet(TypeAliasDeclarationBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(TypeAliasDeclarationBase.prototype, this, {
            kind: exports.StructureKind.TypeAlias,
            type: this.getTypeNodeOrThrow().getText(),
        });
    }
}

const TypeLiteralNodeBase = TypeElementMemberedNode(TypeNode);
class TypeLiteralNode extends TypeLiteralNodeBase {
}

const TypeParameterDeclarationBase = NamedNode(Node);
class TypeParameterDeclaration extends TypeParameterDeclarationBase {
    getConstraint() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.constraint);
    }
    getConstraintOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getConstraint(), "Expected to find the type parameter's constraint.");
    }
    setConstraint(text) {
        text = this.getParentOrThrow()._getTextWithQueuedChildIndentation(text);
        if (common.StringUtils.isNullOrWhitespace(text)) {
            this.removeConstraint();
            return this;
        }
        const constraint = this.getConstraint();
        if (constraint != null) {
            constraint.replaceWithText(text);
            return this;
        }
        const nameNode = this.getNameNode();
        insertIntoParentTextRange({
            parent: this,
            insertPos: nameNode.getEnd(),
            newText: ` extends ${text}`,
        });
        return this;
    }
    removeConstraint() {
        removeConstraintOrDefault(this.getConstraint(), common.SyntaxKind.ExtendsKeyword);
        return this;
    }
    getDefault() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.default);
    }
    getDefaultOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getDefault(), "Expected to find the type parameter's default.");
    }
    setDefault(text) {
        text = this.getParentOrThrow()._getTextWithQueuedChildIndentation(text);
        if (common.StringUtils.isNullOrWhitespace(text)) {
            this.removeDefault();
            return this;
        }
        const defaultNode = this.getDefault();
        if (defaultNode != null) {
            defaultNode.replaceWithText(text);
            return this;
        }
        const insertAfterNode = this.getConstraint() || this.getNameNode();
        insertIntoParentTextRange({
            parent: this,
            insertPos: insertAfterNode.getEnd(),
            newText: ` = ${text}`,
        });
        return this;
    }
    removeDefault() {
        removeConstraintOrDefault(this.getDefault(), common.SyntaxKind.EqualsToken);
        return this;
    }
    remove() {
        const parentSyntaxList = this.getParentSyntaxListOrThrow();
        const typeParameters = parentSyntaxList.getChildrenOfKind(common.SyntaxKind.TypeParameter);
        if (typeParameters.length === 1)
            removeAllTypeParameters();
        else
            removeCommaSeparatedChild(this);
        function removeAllTypeParameters() {
            const children = [
                parentSyntaxList.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.LessThanToken),
                parentSyntaxList,
                parentSyntaxList.getNextSiblingIfKindOrThrow(common.SyntaxKind.GreaterThanToken),
            ];
            removeChildren({ children });
        }
    }
    set(structure) {
        callBaseSet(TypeParameterDeclarationBase.prototype, this, structure);
        if (structure.constraint != null)
            this.setConstraint(structure.constraint);
        else if (structure.hasOwnProperty("constraint"))
            this.removeConstraint();
        if (structure.default != null)
            this.setDefault(structure.default);
        else if (structure.hasOwnProperty("default"))
            this.removeDefault();
        return this;
    }
    getStructure() {
        const constraintNode = this.getConstraint();
        const defaultNode = this.getDefault();
        return callBaseGetStructure(TypeParameterDeclarationBase.prototype, this, {
            kind: exports.StructureKind.TypeParameter,
            constraint: constraintNode != null ? constraintNode.getText({ trimLeadingIndentation: true }) : undefined,
            default: defaultNode ? defaultNode.getText({ trimLeadingIndentation: true }) : undefined,
        });
    }
}
function removeConstraintOrDefault(nodeToRemove, siblingKind) {
    if (nodeToRemove == null)
        return;
    removeChildren({
        children: [nodeToRemove.getPreviousSiblingIfKindOrThrow(siblingKind), nodeToRemove],
        removePrecedingSpaces: true,
    });
}

class TypePredicateNode extends TypeNode {
    getParameterNameNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.parameterName);
    }
    hasAssertsModifier() {
        return this.compilerNode.assertsModifier != null;
    }
    getAssertsModifier() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.assertsModifier);
    }
    getAssertsModifierOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getAssertsModifier(), "Expected to find an asserts modifier.");
    }
    getTypeNode() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.type);
    }
    getTypeNodeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getTypeNode(), "Expected to find a type node.");
    }
}

class TypeReferenceNode extends TypeNode {
    getTypeName() {
        return this._getNodeFromCompilerNode(this.compilerNode.typeName);
    }
    getTypeArguments() {
        if (this.compilerNode.typeArguments == null)
            return [];
        return this.compilerNode.typeArguments.map(a => this._getNodeFromCompilerNode(a));
    }
}

class UnionTypeNode extends TypeNode {
    getTypeNodes() {
        return this.compilerNode.types.map(t => this._getNodeFromCompilerNode(t));
    }
}

class JSDocType extends TypeNode {
}

const JSDocFunctionTypeBase = SignaturedDeclaration(JSDocType);
class JSDocFunctionType extends JSDocFunctionTypeBase {
}

class JSDocImplementsTag extends JSDocTag {
}

class JSDocLink extends Node {
}

class JSDocLinkCode extends Node {
}

class JSDocLinkPlain extends Node {
}

class JSDocMemberName extends Node {
}

class JSDocOverrideTag extends JSDocTag {
}

const JSDocParameterTagBase = JSDocPropertyLikeTag(JSDocTag);
class JSDocParameterTag extends JSDocParameterTagBase {
}

class JSDocPrivateTag extends JSDocTag {
}

const JSDocPropertyTagBase = JSDocPropertyLikeTag(JSDocTag);
class JSDocPropertyTag extends JSDocPropertyTagBase {
}

class JSDocProtectedTag extends JSDocTag {
}

class JSDocPublicTag extends JSDocTag {
}

class JSDocReadonlyTag extends JSDocTag {
}

const JSDocReturnTagBase = JSDocTypeExpressionableTag(JSDocTag);
class JSDocReturnTag extends JSDocReturnTagBase {
}

const JSDocSeeTagBase = JSDocTypeExpressionableTag(JSDocTag);
class JSDocSeeTag extends JSDocSeeTagBase {
}

class JSDocSignature extends JSDocType {
    getTypeNode() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.type);
    }
}

class JSDocTagInfo {
    constructor(compilerObject) {
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getName() {
        return this.compilerObject.name;
    }
    getText() {
        var _a;
        return (_a = this.compilerObject.text) !== null && _a !== void 0 ? _a : [];
    }
}

const JSDocTemplateTagBase = JSDocTypeParameteredTag(JSDocTag);
class JSDocTemplateTag extends JSDocTemplateTagBase {
    getConstraint() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.constraint);
    }
    getConstraintOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getConstraint(), "Expected to find the JS doc template tag's constraint.");
    }
}

class JSDocText extends Node {
}

const JSDocThisTagBase = JSDocTypeExpressionableTag(JSDocTag);
class JSDocThisTag extends JSDocThisTagBase {
}

class JSDocTypedefTag extends JSDocTag {
}

class JSDocTypeExpression extends TypeNode {
    getTypeNode() {
        return this._getNodeFromCompilerNode(this.compilerNode.type);
    }
}

class JSDocTypeTag extends JSDocTag {
    getTypeExpression() {
        const node = this.compilerNode.typeExpression;
        if (node != null && node.pos === node.end)
            return undefined;
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.typeExpression);
    }
}

class JSDocUnknownTag extends JSDocTag {
}

class CommentEnumMember extends Node {
    remove() {
        removeChildrenWithFormatting({
            children: [this],
            getSiblingFormatting: () => FormattingKind.Newline,
        });
    }
}

const createBase$b = (ctor) => TextInsertableNode(ModuleChildableNode(JSDocableNode(AmbientableNode(ExportableNode(ModifierableNode(NamedNode(ctor)))))));
const EnumDeclarationBase = createBase$b(Statement);
class EnumDeclaration extends EnumDeclarationBase {
    set(structure) {
        callBaseSet(EnumDeclarationBase.prototype, this, structure);
        if (structure.isConst != null)
            this.setIsConstEnum(structure.isConst);
        if (structure.members != null) {
            this.getMembers().forEach(m => m.remove());
            this.addMembers(structure.members);
        }
        return this;
    }
    addMember(structure) {
        return this.addMembers([structure])[0];
    }
    addMembers(structures) {
        return this.insertMembers(this.getMembers().length, structures);
    }
    insertMember(index, structure) {
        return this.insertMembers(index, [structure])[0];
    }
    insertMembers(index, structures) {
        if (structures.length === 0)
            return [];
        const members = this.getMembersWithComments();
        index = verifyAndGetIndex(index, members.length);
        const writer = this._getWriterWithChildIndentation();
        const structurePrinter = this._context.structurePrinterFactory.forEnumMember();
        structurePrinter.printTexts(writer, structures);
        insertIntoCommaSeparatedNodes({
            parent: this.getChildSyntaxListOrThrow(),
            currentNodes: members,
            insertIndex: index,
            newText: writer.toString(),
            useNewLines: true,
            useTrailingCommas: this._context.manipulationSettings.getUseTrailingCommas(),
        });
        return getNodesToReturn(members, this.getMembersWithComments(), index, !areAllStructuresStructures());
        function areAllStructuresStructures() {
            if (!(structures instanceof Array))
                return false;
            return structures.every(s => typeof s === "object");
        }
    }
    getMember(nameOrFindFunction) {
        return getNodeByNameOrFindFunction(this.getMembers(), nameOrFindFunction);
    }
    getMemberOrThrow(nameOrFindFunction) {
        return common.errors.throwIfNullOrUndefined(this.getMember(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("enum member", nameOrFindFunction));
    }
    getMembers() {
        return this.compilerNode.members.map(m => this._getNodeFromCompilerNode(m));
    }
    getMembersWithComments() {
        const compilerNode = this.compilerNode;
        return ExtendedParser.getContainerArray(compilerNode, this.getSourceFile().compilerNode)
            .map(m => this._getNodeFromCompilerNode(m));
    }
    setIsConstEnum(value) {
        return this.toggleModifier("const", value);
    }
    isConstEnum() {
        return this.getConstKeyword() != null;
    }
    getConstKeyword() {
        return this.getFirstModifierByKind(common.SyntaxKind.ConstKeyword);
    }
    getStructure() {
        return callBaseGetStructure(EnumDeclarationBase.prototype, this, {
            kind: exports.StructureKind.Enum,
            isConst: this.isConstEnum(),
            members: this.getMembers().map(member => member.getStructure()),
        });
    }
}

const createBase$a = (ctor) => JSDocableNode(InitializerExpressionableNode(PropertyNamedNode(ctor)));
const EnumMemberBase = createBase$a(Node);
class EnumMember extends EnumMemberBase {
    getValue() {
        return this._context.typeChecker.getConstantValue(this);
    }
    setValue(value) {
        let text;
        if (typeof value === "string") {
            const quoteKind = this._context.manipulationSettings.getQuoteKind();
            text = quoteKind + common.StringUtils.escapeForWithinString(value, quoteKind) + quoteKind;
        }
        else {
            text = value.toString();
        }
        this.setInitializer(text);
        return this;
    }
    remove() {
        const childrenToRemove = [this];
        const commaToken = this.getNextSiblingIfKind(common.SyntaxKind.CommaToken);
        if (commaToken != null)
            childrenToRemove.push(commaToken);
        removeChildrenWithFormatting({
            children: childrenToRemove,
            getSiblingFormatting: () => FormattingKind.Newline,
        });
    }
    set(structure) {
        callBaseSet(EnumMemberBase.prototype, this, structure);
        if (structure.value != null)
            this.setValue(structure.value);
        else if (structure.hasOwnProperty("value") && structure.initializer == null)
            this.removeInitializer();
        return this;
    }
    getStructure() {
        return callBaseGetStructure(EnumMemberBase.prototype, this, {
            kind: exports.StructureKind.EnumMember,
            value: undefined,
        });
    }
}

class HeritageClause extends Node {
    getTypeNodes() {
        var _a, _b;
        return (_b = (_a = this.compilerNode.types) === null || _a === void 0 ? void 0 : _a.map(t => this._getNodeFromCompilerNode(t))) !== null && _b !== void 0 ? _b : [];
    }
    getToken() {
        return this.compilerNode.token;
    }
    removeExpression(expressionNodeOrIndex) {
        const expressions = this.getTypeNodes();
        const expressionNodeToRemove = typeof expressionNodeOrIndex === "number" ? getExpressionFromIndex(expressionNodeOrIndex) : expressionNodeOrIndex;
        if (expressions.length === 1) {
            const heritageClauses = this.getParentSyntaxListOrThrow().getChildren();
            if (heritageClauses.length === 1)
                removeChildren({ children: [heritageClauses[0].getParentSyntaxListOrThrow()], removePrecedingSpaces: true });
            else
                removeChildren({ children: [this], removePrecedingSpaces: true });
        }
        else {
            removeCommaSeparatedChild(expressionNodeToRemove);
        }
        return this;
        function getExpressionFromIndex(index) {
            return expressions[verifyAndGetIndex(index, expressions.length - 1)];
        }
    }
}

class TypeElement extends Node {
    remove() {
        removeInterfaceMember(this);
    }
}

const createBase$9 = (ctor) => TypeParameteredNode(ChildOrderableNode(JSDocableNode(SignaturedDeclaration(ctor))));
const CallSignatureDeclarationBase = createBase$9(TypeElement);
class CallSignatureDeclaration extends CallSignatureDeclarationBase {
    set(structure) {
        callBaseSet(CallSignatureDeclarationBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(CallSignatureDeclarationBase.prototype, this, {
            kind: exports.StructureKind.CallSignature,
        });
    }
}

class CommentTypeElement extends TypeElement {
}

const createBase$8 = (ctor) => TypeParameteredNode(ChildOrderableNode(JSDocableNode(SignaturedDeclaration(ctor))));
const ConstructSignatureDeclarationBase = createBase$8(TypeElement);
class ConstructSignatureDeclaration extends ConstructSignatureDeclarationBase {
    set(structure) {
        callBaseSet(ConstructSignatureDeclarationBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(ConstructSignatureDeclarationBase.prototype, this, {
            kind: exports.StructureKind.ConstructSignature,
        });
    }
}

const createBase$7 = (ctor) => ReturnTypedNode(ChildOrderableNode(JSDocableNode(ReadonlyableNode(ModifierableNode(ctor)))));
const IndexSignatureDeclarationBase = createBase$7(TypeElement);
class IndexSignatureDeclaration extends IndexSignatureDeclarationBase {
    getKeyName() {
        return this.getKeyNameNode().getText();
    }
    setKeyName(name) {
        common.errors.throwIfWhitespaceOrNotString(name, "name");
        if (this.getKeyName() === name)
            return;
        this.getKeyNameNode().replaceWithText(name, this._getWriterWithQueuedChildIndentation());
    }
    getKeyNameNode() {
        const param = this.compilerNode.parameters[0];
        return this._getNodeFromCompilerNode(param.name);
    }
    getKeyType() {
        return this.getKeyNameNode().getType();
    }
    setKeyType(type) {
        common.errors.throwIfWhitespaceOrNotString(type, "type");
        const keyTypeNode = this.getKeyTypeNode();
        if (keyTypeNode.getText() === type)
            return this;
        keyTypeNode.replaceWithText(type, this._getWriterWithQueuedChildIndentation());
        return this;
    }
    getKeyTypeNode() {
        const param = this.compilerNode.parameters[0];
        return this._getNodeFromCompilerNode(param.type);
    }
    set(structure) {
        callBaseSet(IndexSignatureDeclarationBase.prototype, this, structure);
        if (structure.keyName != null)
            this.setKeyName(structure.keyName);
        if (structure.keyType != null)
            this.setKeyType(structure.keyType);
        return this;
    }
    getStructure() {
        const keyTypeNode = this.getKeyTypeNode();
        return callBaseGetStructure(IndexSignatureDeclarationBase.prototype, this, {
            kind: exports.StructureKind.IndexSignature,
            keyName: this.getKeyName(),
            keyType: keyTypeNode.getText(),
        });
    }
}

const createBase$6 = (ctor) => TypeElementMemberedNode(TextInsertableNode(ExtendsClauseableNode(HeritageClauseableNode(TypeParameteredNode(JSDocableNode(AmbientableNode(ModuleChildableNode(ExportableNode(ModifierableNode(NamedNode(ctor)))))))))));
const InterfaceDeclarationBase = createBase$6(Statement);
class InterfaceDeclaration extends InterfaceDeclarationBase {
    getBaseTypes() {
        return this.getType().getBaseTypes();
    }
    getBaseDeclarations() {
        return common.ArrayUtils.flatten(this.getType().getBaseTypes().map(t => {
            var _a, _b;
            return (_b = (_a = t.getSymbol()) === null || _a === void 0 ? void 0 : _a.getDeclarations()) !== null && _b !== void 0 ? _b : [];
        }));
    }
    getImplementations() {
        return this.getNameNode().getImplementations();
    }
    set(structure) {
        callBaseSet(InterfaceDeclarationBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(InterfaceDeclarationBase.prototype, this, {
            kind: exports.StructureKind.Interface,
        });
    }
}

const createBase$5 = (ctor) => ChildOrderableNode(JSDocableNode(QuestionTokenableNode(TypeParameteredNode(SignaturedDeclaration(PropertyNamedNode(ctor))))));
const MethodSignatureBase = createBase$5(TypeElement);
class MethodSignature extends MethodSignatureBase {
    set(structure) {
        callBaseSet(MethodSignatureBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(MethodSignatureBase.prototype, this, {
            kind: exports.StructureKind.MethodSignature,
        });
    }
}

const createBase$4 = (ctor) => ChildOrderableNode(JSDocableNode(ReadonlyableNode(QuestionTokenableNode(InitializerExpressionableNode(TypedNode(PropertyNamedNode(ModifierableNode(ctor))))))));
const PropertySignatureBase = createBase$4(TypeElement);
class PropertySignature extends PropertySignatureBase {
    set(structure) {
        callBaseSet(PropertySignatureBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(PropertySignatureBase.prototype, this, {
            kind: exports.StructureKind.PropertySignature,
        });
    }
}

function JsxAttributedNode(Base) {
    return class extends Base {
        getAttributes() {
            return this.compilerNode.attributes.properties.map(p => this._getNodeFromCompilerNode(p));
        }
        getAttributeOrThrow(nameOrFindFunction) {
            return common.errors.throwIfNullOrUndefined(this.getAttribute(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("attribute", nameOrFindFunction));
        }
        getAttribute(nameOrFindFunction) {
            return getNodeByNameOrFindFunction(this.getAttributes(), nameOrFindFunction);
        }
        addAttribute(structure) {
            return this.addAttributes([structure])[0];
        }
        addAttributes(structures) {
            return this.insertAttributes(this.compilerNode.attributes.properties.length, structures);
        }
        insertAttribute(index, structure) {
            return this.insertAttributes(index, [structure])[0];
        }
        insertAttributes(index, structures) {
            if (structures.length === 0)
                return [];
            const originalChildrenCount = this.compilerNode.attributes.properties.length;
            index = verifyAndGetIndex(index, originalChildrenCount);
            const insertPos = index === 0 ? this.getTagNameNode().getEnd() : this.getAttributes()[index - 1].getEnd();
            const writer = this._getWriterWithQueuedChildIndentation();
            const structuresPrinter = new SpaceFormattingStructuresPrinter(this._context.structurePrinterFactory.forJsxAttributeDecider());
            structuresPrinter.printText(writer, structures);
            insertIntoParentTextRange({
                insertPos,
                newText: " " + writer.toString(),
                parent: this.getNodeProperty("attributes").getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
            });
            return getNodesToReturn(originalChildrenCount, this.getAttributes(), index, false);
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.attributes != null) {
                this.getAttributes().forEach(a => a.remove());
                this.addAttributes(structure.attributes);
            }
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                attributes: this.getAttributes().map(a => a.getStructure()),
            });
        }
    };
}

function JsxTagNamedNode(Base) {
    return class extends Base {
        getTagNameNode() {
            return this._getNodeFromCompilerNode(this.compilerNode.tagName);
        }
        set(structure) {
            callBaseSet(Base.prototype, this, structure);
            if (structure.name != null)
                this.getTagNameNode().replaceWithText(structure.name);
            return this;
        }
        getStructure() {
            return callBaseGetStructure(Base.prototype, this, {
                name: this.getTagNameNode().getText(),
            });
        }
    };
}

const JsxAttributeBase = NamedNode(Node);
class JsxAttribute extends JsxAttributeBase {
    getInitializerOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getInitializer(), `Expected to find an initializer for the JSX attribute '${this.getName()}'`);
    }
    getInitializer() {
        return this._getNodeFromCompilerNodeIfExists(this.compilerNode.initializer);
    }
    setInitializer(textOrWriterFunction) {
        const text = getTextFromStringOrWriter(this._getWriterWithQueuedIndentation(), textOrWriterFunction);
        if (common.StringUtils.isNullOrWhitespace(text)) {
            this.removeInitializer();
            return this;
        }
        const initializer = this.getInitializer();
        if (initializer != null) {
            initializer.replaceWithText(text);
            return this;
        }
        insertIntoParentTextRange({
            insertPos: this.getNameNode().getEnd(),
            parent: this,
            newText: `=${text}`,
        });
        return this;
    }
    removeInitializer() {
        const initializer = this.getInitializer();
        if (initializer == null)
            return this;
        removeChildren({
            children: [initializer.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.EqualsToken), initializer],
            removePrecedingSpaces: true,
            removePrecedingNewLines: true,
        });
        return this;
    }
    remove() {
        removeChildren({
            children: [this],
            removePrecedingNewLines: true,
            removePrecedingSpaces: true,
        });
    }
    set(structure) {
        callBaseSet(JsxAttributeBase.prototype, this, structure);
        if (structure.initializer != null)
            this.setInitializer(structure.initializer);
        else if (structure.hasOwnProperty("initializer"))
            this.removeInitializer();
        return this;
    }
    getStructure() {
        const initializer = this.getInitializer();
        return callBaseGetStructure(JsxAttributeBase.prototype, this, {
            kind: exports.StructureKind.JsxAttribute,
            initializer: initializer === null || initializer === void 0 ? void 0 : initializer.getText(),
        });
    }
}

const createBase$3 = (ctor) => JsxTagNamedNode(ctor);
const JsxClosingElementBase = createBase$3(Node);
class JsxClosingElement extends JsxClosingElementBase {
}

class JsxClosingFragment extends Expression {
}

const JsxElementBase = PrimaryExpression;
class JsxElement extends JsxElementBase {
    getJsxChildren() {
        return this.compilerNode.children.map(c => this._getNodeFromCompilerNode(c));
    }
    getOpeningElement() {
        return this._getNodeFromCompilerNode(this.compilerNode.openingElement);
    }
    getClosingElement() {
        return this._getNodeFromCompilerNode(this.compilerNode.closingElement);
    }
    setBodyText(textOrWriterFunction) {
        const newText = getBodyText(this._getWriterWithIndentation(), textOrWriterFunction);
        setText(this, newText);
        return this;
    }
    setBodyTextInline(textOrWriterFunction) {
        const writer = this._getWriterWithQueuedChildIndentation();
        printTextFromStringOrWriter(writer, textOrWriterFunction);
        if (writer.isLastNewLine()) {
            writer.setIndentationLevel(Math.max(0, this.getIndentationLevel() - 1));
            writer.write("");
        }
        setText(this, writer.toString());
        return this;
    }
    set(structure) {
        callBaseSet(JsxElementBase.prototype, this, structure);
        if (structure.attributes != null) {
            const openingElement = this.getOpeningElement();
            openingElement.getAttributes().forEach(a => a.remove());
            openingElement.addAttributes(structure.attributes);
        }
        if (structure.children != null)
            throw new common.errors.NotImplementedError("Setting JSX children is currently not implemented. Please open an issue if you need this.");
        if (structure.bodyText != null)
            this.setBodyText(structure.bodyText);
        else if (structure.hasOwnProperty("bodyText"))
            this.setBodyTextInline("");
        if (structure.name != null) {
            this.getOpeningElement().getTagNameNode().replaceWithText(structure.name);
            this.getClosingElement().getTagNameNode().replaceWithText(structure.name);
        }
        return this;
    }
    getStructure() {
        const openingElement = this.getOpeningElement();
        const structure = callBaseGetStructure(JsxElementBase.prototype, this, {
            kind: exports.StructureKind.JsxElement,
            name: openingElement.getTagNameNode().getText(),
            attributes: openingElement.getAttributes().map(a => a.getStructure()),
            children: undefined,
            bodyText: getBodyTextWithoutLeadingIndentation(this),
        });
        delete structure.children;
        return structure;
    }
}
function setText(element, newText) {
    const openingElement = element.getOpeningElement();
    const closingElement = element.getClosingElement();
    insertIntoParentTextRange({
        insertPos: openingElement.getEnd(),
        newText,
        parent: element.getChildSyntaxListOrThrow(),
        replacing: {
            textLength: closingElement.getStart() - openingElement.getEnd(),
        },
    });
}

const JsxExpressionBase = ExpressionableNode(DotDotDotTokenableNode(Expression));
class JsxExpression extends JsxExpressionBase {
}

class JsxFragment extends PrimaryExpression {
    getJsxChildren() {
        return this.compilerNode.children.map(c => this._getNodeFromCompilerNode(c));
    }
    getOpeningFragment() {
        return this._getNodeFromCompilerNode(this.compilerNode.openingFragment);
    }
    getClosingFragment() {
        return this._getNodeFromCompilerNode(this.compilerNode.closingFragment);
    }
}

const createBase$2 = (ctor) => JsxAttributedNode(JsxTagNamedNode(ctor));
const JsxOpeningElementBase = createBase$2(Expression);
class JsxOpeningElement extends JsxOpeningElementBase {
}

class JsxOpeningFragment extends Expression {
}

const createBase$1 = (ctor) => JsxAttributedNode(JsxTagNamedNode(ctor));
const JsxSelfClosingElementBase = createBase$1(PrimaryExpression);
class JsxSelfClosingElement extends JsxSelfClosingElementBase {
    set(structure) {
        callBaseSet(JsxSelfClosingElementBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(JsxSelfClosingElementBase.prototype, this, {
            kind: exports.StructureKind.JsxSelfClosingElement,
        });
    }
}

const JsxSpreadAttributeBase = ExpressionedNode(Node);
class JsxSpreadAttribute extends JsxSpreadAttributeBase {
    remove() {
        removeChildren({
            children: [this],
            removePrecedingNewLines: true,
            removePrecedingSpaces: true,
        });
    }
    set(structure) {
        callBaseSet(JsxSpreadAttributeBase.prototype, this, structure);
        if (structure.expression != null)
            this.setExpression(structure.expression);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(JsxSpreadAttributeBase.prototype, this, {
            kind: exports.StructureKind.JsxSpreadAttribute,
            expression: this.getExpression().getText(),
        });
    }
}

const JsxTextBase = LiteralLikeNode(Node);
class JsxText extends JsxTextBase {
    containsOnlyTriviaWhiteSpaces() {
        const oldCompilerNode = this.compilerNode;
        if (typeof oldCompilerNode.containsOnlyWhiteSpaces === "boolean")
            return oldCompilerNode.containsOnlyWhiteSpaces;
        return this.compilerNode.containsOnlyTriviaWhiteSpaces;
    }
}

const BigIntLiteralBase = LiteralExpression;
class BigIntLiteral extends BigIntLiteralBase {
    getLiteralValue() {
        const text = this.compilerNode.text;
        if (typeof BigInt === "undefined")
            throw new common.errors.InvalidOperationError("Runtime environment does not support BigInts. Perhaps work with the text instead?");
        const textWithoutN = text.substring(0, text.length - 1);
        return BigInt(textWithoutN);
    }
    setLiteralValue(value) {
        if (typeof value !== "bigint")
            throw new common.errors.ArgumentTypeError("value", "bigint", typeof value);
        replaceNodeText({
            sourceFile: this._sourceFile,
            start: this.getStart(),
            replacingLength: this.getWidth(),
            newText: value.toString() + "n",
        });
        return this;
    }
}

const TrueLiteralBase = PrimaryExpression;
class TrueLiteral extends TrueLiteralBase {
    getLiteralValue() {
        return getLiteralValue(this);
    }
    setLiteralValue(value) {
        return setLiteralValue(this, value);
    }
}
const FalseLiteralBase = PrimaryExpression;
class FalseLiteral extends FalseLiteralBase {
    getLiteralValue() {
        return getLiteralValue(this);
    }
    setLiteralValue(value) {
        return setLiteralValue(this, value);
    }
}
function setLiteralValue(node, value) {
    if (getLiteralValue(node) === value)
        return node;
    const parent = node.getParentSyntaxList() || node.getParentOrThrow();
    const index = node.getChildIndex();
    node.replaceWithText(value ? "true" : "false");
    return parent.getChildAtIndex(index);
}
function getLiteralValue(node) {
    return node.getKind() === common.SyntaxKind.TrueKeyword;
}

const NullLiteralBase = PrimaryExpression;
class NullLiteral extends NullLiteralBase {
}

const NumericLiteralBase = LiteralExpression;
class NumericLiteral extends NumericLiteralBase {
    getLiteralValue() {
        const text = this.compilerNode.text;
        if (text.indexOf(".") >= 0)
            return parseFloat(text);
        return parseInt(text, 10);
    }
    setLiteralValue(value) {
        replaceNodeText({
            sourceFile: this._sourceFile,
            start: this.getStart(),
            replacingLength: this.getWidth(),
            newText: value.toString(10),
        });
        return this;
    }
}

exports.QuoteKind = void 0;
(function (QuoteKind) {
    QuoteKind["Single"] = "'";
    QuoteKind["Double"] = "\"";
})(exports.QuoteKind || (exports.QuoteKind = {}));

const RegularExpressionLiteralBase = LiteralExpression;
class RegularExpressionLiteral extends RegularExpressionLiteralBase {
    getLiteralValue() {
        const pattern = /^\/(.*)\/([^\/]*)$/;
        const text = this.compilerNode.text;
        const matches = pattern.exec(text);
        return new RegExp(matches[1], matches[2]);
    }
    setLiteralValue(regExpOrPattern, flags) {
        let pattern;
        if (typeof regExpOrPattern === "string")
            pattern = regExpOrPattern;
        else {
            pattern = regExpOrPattern.source;
            flags = regExpOrPattern.flags;
        }
        replaceNodeText({
            sourceFile: this._sourceFile,
            start: this.getStart(),
            replacingLength: this.getWidth(),
            newText: `/${pattern}/${flags || ""}`,
        });
        return this;
    }
}

const StringLiteralBase = LiteralExpression;
class StringLiteral extends StringLiteralBase {
    getLiteralValue() {
        return this.compilerNode.text;
    }
    setLiteralValue(value) {
        replaceNodeText({
            sourceFile: this._sourceFile,
            start: this.getStart() + 1,
            replacingLength: this.getWidth() - 2,
            newText: common.StringUtils.escapeForWithinString(value, this.getQuoteKind()),
        });
        return this;
    }
    getQuoteKind() {
        return this.getText()[0] === "'" ? exports.QuoteKind.Single : exports.QuoteKind.Double;
    }
}

const NoSubstitutionTemplateLiteralBase = LiteralExpression;
class NoSubstitutionTemplateLiteral extends NoSubstitutionTemplateLiteralBase {
    getLiteralValue() {
        return this.compilerNode.text;
    }
    setLiteralValue(value) {
        const childIndex = this.getChildIndex();
        const parent = this.getParentSyntaxList() || this.getParentOrThrow();
        replaceNodeText({
            sourceFile: this._sourceFile,
            start: this.getStart() + 1,
            replacingLength: this.getWidth() - 2,
            newText: value,
        });
        return parent.getChildAtIndex(childIndex);
    }
}

class TaggedTemplateExpression extends MemberExpression {
    getTag() {
        return this._getNodeFromCompilerNode(this.compilerNode.tag);
    }
    getTemplate() {
        return this._getNodeFromCompilerNode(this.compilerNode.template);
    }
    removeTag() {
        var _a;
        const parent = (_a = this.getParentSyntaxList()) !== null && _a !== void 0 ? _a : this.getParentOrThrow();
        const index = this.getChildIndex();
        const template = this.getTemplate();
        insertIntoParentTextRange({
            customMappings: (newParent, newSourceFile) => [{ currentNode: template, newNode: newParent.getChildren(newSourceFile)[index] }],
            parent,
            insertPos: this.getStart(),
            newText: this.getTemplate().getText(),
            replacing: {
                textLength: this.getWidth(),
                nodes: [this],
            },
        });
        return parent.getChildAtIndex(index);
    }
}

const TemplateExpressionBase = PrimaryExpression;
class TemplateExpression extends TemplateExpressionBase {
    getHead() {
        return this._getNodeFromCompilerNode(this.compilerNode.head);
    }
    getTemplateSpans() {
        return this.compilerNode.templateSpans.map(s => this._getNodeFromCompilerNode(s));
    }
    setLiteralValue(value) {
        var _a;
        const childIndex = this.getChildIndex();
        const parent = (_a = this.getParentSyntaxList()) !== null && _a !== void 0 ? _a : this.getParentOrThrow();
        replaceNodeText({
            sourceFile: this._sourceFile,
            start: this.getStart() + 1,
            replacingLength: this.getWidth() - 2,
            newText: value,
        });
        return parent.getChildAtIndex(childIndex);
    }
}

const TemplateHeadBase = LiteralLikeNode(Node);
class TemplateHead extends TemplateHeadBase {
}

const TemplateMiddleBase = LiteralLikeNode(Node);
class TemplateMiddle extends TemplateMiddleBase {
}

const TemplateSpanBase = ExpressionedNode(Node);
class TemplateSpan extends TemplateSpanBase {
    getLiteral() {
        return this._getNodeFromCompilerNode(this.compilerNode.literal);
    }
}

const TemplateTailBase = LiteralLikeNode(Node);
class TemplateTail extends TemplateTailBase {
}

function CommonIdentifierBase(Base) {
    return class extends Base {
        getText() {
            return this.compilerNode.text;
        }
        getDefinitionNodes() {
            return this.getDefinitions().map(d => d.getDeclarationNode()).filter(d => d != null);
        }
        getDefinitions() {
            return this._context.languageService.getDefinitions(this);
        }
    };
}

const ComputedPropertyNameBase = ExpressionedNode(Node);
class ComputedPropertyName extends ComputedPropertyNameBase {
}

const IdentifierBase = CommonIdentifierBase(ReferenceFindableNode(RenameableNode(PrimaryExpression)));
class Identifier extends IdentifierBase {
    getImplementations() {
        return this._context.languageService.getImplementations(this);
    }
}

const PrivateIdentifierBase = CommonIdentifierBase(ReferenceFindableNode(RenameableNode(Node)));
class PrivateIdentifier extends PrivateIdentifierBase {
}

class QualifiedName extends Node {
    getLeft() {
        return this._getNodeFromCompilerNode(this.compilerNode.left);
    }
    getRight() {
        return this._getNodeFromCompilerNode(this.compilerNode.right);
    }
}

const createBase = (ctor) => ExportGetableNode(ExclamationTokenableNode(TypedNode(InitializerExpressionableNode(BindingNamedNode(ctor)))));
const VariableDeclarationBase = createBase(Node);
class VariableDeclaration extends VariableDeclarationBase {
    remove() {
        const parent = this.getParentOrThrow();
        switch (parent.getKind()) {
            case common.SyntaxKind.VariableDeclarationList:
                removeFromDeclarationList(this);
                break;
            case common.SyntaxKind.CatchClause:
                removeFromCatchClause(this);
                break;
            default:
                throw new common.errors.NotImplementedError(`Not implemented for syntax kind: ${parent.getKindName()}`);
        }
        function removeFromDeclarationList(node) {
            const variableStatement = parent.getParentIfKindOrThrow(common.SyntaxKind.VariableStatement);
            const declarations = variableStatement.getDeclarations();
            if (declarations.length === 1)
                variableStatement.remove();
            else
                removeCommaSeparatedChild(node);
        }
        function removeFromCatchClause(node) {
            removeChildren({
                children: [
                    node.getPreviousSiblingIfKindOrThrow(common.SyntaxKind.OpenParenToken),
                    node,
                    node.getNextSiblingIfKindOrThrow(common.SyntaxKind.CloseParenToken),
                ],
                removePrecedingSpaces: true,
            });
        }
    }
    getVariableStatementOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getVariableStatement(), "Expected the grandparent to be a variable statement.");
    }
    getVariableStatement() {
        const grandParent = this.getParentOrThrow().getParentOrThrow();
        return Node.isVariableStatement(grandParent) ? grandParent : undefined;
    }
    set(structure) {
        callBaseSet(VariableDeclarationBase.prototype, this, structure);
        return this;
    }
    getStructure() {
        return callBaseGetStructure(VariableDeclarationBase.prototype, this, {
            kind: exports.StructureKind.VariableDeclaration,
        });
    }
}

const VariableDeclarationListBase = ModifierableNode(Node);
class VariableDeclarationList extends VariableDeclarationListBase {
    getDeclarations() {
        return this.compilerNode.declarations.map(d => this._getNodeFromCompilerNode(d));
    }
    getDeclarationKind() {
        const nodeFlags = this.compilerNode.flags;
        if (nodeFlags & common.ts.NodeFlags.Let)
            return exports.VariableDeclarationKind.Let;
        else if (nodeFlags & common.ts.NodeFlags.Const)
            return exports.VariableDeclarationKind.Const;
        else
            return exports.VariableDeclarationKind.Var;
    }
    getDeclarationKindKeyword() {
        const declarationKind = this.getDeclarationKind();
        switch (declarationKind) {
            case exports.VariableDeclarationKind.Const:
                return this.getFirstChildByKindOrThrow(common.SyntaxKind.ConstKeyword);
            case exports.VariableDeclarationKind.Let:
                return this.getFirstChildByKindOrThrow(common.SyntaxKind.LetKeyword);
            case exports.VariableDeclarationKind.Var:
                return this.getFirstChildByKindOrThrow(common.SyntaxKind.VarKeyword);
            default:
                return common.errors.throwNotImplementedForNeverValueError(declarationKind);
        }
    }
    setDeclarationKind(type) {
        if (this.getDeclarationKind() === type)
            return this;
        const keyword = this.getDeclarationKindKeyword();
        insertIntoParentTextRange({
            insertPos: keyword.getStart(),
            newText: type,
            parent: this,
            replacing: {
                textLength: keyword.getWidth(),
            },
        });
        return this;
    }
    addDeclaration(structure) {
        return this.addDeclarations([structure])[0];
    }
    addDeclarations(structures) {
        return this.insertDeclarations(this.getDeclarations().length, structures);
    }
    insertDeclaration(index, structure) {
        return this.insertDeclarations(index, [structure])[0];
    }
    insertDeclarations(index, structures) {
        const writer = this._getWriterWithQueuedChildIndentation();
        const structurePrinter = new CommaSeparatedStructuresPrinter(this._context.structurePrinterFactory.forVariableDeclaration());
        const originalChildrenCount = this.compilerNode.declarations.length;
        index = verifyAndGetIndex(index, originalChildrenCount);
        structurePrinter.printText(writer, structures);
        insertIntoCommaSeparatedNodes({
            parent: this.getFirstChildByKindOrThrow(common.SyntaxKind.SyntaxList),
            currentNodes: this.getDeclarations(),
            insertIndex: index,
            newText: writer.toString(),
            useTrailingCommas: false,
        });
        return getNodesToReturn(originalChildrenCount, this.getDeclarations(), index, false);
    }
}

class Signature {
    constructor(context, signature) {
        this._context = context;
        this._compilerSignature = signature;
    }
    get compilerSignature() {
        return this._compilerSignature;
    }
    getTypeParameters() {
        const typeParameters = this.compilerSignature.typeParameters || [];
        return typeParameters.map(t => this._context.compilerFactory.getTypeParameter(t));
    }
    getParameters() {
        return this.compilerSignature.parameters.map(p => this._context.compilerFactory.getSymbol(p));
    }
    getReturnType() {
        return this._context.compilerFactory.getType(this.compilerSignature.getReturnType());
    }
    getDocumentationComments() {
        const docs = this.compilerSignature.getDocumentationComment(this._context.typeChecker.compilerObject);
        return docs.map(d => this._context.compilerFactory.getSymbolDisplayPart(d));
    }
    getJsDocTags() {
        const tags = this.compilerSignature.getJsDocTags();
        return tags.map(t => this._context.compilerFactory.getJSDocTagInfo(t));
    }
    getDeclaration() {
        const { compilerFactory } = this._context;
        const compilerSignatureDeclaration = this.compilerSignature.getDeclaration();
        return compilerFactory.getNodeFromCompilerNode(compilerSignatureDeclaration, compilerFactory.getSourceFileForNode(compilerSignatureDeclaration));
    }
}

class Symbol {
    constructor(context, symbol) {
        this._context = context;
        this._compilerSymbol = symbol;
        this.getValueDeclaration();
        this.getDeclarations();
    }
    get compilerSymbol() {
        return this._compilerSymbol;
    }
    getName() {
        return this.compilerSymbol.getName();
    }
    getEscapedName() {
        return this.compilerSymbol.getEscapedName();
    }
    getAliasedSymbolOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getAliasedSymbol(), "Expected to find an aliased symbol.");
    }
    getImmediatelyAliasedSymbol() {
        return this._context.typeChecker.getImmediatelyAliasedSymbol(this);
    }
    getImmediatelyAliasedSymbolOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getImmediatelyAliasedSymbol(), "Expected to find an immediately aliased symbol.");
    }
    getAliasedSymbol() {
        return this._context.typeChecker.getAliasedSymbol(this);
    }
    getExportSymbol() {
        return this._context.typeChecker.getExportSymbolOfSymbol(this);
    }
    isAlias() {
        return (this.getFlags() & common.SymbolFlags.Alias) === common.SymbolFlags.Alias;
    }
    getFlags() {
        return this.compilerSymbol.getFlags();
    }
    hasFlags(flags) {
        return (this.compilerSymbol.flags & flags) === flags;
    }
    getValueDeclarationOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getValueDeclaration(), () => `Expected to find the value declaration of symbol '${this.getName()}'.`);
    }
    getValueDeclaration() {
        const declaration = this.compilerSymbol.valueDeclaration;
        if (declaration == null)
            return undefined;
        return this._context.compilerFactory.getNodeFromCompilerNode(declaration, this._context.compilerFactory.getSourceFileForNode(declaration));
    }
    getDeclarations() {
        var _a;
        return ((_a = this.compilerSymbol.declarations) !== null && _a !== void 0 ? _a : [])
            .map(d => this._context.compilerFactory.getNodeFromCompilerNode(d, this._context.compilerFactory.getSourceFileForNode(d)));
    }
    getExportOrThrow(name) {
        return common.errors.throwIfNullOrUndefined(this.getExport(name), `Expected to find export with name: ${name}`);
    }
    getExport(name) {
        if (this.compilerSymbol.exports == null)
            return undefined;
        const tsSymbol = this.compilerSymbol.exports.get(common.ts.escapeLeadingUnderscores(name));
        return tsSymbol == null ? undefined : this._context.compilerFactory.getSymbol(tsSymbol);
    }
    getExports() {
        if (this.compilerSymbol.exports == null)
            return [];
        return common.ArrayUtils.from(this.compilerSymbol.exports.values()).map(symbol => this._context.compilerFactory.getSymbol(symbol));
    }
    getGlobalExportOrThrow(name) {
        return common.errors.throwIfNullOrUndefined(this.getGlobalExport(name), `Expected to find global export with name: ${name}`);
    }
    getGlobalExport(name) {
        if (this.compilerSymbol.globalExports == null)
            return undefined;
        const tsSymbol = this.compilerSymbol.globalExports.get(common.ts.escapeLeadingUnderscores(name));
        return tsSymbol == null ? undefined : this._context.compilerFactory.getSymbol(tsSymbol);
    }
    getGlobalExports() {
        if (this.compilerSymbol.globalExports == null)
            return [];
        return common.ArrayUtils.from(this.compilerSymbol.globalExports.values()).map(symbol => this._context.compilerFactory.getSymbol(symbol));
    }
    getMemberOrThrow(name) {
        return common.errors.throwIfNullOrUndefined(this.getMember(name), `Expected to find member with name: ${name}`);
    }
    getMember(name) {
        if (this.compilerSymbol.members == null)
            return undefined;
        const tsSymbol = this.compilerSymbol.members.get(common.ts.escapeLeadingUnderscores(name));
        return tsSymbol == null ? undefined : this._context.compilerFactory.getSymbol(tsSymbol);
    }
    getMembers() {
        if (this.compilerSymbol.members == null)
            return [];
        return common.ArrayUtils.from(this.compilerSymbol.members.values()).map(symbol => this._context.compilerFactory.getSymbol(symbol));
    }
    getDeclaredType() {
        return this._context.typeChecker.getDeclaredTypeOfSymbol(this);
    }
    getTypeAtLocation(node) {
        return this._context.typeChecker.getTypeOfSymbolAtLocation(this, node);
    }
    getFullyQualifiedName() {
        return this._context.typeChecker.getFullyQualifiedName(this);
    }
    getJsDocTags() {
        return this.compilerSymbol.getJsDocTags(this._context.typeChecker.compilerObject)
            .map(info => new JSDocTagInfo(info));
    }
}

class TextSpan {
    constructor(compilerObject) {
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getStart() {
        return this.compilerObject.start;
    }
    getEnd() {
        return this.compilerObject.start + this.compilerObject.length;
    }
    getLength() {
        return this.compilerObject.length;
    }
}

class TextChange {
    constructor(compilerObject) {
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getSpan() {
        return new TextSpan(this.compilerObject.span);
    }
    getNewText() {
        return this.compilerObject.newText;
    }
}
__decorate([
    common.Memoize
], TextChange.prototype, "getSpan", null);

class FileTextChanges {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
        const file = context.compilerFactory
            .getSourceFileFromCacheFromFilePath(context.fileSystemWrapper.getStandardizedAbsolutePath(compilerObject.fileName));
        this._existingFileExists = file != null;
        if (!compilerObject.isNewFile)
            this._sourceFile = file;
    }
    getFilePath() {
        return this._compilerObject.fileName;
    }
    getSourceFile() {
        return this._sourceFile;
    }
    getTextChanges() {
        return this._compilerObject.textChanges.map(c => new TextChange(c));
    }
    applyChanges(options = {}) {
        if (this._isApplied)
            return;
        if (this.isNewFile() && this._existingFileExists && !options.overwrite) {
            throw new common.errors.InvalidOperationError(`Cannot apply file text change for creating a new file when the `
                + `file exists at path ${this.getFilePath()}. Did you mean to provide the overwrite option?`);
        }
        let file;
        if (this.isNewFile())
            file = this._context.project.createSourceFile(this.getFilePath(), "", { overwrite: options.overwrite });
        else
            file = this.getSourceFile();
        if (file == null) {
            throw new common.errors.InvalidOperationError(`Cannot apply file text change to modify existing file `
                + `that doesn't exist at path: ${this.getFilePath()}`);
        }
        file.applyTextChanges(this.getTextChanges());
        this._isApplied = true;
        return this;
    }
    isNewFile() {
        return !!this._compilerObject.isNewFile;
    }
}
__decorate([
    common.Memoize
], FileTextChanges.prototype, "getTextChanges", null);

class CodeAction {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getDescription() {
        return this.compilerObject.description;
    }
    getChanges() {
        return this.compilerObject.changes.map(change => new FileTextChanges(this._context, change));
    }
}

class CodeFixAction extends CodeAction {
    getFixName() {
        return this.compilerObject.fixName;
    }
    getFixId() {
        return this.compilerObject.fixId;
    }
    getFixAllDescription() {
        return this.compilerObject.fixAllDescription;
    }
}

class CombinedCodeActions {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getChanges() {
        return this.compilerObject.changes.map(change => new FileTextChanges(this._context, change));
    }
    applyChanges(options) {
        for (const change of this.getChanges())
            change.applyChanges(options);
        return this;
    }
}
__decorate([
    common.Memoize
], CombinedCodeActions.prototype, "getChanges", null);

class DocumentSpan {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
        this._sourceFile = this._context.compilerFactory
            .getSourceFileFromCacheFromFilePath(context.fileSystemWrapper.getStandardizedAbsolutePath(this.compilerObject.fileName));
        this._sourceFile._doActionPreNextModification(() => this.getNode());
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getSourceFile() {
        return this._sourceFile;
    }
    getTextSpan() {
        return new TextSpan(this.compilerObject.textSpan);
    }
    getNode() {
        const textSpan = this.getTextSpan();
        const sourceFile = this.getSourceFile();
        const start = textSpan.getStart();
        const width = textSpan.getEnd();
        return findBestMatchingNode();
        function findBestMatchingNode() {
            let bestNode;
            sourceFile._context.compilerFactory.forgetNodesCreatedInBlock(remember => {
                let foundNode;
                let nextNode = sourceFile;
                while (nextNode != null) {
                    if (foundNode == null)
                        bestNode = nextNode;
                    if (nextNode.getStart() === start && nextNode.getWidth() === width)
                        bestNode = foundNode = nextNode;
                    else if (foundNode != null)
                        break;
                    nextNode = nextNode.getChildAtPos(start);
                }
                if (bestNode != null)
                    remember(bestNode);
            });
            return bestNode;
        }
    }
    getOriginalTextSpan() {
        const { originalTextSpan } = this.compilerObject;
        return originalTextSpan == null ? undefined : new TextSpan(originalTextSpan);
    }
    getOriginalFileName() {
        return this.compilerObject.originalFileName;
    }
}
__decorate([
    common.Memoize
], DocumentSpan.prototype, "getTextSpan", null);
__decorate([
    common.Memoize
], DocumentSpan.prototype, "getNode", null);
__decorate([
    common.Memoize
], DocumentSpan.prototype, "getOriginalTextSpan", null);

class DefinitionInfo extends DocumentSpan {
    constructor(context, compilerObject) {
        super(context, compilerObject);
        this.getSourceFile()._doActionPreNextModification(() => this.getDeclarationNode());
    }
    getKind() {
        return this.compilerObject.kind;
    }
    getName() {
        return this.compilerObject.name;
    }
    getContainerKind() {
        return this.compilerObject.containerKind;
    }
    getContainerName() {
        return this.compilerObject.containerName;
    }
    getDeclarationNode() {
        if (this.getKind() === "module" && this.getTextSpan().getLength() === this.getSourceFile().getFullWidth())
            return this.getSourceFile();
        const start = this.getTextSpan().getStart();
        const identifier = findIdentifier(this.getSourceFile());
        return identifier == null ? undefined : identifier.getParentOrThrow();
        function findIdentifier(node) {
            if (node.getKind() === common.SyntaxKind.Identifier && node.getStart() === start)
                return node;
            for (const child of node._getChildrenIterator()) {
                if (child.getPos() <= start && child.getEnd() > start)
                    return findIdentifier(child);
            }
            return undefined;
        }
    }
}
__decorate([
    common.Memoize
], DefinitionInfo.prototype, "getDeclarationNode", null);

class DiagnosticMessageChain {
    constructor(compilerObject) {
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getMessageText() {
        return this.compilerObject.messageText;
    }
    getNext() {
        const next = this.compilerObject.next;
        if (next == null)
            return undefined;
        if (next instanceof Array)
            return next.map(n => new DiagnosticMessageChain(n));
        return [new DiagnosticMessageChain(next)];
    }
    getCode() {
        return this.compilerObject.code;
    }
    getCategory() {
        return this.compilerObject.category;
    }
}

class Diagnostic {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
        this.getSourceFile();
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getSourceFile() {
        if (this._context == null)
            return undefined;
        const file = this.compilerObject.file;
        return file == null ? undefined : this._context.compilerFactory.getSourceFile(file, { markInProject: false });
    }
    getMessageText() {
        const messageText = this._compilerObject.messageText;
        if (typeof messageText === "string")
            return messageText;
        if (this._context == null)
            return new DiagnosticMessageChain(messageText);
        else
            return this._context.compilerFactory.getDiagnosticMessageChain(messageText);
    }
    getLineNumber() {
        const sourceFile = this.getSourceFile();
        const start = this.getStart();
        if (sourceFile == null || start == null)
            return undefined;
        return common.StringUtils.getLineNumberAtPos(sourceFile.getFullText(), start);
    }
    getStart() {
        return this.compilerObject.start;
    }
    getLength() {
        return this.compilerObject.length;
    }
    getCategory() {
        return this.compilerObject.category;
    }
    getCode() {
        return this.compilerObject.code;
    }
    getSource() {
        return this.compilerObject.source;
    }
}
__decorate([
    common.Memoize
], Diagnostic.prototype, "getSourceFile", null);

class DiagnosticWithLocation extends Diagnostic {
    constructor(context, compilerObject) {
        super(context, compilerObject);
    }
    getLineNumber() {
        return super.getLineNumber();
    }
    getStart() {
        return super.getStart();
    }
    getLength() {
        return super.getLength();
    }
    getSourceFile() {
        return super.getSourceFile();
    }
}

class OutputFile {
    constructor(context, compilerObject) {
        this._compilerObject = compilerObject;
        this._context = context;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getFilePath() {
        return this._context.fileSystemWrapper.getStandardizedAbsolutePath(this.compilerObject.name);
    }
    getWriteByteOrderMark() {
        return this.compilerObject.writeByteOrderMark || false;
    }
    getText() {
        return this.compilerObject.text;
    }
}

class EmitOutput {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getEmitSkipped() {
        return this.compilerObject.emitSkipped;
    }
    getOutputFiles() {
        return this.compilerObject.outputFiles.map(f => new OutputFile(this._context, f));
    }
}
__decorate([
    common.Memoize
], EmitOutput.prototype, "getOutputFiles", null);

class EmitResult {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
        this.getDiagnostics();
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getEmitSkipped() {
        return this.compilerObject.emitSkipped;
    }
    getDiagnostics() {
        return this.compilerObject.diagnostics.map(d => this._context.compilerFactory.getDiagnostic(d));
    }
}
__decorate([
    common.Memoize
], EmitResult.prototype, "getDiagnostics", null);

class ImplementationLocation extends DocumentSpan {
    constructor(context, compilerObject) {
        super(context, compilerObject);
    }
    getKind() {
        return this.compilerObject.kind;
    }
    getDisplayParts() {
        return this.compilerObject.displayParts.map(p => this._context.compilerFactory.getSymbolDisplayPart(p));
    }
}
__decorate([
    common.Memoize
], ImplementationLocation.prototype, "getDisplayParts", null);

class MemoryEmitResult extends EmitResult {
    constructor(context, compilerObject, _files) {
        super(context, compilerObject);
        this._files = _files;
    }
    getFiles() {
        return this._files;
    }
    saveFiles() {
        const fileSystem = this._context.fileSystemWrapper;
        const promises = this._files.map(f => fileSystem.writeFile(f.filePath, f.writeByteOrderMark ? "\uFEFF" + f.text : f.text));
        return Promise.all(promises);
    }
    saveFilesSync() {
        const fileSystem = this._context.fileSystemWrapper;
        for (const file of this._files)
            fileSystem.writeFileSync(file.filePath, file.writeByteOrderMark ? "\uFEFF" + file.text : file.text);
    }
}

class RefactorEditInfo {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getEdits() {
        return this.compilerObject.edits.map(edit => new FileTextChanges(this._context, edit));
    }
    getRenameFilePath() {
        return this.compilerObject.renameFilename;
    }
    getRenameLocation() {
        return this.compilerObject.renameLocation;
    }
    applyChanges(options) {
        for (const change of this.getEdits())
            change.applyChanges(options);
        return this;
    }
}
__decorate([
    common.Memoize
], RefactorEditInfo.prototype, "getEdits", null);

class ReferencedSymbol {
    constructor(context, compilerObject) {
        this._context = context;
        this._compilerObject = compilerObject;
        this._references = this.compilerObject.references.map(r => context.compilerFactory.getReferenceEntry(r));
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getDefinition() {
        return this._context.compilerFactory.getReferencedSymbolDefinitionInfo(this.compilerObject.definition);
    }
    getReferences() {
        return this._references;
    }
}
__decorate([
    common.Memoize
], ReferencedSymbol.prototype, "getDefinition", null);

class ReferencedSymbolDefinitionInfo extends DefinitionInfo {
    constructor(context, compilerObject) {
        super(context, compilerObject);
    }
    getDisplayParts() {
        return this.compilerObject.displayParts.map(p => this._context.compilerFactory.getSymbolDisplayPart(p));
    }
}
__decorate([
    common.Memoize
], ReferencedSymbolDefinitionInfo.prototype, "getDisplayParts", null);

class ReferenceEntry extends DocumentSpan {
    constructor(context, compilerObject) {
        super(context, compilerObject);
    }
    isWriteAccess() {
        return this.compilerObject.isWriteAccess;
    }
    isDefinition() {
        return this.compilerObject.isDefinition;
    }
    isInString() {
        return this.compilerObject.isInString;
    }
}

class RenameLocation extends DocumentSpan {
    getPrefixText() {
        return this._compilerObject.prefixText;
    }
    getSuffixText() {
        return this._compilerObject.suffixText;
    }
}

class SymbolDisplayPart {
    constructor(compilerObject) {
        this._compilerObject = compilerObject;
    }
    get compilerObject() {
        return this._compilerObject;
    }
    getText() {
        return this.compilerObject.text;
    }
    getKind() {
        return this.compilerObject.kind;
    }
}

class TypeChecker {
    constructor(context) {
        this._context = context;
    }
    get compilerObject() {
        return this._getCompilerObject();
    }
    _reset(getTypeChecker) {
        this._getCompilerObject = getTypeChecker;
    }
    getAmbientModules() {
        return this.compilerObject.getAmbientModules().map(s => this._context.compilerFactory.getSymbol(s));
    }
    getApparentType(type) {
        return this._context.compilerFactory.getType(this.compilerObject.getApparentType(type.compilerType));
    }
    getConstantValue(node) {
        return this.compilerObject.getConstantValue(node.compilerNode);
    }
    getFullyQualifiedName(symbol) {
        return this.compilerObject.getFullyQualifiedName(symbol.compilerSymbol);
    }
    getTypeAtLocation(node) {
        return this._context.compilerFactory.getType(this.compilerObject.getTypeAtLocation(node.compilerNode));
    }
    getContextualType(expression) {
        const contextualType = this.compilerObject.getContextualType(expression.compilerNode);
        return contextualType == null ? undefined : this._context.compilerFactory.getType(contextualType);
    }
    getTypeOfSymbolAtLocation(symbol, node) {
        return this._context.compilerFactory.getType(this.compilerObject.getTypeOfSymbolAtLocation(symbol.compilerSymbol, node.compilerNode));
    }
    getDeclaredTypeOfSymbol(symbol) {
        return this._context.compilerFactory.getType(this.compilerObject.getDeclaredTypeOfSymbol(symbol.compilerSymbol));
    }
    getSymbolAtLocation(node) {
        const compilerSymbol = this.compilerObject.getSymbolAtLocation(node.compilerNode);
        return compilerSymbol == null ? undefined : this._context.compilerFactory.getSymbol(compilerSymbol);
    }
    getAliasedSymbol(symbol) {
        if (!symbol.hasFlags(common.SymbolFlags.Alias))
            return undefined;
        const tsAliasSymbol = this.compilerObject.getAliasedSymbol(symbol.compilerSymbol);
        return tsAliasSymbol == null ? undefined : this._context.compilerFactory.getSymbol(tsAliasSymbol);
    }
    getImmediatelyAliasedSymbol(symbol) {
        const tsAliasSymbol = this.compilerObject.getImmediateAliasedSymbol(symbol.compilerSymbol);
        return tsAliasSymbol == null ? undefined : this._context.compilerFactory.getSymbol(tsAliasSymbol);
    }
    getExportSymbolOfSymbol(symbol) {
        return this._context.compilerFactory.getSymbol(this.compilerObject.getExportSymbolOfSymbol(symbol.compilerSymbol));
    }
    getPropertiesOfType(type) {
        return this.compilerObject.getPropertiesOfType(type.compilerType).map(p => this._context.compilerFactory.getSymbol(p));
    }
    getTypeText(type, enclosingNode, typeFormatFlags) {
        if (typeFormatFlags == null)
            typeFormatFlags = this._getDefaultTypeFormatFlags(enclosingNode);
        return this.compilerObject.typeToString(type.compilerType, enclosingNode === null || enclosingNode === void 0 ? void 0 : enclosingNode.compilerNode, typeFormatFlags);
    }
    getReturnTypeOfSignature(signature) {
        return this._context.compilerFactory.getType(this.compilerObject.getReturnTypeOfSignature(signature.compilerSignature));
    }
    getSignatureFromNode(node) {
        const signature = this.compilerObject.getSignatureFromDeclaration(node.compilerNode);
        return signature == null ? undefined : this._context.compilerFactory.getSignature(signature);
    }
    getExportsOfModule(moduleSymbol) {
        const symbols = this.compilerObject.getExportsOfModule(moduleSymbol.compilerSymbol);
        return (symbols || []).map(s => this._context.compilerFactory.getSymbol(s));
    }
    getExportSpecifierLocalTargetSymbol(exportSpecifier) {
        const symbol = this.compilerObject.getExportSpecifierLocalTargetSymbol(exportSpecifier.compilerNode);
        return symbol == null ? undefined : this._context.compilerFactory.getSymbol(symbol);
    }
    getResolvedSignature(node) {
        const resolvedSignature = this.compilerObject.getResolvedSignature(node.compilerNode);
        if (!resolvedSignature || !resolvedSignature.declaration)
            return undefined;
        return this._context.compilerFactory.getSignature(resolvedSignature);
    }
    getResolvedSignatureOrThrow(node) {
        return common.errors.throwIfNullOrUndefined(this.getResolvedSignature(node), "Signature could not be resolved.");
    }
    getBaseTypeOfLiteralType(type) {
        return this._context.compilerFactory.getType(this.compilerObject.getBaseTypeOfLiteralType(type.compilerType));
    }
    getSymbolsInScope(node, meaning) {
        return this.compilerObject.getSymbolsInScope(node.compilerNode, meaning)
            .map(s => this._context.compilerFactory.getSymbol(s));
    }
    getTypeArguments(typeReference) {
        return this.compilerObject.getTypeArguments(typeReference.compilerType)
            .map(arg => this._context.compilerFactory.getType(arg));
    }
    _getDefaultTypeFormatFlags(enclosingNode) {
        let formatFlags = (common.TypeFormatFlags.UseTypeOfFunction | common.TypeFormatFlags.NoTruncation | common.TypeFormatFlags.UseFullyQualifiedType
            | common.TypeFormatFlags.WriteTypeArgumentsOfSignature);
        if (enclosingNode != null && enclosingNode.getKind() === common.SyntaxKind.TypeAliasDeclaration)
            formatFlags |= common.TypeFormatFlags.InTypeAlias;
        return formatFlags;
    }
}

class Program {
    constructor(opts) {
        this._context = opts.context;
        this._configFileParsingDiagnostics = opts.configFileParsingDiagnostics;
        this._typeChecker = new TypeChecker(this._context);
        this._reset(opts.rootNames, opts.host);
    }
    get compilerObject() {
        return this._getOrCreateCompilerObject();
    }
    _isCompilerProgramCreated() {
        return this._createdCompilerObject != null;
    }
    _reset(rootNames, host) {
        const compilerOptions = this._context.compilerOptions.get();
        this._getOrCreateCompilerObject = () => {
            if (this._createdCompilerObject == null) {
                this._createdCompilerObject = common.ts.createProgram(rootNames, compilerOptions, host, this._oldProgram, this._configFileParsingDiagnostics);
                delete this._oldProgram;
            }
            return this._createdCompilerObject;
        };
        if (this._createdCompilerObject != null) {
            this._oldProgram = this._createdCompilerObject;
            delete this._createdCompilerObject;
        }
        this._typeChecker._reset(() => this.compilerObject.getTypeChecker());
    }
    getTypeChecker() {
        return this._typeChecker;
    }
    emit(options = {}) {
        return __awaiter(this, void 0, void 0, function* () {
            if (options.writeFile) {
                const message = `Cannot specify a ${"writeFile"} option when emitting asynchrously. `
                    + `Use ${"emitSync"}() instead.`;
                throw new common.errors.InvalidOperationError(message);
            }
            const { fileSystemWrapper } = this._context;
            const promises = [];
            const emitResult = this._emit(Object.assign({ writeFile: (filePath, text, writeByteOrderMark) => {
                    promises
                        .push(fileSystemWrapper.writeFile(fileSystemWrapper.getStandardizedAbsolutePath(filePath), writeByteOrderMark ? "\uFEFF" + text : text));
                } }, options));
            yield Promise.all(promises);
            return new EmitResult(this._context, emitResult);
        });
    }
    emitSync(options = {}) {
        return new EmitResult(this._context, this._emit(options));
    }
    emitToMemory(options = {}) {
        const sourceFiles = [];
        const { fileSystemWrapper } = this._context;
        const emitResult = this._emit(Object.assign({ writeFile: (filePath, text, writeByteOrderMark) => {
                sourceFiles.push({
                    filePath: fileSystemWrapper.getStandardizedAbsolutePath(filePath),
                    text,
                    writeByteOrderMark: writeByteOrderMark || false,
                });
            } }, options));
        return new MemoryEmitResult(this._context, emitResult, sourceFiles);
    }
    _emit(options = {}) {
        const targetSourceFile = options.targetSourceFile != null ? options.targetSourceFile.compilerNode : undefined;
        const { emitOnlyDtsFiles, customTransformers, writeFile } = options;
        const cancellationToken = undefined;
        return this.compilerObject.emit(targetSourceFile, writeFile, cancellationToken, emitOnlyDtsFiles, customTransformers);
    }
    getSyntacticDiagnostics(sourceFile) {
        const compilerDiagnostics = this.compilerObject.getSyntacticDiagnostics(sourceFile == null ? undefined : sourceFile.compilerNode);
        return compilerDiagnostics.map(d => this._context.compilerFactory.getDiagnosticWithLocation(d));
    }
    getSemanticDiagnostics(sourceFile) {
        const compilerDiagnostics = this.compilerObject.getSemanticDiagnostics(sourceFile === null || sourceFile === void 0 ? void 0 : sourceFile.compilerNode);
        return compilerDiagnostics.map(d => this._context.compilerFactory.getDiagnostic(d));
    }
    getDeclarationDiagnostics(sourceFile) {
        const compilerDiagnostics = this.compilerObject.getDeclarationDiagnostics(sourceFile === null || sourceFile === void 0 ? void 0 : sourceFile.compilerNode);
        return compilerDiagnostics.map(d => this._context.compilerFactory.getDiagnosticWithLocation(d));
    }
    getGlobalDiagnostics() {
        const compilerDiagnostics = this.compilerObject.getGlobalDiagnostics();
        return compilerDiagnostics.map(d => this._context.compilerFactory.getDiagnostic(d));
    }
    getConfigFileParsingDiagnostics() {
        const compilerDiagnostics = this.compilerObject.getConfigFileParsingDiagnostics();
        return compilerDiagnostics.map(d => this._context.compilerFactory.getDiagnostic(d));
    }
    getEmitModuleResolutionKind() {
        return common.getEmitModuleResolutionKind(this.compilerObject.getCompilerOptions());
    }
    isSourceFileFromExternalLibrary(sourceFile) {
        return sourceFile.isFromExternalLibrary();
    }
}

class LanguageService {
    constructor(params) {
        var _a;
        this._projectVersion = 0;
        this._context = params.context;
        const { languageServiceHost, compilerHost } = common.createHosts({
            transactionalFileSystem: this._context.fileSystemWrapper,
            sourceFileContainer: this._context.getSourceFileContainer(),
            compilerOptions: this._context.compilerOptions,
            getNewLine: () => this._context.manipulationSettings.getNewLineKindAsString(),
            getProjectVersion: () => `${this._projectVersion}`,
            resolutionHost: (_a = params.resolutionHost) !== null && _a !== void 0 ? _a : {},
            libFolderPath: params.libFolderPath,
            skipLoadingLibFiles: params.skipLoadingLibFiles,
        });
        this._compilerHost = compilerHost;
        this._compilerObject = common.ts.createLanguageService(languageServiceHost, this._context.compilerFactory.documentRegistry);
        this._program = new Program({
            context: this._context,
            rootNames: Array.from(this._context.compilerFactory.getSourceFilePaths()),
            host: this._compilerHost,
            configFileParsingDiagnostics: params.configFileParsingDiagnostics,
        });
        this._context.compilerFactory.onSourceFileAdded(() => this._reset());
        this._context.compilerFactory.onSourceFileRemoved(() => this._reset());
    }
    get compilerObject() {
        return this._compilerObject;
    }
    _reset() {
        this._projectVersion += 1;
        this._program._reset(Array.from(this._context.compilerFactory.getSourceFilePaths()), this._compilerHost);
    }
    getProgram() {
        return this._program;
    }
    getDefinitions(node) {
        return this.getDefinitionsAtPosition(node._sourceFile, node.getStart());
    }
    getDefinitionsAtPosition(sourceFile, pos) {
        const results = this.compilerObject.getDefinitionAtPosition(sourceFile.getFilePath(), pos) || [];
        return results.map(info => this._context.compilerFactory.getDefinitionInfo(info));
    }
    getImplementations(node) {
        return this.getImplementationsAtPosition(node._sourceFile, node.getStart());
    }
    getImplementationsAtPosition(sourceFile, pos) {
        const results = this.compilerObject.getImplementationAtPosition(sourceFile.getFilePath(), pos) || [];
        return results.map(location => new ImplementationLocation(this._context, location));
    }
    findReferences(node) {
        return this.findReferencesAtPosition(node._sourceFile, node.getStart());
    }
    findReferencesAsNodes(node) {
        const referencedSymbols = this.findReferences(node);
        return Array.from(getReferencingNodes());
        function* getReferencingNodes() {
            for (const referencedSymbol of referencedSymbols) {
                const isAlias = referencedSymbol.getDefinition().getKind() === common.ts.ScriptElementKind.alias;
                const references = referencedSymbol.getReferences();
                for (let i = 0; i < references.length; i++) {
                    const reference = references[i];
                    if (isAlias || !reference.isDefinition() || i > 0)
                        yield reference.getNode();
                }
            }
        }
    }
    findReferencesAtPosition(sourceFile, pos) {
        const results = this.compilerObject.findReferences(sourceFile.getFilePath(), pos) || [];
        return results.map(s => this._context.compilerFactory.getReferencedSymbol(s));
    }
    findRenameLocations(node, options = {}) {
        const usePrefixAndSuffixText = options.usePrefixAndSuffixText == null
            ? this._context.manipulationSettings.getUsePrefixAndSuffixTextForRename()
            : options.usePrefixAndSuffixText;
        const renameLocations = this.compilerObject.findRenameLocations(node._sourceFile.getFilePath(), node.getStart(), options.renameInStrings || false, options.renameInComments || false, usePrefixAndSuffixText) || [];
        return renameLocations.map(l => new RenameLocation(this._context, l));
    }
    getSuggestionDiagnostics(filePathOrSourceFile) {
        const filePath = this._getFilePathFromFilePathOrSourceFile(filePathOrSourceFile);
        const suggestionDiagnostics = this.compilerObject.getSuggestionDiagnostics(filePath);
        return suggestionDiagnostics.map(d => this._context.compilerFactory.getDiagnosticWithLocation(d));
    }
    getFormattingEditsForRange(filePath, range, formatSettings) {
        return (this.compilerObject.getFormattingEditsForRange(filePath, range[0], range[1], this._getFilledSettings(formatSettings)) || []).map(e => new TextChange(e));
    }
    getFormattingEditsForDocument(filePath, formatSettings) {
        const standardizedFilePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePath);
        return (this.compilerObject.getFormattingEditsForDocument(standardizedFilePath, this._getFilledSettings(formatSettings)) || [])
            .map(e => new TextChange(e));
    }
    getFormattedDocumentText(filePath, formatSettings) {
        const standardizedFilePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePath);
        const sourceFile = this._context.compilerFactory.getSourceFileFromCacheFromFilePath(standardizedFilePath);
        if (sourceFile == null)
            throw new common.errors.FileNotFoundError(standardizedFilePath);
        formatSettings = this._getFilledSettings(formatSettings);
        const formattingEdits = this.getFormattingEditsForDocument(standardizedFilePath, formatSettings);
        let newText = getTextFromTextChanges(sourceFile, formattingEdits);
        const newLineChar = formatSettings.newLineCharacter;
        if (formatSettings.ensureNewLineAtEndOfFile && !newText.endsWith(newLineChar))
            newText += newLineChar;
        return newText.replace(/\r?\n/g, newLineChar);
    }
    getEmitOutput(filePathOrSourceFile, emitOnlyDtsFiles) {
        const filePath = this._getFilePathFromFilePathOrSourceFile(filePathOrSourceFile);
        const compilerObject = this.compilerObject;
        return new EmitOutput(this._context, getCompilerEmitOutput());
        function getCompilerEmitOutput() {
            const program = compilerObject.getProgram();
            if (program == null || program.getSourceFile(filePath) == null)
                return { emitSkipped: true, outputFiles: [] };
            return compilerObject.getEmitOutput(filePath, emitOnlyDtsFiles);
        }
    }
    getIdentationAtPosition(filePathOrSourceFile, position, settings) {
        const filePath = this._getFilePathFromFilePathOrSourceFile(filePathOrSourceFile);
        if (settings == null)
            settings = this._context.manipulationSettings.getEditorSettings();
        else
            fillDefaultEditorSettings(settings, this._context.manipulationSettings);
        return this.compilerObject.getIndentationAtPosition(filePath, position, settings);
    }
    organizeImports(filePathOrSourceFile, formatSettings = {}, userPreferences = {}) {
        const scope = {
            type: "file",
            fileName: this._getFilePathFromFilePathOrSourceFile(filePathOrSourceFile),
        };
        return this.compilerObject.organizeImports(scope, this._getFilledSettings(formatSettings), this._getFilledUserPreferences(userPreferences))
            .map(fileTextChanges => new FileTextChanges(this._context, fileTextChanges));
    }
    getEditsForRefactor(filePathOrSourceFile, formatSettings, positionOrRange, refactorName, actionName, preferences = {}) {
        const filePath = this._getFilePathFromFilePathOrSourceFile(filePathOrSourceFile);
        const position = typeof positionOrRange === "number" ? positionOrRange : { pos: positionOrRange.getPos(), end: positionOrRange.getEnd() };
        const compilerObject = this.compilerObject.getEditsForRefactor(filePath, this._getFilledSettings(formatSettings), position, refactorName, actionName, this._getFilledUserPreferences(preferences));
        return compilerObject != null ? new RefactorEditInfo(this._context, compilerObject) : undefined;
    }
    getCombinedCodeFix(filePathOrSourceFile, fixId, formatSettings = {}, preferences = {}) {
        const compilerResult = this.compilerObject.getCombinedCodeFix({
            type: "file",
            fileName: this._getFilePathFromFilePathOrSourceFile(filePathOrSourceFile),
        }, fixId, this._getFilledSettings(formatSettings), this._getFilledUserPreferences(preferences || {}));
        return new CombinedCodeActions(this._context, compilerResult);
    }
    getCodeFixesAtPosition(filePathOrSourceFile, start, end, errorCodes, formatOptions = {}, preferences = {}) {
        const filePath = this._getFilePathFromFilePathOrSourceFile(filePathOrSourceFile);
        const compilerResult = this.compilerObject.getCodeFixesAtPosition(filePath, start, end, errorCodes, this._getFilledSettings(formatOptions), this._getFilledUserPreferences(preferences || {}));
        return compilerResult.map(compilerObject => new CodeFixAction(this._context, compilerObject));
    }
    _getFilePathFromFilePathOrSourceFile(filePathOrSourceFile) {
        const filePath = typeof filePathOrSourceFile === "string"
            ? this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePathOrSourceFile)
            : filePathOrSourceFile.getFilePath();
        if (!this._context.compilerFactory.containsSourceFileAtPath(filePath))
            throw new common.errors.FileNotFoundError(filePath);
        return filePath;
    }
    _getFilledSettings(settings) {
        if (settings["_filled"])
            return settings;
        settings = common.ObjectUtils.assign(this._context.getFormatCodeSettings(), settings);
        fillDefaultFormatCodeSettings(settings, this._context.manipulationSettings);
        settings["_filled"] = true;
        return settings;
    }
    _getFilledUserPreferences(userPreferences) {
        return common.ObjectUtils.assign(this._context.getUserPreferences(), userPreferences);
    }
}

class Type {
    constructor(context, type) {
        this._context = context;
        this._compilerType = type;
    }
    get compilerType() {
        return this._compilerType;
    }
    getText(enclosingNode, typeFormatFlags) {
        return this._context.typeChecker.getTypeText(this, enclosingNode, typeFormatFlags);
    }
    getAliasSymbol() {
        return this.compilerType.aliasSymbol == null ? undefined : this._context.compilerFactory.getSymbol(this.compilerType.aliasSymbol);
    }
    getAliasSymbolOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getAliasSymbol(), "Expected to find an alias symbol.");
    }
    getAliasTypeArguments() {
        const aliasTypeArgs = this.compilerType.aliasTypeArguments || [];
        return aliasTypeArgs.map(t => this._context.compilerFactory.getType(t));
    }
    getApparentType() {
        return this._context.typeChecker.getApparentType(this);
    }
    getArrayElementTypeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getArrayElementType(), "Expected to find an array element type.");
    }
    getArrayElementType() {
        if (!this.isArray())
            return undefined;
        return this.getTypeArguments()[0];
    }
    getBaseTypes() {
        const baseTypes = this.compilerType.getBaseTypes() || [];
        return baseTypes.map(t => this._context.compilerFactory.getType(t));
    }
    getBaseTypeOfLiteralType() {
        return this._context.typeChecker.getBaseTypeOfLiteralType(this);
    }
    getCallSignatures() {
        return this.compilerType.getCallSignatures().map(s => this._context.compilerFactory.getSignature(s));
    }
    getConstructSignatures() {
        return this.compilerType.getConstructSignatures().map(s => this._context.compilerFactory.getSignature(s));
    }
    getConstraintOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getConstraint(), "Expected to find a constraint.");
    }
    getConstraint() {
        const constraint = this.compilerType.getConstraint();
        return constraint == null ? undefined : this._context.compilerFactory.getType(constraint);
    }
    getDefaultOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getDefault(), "Expected to find a default type.");
    }
    getDefault() {
        const defaultType = this.compilerType.getDefault();
        return defaultType == null ? undefined : this._context.compilerFactory.getType(defaultType);
    }
    getProperties() {
        return this.compilerType.getProperties().map(s => this._context.compilerFactory.getSymbol(s));
    }
    getPropertyOrThrow(nameOrFindFunction) {
        return common.errors.throwIfNullOrUndefined(this.getProperty(nameOrFindFunction), () => getNotFoundErrorMessageForNameOrFindFunction("symbol property", nameOrFindFunction));
    }
    getProperty(nameOrFindFunction) {
        return getSymbolByNameOrFindFunction(this.getProperties(), nameOrFindFunction);
    }
    getApparentProperties() {
        return this.compilerType.getApparentProperties().map(s => this._context.compilerFactory.getSymbol(s));
    }
    getApparentProperty(nameOrFindFunction) {
        return getSymbolByNameOrFindFunction(this.getApparentProperties(), nameOrFindFunction);
    }
    isNullable() {
        return this.getUnionTypes().some(t => t.isNull() || t.isUndefined());
    }
    getNonNullableType() {
        return this._context.compilerFactory.getType(this.compilerType.getNonNullableType());
    }
    getNumberIndexType() {
        const numberIndexType = this.compilerType.getNumberIndexType();
        return numberIndexType == null ? undefined : this._context.compilerFactory.getType(numberIndexType);
    }
    getStringIndexType() {
        const stringIndexType = this.compilerType.getStringIndexType();
        return stringIndexType == null ? undefined : this._context.compilerFactory.getType(stringIndexType);
    }
    getTargetType() {
        const targetType = this.compilerType.target || undefined;
        return targetType == null ? undefined : this._context.compilerFactory.getType(targetType);
    }
    getTargetTypeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getTargetType(), "Expected to find the target type.");
    }
    getTypeArguments() {
        return this._context.typeChecker.getTypeArguments(this);
    }
    getTupleElements() {
        return this.isTuple() ? this.getTypeArguments() : [];
    }
    getUnionTypes() {
        if (!this.isUnion())
            return [];
        return this.compilerType.types.map(t => this._context.compilerFactory.getType(t));
    }
    getIntersectionTypes() {
        if (!this.isIntersection())
            return [];
        return this.compilerType.types.map(t => this._context.compilerFactory.getType(t));
    }
    getLiteralValue() {
        var _a;
        return (_a = this.compilerType) === null || _a === void 0 ? void 0 : _a.value;
    }
    getLiteralValueOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getLiteralValue(), "Type was not a literal type.");
    }
    getLiteralFreshType() {
        var _a;
        const type = (_a = this.compilerType) === null || _a === void 0 ? void 0 : _a.freshType;
        return type == null ? undefined : this._context.compilerFactory.getType(type);
    }
    getLiteralFreshTypeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getLiteralFreshType(), "Type was not a literal type.");
    }
    getLiteralRegularType() {
        var _a;
        const type = (_a = this.compilerType) === null || _a === void 0 ? void 0 : _a.regularType;
        return type == null ? undefined : this._context.compilerFactory.getType(type);
    }
    getLiteralRegularTypeOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getLiteralRegularType(), "Type was not a literal type.");
    }
    getSymbol() {
        const tsSymbol = this.compilerType.getSymbol();
        return tsSymbol == null ? undefined : this._context.compilerFactory.getSymbol(tsSymbol);
    }
    getSymbolOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getSymbol(), "Expected to find a symbol.");
    }
    isAnonymous() {
        return this._hasObjectFlag(common.ObjectFlags.Anonymous);
    }
    isAny() {
        return this._hasTypeFlag(common.TypeFlags.Any);
    }
    isArray() {
        const symbol = this.getSymbol();
        if (symbol == null)
            return false;
        return symbol.getName() === "Array" && this.getTypeArguments().length === 1;
    }
    isBoolean() {
        return this._hasTypeFlag(common.TypeFlags.Boolean);
    }
    isString() {
        return this._hasTypeFlag(common.TypeFlags.String);
    }
    isNumber() {
        return this._hasTypeFlag(common.TypeFlags.Number);
    }
    isLiteral() {
        const isBooleanLiteralForTs3_0 = this.isBooleanLiteral();
        return this.compilerType.isLiteral() || isBooleanLiteralForTs3_0;
    }
    isBooleanLiteral() {
        return this._hasTypeFlag(common.TypeFlags.BooleanLiteral);
    }
    isEnumLiteral() {
        return this._hasTypeFlag(common.TypeFlags.EnumLiteral) && !this.isUnion();
    }
    isNumberLiteral() {
        return this._hasTypeFlag(common.TypeFlags.NumberLiteral);
    }
    isStringLiteral() {
        return this.compilerType.isStringLiteral();
    }
    isClass() {
        return this.compilerType.isClass();
    }
    isClassOrInterface() {
        return this.compilerType.isClassOrInterface();
    }
    isEnum() {
        const hasEnumFlag = this._hasTypeFlag(common.TypeFlags.Enum);
        if (hasEnumFlag)
            return true;
        if (this.isEnumLiteral() && !this.isUnion())
            return false;
        const symbol = this.getSymbol();
        if (symbol == null)
            return false;
        const valueDeclaration = symbol.getValueDeclaration();
        return valueDeclaration != null && Node.isEnumDeclaration(valueDeclaration);
    }
    isInterface() {
        return this._hasObjectFlag(common.ObjectFlags.Interface);
    }
    isObject() {
        return this._hasTypeFlag(common.TypeFlags.Object);
    }
    isTypeParameter() {
        return this.compilerType.isTypeParameter();
    }
    isTuple() {
        const targetType = this.getTargetType();
        if (targetType == null)
            return false;
        return targetType._hasObjectFlag(common.ObjectFlags.Tuple);
    }
    isUnion() {
        return this.compilerType.isUnion();
    }
    isIntersection() {
        return this.compilerType.isIntersection();
    }
    isUnionOrIntersection() {
        return this.compilerType.isUnionOrIntersection();
    }
    isUnknown() {
        return this._hasTypeFlag(common.TypeFlags.Unknown);
    }
    isNull() {
        return this._hasTypeFlag(common.TypeFlags.Null);
    }
    isUndefined() {
        return this._hasTypeFlag(common.TypeFlags.Undefined);
    }
    getFlags() {
        return this.compilerType.flags;
    }
    getObjectFlags() {
        if (!this.isObject())
            return 0;
        return this.compilerType.objectFlags || 0;
    }
    _hasTypeFlag(flag) {
        return (this.compilerType.flags & flag) === flag;
    }
    _hasObjectFlag(flag) {
        return (this.getObjectFlags() & flag) === flag;
    }
}

class TypeParameter extends Type {
    getConstraintOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getConstraint(), "Expected type parameter to have a constraint.");
    }
    getConstraint() {
        const declaration = this._getTypeParameterDeclaration();
        if (declaration == null)
            return undefined;
        const constraintNode = declaration.getConstraint();
        if (constraintNode == null)
            return undefined;
        return this._context.typeChecker.getTypeAtLocation(constraintNode);
    }
    getDefaultOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getDefault(), "Expected type parameter to have a default type.");
    }
    getDefault() {
        const declaration = this._getTypeParameterDeclaration();
        if (declaration == null)
            return undefined;
        const defaultNode = declaration.getDefault();
        if (defaultNode == null)
            return undefined;
        return this._context.typeChecker.getTypeAtLocation(defaultNode);
    }
    _getTypeParameterDeclaration() {
        const symbol = this.getSymbol();
        if (symbol == null)
            return undefined;
        const declaration = symbol.getDeclarations()[0];
        if (declaration == null)
            return undefined;
        if (!Node.isTypeParameterDeclaration(declaration))
            return undefined;
        return declaration;
    }
}

class DirectoryEmitResult {
    constructor(_skippedFilePaths, _outputFilePaths) {
        this._skippedFilePaths = _skippedFilePaths;
        this._outputFilePaths = _outputFilePaths;
    }
    getSkippedFilePaths() {
        return this._skippedFilePaths;
    }
    getOutputFilePaths() {
        return this._outputFilePaths;
    }
}

class Directory {
    constructor(context, path) {
        this.__context = context;
        this._setPathInternal(path);
    }
    _setPathInternal(path) {
        this._path = path;
        this._pathParts = path.split("/").filter(p => p.length > 0);
    }
    get _context() {
        this._throwIfDeletedOrRemoved();
        return this.__context;
    }
    isAncestorOf(possibleDescendant) {
        return Directory._isAncestorOfDir(this, possibleDescendant);
    }
    isDescendantOf(possibleAncestor) {
        return Directory._isAncestorOfDir(possibleAncestor, this);
    }
    _getDepth() {
        return this._pathParts.length;
    }
    getPath() {
        this._throwIfDeletedOrRemoved();
        return this._path;
    }
    getBaseName() {
        return this._pathParts[this._pathParts.length - 1];
    }
    getParentOrThrow() {
        return common.errors.throwIfNullOrUndefined(this.getParent(), () => `Parent directory of ${this.getPath()} does not exist or was never added.`);
    }
    getParent() {
        if (common.FileUtils.isRootDirPath(this.getPath()))
            return undefined;
        return this.addDirectoryAtPathIfExists(common.FileUtils.getDirPath(this.getPath()));
    }
    getDirectoryOrThrow(pathOrCondition) {
        return common.errors.throwIfNullOrUndefined(this.getDirectory(pathOrCondition), () => {
            if (typeof pathOrCondition === "string")
                return `Could not find a directory at path '${this._context.fileSystemWrapper.getStandardizedAbsolutePath(pathOrCondition, this.getPath())}'.`;
            return "Could not find child directory that matched condition.";
        });
    }
    getDirectory(pathOrCondition) {
        if (typeof pathOrCondition === "string") {
            const path = this._context.fileSystemWrapper.getStandardizedAbsolutePath(pathOrCondition, this.getPath());
            return this._context.compilerFactory.getDirectoryFromCache(path);
        }
        return this.getDirectories().find(pathOrCondition);
    }
    getSourceFileOrThrow(pathOrCondition) {
        return common.errors.throwIfNullOrUndefined(this.getSourceFile(pathOrCondition), () => {
            if (typeof pathOrCondition === "string") {
                const absolutePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(pathOrCondition, this.getPath());
                return `Could not find child source file at path '${absolutePath}'.`;
            }
            return "Could not find child source file that matched condition.";
        });
    }
    getSourceFile(pathOrCondition) {
        if (typeof pathOrCondition === "string") {
            const path = this._context.fileSystemWrapper.getStandardizedAbsolutePath(pathOrCondition, this.getPath());
            return this._context.compilerFactory.getSourceFileFromCacheFromFilePath(path);
        }
        for (const sourceFile of this._getSourceFilesIterator()) {
            if (pathOrCondition(sourceFile))
                return sourceFile;
        }
        return undefined;
    }
    getDirectories() {
        return Array.from(this._getDirectoriesIterator());
    }
    _getDirectoriesIterator() {
        return this._context.compilerFactory.getChildDirectoriesOfDirectory(this.getPath());
    }
    getSourceFiles(globPatterns) {
        const { compilerFactory, fileSystemWrapper } = this._context;
        const dir = this;
        if (typeof globPatterns === "string" || globPatterns instanceof Array) {
            const finalGlobPatterns = typeof globPatterns === "string" ? [globPatterns] : globPatterns;
            return Array.from(getFilteredSourceFiles(finalGlobPatterns));
        }
        else {
            return Array.from(this._getSourceFilesIterator());
        }
        function* getFilteredSourceFiles(globPatterns) {
            const sourceFilePaths = Array.from(getSourceFilePaths());
            const matchedPaths = common.matchGlobs(sourceFilePaths, globPatterns, dir.getPath());
            for (const matchedPath of matchedPaths)
                yield compilerFactory.getSourceFileFromCacheFromFilePath(fileSystemWrapper.getStandardizedAbsolutePath(matchedPath));
            function* getSourceFilePaths() {
                for (const sourceFile of dir._getDescendantSourceFilesIterator())
                    yield sourceFile.getFilePath();
            }
        }
    }
    _getSourceFilesIterator() {
        return this._context.compilerFactory.getChildSourceFilesOfDirectory(this.getPath());
    }
    getDescendantSourceFiles() {
        return Array.from(this._getDescendantSourceFilesIterator());
    }
    *_getDescendantSourceFilesIterator() {
        for (const sourceFile of this._getSourceFilesIterator())
            yield sourceFile;
        for (const directory of this._getDirectoriesIterator())
            yield* directory._getDescendantSourceFilesIterator();
    }
    getDescendantDirectories() {
        return Array.from(this._getDescendantDirectoriesIterator());
    }
    *_getDescendantDirectoriesIterator() {
        for (const directory of this.getDirectories()) {
            yield directory;
            yield* directory._getDescendantDirectoriesIterator();
        }
    }
    addSourceFilesAtPaths(fileGlobs) {
        fileGlobs = typeof fileGlobs === "string" ? [fileGlobs] : fileGlobs;
        fileGlobs = fileGlobs.map(g => {
            if (common.FileUtils.pathIsAbsolute(g))
                return g;
            return common.FileUtils.pathJoin(this.getPath(), g);
        });
        return this._context.directoryCoordinator.addSourceFilesAtPaths(fileGlobs, { markInProject: this._isInProject() });
    }
    addDirectoryAtPathIfExists(relativeOrAbsoluteDirPath, options = {}) {
        const dirPath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(relativeOrAbsoluteDirPath, this.getPath());
        return this._context.directoryCoordinator.addDirectoryAtPathIfExists(dirPath, Object.assign(Object.assign({}, options), { markInProject: this._isInProject() }));
    }
    addDirectoryAtPath(relativeOrAbsoluteDirPath, options = {}) {
        const dirPath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(relativeOrAbsoluteDirPath, this.getPath());
        return this._context.directoryCoordinator.addDirectoryAtPath(dirPath, Object.assign(Object.assign({}, options), { markInProject: this._isInProject() }));
    }
    createDirectory(relativeOrAbsoluteDirPath) {
        const dirPath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(relativeOrAbsoluteDirPath, this.getPath());
        return this._context.directoryCoordinator.createDirectoryOrAddIfExists(dirPath, { markInProject: this._isInProject() });
    }
    createSourceFile(relativeFilePath, sourceFileText, options) {
        const filePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(relativeFilePath, this.getPath());
        return this._context.compilerFactory.createSourceFile(filePath, sourceFileText || "", Object.assign(Object.assign({}, (options || {})), { markInProject: this._isInProject() }));
    }
    addSourceFileAtPathIfExists(relativeFilePath) {
        const filePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(relativeFilePath, this.getPath());
        return this._context.directoryCoordinator.addSourceFileAtPathIfExists(filePath, { markInProject: this._isInProject() });
    }
    addSourceFileAtPath(relativeFilePath) {
        const filePath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(relativeFilePath, this.getPath());
        return this._context.directoryCoordinator.addSourceFileAtPath(filePath, { markInProject: this._isInProject() });
    }
    emit(options = {}) {
        return __awaiter(this, void 0, void 0, function* () {
            const { fileSystemWrapper } = this._context;
            const writeTasks = [];
            const outputFilePaths = [];
            const skippedFilePaths = [];
            for (const emitResult of this._emitInternal(options)) {
                if (isStandardizedFilePath(emitResult))
                    skippedFilePaths.push(emitResult);
                else {
                    writeTasks.push(fileSystemWrapper.writeFile(emitResult.filePath, emitResult.fileText));
                    outputFilePaths.push(emitResult.filePath);
                }
            }
            yield Promise.all(writeTasks);
            return new DirectoryEmitResult(skippedFilePaths, outputFilePaths);
        });
    }
    emitSync(options = {}) {
        const { fileSystemWrapper } = this._context;
        const outputFilePaths = [];
        const skippedFilePaths = [];
        for (const emitResult of this._emitInternal(options)) {
            if (isStandardizedFilePath(emitResult))
                skippedFilePaths.push(emitResult);
            else {
                fileSystemWrapper.writeFileSync(emitResult.filePath, emitResult.fileText);
                outputFilePaths.push(emitResult.filePath);
            }
        }
        return new DirectoryEmitResult(skippedFilePaths, outputFilePaths);
    }
    _emitInternal(options = {}) {
        const { emitOnlyDtsFiles = false } = options;
        const isJsFile = options.outDir == null ? undefined : /\.js$/i;
        const isMapFile = options.outDir == null ? undefined : /\.js\.map$/i;
        const isDtsFile = options.declarationDir == null && options.outDir == null ? undefined : /\.d\.ts$/i;
        const getStandardizedPath = (path) => path == null
            ? undefined
            : this._context.fileSystemWrapper.getStandardizedAbsolutePath(path, this.getPath());
        const getSubDirPath = (path, dir) => path == null
            ? undefined
            : common.FileUtils.pathJoin(path, dir.getBaseName());
        const hasDeclarationDir = this._context.compilerOptions.get().declarationDir != null || options.declarationDir != null;
        return emitDirectory(this, getStandardizedPath(options.outDir), getStandardizedPath(options.declarationDir));
        function* emitDirectory(directory, outDir, declarationDir) {
            for (const sourceFile of directory.getSourceFiles()) {
                const output = sourceFile.getEmitOutput({ emitOnlyDtsFiles });
                if (output.getEmitSkipped()) {
                    yield sourceFile.getFilePath();
                    continue;
                }
                for (const outputFile of output.getOutputFiles()) {
                    let filePath = outputFile.getFilePath();
                    const fileText = outputFile.getWriteByteOrderMark() ? common.FileUtils.getTextWithByteOrderMark(outputFile.getText()) : outputFile.getText();
                    if (outDir != null && (isJsFile.test(filePath) || isMapFile.test(filePath) || (!hasDeclarationDir && isDtsFile.test(filePath))))
                        filePath = common.FileUtils.pathJoin(outDir, common.FileUtils.getBaseName(filePath));
                    else if (declarationDir != null && isDtsFile.test(filePath))
                        filePath = common.FileUtils.pathJoin(declarationDir, common.FileUtils.getBaseName(filePath));
                    yield { filePath, fileText };
                }
            }
            for (const dir of directory.getDirectories())
                yield* emitDirectory(dir, getSubDirPath(outDir, dir), getSubDirPath(declarationDir, dir));
        }
    }
    copyToDirectory(dirPathOrDirectory, options) {
        const dirPath = typeof dirPathOrDirectory === "string" ? dirPathOrDirectory : dirPathOrDirectory.getPath();
        return this.copy(common.FileUtils.pathJoin(dirPath, this.getBaseName()), options);
    }
    copy(relativeOrAbsolutePath, options) {
        const originalPath = this.getPath();
        const fileSystem = this._context.fileSystemWrapper;
        const newPath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(relativeOrAbsolutePath, this.getPath());
        if (originalPath === newPath)
            return this;
        options = getDirectoryCopyOptions(options);
        if (options.includeUntrackedFiles)
            fileSystem.queueCopyDirectory(originalPath, newPath);
        return this._copyInternal(newPath, options);
    }
    copyImmediately(relativeOrAbsolutePath, options) {
        return __awaiter(this, void 0, void 0, function* () {
            const fileSystem = this._context.fileSystemWrapper;
            const originalPath = this.getPath();
            const newPath = fileSystem.getStandardizedAbsolutePath(relativeOrAbsolutePath, originalPath);
            if (originalPath === newPath) {
                yield this.save();
                return this;
            }
            options = getDirectoryCopyOptions(options);
            const newDir = this._copyInternal(newPath, options);
            if (options.includeUntrackedFiles)
                yield fileSystem.copyDirectoryImmediately(originalPath, newPath);
            yield newDir.save();
            return newDir;
        });
    }
    copyImmediatelySync(relativeOrAbsolutePath, options) {
        const fileSystem = this._context.fileSystemWrapper;
        const originalPath = this.getPath();
        const newPath = fileSystem.getStandardizedAbsolutePath(relativeOrAbsolutePath, originalPath);
        if (originalPath === newPath) {
            this.saveSync();
            return this;
        }
        options = getDirectoryCopyOptions(options);
        const newDir = this._copyInternal(newPath, options);
        if (options.includeUntrackedFiles)
            fileSystem.copyDirectoryImmediatelySync(originalPath, newPath);
        newDir.saveSync();
        return newDir;
    }
    _copyInternal(newPath, options) {
        const originalPath = this.getPath();
        if (originalPath === newPath)
            return this;
        const { fileSystemWrapper: fileSystem, compilerFactory } = this._context;
        const copyingDirectories = [this, ...this.getDescendantDirectories()].map(directory => ({
            newDirPath: directory === this ? newPath : fileSystem.getStandardizedAbsolutePath(this.getRelativePathTo(directory), newPath),
        }));
        const copyingSourceFiles = this.getDescendantSourceFiles().map(sourceFile => ({
            sourceFile,
            newFilePath: fileSystem.getStandardizedAbsolutePath(this.getRelativePathTo(sourceFile), newPath),
            references: this._getReferencesForCopy(sourceFile),
        }));
        for (const { newDirPath } of copyingDirectories)
            this._context.compilerFactory.createDirectoryOrAddIfExists(newDirPath, { markInProject: this._isInProject() });
        for (const { sourceFile, newFilePath } of copyingSourceFiles)
            sourceFile._copyInternal(newFilePath, options);
        for (const { references, newFilePath } of copyingSourceFiles)
            this.getSourceFileOrThrow(newFilePath)._updateReferencesForCopyInternal(references);
        return compilerFactory.getDirectoryFromCache(newPath);
    }
    moveToDirectory(dirPathOrDirectory, options) {
        const dirPath = typeof dirPathOrDirectory === "string" ? dirPathOrDirectory : dirPathOrDirectory.getPath();
        return this.move(common.FileUtils.pathJoin(dirPath, this.getBaseName()), options);
    }
    move(relativeOrAbsolutePath, options) {
        const fileSystem = this._context.fileSystemWrapper;
        const originalPath = this.getPath();
        const newPath = fileSystem.getStandardizedAbsolutePath(relativeOrAbsolutePath, originalPath);
        if (originalPath === newPath)
            return this;
        return this._moveInternal(newPath, options, () => fileSystem.queueMoveDirectory(originalPath, newPath));
    }
    moveImmediately(relativeOrAbsolutePath, options) {
        return __awaiter(this, void 0, void 0, function* () {
            const fileSystem = this._context.fileSystemWrapper;
            const originalPath = this.getPath();
            const newPath = fileSystem.getStandardizedAbsolutePath(relativeOrAbsolutePath, originalPath);
            if (originalPath === newPath) {
                yield this.save();
                return this;
            }
            this._moveInternal(newPath, options);
            yield fileSystem.moveDirectoryImmediately(originalPath, newPath);
            yield this.save();
            return this;
        });
    }
    moveImmediatelySync(relativeOrAbsolutePath, options) {
        const fileSystem = this._context.fileSystemWrapper;
        const originalPath = this.getPath();
        const newPath = fileSystem.getStandardizedAbsolutePath(relativeOrAbsolutePath, originalPath);
        if (originalPath === newPath) {
            this.saveSync();
            return this;
        }
        this._moveInternal(newPath, options);
        fileSystem.moveDirectoryImmediatelySync(originalPath, newPath);
        this.saveSync();
        return this;
    }
    _moveInternal(newPath, options, preAction) {
        const originalPath = this.getPath();
        if (originalPath === newPath)
            return this;
        const existingDir = this._context.compilerFactory.getDirectoryFromCacheOnlyIfInCache(newPath);
        const markInProject = existingDir != null && existingDir._isInProject();
        if (preAction)
            preAction();
        const fileSystem = this._context.fileSystemWrapper;
        const compilerFactory = this._context.compilerFactory;
        const movingDirectories = [this, ...this.getDescendantDirectories()].map(directory => ({
            directory,
            oldPath: directory.getPath(),
            newDirPath: directory === this ? newPath : fileSystem.getStandardizedAbsolutePath(this.getRelativePathTo(directory), newPath),
        }));
        const movingSourceFiles = this.getDescendantSourceFiles().map(sourceFile => ({
            sourceFile,
            newFilePath: fileSystem.getStandardizedAbsolutePath(this.getRelativePathTo(sourceFile), newPath),
            references: this._getReferencesForMove(sourceFile),
        }));
        for (const { directory, oldPath, newDirPath } of movingDirectories) {
            compilerFactory.removeDirectoryFromCache(oldPath);
            const dirToOverwrite = compilerFactory.getDirectoryFromCache(newDirPath);
            if (dirToOverwrite != null)
                dirToOverwrite._forgetOnlyThis();
            directory._setPathInternal(newDirPath);
            compilerFactory.addDirectoryToCache(directory);
        }
        for (const { sourceFile, newFilePath } of movingSourceFiles)
            sourceFile._moveInternal(newFilePath, options);
        for (const { sourceFile, references } of movingSourceFiles)
            sourceFile._updateReferencesForMoveInternal(references, originalPath);
        if (markInProject)
            this._markAsInProject();
        return this;
    }
    clear() {
        const path = this.getPath();
        this._deleteDescendants();
        this._context.fileSystemWrapper.queueDirectoryDelete(path);
        this._context.fileSystemWrapper.queueMkdir(path);
    }
    clearImmediately() {
        return __awaiter(this, void 0, void 0, function* () {
            const path = this.getPath();
            this._deleteDescendants();
            yield this._context.fileSystemWrapper.clearDirectoryImmediately(path);
        });
    }
    clearImmediatelySync() {
        const path = this.getPath();
        this._deleteDescendants();
        this._context.fileSystemWrapper.clearDirectoryImmediatelySync(path);
    }
    delete() {
        const path = this.getPath();
        this._deleteDescendants();
        this._context.fileSystemWrapper.queueDirectoryDelete(path);
        this.forget();
    }
    _deleteDescendants() {
        for (const sourceFile of this.getSourceFiles())
            sourceFile.delete();
        for (const dir of this.getDirectories())
            dir.delete();
    }
    deleteImmediately() {
        return __awaiter(this, void 0, void 0, function* () {
            const { fileSystemWrapper } = this._context;
            const path = this.getPath();
            this.forget();
            yield fileSystemWrapper.deleteDirectoryImmediately(path);
        });
    }
    deleteImmediatelySync() {
        const { fileSystemWrapper } = this._context;
        const path = this.getPath();
        this.forget();
        fileSystemWrapper.deleteDirectoryImmediatelySync(path);
    }
    forget() {
        if (this.wasForgotten())
            return;
        for (const sourceFile of this.getSourceFiles())
            sourceFile.forget();
        for (const dir of this.getDirectories())
            dir.forget();
        this._forgetOnlyThis();
    }
    _forgetOnlyThis() {
        if (this.wasForgotten())
            return;
        this._context.compilerFactory.removeDirectoryFromCache(this.getPath());
        this.__context = undefined;
    }
    save() {
        return __awaiter(this, void 0, void 0, function* () {
            yield this._context.fileSystemWrapper.saveForDirectory(this.getPath());
            const unsavedSourceFiles = this.getDescendantSourceFiles().filter(s => !s.isSaved());
            yield Promise.all(unsavedSourceFiles.map(s => s.save()));
        });
    }
    saveSync() {
        this._context.fileSystemWrapper.saveForDirectorySync(this.getPath());
        const unsavedSourceFiles = this.getDescendantSourceFiles().filter(s => !s.isSaved());
        unsavedSourceFiles.forEach(s => s.saveSync());
    }
    getRelativePathTo(sourceFileDirOrPath) {
        const thisDirectory = this;
        return common.FileUtils.getRelativePathTo(this.getPath(), getPath());
        function getPath() {
            return sourceFileDirOrPath instanceof SourceFile
                ? sourceFileDirOrPath.getFilePath()
                : sourceFileDirOrPath instanceof Directory
                    ? sourceFileDirOrPath.getPath()
                    : thisDirectory._context.fileSystemWrapper.getStandardizedAbsolutePath(sourceFileDirOrPath, thisDirectory.getPath());
        }
    }
    getRelativePathAsModuleSpecifierTo(sourceFileDirOrFilePath) {
        const moduleResolution = this._context.program.getEmitModuleResolutionKind();
        const thisDirectory = this;
        const moduleSpecifier = common.FileUtils.getRelativePathTo(this.getPath(), getPath()).replace(/((\.d\.ts$)|(\.[^/.]+$))/i, "");
        return moduleSpecifier.startsWith("../") ? moduleSpecifier : "./" + moduleSpecifier;
        function getPath() {
            return sourceFileDirOrFilePath instanceof SourceFile
                ? getPathForSourceFile(sourceFileDirOrFilePath)
                : sourceFileDirOrFilePath instanceof Directory
                    ? getPathForDirectory(sourceFileDirOrFilePath)
                    : getPathForFilePath(thisDirectory._context.fileSystemWrapper.getStandardizedAbsolutePath(sourceFileDirOrFilePath, thisDirectory.getPath()));
            function getPathForSourceFile(sourceFile) {
                return getPathForFilePath(sourceFile.getFilePath());
            }
            function getPathForDirectory(dir) {
                switch (moduleResolution) {
                    case common.ModuleResolutionKind.NodeJs:
                        if (dir === thisDirectory)
                            return common.FileUtils.pathJoin(dir.getPath(), "index.ts");
                        return dir.getPath();
                    case common.ModuleResolutionKind.Classic:
                        return common.FileUtils.pathJoin(dir.getPath(), "index.ts");
                    default:
                        return common.errors.throwNotImplementedForNeverValueError(moduleResolution);
                }
            }
            function getPathForFilePath(filePath) {
                const dirPath = common.FileUtils.getDirPath(filePath);
                switch (moduleResolution) {
                    case common.ModuleResolutionKind.NodeJs:
                        if (dirPath === thisDirectory.getPath())
                            return filePath;
                        return filePath.replace(/\/index?(\.d\.ts|\.ts|\.js)$/i, "");
                    case common.ModuleResolutionKind.Classic:
                        return filePath;
                    default:
                        return common.errors.throwNotImplementedForNeverValueError(moduleResolution);
                }
            }
        }
    }
    getProject() {
        return this._context.project;
    }
    wasForgotten() {
        return this.__context == null;
    }
    _isInProject() {
        return this._context.inProjectCoordinator.isDirectoryInProject(this);
    }
    _markAsInProject() {
        this._context.inProjectCoordinator.markDirectoryAsInProject(this);
    }
    _hasLoadedParent() {
        return this._context.compilerFactory.containsDirectoryAtPath(common.FileUtils.getDirPath(this.getPath()));
    }
    _throwIfDeletedOrRemoved() {
        if (this.wasForgotten())
            throw new common.errors.InvalidOperationError("Cannot use a directory that was deleted, removed, or overwritten.");
    }
    _getReferencesForCopy(sourceFile) {
        const literalReferences = sourceFile._getReferencesForCopyInternal();
        return literalReferences.filter(r => !this.isAncestorOf(r[1]));
    }
    _getReferencesForMove(sourceFile) {
        const { literalReferences, referencingLiterals } = sourceFile._getReferencesForMoveInternal();
        return {
            literalReferences: literalReferences.filter(r => !this.isAncestorOf(r[1])),
            referencingLiterals: referencingLiterals.filter(l => !this.isAncestorOf(l._sourceFile)),
        };
    }
    static _isAncestorOfDir(ancestor, descendant) {
        if (descendant instanceof SourceFile) {
            descendant = descendant.getDirectory();
            if (ancestor === descendant)
                return true;
        }
        if (ancestor._pathParts.length >= descendant._pathParts.length)
            return false;
        for (let i = ancestor._pathParts.length - 1; i >= 0; i--) {
            if (ancestor._pathParts[i] !== descendant._pathParts[i])
                return false;
        }
        return true;
    }
}
function getDirectoryCopyOptions(options) {
    options = common.ObjectUtils.clone(options || {});
    setValueIfUndefined(options, "includeUntrackedFiles", true);
    return options;
}
function isStandardizedFilePath(filePath) {
    return typeof filePath === "string";
}

class DirectoryCoordinator {
    constructor(compilerFactory, fileSystemWrapper) {
        this.compilerFactory = compilerFactory;
        this.fileSystemWrapper = fileSystemWrapper;
    }
    addDirectoryAtPathIfExists(dirPath, options) {
        const directory = this.compilerFactory.getDirectoryFromPath(dirPath, options);
        if (directory == null)
            return undefined;
        if (options.recursive) {
            for (const descendantDirPath of common.FileUtils.getDescendantDirectories(this.fileSystemWrapper, dirPath))
                this.compilerFactory.createDirectoryOrAddIfExists(descendantDirPath, options);
        }
        return directory;
    }
    addDirectoryAtPath(dirPath, options) {
        const directory = this.addDirectoryAtPathIfExists(dirPath, options);
        if (directory == null)
            throw new common.errors.DirectoryNotFoundError(dirPath);
        return directory;
    }
    createDirectoryOrAddIfExists(dirPath, options) {
        return this.compilerFactory.createDirectoryOrAddIfExists(dirPath, options);
    }
    addSourceFileAtPathIfExists(filePath, options) {
        return this.compilerFactory.addOrGetSourceFileFromFilePath(filePath, {
            markInProject: options.markInProject,
            scriptKind: undefined,
        });
    }
    addSourceFileAtPath(filePath, options) {
        const sourceFile = this.addSourceFileAtPathIfExists(filePath, options);
        if (sourceFile == null)
            throw new common.errors.FileNotFoundError(this.fileSystemWrapper.getStandardizedAbsolutePath(filePath));
        return sourceFile;
    }
    addSourceFilesAtPaths(fileGlobs, options) {
        if (typeof fileGlobs === "string")
            fileGlobs = [fileGlobs];
        const sourceFiles = [];
        const globbedDirectories = new Set();
        for (const filePath of this.fileSystemWrapper.globSync(fileGlobs)) {
            const sourceFile = this.addSourceFileAtPathIfExists(filePath, options);
            if (sourceFile != null)
                sourceFiles.push(sourceFile);
            globbedDirectories.add(common.FileUtils.getDirPath(filePath));
        }
        for (const dirPath of common.FileUtils.getParentMostPaths(Array.from(globbedDirectories)))
            this.addDirectoryAtPathIfExists(dirPath, { recursive: true, markInProject: options.markInProject });
        return sourceFiles;
    }
}

class DirectoryCache {
    constructor(context) {
        this.context = context;
        this.directoriesByPath = new common.KeyValueCache();
        this.sourceFilesByDirPath = new common.KeyValueCache();
        this.directoriesByDirPath = new common.KeyValueCache();
        this.orphanDirs = new common.KeyValueCache();
    }
    has(dirPath) {
        return this.directoriesByPath.has(dirPath);
    }
    get(dirPath) {
        if (!this.directoriesByPath.has(dirPath)) {
            for (const orphanDir of this.orphanDirs.getValues()) {
                if (common.FileUtils.pathStartsWith(orphanDir.getPath(), dirPath))
                    return this.createOrAddIfExists(dirPath);
            }
            return undefined;
        }
        return this.directoriesByPath.get(dirPath);
    }
    getOrphans() {
        return this.orphanDirs.getValues();
    }
    getAll() {
        return this.directoriesByPath.getValuesAsArray();
    }
    *getAllByDepth() {
        const dirLevels = new common.KeyValueCache();
        let depth = 0;
        for (const orphanDir of this.getOrphans())
            addToDirLevels(orphanDir);
        depth = Math.min(...Array.from(dirLevels.getKeys()));
        while (dirLevels.getSize() > 0) {
            for (const dir of dirLevels.get(depth) || []) {
                yield dir;
                dir.getDirectories().forEach(addToDirLevels);
            }
            dirLevels.removeByKey(depth);
            depth++;
        }
        function addToDirLevels(dir) {
            const dirDepth = dir._getDepth();
            if (depth > dirDepth)
                throw new Error(`For some reason a subdirectory had a lower depth than the parent directory: ${dir.getPath()}`);
            const dirs = dirLevels.getOrCreate(dirDepth, () => []);
            dirs.push(dir);
        }
    }
    remove(dirPath) {
        this.removeFromDirectoriesByDirPath(dirPath);
        this.directoriesByPath.removeByKey(dirPath);
        this.orphanDirs.removeByKey(dirPath);
    }
    *getChildDirectoriesOfDirectory(dirPath) {
        var _a;
        const entries = (_a = this.directoriesByDirPath.get(dirPath)) === null || _a === void 0 ? void 0 : _a.entries();
        if (entries == null)
            return;
        for (const dir of entries)
            yield dir;
    }
    *getChildSourceFilesOfDirectory(dirPath) {
        var _a;
        const entries = (_a = this.sourceFilesByDirPath.get(dirPath)) === null || _a === void 0 ? void 0 : _a.entries();
        if (entries == null)
            return;
        for (const sourceFile of entries)
            yield sourceFile;
    }
    addSourceFile(sourceFile) {
        const dirPath = sourceFile.getDirectoryPath();
        this.createOrAddIfExists(dirPath);
        const sourceFiles = this.sourceFilesByDirPath.getOrCreate(dirPath, () => new common.SortedKeyValueArray(item => item.getBaseName(), common.LocaleStringComparer.instance));
        sourceFiles.set(sourceFile);
    }
    removeSourceFile(filePath) {
        const dirPath = common.FileUtils.getDirPath(filePath);
        const sourceFiles = this.sourceFilesByDirPath.get(dirPath);
        if (sourceFiles == null)
            return;
        sourceFiles.removeByKey(common.FileUtils.getBaseName(filePath));
        if (!sourceFiles.hasItems())
            this.sourceFilesByDirPath.removeByKey(dirPath);
    }
    createOrAddIfExists(dirPath) {
        if (this.has(dirPath))
            return this.get(dirPath);
        this.fillParentsOfDirPath(dirPath);
        return this.createDirectory(dirPath);
    }
    createDirectory(path) {
        const newDirectory = new Directory(this.context, path);
        this.addDirectory(newDirectory);
        return newDirectory;
    }
    addDirectory(directory) {
        const path = directory.getPath();
        const parentDirPath = common.FileUtils.getDirPath(path);
        const isRootDir = parentDirPath === path;
        for (const orphanDir of this.orphanDirs.getValues()) {
            const orphanDirPath = orphanDir.getPath();
            const orphanDirParentPath = common.FileUtils.getDirPath(orphanDirPath);
            const isOrphanRootDir = orphanDirParentPath === orphanDirPath;
            if (!isOrphanRootDir && orphanDirParentPath === path)
                this.orphanDirs.removeByKey(orphanDirPath);
        }
        if (!isRootDir)
            this.addToDirectoriesByDirPath(directory);
        if (!this.has(parentDirPath))
            this.orphanDirs.set(path, directory);
        this.directoriesByPath.set(path, directory);
        if (!this.context.fileSystemWrapper.directoryExistsSync(path))
            this.context.fileSystemWrapper.queueMkdir(path);
        for (const orphanDir of this.orphanDirs.getValues()) {
            if (directory.isAncestorOf(orphanDir))
                this.fillParentsOfDirPath(orphanDir.getPath());
        }
    }
    addToDirectoriesByDirPath(directory) {
        if (common.FileUtils.isRootDirPath(directory.getPath()))
            return;
        const parentDirPath = common.FileUtils.getDirPath(directory.getPath());
        const directories = this.directoriesByDirPath.getOrCreate(parentDirPath, () => new common.SortedKeyValueArray(item => item.getBaseName(), common.LocaleStringComparer.instance));
        directories.set(directory);
    }
    removeFromDirectoriesByDirPath(dirPath) {
        if (common.FileUtils.isRootDirPath(dirPath))
            return;
        const parentDirPath = common.FileUtils.getDirPath(dirPath);
        const directories = this.directoriesByDirPath.get(parentDirPath);
        if (directories == null)
            return;
        directories.removeByKey(common.FileUtils.getBaseName(dirPath));
        if (!directories.hasItems())
            this.directoriesByDirPath.removeByKey(parentDirPath);
    }
    fillParentsOfDirPath(dirPath) {
        const passedDirPaths = [];
        let parentDir = common.FileUtils.getDirPath(dirPath);
        while (dirPath !== parentDir) {
            dirPath = parentDir;
            parentDir = common.FileUtils.getDirPath(dirPath);
            if (this.directoriesByPath.has(dirPath)) {
                for (const currentDirPath of passedDirPaths)
                    this.createDirectory(currentDirPath);
                break;
            }
            passedDirPaths.unshift(dirPath);
        }
    }
}

class ForgetfulNodeCache extends common.KeyValueCache {
    constructor() {
        super(...arguments);
        this.forgetStack = [];
    }
    getOrCreate(key, createFunc) {
        return super.getOrCreate(key, () => {
            const node = createFunc();
            if (this.forgetStack.length > 0)
                this.forgetStack[this.forgetStack.length - 1].add(node);
            return node;
        });
    }
    setForgetPoint() {
        this.forgetStack.push(new Set());
    }
    forgetLastPoint() {
        const nodes = this.forgetStack.pop();
        if (nodes != null)
            this.forgetNodes(nodes.values());
    }
    rememberNode(node) {
        if (node.wasForgotten())
            throw new common.errors.InvalidOperationError("Cannot remember a node that was removed or forgotten.");
        let wasInForgetStack = false;
        for (const stackItem of this.forgetStack) {
            if (stackItem.delete(node)) {
                wasInForgetStack = true;
                break;
            }
        }
        if (wasInForgetStack)
            this.rememberParentOfNode(node);
        return wasInForgetStack;
    }
    rememberParentOfNode(node) {
        const parent = node.getParentSyntaxList() || node.getParent();
        if (parent != null)
            this.rememberNode(parent);
    }
    forgetNodes(nodes) {
        for (const node of nodes) {
            if (node.wasForgotten() || node.getKind() === common.SyntaxKind.SourceFile)
                continue;
            node._forgetOnlyThis();
        }
    }
}

const kindToWrapperMappings = {
    [common.SyntaxKind.SourceFile]: SourceFile,
    [common.SyntaxKind.ArrayBindingPattern]: ArrayBindingPattern,
    [common.SyntaxKind.ArrayLiteralExpression]: ArrayLiteralExpression,
    [common.SyntaxKind.ArrayType]: ArrayTypeNode,
    [common.SyntaxKind.ArrowFunction]: ArrowFunction,
    [common.SyntaxKind.AsExpression]: AsExpression,
    [common.SyntaxKind.AwaitExpression]: AwaitExpression,
    [common.SyntaxKind.BigIntLiteral]: BigIntLiteral,
    [common.SyntaxKind.BindingElement]: BindingElement,
    [common.SyntaxKind.BinaryExpression]: BinaryExpression,
    [common.SyntaxKind.Block]: Block,
    [common.SyntaxKind.BreakStatement]: BreakStatement,
    [common.SyntaxKind.CallExpression]: CallExpression,
    [common.SyntaxKind.CallSignature]: CallSignatureDeclaration,
    [common.SyntaxKind.CaseBlock]: CaseBlock,
    [common.SyntaxKind.CaseClause]: CaseClause,
    [common.SyntaxKind.CatchClause]: CatchClause,
    [common.SyntaxKind.ClassDeclaration]: ClassDeclaration,
    [common.SyntaxKind.ClassExpression]: ClassExpression,
    [common.SyntaxKind.ClassStaticBlockDeclaration]: ClassStaticBlockDeclaration,
    [common.SyntaxKind.ConditionalType]: ConditionalTypeNode,
    [common.SyntaxKind.Constructor]: ConstructorDeclaration,
    [common.SyntaxKind.ConstructorType]: ConstructorTypeNode,
    [common.SyntaxKind.ConstructSignature]: ConstructSignatureDeclaration,
    [common.SyntaxKind.ContinueStatement]: ContinueStatement,
    [common.SyntaxKind.CommaListExpression]: CommaListExpression,
    [common.SyntaxKind.ComputedPropertyName]: ComputedPropertyName,
    [common.SyntaxKind.ConditionalExpression]: ConditionalExpression,
    [common.SyntaxKind.DebuggerStatement]: DebuggerStatement,
    [common.SyntaxKind.Decorator]: Decorator,
    [common.SyntaxKind.DefaultClause]: DefaultClause,
    [common.SyntaxKind.DeleteExpression]: DeleteExpression,
    [common.SyntaxKind.DoStatement]: DoStatement,
    [common.SyntaxKind.ElementAccessExpression]: ElementAccessExpression,
    [common.SyntaxKind.EmptyStatement]: EmptyStatement,
    [common.SyntaxKind.EnumDeclaration]: EnumDeclaration,
    [common.SyntaxKind.EnumMember]: EnumMember,
    [common.SyntaxKind.ExportAssignment]: ExportAssignment,
    [common.SyntaxKind.ExportDeclaration]: ExportDeclaration,
    [common.SyntaxKind.ExportSpecifier]: ExportSpecifier,
    [common.SyntaxKind.ExpressionWithTypeArguments]: ExpressionWithTypeArguments,
    [common.SyntaxKind.ExpressionStatement]: ExpressionStatement,
    [common.SyntaxKind.ExternalModuleReference]: ExternalModuleReference,
    [common.SyntaxKind.QualifiedName]: QualifiedName,
    [common.SyntaxKind.ForInStatement]: ForInStatement,
    [common.SyntaxKind.ForOfStatement]: ForOfStatement,
    [common.SyntaxKind.ForStatement]: ForStatement,
    [common.SyntaxKind.FunctionDeclaration]: FunctionDeclaration,
    [common.SyntaxKind.FunctionExpression]: FunctionExpression,
    [common.SyntaxKind.FunctionType]: FunctionTypeNode,
    [common.SyntaxKind.GetAccessor]: GetAccessorDeclaration,
    [common.SyntaxKind.HeritageClause]: HeritageClause,
    [common.SyntaxKind.Identifier]: Identifier,
    [common.SyntaxKind.IfStatement]: IfStatement,
    [common.SyntaxKind.ImportClause]: ImportClause,
    [common.SyntaxKind.ImportDeclaration]: ImportDeclaration,
    [common.SyntaxKind.ImportEqualsDeclaration]: ImportEqualsDeclaration,
    [common.SyntaxKind.ImportSpecifier]: ImportSpecifier,
    [common.SyntaxKind.ImportType]: ImportTypeNode,
    [common.SyntaxKind.IndexedAccessType]: IndexedAccessTypeNode,
    [common.SyntaxKind.IndexSignature]: IndexSignatureDeclaration,
    [common.SyntaxKind.InferType]: InferTypeNode,
    [common.SyntaxKind.InterfaceDeclaration]: InterfaceDeclaration,
    [common.SyntaxKind.IntersectionType]: IntersectionTypeNode,
    [common.SyntaxKind.JSDocAugmentsTag]: JSDocAugmentsTag,
    [common.SyntaxKind.JSDocAuthorTag]: JSDocAuthorTag,
    [common.SyntaxKind.JSDocCallbackTag]: JSDocCallbackTag,
    [common.SyntaxKind.JSDocClassTag]: JSDocClassTag,
    [common.SyntaxKind.JSDocDeprecatedTag]: JSDocDeprecatedTag,
    [common.SyntaxKind.JSDocEnumTag]: JSDocEnumTag,
    [common.SyntaxKind.JSDocFunctionType]: JSDocFunctionType,
    [common.SyntaxKind.JSDocImplementsTag]: JSDocImplementsTag,
    [common.SyntaxKind.JSDocLink]: JSDocLink,
    [common.SyntaxKind.JSDocLinkCode]: JSDocLinkCode,
    [common.SyntaxKind.JSDocLinkPlain]: JSDocLinkPlain,
    [common.SyntaxKind.JSDocMemberName]: JSDocMemberName,
    [common.SyntaxKind.JSDocOverrideTag]: JSDocOverrideTag,
    [common.SyntaxKind.JSDocParameterTag]: JSDocParameterTag,
    [common.SyntaxKind.JSDocPrivateTag]: JSDocPrivateTag,
    [common.SyntaxKind.JSDocPropertyTag]: JSDocPropertyTag,
    [common.SyntaxKind.JSDocProtectedTag]: JSDocProtectedTag,
    [common.SyntaxKind.JSDocPublicTag]: JSDocPublicTag,
    [common.SyntaxKind.JSDocReturnTag]: JSDocReturnTag,
    [common.SyntaxKind.JSDocReadonlyTag]: JSDocReadonlyTag,
    [common.SyntaxKind.JSDocSeeTag]: JSDocSeeTag,
    [common.SyntaxKind.JSDocSignature]: JSDocSignature,
    [common.SyntaxKind.JSDocTag]: JSDocUnknownTag,
    [common.SyntaxKind.JSDocTemplateTag]: JSDocTemplateTag,
    [common.SyntaxKind.JSDocText]: JSDocText,
    [common.SyntaxKind.JSDocThisTag]: JSDocThisTag,
    [common.SyntaxKind.JSDocTypeExpression]: JSDocTypeExpression,
    [common.SyntaxKind.JSDocTypeTag]: JSDocTypeTag,
    [common.SyntaxKind.JSDocTypedefTag]: JSDocTypedefTag,
    [common.SyntaxKind.JsxAttribute]: JsxAttribute,
    [common.SyntaxKind.JsxClosingElement]: JsxClosingElement,
    [common.SyntaxKind.JsxClosingFragment]: JsxClosingFragment,
    [common.SyntaxKind.JsxElement]: JsxElement,
    [common.SyntaxKind.JsxExpression]: JsxExpression,
    [common.SyntaxKind.JsxFragment]: JsxFragment,
    [common.SyntaxKind.JsxOpeningElement]: JsxOpeningElement,
    [common.SyntaxKind.JsxOpeningFragment]: JsxOpeningFragment,
    [common.SyntaxKind.JsxSelfClosingElement]: JsxSelfClosingElement,
    [common.SyntaxKind.JsxSpreadAttribute]: JsxSpreadAttribute,
    [common.SyntaxKind.JsxText]: JsxText,
    [common.SyntaxKind.LabeledStatement]: LabeledStatement,
    [common.SyntaxKind.LiteralType]: LiteralTypeNode,
    [common.SyntaxKind.MappedType]: MappedTypeNode,
    [common.SyntaxKind.MetaProperty]: MetaProperty,
    [common.SyntaxKind.MethodDeclaration]: MethodDeclaration,
    [common.SyntaxKind.MethodSignature]: MethodSignature,
    [common.SyntaxKind.ModuleBlock]: ModuleBlock,
    [common.SyntaxKind.ModuleDeclaration]: ModuleDeclaration,
    [common.SyntaxKind.NamedExports]: NamedExports,
    [common.SyntaxKind.NamedImports]: NamedImports,
    [common.SyntaxKind.NamedTupleMember]: NamedTupleMember,
    [common.SyntaxKind.NamespaceExport]: NamespaceExport,
    [common.SyntaxKind.NamespaceImport]: NamespaceImport,
    [common.SyntaxKind.NewExpression]: NewExpression,
    [common.SyntaxKind.NonNullExpression]: NonNullExpression,
    [common.SyntaxKind.NotEmittedStatement]: NotEmittedStatement,
    [common.SyntaxKind.NoSubstitutionTemplateLiteral]: NoSubstitutionTemplateLiteral,
    [common.SyntaxKind.NumericLiteral]: NumericLiteral,
    [common.SyntaxKind.ObjectBindingPattern]: ObjectBindingPattern,
    [common.SyntaxKind.ObjectLiteralExpression]: ObjectLiteralExpression,
    [common.SyntaxKind.OmittedExpression]: OmittedExpression,
    [common.SyntaxKind.Parameter]: ParameterDeclaration,
    [common.SyntaxKind.ParenthesizedExpression]: ParenthesizedExpression,
    [common.SyntaxKind.ParenthesizedType]: ParenthesizedTypeNode,
    [common.SyntaxKind.PartiallyEmittedExpression]: PartiallyEmittedExpression,
    [common.SyntaxKind.PostfixUnaryExpression]: PostfixUnaryExpression,
    [common.SyntaxKind.PrefixUnaryExpression]: PrefixUnaryExpression,
    [common.SyntaxKind.PrivateIdentifier]: PrivateIdentifier,
    [common.SyntaxKind.PropertyAccessExpression]: PropertyAccessExpression,
    [common.SyntaxKind.PropertyAssignment]: PropertyAssignment,
    [common.SyntaxKind.PropertyDeclaration]: PropertyDeclaration,
    [common.SyntaxKind.PropertySignature]: PropertySignature,
    [common.SyntaxKind.RegularExpressionLiteral]: RegularExpressionLiteral,
    [common.SyntaxKind.ReturnStatement]: ReturnStatement,
    [common.SyntaxKind.SetAccessor]: SetAccessorDeclaration,
    [common.SyntaxKind.ShorthandPropertyAssignment]: ShorthandPropertyAssignment,
    [common.SyntaxKind.SpreadAssignment]: SpreadAssignment,
    [common.SyntaxKind.SpreadElement]: SpreadElement,
    [common.SyntaxKind.StringLiteral]: StringLiteral,
    [common.SyntaxKind.SwitchStatement]: SwitchStatement,
    [common.SyntaxKind.SyntaxList]: SyntaxList,
    [common.SyntaxKind.TaggedTemplateExpression]: TaggedTemplateExpression,
    [common.SyntaxKind.TemplateExpression]: TemplateExpression,
    [common.SyntaxKind.TemplateHead]: TemplateHead,
    [common.SyntaxKind.TemplateLiteralType]: TemplateLiteralTypeNode,
    [common.SyntaxKind.TemplateMiddle]: TemplateMiddle,
    [common.SyntaxKind.TemplateSpan]: TemplateSpan,
    [common.SyntaxKind.TemplateTail]: TemplateTail,
    [common.SyntaxKind.ThisType]: ThisTypeNode,
    [common.SyntaxKind.ThrowStatement]: ThrowStatement,
    [common.SyntaxKind.TryStatement]: TryStatement,
    [common.SyntaxKind.TupleType]: TupleTypeNode,
    [common.SyntaxKind.TypeAliasDeclaration]: TypeAliasDeclaration,
    [common.SyntaxKind.TypeAssertionExpression]: TypeAssertion,
    [common.SyntaxKind.TypeLiteral]: TypeLiteralNode,
    [common.SyntaxKind.TypeParameter]: TypeParameterDeclaration,
    [common.SyntaxKind.TypePredicate]: TypePredicateNode,
    [common.SyntaxKind.TypeReference]: TypeReferenceNode,
    [common.SyntaxKind.UnionType]: UnionTypeNode,
    [common.SyntaxKind.VariableDeclaration]: VariableDeclaration,
    [common.SyntaxKind.VariableDeclarationList]: VariableDeclarationList,
    [common.SyntaxKind.VariableStatement]: VariableStatement,
    [common.SyntaxKind.JSDocComment]: JSDoc,
    [common.SyntaxKind.TypeOfExpression]: TypeOfExpression,
    [common.SyntaxKind.WhileStatement]: WhileStatement,
    [common.SyntaxKind.WithStatement]: WithStatement,
    [common.SyntaxKind.YieldExpression]: YieldExpression,
    [common.SyntaxKind.SemicolonToken]: Node,
    [common.SyntaxKind.AnyKeyword]: Expression,
    [common.SyntaxKind.BooleanKeyword]: Expression,
    [common.SyntaxKind.FalseKeyword]: FalseLiteral,
    [common.SyntaxKind.ImportKeyword]: ImportExpression,
    [common.SyntaxKind.InferKeyword]: Node,
    [common.SyntaxKind.NeverKeyword]: Node,
    [common.SyntaxKind.NullKeyword]: NullLiteral,
    [common.SyntaxKind.NumberKeyword]: Expression,
    [common.SyntaxKind.ObjectKeyword]: Expression,
    [common.SyntaxKind.StringKeyword]: Expression,
    [common.SyntaxKind.SymbolKeyword]: Expression,
    [common.SyntaxKind.SuperKeyword]: SuperExpression,
    [common.SyntaxKind.ThisKeyword]: ThisExpression,
    [common.SyntaxKind.TrueKeyword]: TrueLiteral,
    [common.SyntaxKind.UndefinedKeyword]: Expression,
    [common.SyntaxKind.VoidExpression]: VoidExpression,
};

class CompilerFactory {
    constructor(context) {
        this.context = context;
        this.sourceFileCacheByFilePath = new Map();
        this.diagnosticCache = new common.WeakCache();
        this.definitionInfoCache = new common.WeakCache();
        this.documentSpanCache = new common.WeakCache();
        this.diagnosticMessageChainCache = new common.WeakCache();
        this.jsDocTagInfoCache = new common.WeakCache();
        this.signatureCache = new common.WeakCache();
        this.symbolCache = new common.WeakCache();
        this.symbolDisplayPartCache = new common.WeakCache();
        this.referenceEntryCache = new common.WeakCache();
        this.referencedSymbolCache = new common.WeakCache();
        this.referencedSymbolDefinitionInfoCache = new common.WeakCache();
        this.typeCache = new common.WeakCache();
        this.typeParameterCache = new common.WeakCache();
        this.nodeCache = new ForgetfulNodeCache();
        this.sourceFileAddedEventContainer = new common.EventContainer();
        this.sourceFileRemovedEventContainer = new common.EventContainer();
        this.documentRegistry = new common.DocumentRegistry(context.fileSystemWrapper);
        this.directoryCache = new DirectoryCache(context);
        this.context.compilerOptions.onModified(() => {
            const currentSourceFiles = Array.from(this.sourceFileCacheByFilePath.values());
            for (const sourceFile of currentSourceFiles) {
                replaceSourceFileForCacheUpdate(sourceFile);
            }
        });
    }
    *getSourceFilesByDirectoryDepth() {
        for (const dir of this.getDirectoriesByDepth())
            yield* dir.getSourceFiles();
    }
    getSourceFilePaths() {
        return this.sourceFileCacheByFilePath.keys();
    }
    getChildDirectoriesOfDirectory(dirPath) {
        return this.directoryCache.getChildDirectoriesOfDirectory(dirPath);
    }
    getChildSourceFilesOfDirectory(dirPath) {
        return this.directoryCache.getChildSourceFilesOfDirectory(dirPath);
    }
    onSourceFileAdded(subscription, subscribe = true) {
        if (subscribe)
            this.sourceFileAddedEventContainer.subscribe(subscription);
        else
            this.sourceFileAddedEventContainer.unsubscribe(subscription);
    }
    onSourceFileRemoved(subscription) {
        this.sourceFileRemovedEventContainer.subscribe(subscription);
    }
    createSourceFile(filePath, sourceFileText, options) {
        sourceFileText = sourceFileText instanceof Function ? getTextFromStringOrWriter(this.context.createWriter(), sourceFileText) : sourceFileText || "";
        if (typeof sourceFileText === "string")
            return this.createSourceFileFromText(filePath, sourceFileText, options);
        const writer = this.context.createWriter();
        const structurePrinter = this.context.structurePrinterFactory.forSourceFile({
            isAmbient: common.FileUtils.getExtension(filePath) === ".d.ts",
        });
        structurePrinter.printText(writer, sourceFileText);
        return this.createSourceFileFromText(filePath, writer.toString(), options);
    }
    createSourceFileFromText(filePath, sourceText, options) {
        filePath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(filePath);
        if (options.overwrite === true)
            return this.createOrOverwriteSourceFileFromText(filePath, sourceText, options);
        this.throwIfFileExists(filePath, "Did you mean to provide the overwrite option?");
        return this.createSourceFileFromTextInternal(filePath, sourceText, options);
    }
    throwIfFileExists(filePath, prefixMessage) {
        if (!this.containsSourceFileAtPath(filePath) && !this.context.fileSystemWrapper.fileExistsSync(filePath))
            return;
        prefixMessage = prefixMessage == null ? "" : prefixMessage + " ";
        throw new common.errors.InvalidOperationError(`${prefixMessage}A source file already exists at the provided file path: ${filePath}`);
    }
    createOrOverwriteSourceFileFromText(filePath, sourceText, options) {
        filePath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(filePath);
        const existingSourceFile = this.addOrGetSourceFileFromFilePath(filePath, options);
        if (existingSourceFile != null) {
            existingSourceFile.getChildren().forEach(c => c.forget());
            this.replaceCompilerNode(existingSourceFile, this.createCompilerSourceFileFromText(filePath, sourceText, options.scriptKind));
            return existingSourceFile;
        }
        return this.createSourceFileFromTextInternal(filePath, sourceText, options);
    }
    getSourceFileFromCacheFromFilePath(filePath) {
        filePath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(filePath);
        return this.sourceFileCacheByFilePath.get(filePath);
    }
    addOrGetSourceFileFromFilePath(filePath, options) {
        filePath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(filePath);
        let sourceFile = this.sourceFileCacheByFilePath.get(filePath);
        if (sourceFile == null) {
            let fileText;
            try {
                fileText = this.context.fileSystemWrapper.readFileSync(filePath, this.context.getEncoding());
            }
            catch (_a) {
            }
            if (fileText != null) {
                this.context.logger.log(`Loaded file: ${filePath}`);
                sourceFile = this.createSourceFileFromTextInternal(filePath, fileText, options);
                sourceFile._setIsSaved(true);
            }
        }
        if (sourceFile != null && options.markInProject)
            sourceFile._markAsInProject();
        return sourceFile;
    }
    containsSourceFileAtPath(filePath) {
        filePath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(filePath);
        return this.sourceFileCacheByFilePath.has(filePath);
    }
    containsDirectoryAtPath(dirPath) {
        dirPath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(dirPath);
        return this.directoryCache.has(dirPath);
    }
    getSourceFileForNode(compilerNode) {
        let currentNode = compilerNode;
        while (currentNode.kind !== common.SyntaxKind.SourceFile) {
            if (currentNode.parent == null)
                return undefined;
            currentNode = currentNode.parent;
        }
        return this.getSourceFile(currentNode, { markInProject: false });
    }
    hasCompilerNode(compilerNode) {
        return this.nodeCache.has(compilerNode);
    }
    getExistingNodeFromCompilerNode(compilerNode) {
        return this.nodeCache.get(compilerNode);
    }
    getNodeFromCompilerNode(compilerNode, sourceFile) {
        if (compilerNode.kind === common.SyntaxKind.SourceFile)
            return this.getSourceFile(compilerNode, { markInProject: false });
        return this.nodeCache.getOrCreate(compilerNode, () => {
            const node = createNode.call(this);
            initializeNode.call(this, node);
            return node;
        });
        function createNode() {
            if (isCommentNode(compilerNode)) {
                if (CommentNodeParser.isCommentStatement(compilerNode))
                    return new CommentStatement(this.context, compilerNode, sourceFile);
                if (CommentNodeParser.isCommentClassElement(compilerNode))
                    return new CommentClassElement(this.context, compilerNode, sourceFile);
                if (CommentNodeParser.isCommentTypeElement(compilerNode))
                    return new CommentTypeElement(this.context, compilerNode, sourceFile);
                if (CommentNodeParser.isCommentObjectLiteralElement(compilerNode))
                    return new CommentObjectLiteralElement(this.context, compilerNode, sourceFile);
                if (CommentNodeParser.isCommentEnumMember(compilerNode))
                    return new CommentEnumMember(this.context, compilerNode, sourceFile);
                return common.errors.throwNotImplementedForNeverValueError(compilerNode);
            }
            const ctor = kindToWrapperMappings[compilerNode.kind] || Node;
            return new ctor(this.context, compilerNode, sourceFile);
        }
        function isCommentNode(node) {
            return node._commentKind != null;
        }
        function initializeNode(node) {
            if (compilerNode.parent != null) {
                const parentNode = this.getNodeFromCompilerNode(compilerNode.parent, sourceFile);
                parentNode._wrappedChildCount++;
            }
            const parentSyntaxList = node._getParentSyntaxListIfWrapped();
            if (parentSyntaxList != null)
                parentSyntaxList._wrappedChildCount++;
            if (compilerNode.kind === common.SyntaxKind.SyntaxList) {
                let count = 0;
                for (const _ of node._getChildrenInCacheIterator())
                    count++;
                node._wrappedChildCount = count;
            }
        }
    }
    createSourceFileFromTextInternal(filePath, text, options) {
        const hasBom = common.StringUtils.hasBom(text);
        if (hasBom)
            text = common.StringUtils.stripBom(text);
        const sourceFile = this.getSourceFile(this.createCompilerSourceFileFromText(filePath, text, options.scriptKind), options);
        if (hasBom)
            sourceFile._hasBom = true;
        return sourceFile;
    }
    createCompilerSourceFileFromText(filePath, text, scriptKind) {
        return this.documentRegistry.createOrUpdateSourceFile(filePath, this.context.compilerOptions.get(), common.ts.ScriptSnapshot.fromString(text), scriptKind);
    }
    getSourceFile(compilerSourceFile, options) {
        var _a;
        let wasAdded = false;
        const sourceFile = (_a = this.sourceFileCacheByFilePath.get(compilerSourceFile.fileName)) !== null && _a !== void 0 ? _a : this.nodeCache.getOrCreate(compilerSourceFile, () => {
            const createdSourceFile = new SourceFile(this.context, compilerSourceFile);
            if (!options.markInProject)
                this.context.inProjectCoordinator.setSourceFileNotInProject(createdSourceFile);
            this.addSourceFileToCache(createdSourceFile);
            wasAdded = true;
            return createdSourceFile;
        });
        if (options.markInProject) {
            sourceFile._markAsInProject();
            if (wasAdded)
                this.sourceFileAddedEventContainer.fire(sourceFile);
        }
        return sourceFile;
    }
    addSourceFileToCache(sourceFile) {
        this.sourceFileCacheByFilePath.set(sourceFile.getFilePath(), sourceFile);
        this.context.fileSystemWrapper.removeFileDelete(sourceFile.getFilePath());
        this.directoryCache.addSourceFile(sourceFile);
    }
    getDirectoryFromPath(dirPath, options) {
        dirPath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(dirPath);
        let directory = this.directoryCache.get(dirPath);
        if (directory == null && this.context.fileSystemWrapper.directoryExistsSync(dirPath))
            directory = this.directoryCache.createOrAddIfExists(dirPath);
        if (directory != null && options.markInProject)
            directory._markAsInProject();
        return directory;
    }
    createDirectoryOrAddIfExists(dirPath, options) {
        const directory = this.directoryCache.createOrAddIfExists(dirPath);
        if (directory != null && options.markInProject)
            directory._markAsInProject();
        return directory;
    }
    getDirectoryFromCache(dirPath) {
        return this.directoryCache.get(dirPath);
    }
    getDirectoryFromCacheOnlyIfInCache(dirPath) {
        return this.directoryCache.has(dirPath)
            ? this.directoryCache.get(dirPath)
            : undefined;
    }
    getDirectoriesByDepth() {
        return this.directoryCache.getAllByDepth();
    }
    getOrphanDirectories() {
        return this.directoryCache.getOrphans();
    }
    getSymbolDisplayPart(compilerObject) {
        return this.symbolDisplayPartCache.getOrCreate(compilerObject, () => new SymbolDisplayPart(compilerObject));
    }
    getType(type) {
        if ((type.flags & common.TypeFlags.TypeParameter) === common.TypeFlags.TypeParameter)
            return this.getTypeParameter(type);
        return this.typeCache.getOrCreate(type, () => new Type(this.context, type));
    }
    getTypeParameter(typeParameter) {
        return this.typeParameterCache.getOrCreate(typeParameter, () => new TypeParameter(this.context, typeParameter));
    }
    getSignature(signature) {
        return this.signatureCache.getOrCreate(signature, () => new Signature(this.context, signature));
    }
    getSymbol(symbol) {
        return this.symbolCache.getOrCreate(symbol, () => new Symbol(this.context, symbol));
    }
    getDefinitionInfo(compilerObject) {
        return this.definitionInfoCache.getOrCreate(compilerObject, () => new DefinitionInfo(this.context, compilerObject));
    }
    getDocumentSpan(compilerObject) {
        return this.documentSpanCache.getOrCreate(compilerObject, () => new DocumentSpan(this.context, compilerObject));
    }
    getReferenceEntry(compilerObject) {
        return this.referenceEntryCache.getOrCreate(compilerObject, () => new ReferenceEntry(this.context, compilerObject));
    }
    getReferencedSymbol(compilerObject) {
        return this.referencedSymbolCache.getOrCreate(compilerObject, () => new ReferencedSymbol(this.context, compilerObject));
    }
    getReferencedSymbolDefinitionInfo(compilerObject) {
        return this.referencedSymbolDefinitionInfoCache.getOrCreate(compilerObject, () => new ReferencedSymbolDefinitionInfo(this.context, compilerObject));
    }
    getDiagnostic(diagnostic) {
        return this.diagnosticCache.getOrCreate(diagnostic, () => {
            if (diagnostic.start != null)
                return new DiagnosticWithLocation(this.context, diagnostic);
            return new Diagnostic(this.context, diagnostic);
        });
    }
    getDiagnosticWithLocation(diagnostic) {
        return this.diagnosticCache.getOrCreate(diagnostic, () => new DiagnosticWithLocation(this.context, diagnostic));
    }
    getDiagnosticMessageChain(compilerObject) {
        return this.diagnosticMessageChainCache.getOrCreate(compilerObject, () => new DiagnosticMessageChain(compilerObject));
    }
    getJSDocTagInfo(jsDocTagInfo) {
        return this.jsDocTagInfoCache.getOrCreate(jsDocTagInfo, () => new JSDocTagInfo(jsDocTagInfo));
    }
    replaceCompilerNode(oldNode, newNode) {
        const nodeToReplace = oldNode instanceof Node ? oldNode.compilerNode : oldNode;
        const node = oldNode instanceof Node ? oldNode : this.nodeCache.get(oldNode);
        if (nodeToReplace.kind === common.SyntaxKind.SourceFile && nodeToReplace.fileName !== newNode.fileName) {
            const sourceFile = node;
            this.removeCompilerNodeFromCache(nodeToReplace);
            sourceFile._replaceCompilerNodeFromFactory(newNode);
            this.nodeCache.set(newNode, sourceFile);
            this.addSourceFileToCache(sourceFile);
            this.sourceFileAddedEventContainer.fire(sourceFile);
        }
        else {
            this.nodeCache.replaceKey(nodeToReplace, newNode);
            if (node != null)
                node._replaceCompilerNodeFromFactory(newNode);
        }
    }
    removeNodeFromCache(node) {
        this.removeCompilerNodeFromCache(node.compilerNode);
    }
    removeCompilerNodeFromCache(compilerNode) {
        this.nodeCache.removeByKey(compilerNode);
        if (compilerNode.kind === common.SyntaxKind.SourceFile) {
            const sourceFile = compilerNode;
            const standardizedFilePath = this.context.fileSystemWrapper.getStandardizedAbsolutePath(sourceFile.fileName);
            this.directoryCache.removeSourceFile(standardizedFilePath);
            const wrappedSourceFile = this.sourceFileCacheByFilePath.get(standardizedFilePath);
            this.sourceFileCacheByFilePath.delete(standardizedFilePath);
            this.documentRegistry.removeSourceFile(standardizedFilePath);
            if (wrappedSourceFile != null)
                this.sourceFileRemovedEventContainer.fire(wrappedSourceFile);
        }
    }
    addDirectoryToCache(directory) {
        this.directoryCache.addDirectory(directory);
    }
    removeDirectoryFromCache(dirPath) {
        this.directoryCache.remove(dirPath);
    }
    forgetNodesCreatedInBlock(block) {
        this.nodeCache.setForgetPoint();
        let wasPromise = false;
        let result;
        try {
            result = block((...nodes) => {
                for (const node of nodes)
                    this.nodeCache.rememberNode(node);
            });
            if (Node.isNode(result))
                this.nodeCache.rememberNode(result);
            if (isPromise(result)) {
                wasPromise = true;
                return result.then(value => {
                    if (Node.isNode(value))
                        this.nodeCache.rememberNode(value);
                    this.nodeCache.forgetLastPoint();
                    return value;
                });
            }
        }
        finally {
            if (!wasPromise)
                this.nodeCache.forgetLastPoint();
        }
        return result;
        function isPromise(value) {
            return value != null && typeof value.then === "function";
        }
    }
}

class InProjectCoordinator {
    constructor(compilerFactory) {
        this.compilerFactory = compilerFactory;
        this.notInProjectFiles = new Set();
        compilerFactory.onSourceFileRemoved(sourceFile => {
            this.notInProjectFiles.delete(sourceFile);
        });
    }
    setSourceFileNotInProject(sourceFile) {
        this.notInProjectFiles.add(sourceFile);
        sourceFile._inProject = false;
    }
    markSourceFileAsInProject(sourceFile) {
        if (this.isSourceFileInProject(sourceFile))
            return;
        this._internalMarkSourceFileAsInProject(sourceFile);
        this.notInProjectFiles.delete(sourceFile);
    }
    markSourceFilesAsInProjectForResolution() {
        const nodeModulesSearchName = "/node_modules/";
        const compilerFactory = this.compilerFactory;
        const changedSourceFiles = [];
        const unchangedSourceFiles = [];
        for (const sourceFile of [...this.notInProjectFiles.values()]) {
            if (shouldMarkInProject(sourceFile)) {
                this._internalMarkSourceFileAsInProject(sourceFile);
                this.notInProjectFiles.delete(sourceFile);
                changedSourceFiles.push(sourceFile);
            }
            else {
                unchangedSourceFiles.push(sourceFile);
            }
        }
        return { changedSourceFiles, unchangedSourceFiles };
        function shouldMarkInProject(sourceFile) {
            const filePath = sourceFile.getFilePath();
            const index = filePath.toLowerCase().lastIndexOf(nodeModulesSearchName);
            if (index === -1)
                return true;
            const nodeModulesPath = filePath.substring(0, index + nodeModulesSearchName.length - 1);
            const nodeModulesDir = compilerFactory.getDirectoryFromCacheOnlyIfInCache(nodeModulesPath);
            if (nodeModulesDir != null && nodeModulesDir._isInProject())
                return true;
            let directory = sourceFile.getDirectory();
            while (directory != null && directory.getPath() !== nodeModulesPath) {
                if (directory._isInProject())
                    return true;
                directory = compilerFactory.getDirectoryFromCacheOnlyIfInCache(common.FileUtils.getDirPath(directory.getPath()));
            }
            return false;
        }
    }
    _internalMarkSourceFileAsInProject(sourceFile) {
        sourceFile._inProject = true;
        this.markDirectoryAsInProject(sourceFile.getDirectory());
    }
    isSourceFileInProject(sourceFile) {
        return sourceFile._inProject === true;
    }
    setDirectoryAndFilesAsNotInProjectForTesting(directory) {
        for (const subDir of directory.getDirectories())
            this.setDirectoryAndFilesAsNotInProjectForTesting(subDir);
        for (const file of directory.getSourceFiles()) {
            delete file._inProject;
            this.notInProjectFiles.add(file);
        }
        delete directory._inProject;
    }
    markDirectoryAsInProject(directory) {
        if (this.isDirectoryInProject(directory))
            return;
        const inProjectCoordinator = this;
        const compilerFactory = this.compilerFactory;
        directory._inProject = true;
        markAncestorDirs(directory);
        function markAncestorDirs(dir) {
            const ancestorDirs = Array.from(getAncestorsUpToOneInProject(dir));
            const topAncestor = ancestorDirs[ancestorDirs.length - 1];
            if (topAncestor == null || !inProjectCoordinator.isDirectoryInProject(topAncestor))
                return;
            for (const ancestorDir of ancestorDirs)
                ancestorDir._inProject = true;
        }
        function* getAncestorsUpToOneInProject(dir) {
            if (common.FileUtils.isRootDirPath(dir.getPath()))
                return;
            const parentDirPath = common.FileUtils.getDirPath(dir.getPath());
            const parentDir = compilerFactory.getDirectoryFromCacheOnlyIfInCache(parentDirPath);
            if (parentDir == null)
                return;
            yield parentDir;
            if (!inProjectCoordinator.isDirectoryInProject(parentDir))
                yield* getAncestorsUpToOneInProject(parentDir);
        }
    }
    isDirectoryInProject(directory) {
        return directory._inProject === true;
    }
}

class StructurePrinterFactory {
    constructor(_getFormatCodeSettings) {
        this._getFormatCodeSettings = _getFormatCodeSettings;
    }
    getFormatCodeSettings() {
        return this._getFormatCodeSettings();
    }
    forInitializerExpressionableNode() {
        return new InitializerExpressionableNodeStructurePrinter();
    }
    forModifierableNode() {
        return new ModifierableNodeStructurePrinter();
    }
    forReturnTypedNode(alwaysWrite) {
        return new ReturnTypedNodeStructurePrinter(alwaysWrite);
    }
    forTypedNode(separator, alwaysWrite) {
        return new TypedNodeStructurePrinter(separator, alwaysWrite);
    }
    forClassDeclaration(options) {
        return new ClassDeclarationStructurePrinter(this, options);
    }
    forClassMember(options) {
        return new ClassMemberStructurePrinter(this, options);
    }
    forClassStaticBlockDeclaration() {
        return new ClassStaticBlockDeclarationStructurePrinter(this);
    }
    forConstructorDeclaration(options) {
        return new ConstructorDeclarationStructurePrinter(this, options);
    }
    forGetAccessorDeclaration(options) {
        return new GetAccessorDeclarationStructurePrinter(this, options);
    }
    forMethodDeclaration(options) {
        return new MethodDeclarationStructurePrinter(this, options);
    }
    forPropertyDeclaration() {
        return new PropertyDeclarationStructurePrinter(this);
    }
    forSetAccessorDeclaration(options) {
        return new SetAccessorDeclarationStructurePrinter(this, options);
    }
    forDecorator() {
        return new DecoratorStructurePrinter(this);
    }
    forJSDoc() {
        return new JSDocStructurePrinter(this);
    }
    forJSDocTag(options) {
        return new JSDocTagStructurePrinter(this, options);
    }
    forEnumDeclaration() {
        return new EnumDeclarationStructurePrinter(this);
    }
    forEnumMember() {
        return new EnumMemberStructurePrinter(this);
    }
    forObjectLiteralExpressionProperty() {
        return new ObjectLiteralExpressionPropertyStructurePrinter(this);
    }
    forPropertyAssignment() {
        return new PropertyAssignmentStructurePrinter(this);
    }
    forShorthandPropertyAssignment() {
        return new ShorthandPropertyAssignmentStructurePrinter(this);
    }
    forSpreadAssignment() {
        return new SpreadAssignmentStructurePrinter(this);
    }
    forFunctionDeclaration(options) {
        return new FunctionDeclarationStructurePrinter(this, options);
    }
    forParameterDeclaration() {
        return new ParameterDeclarationStructurePrinter(this);
    }
    forCallSignatureDeclaration() {
        return new CallSignatureDeclarationStructurePrinter(this);
    }
    forConstructSignatureDeclaration() {
        return new ConstructSignatureDeclarationStructurePrinter(this);
    }
    forIndexSignatureDeclaration() {
        return new IndexSignatureDeclarationStructurePrinter(this);
    }
    forInterfaceDeclaration() {
        return new InterfaceDeclarationStructurePrinter(this);
    }
    forMethodSignature() {
        return new MethodSignatureStructurePrinter(this);
    }
    forPropertySignature() {
        return new PropertySignatureStructurePrinter(this);
    }
    forTypeElementMemberedNode() {
        return new TypeElementMemberedNodeStructurePrinter(this);
    }
    forTypeElementMember() {
        return new TypeElementMemberStructurePrinter(this);
    }
    forJsxAttributeDecider() {
        return new JsxAttributeDeciderStructurePrinter(this);
    }
    forJsxAttribute() {
        return new JsxAttributeStructurePrinter(this);
    }
    forJsxChildDecider() {
        return new JsxChildDeciderStructurePrinter(this);
    }
    forJsxElement() {
        return new JsxElementStructurePrinter(this);
    }
    forJsxSelfClosingElement() {
        return new JsxSelfClosingElementStructurePrinter(this);
    }
    forJsxSpreadAttribute() {
        return new JsxSpreadAttributeStructurePrinter(this);
    }
    forExportAssignment() {
        return new ExportAssignmentStructurePrinter(this);
    }
    forExportDeclaration() {
        return new ExportDeclarationStructurePrinter(this);
    }
    forImportDeclaration() {
        return new ImportDeclarationStructurePrinter(this);
    }
    forModuleDeclaration(options) {
        return new ModuleDeclarationStructurePrinter(this, options);
    }
    forNamedImportExportSpecifier() {
        return new NamedImportExportSpecifierStructurePrinter(this);
    }
    forSourceFile(options) {
        return new SourceFileStructurePrinter(this, options);
    }
    forStatementedNode(options) {
        return new StatementedNodeStructurePrinter(this, options);
    }
    forStatement(options) {
        return new StatementStructurePrinter(this, options);
    }
    forVariableStatement() {
        return new VariableStatementStructurePrinter(this);
    }
    forTypeAliasDeclaration() {
        return new TypeAliasDeclarationStructurePrinter(this);
    }
    forTypeParameterDeclaration() {
        return new TypeParameterDeclarationStructurePrinter(this);
    }
    forVariableDeclaration() {
        return new VariableDeclarationStructurePrinter(this);
    }
}
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forInitializerExpressionableNode", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forModifierableNode", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forReturnTypedNode", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forTypedNode", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forClassDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forClassMember", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forClassStaticBlockDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forConstructorDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forGetAccessorDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forMethodDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forPropertyDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forSetAccessorDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forDecorator", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJSDoc", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJSDocTag", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forEnumDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forEnumMember", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forObjectLiteralExpressionProperty", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forPropertyAssignment", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forShorthandPropertyAssignment", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forSpreadAssignment", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forFunctionDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forParameterDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forCallSignatureDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forConstructSignatureDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forIndexSignatureDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forInterfaceDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forMethodSignature", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forPropertySignature", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forTypeElementMemberedNode", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forTypeElementMember", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJsxAttributeDecider", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJsxAttribute", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJsxChildDecider", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJsxElement", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJsxSelfClosingElement", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forJsxSpreadAttribute", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forExportAssignment", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forExportDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forImportDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forModuleDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forNamedImportExportSpecifier", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forSourceFile", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forStatementedNode", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forStatement", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forVariableStatement", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forTypeAliasDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forTypeParameterDeclaration", null);
__decorate([
    common.Memoize
], StructurePrinterFactory.prototype, "forVariableDeclaration", null);

function createWrappedNode(node, opts = {}) {
    const { compilerOptions = {}, sourceFile, typeChecker } = opts;
    const compilerOptionsContainer = new common.CompilerOptionsContainer();
    compilerOptionsContainer.set(compilerOptions);
    const projectContext = new ProjectContext({
        project: undefined,
        fileSystemWrapper: new common.TransactionalFileSystem(new common.RealFileSystemHost()),
        compilerOptionsContainer,
        createLanguageService: false,
        typeChecker,
        configFileParsingDiagnostics: [],
        skipLoadingLibFiles: true,
        libFolderPath: undefined,
    });
    const wrappedSourceFile = projectContext.compilerFactory.getSourceFile(getSourceFileNode(), { markInProject: true });
    return projectContext.compilerFactory.getNodeFromCompilerNode(node, wrappedSourceFile);
    function getSourceFileNode() {
        return sourceFile !== null && sourceFile !== void 0 ? sourceFile : getSourceFileFromNode(node);
    }
    function getSourceFileFromNode(compilerNode) {
        if (compilerNode.kind === common.SyntaxKind.SourceFile)
            return compilerNode;
        if (compilerNode.parent == null)
            throw new common.errors.InvalidOperationError("Please ensure the node was created from a source file with 'setParentNodes' set to 'true'.");
        let parent = compilerNode;
        while (parent.parent != null)
            parent = parent.parent;
        if (parent.kind !== common.SyntaxKind.SourceFile)
            throw new common.errors.NotImplementedError("For some reason the top parent was not a source file.");
        return parent;
    }
}

class ProjectContext {
    constructor(params) {
        this.logger = new ConsoleLogger();
        this.manipulationSettings = new ManipulationSettingsContainer();
        this._project = params.project;
        this.fileSystemWrapper = params.fileSystemWrapper;
        this._compilerOptions = params.compilerOptionsContainer;
        this.compilerFactory = new CompilerFactory(this);
        this.inProjectCoordinator = new InProjectCoordinator(this.compilerFactory);
        this.structurePrinterFactory = new StructurePrinterFactory(() => this.manipulationSettings.getFormatCodeSettings());
        this.lazyReferenceCoordinator = new LazyReferenceCoordinator(this.compilerFactory);
        this.directoryCoordinator = new DirectoryCoordinator(this.compilerFactory, params.fileSystemWrapper);
        this._languageService = params.createLanguageService
            ? new LanguageService({
                context: this,
                configFileParsingDiagnostics: params.configFileParsingDiagnostics,
                resolutionHost: params.resolutionHost && params.resolutionHost(this.getModuleResolutionHost(), () => this.compilerOptions.get()),
                skipLoadingLibFiles: params.skipLoadingLibFiles,
                libFolderPath: params.libFolderPath,
            })
            : undefined;
        if (params.typeChecker != null) {
            common.errors.throwIfTrue(params.createLanguageService, "Cannot specify a type checker and create a language service.");
            this._customTypeChecker = new TypeChecker(this);
            this._customTypeChecker._reset(() => params.typeChecker);
        }
    }
    get project() {
        if (this._project == null)
            throw new common.errors.InvalidOperationError("This operation is not permitted in this context.");
        return this._project;
    }
    get compilerOptions() {
        return this._compilerOptions;
    }
    get languageService() {
        if (this._languageService == null)
            throw this.getToolRequiredError("language service");
        return this._languageService;
    }
    get program() {
        if (this._languageService == null)
            throw this.getToolRequiredError("program");
        return this.languageService.getProgram();
    }
    get typeChecker() {
        if (this._customTypeChecker != null)
            return this._customTypeChecker;
        if (this._languageService == null)
            throw this.getToolRequiredError("type checker");
        return this.program.getTypeChecker();
    }
    hasLanguageService() {
        return this._languageService != null;
    }
    getEncoding() {
        return this.compilerOptions.getEncoding();
    }
    getFormatCodeSettings() {
        return this.manipulationSettings.getFormatCodeSettings();
    }
    getUserPreferences() {
        return this.manipulationSettings.getUserPreferences();
    }
    resetProgram() {
        this.languageService._reset();
    }
    createWriter() {
        const indentationText = this.manipulationSettings.getIndentationText();
        return new CodeBlockWriter__default['default']({
            newLine: this.manipulationSettings.getNewLineKindAsString(),
            indentNumberOfSpaces: indentationText === exports.IndentationText.Tab ? undefined : indentationText.length,
            useTabs: indentationText === exports.IndentationText.Tab,
            useSingleQuote: this.manipulationSettings.getQuoteKind() === exports.QuoteKind.Single,
        });
    }
    getPreEmitDiagnostics(sourceFile) {
        const compilerDiagnostics = common.ts.getPreEmitDiagnostics(this.program.compilerObject, sourceFile === null || sourceFile === void 0 ? void 0 : sourceFile.compilerNode);
        return compilerDiagnostics.map(d => this.compilerFactory.getDiagnostic(d));
    }
    getSourceFileContainer() {
        return {
            addOrGetSourceFileFromFilePath: (filePath, opts) => {
                var _a;
                return Promise.resolve((_a = this.compilerFactory.addOrGetSourceFileFromFilePath(filePath, opts)) === null || _a === void 0 ? void 0 : _a.compilerNode);
            },
            addOrGetSourceFileFromFilePathSync: (filePath, opts) => {
                var _a;
                return (_a = this.compilerFactory.addOrGetSourceFileFromFilePath(filePath, opts)) === null || _a === void 0 ? void 0 : _a.compilerNode;
            },
            addLibFileToCacheByText: (filePath, fileText, scriptKind) => {
                return this.compilerFactory.documentRegistry.createOrUpdateSourceFile(filePath, this.compilerOptions.get(), common.ts.ScriptSnapshot.fromString(fileText), scriptKind);
            },
            containsDirectoryAtPath: dirPath => this.compilerFactory.containsDirectoryAtPath(dirPath),
            containsSourceFileAtPath: filePath => this.compilerFactory.containsSourceFileAtPath(filePath),
            getSourceFileFromCacheFromFilePath: filePath => {
                const sourceFile = this.compilerFactory.getSourceFileFromCacheFromFilePath(filePath);
                return sourceFile === null || sourceFile === void 0 ? void 0 : sourceFile.compilerNode;
            },
            getSourceFilePaths: () => this.compilerFactory.getSourceFilePaths(),
            getSourceFileVersion: sourceFile => this.compilerFactory.documentRegistry.getSourceFileVersion(sourceFile),
            getChildDirectoriesOfDirectory: dirPath => {
                const result = [];
                for (const dir of this.compilerFactory.getChildDirectoriesOfDirectory(dirPath))
                    result.push(dir.getPath());
                return result;
            },
        };
    }
    getModuleResolutionHost() {
        return common.createModuleResolutionHost({
            transactionalFileSystem: this.fileSystemWrapper,
            getEncoding: () => this.getEncoding(),
            sourceFileContainer: this.getSourceFileContainer(),
        });
    }
    getToolRequiredError(name) {
        return new common.errors.InvalidOperationError(`A ${name} is required for this operation. `
            + "This might occur when manipulating or getting type information from a node that was not added "
            + `to a Project object and created via ${"createWrappedNode"}. `
            + `Please submit a bug report if you don't believe a ${name} should be required for this operation.`);
    }
}
__decorate([
    common.Memoize
], ProjectContext.prototype, "getSourceFileContainer", null);
__decorate([
    common.Memoize
], ProjectContext.prototype, "getModuleResolutionHost", null);

class Project {
    constructor(options = {}) {
        var _a;
        verifyOptions();
        const fileSystem = getFileSystem();
        const fileSystemWrapper = new common.TransactionalFileSystem(fileSystem);
        const tsConfigResolver = options.tsConfigFilePath == null
            ? undefined
            : new common.TsConfigResolver(fileSystemWrapper, fileSystemWrapper.getStandardizedAbsolutePath(options.tsConfigFilePath), getEncoding());
        const compilerOptions = getCompilerOptions();
        const compilerOptionsContainer = new common.CompilerOptionsContainer();
        compilerOptionsContainer.set(compilerOptions);
        this._context = new ProjectContext({
            project: this,
            compilerOptionsContainer,
            fileSystemWrapper,
            createLanguageService: true,
            resolutionHost: options.resolutionHost,
            configFileParsingDiagnostics: (_a = tsConfigResolver === null || tsConfigResolver === void 0 ? void 0 : tsConfigResolver.getErrors()) !== null && _a !== void 0 ? _a : [],
            skipLoadingLibFiles: options.skipLoadingLibFiles,
            libFolderPath: options.libFolderPath,
        });
        if (options.manipulationSettings != null)
            this._context.manipulationSettings.set(options.manipulationSettings);
        if (tsConfigResolver != null && options.skipAddingFilesFromTsConfig !== true) {
            this._addSourceFilesForTsConfigResolver(tsConfigResolver, compilerOptions);
            if (!options.skipFileDependencyResolution)
                this.resolveSourceFileDependencies();
        }
        function verifyOptions() {
            if (options.fileSystem != null && options.useInMemoryFileSystem)
                throw new common.errors.InvalidOperationError("Cannot provide a file system when specifying to use an in-memory file system.");
        }
        function getFileSystem() {
            var _a;
            if (options.useInMemoryFileSystem)
                return new common.InMemoryFileSystemHost();
            return (_a = options.fileSystem) !== null && _a !== void 0 ? _a : new common.RealFileSystemHost();
        }
        function getCompilerOptions() {
            var _a;
            return Object.assign(Object.assign({}, getTsConfigCompilerOptions()), ((_a = options.compilerOptions) !== null && _a !== void 0 ? _a : {}));
        }
        function getTsConfigCompilerOptions() {
            var _a;
            return (_a = tsConfigResolver === null || tsConfigResolver === void 0 ? void 0 : tsConfigResolver.getCompilerOptions()) !== null && _a !== void 0 ? _a : {};
        }
        function getEncoding() {
            var _a;
            const defaultEncoding = "utf-8";
            if (options.compilerOptions != null)
                return (_a = options.compilerOptions.charset) !== null && _a !== void 0 ? _a : defaultEncoding;
            return defaultEncoding;
        }
    }
    get manipulationSettings() {
        return this._context.manipulationSettings;
    }
    get compilerOptions() {
        return this._context.compilerOptions;
    }
    resolveSourceFileDependencies() {
        const sourceFiles = new Set();
        const onSourceFileAdded = (sourceFile) => sourceFiles.add(sourceFile);
        const { compilerFactory, inProjectCoordinator } = this._context;
        compilerFactory.onSourceFileAdded(onSourceFileAdded);
        try {
            this.getProgram().compilerObject;
        }
        finally {
            compilerFactory.onSourceFileAdded(onSourceFileAdded, false);
        }
        const result = inProjectCoordinator.markSourceFilesAsInProjectForResolution();
        for (const sourceFile of result.changedSourceFiles)
            sourceFiles.add(sourceFile);
        for (const sourceFile of result.unchangedSourceFiles)
            sourceFiles.delete(sourceFile);
        return Array.from(sourceFiles.values());
    }
    addDirectoryAtPathIfExists(dirPath, options = {}) {
        return this._context.directoryCoordinator.addDirectoryAtPathIfExists(this._context.fileSystemWrapper.getStandardizedAbsolutePath(dirPath), Object.assign(Object.assign({}, options), { markInProject: true }));
    }
    addDirectoryAtPath(dirPath, options = {}) {
        return this._context.directoryCoordinator.addDirectoryAtPath(this._context.fileSystemWrapper.getStandardizedAbsolutePath(dirPath), Object.assign(Object.assign({}, options), { markInProject: true }));
    }
    createDirectory(dirPath) {
        return this._context.directoryCoordinator.createDirectoryOrAddIfExists(this._context.fileSystemWrapper.getStandardizedAbsolutePath(dirPath), { markInProject: true });
    }
    getDirectoryOrThrow(dirPath) {
        return common.errors.throwIfNullOrUndefined(this.getDirectory(dirPath), () => `Could not find a directory at the specified path: ${this._context.fileSystemWrapper.getStandardizedAbsolutePath(dirPath)}`);
    }
    getDirectory(dirPath) {
        const { compilerFactory } = this._context;
        return compilerFactory.getDirectoryFromCache(this._context.fileSystemWrapper.getStandardizedAbsolutePath(dirPath));
    }
    getDirectories() {
        return Array.from(this._getProjectDirectoriesByDirectoryDepth());
    }
    getRootDirectories() {
        const { inProjectCoordinator } = this._context;
        const result = [];
        for (const dir of this._context.compilerFactory.getOrphanDirectories()) {
            for (const inProjectDir of findInProjectDirectories(dir))
                result.push(inProjectDir);
        }
        return result;
        function* findInProjectDirectories(dir) {
            if (inProjectCoordinator.isDirectoryInProject(dir)) {
                yield dir;
                return;
            }
            for (const childDir of dir._getDirectoriesIterator())
                yield* findInProjectDirectories(childDir);
        }
    }
    addSourceFilesAtPaths(fileGlobs) {
        return this._context.directoryCoordinator.addSourceFilesAtPaths(fileGlobs, { markInProject: true });
    }
    addSourceFileAtPathIfExists(filePath) {
        return this._context.directoryCoordinator.addSourceFileAtPathIfExists(this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePath), { markInProject: true });
    }
    addSourceFileAtPath(filePath) {
        return this._context.directoryCoordinator.addSourceFileAtPath(this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePath), { markInProject: true });
    }
    addSourceFilesFromTsConfig(tsConfigFilePath) {
        const resolver = new common.TsConfigResolver(this._context.fileSystemWrapper, this._context.fileSystemWrapper.getStandardizedAbsolutePath(tsConfigFilePath), this._context.getEncoding());
        return this._addSourceFilesForTsConfigResolver(resolver, resolver.getCompilerOptions());
    }
    _addSourceFilesForTsConfigResolver(tsConfigResolver, compilerOptions) {
        const paths = tsConfigResolver.getPaths(compilerOptions);
        const addedSourceFiles = paths.filePaths.map(p => this.addSourceFileAtPath(p));
        for (const dirPath of paths.directoryPaths)
            this.addDirectoryAtPathIfExists(dirPath);
        return addedSourceFiles;
    }
    createSourceFile(filePath, sourceFileText, options) {
        return this._context.compilerFactory.createSourceFile(this._context.fileSystemWrapper.getStandardizedAbsolutePath(filePath), sourceFileText !== null && sourceFileText !== void 0 ? sourceFileText : "", Object.assign(Object.assign({}, (options !== null && options !== void 0 ? options : {})), { markInProject: true }));
    }
    removeSourceFile(sourceFile) {
        const previouslyForgotten = sourceFile.wasForgotten();
        sourceFile.forget();
        return !previouslyForgotten;
    }
    getSourceFileOrThrow(fileNameOrSearchFunction) {
        const sourceFile = this.getSourceFile(fileNameOrSearchFunction);
        if (sourceFile != null)
            return sourceFile;
        if (typeof fileNameOrSearchFunction === "string") {
            const fileNameOrPath = common.FileUtils.standardizeSlashes(fileNameOrSearchFunction);
            if (common.FileUtils.pathIsAbsolute(fileNameOrPath) || fileNameOrPath.indexOf("/") >= 0) {
                const errorFileNameOrPath = this._context.fileSystemWrapper.getStandardizedAbsolutePath(fileNameOrPath);
                throw new common.errors.InvalidOperationError(`Could not find source file in project at the provided path: ${errorFileNameOrPath}`);
            }
            else {
                throw new common.errors.InvalidOperationError(`Could not find source file in project with the provided file name: ${fileNameOrSearchFunction}`);
            }
        }
        else {
            throw new common.errors.InvalidOperationError(`Could not find source file in project based on the provided condition.`);
        }
    }
    getSourceFile(fileNameOrSearchFunction) {
        const filePathOrSearchFunction = getFilePathOrSearchFunction(this._context.fileSystemWrapper);
        if (isStandardizedFilePath(filePathOrSearchFunction)) {
            return this._context.compilerFactory.getSourceFileFromCacheFromFilePath(filePathOrSearchFunction);
        }
        return common.IterableUtils.find(this._getProjectSourceFilesByDirectoryDepth(), filePathOrSearchFunction);
        function getFilePathOrSearchFunction(fileSystemWrapper) {
            if (fileNameOrSearchFunction instanceof Function)
                return fileNameOrSearchFunction;
            const fileNameOrPath = common.FileUtils.standardizeSlashes(fileNameOrSearchFunction);
            if (common.FileUtils.pathIsAbsolute(fileNameOrPath) || fileNameOrPath.indexOf("/") >= 0)
                return fileSystemWrapper.getStandardizedAbsolutePath(fileNameOrPath);
            else
                return def => common.FileUtils.pathEndsWith(def.getFilePath(), fileNameOrPath);
        }
        function isStandardizedFilePath(obj) {
            return typeof obj === "string";
        }
    }
    getSourceFiles(globPatterns) {
        const { compilerFactory, fileSystemWrapper } = this._context;
        const sourceFiles = this._getProjectSourceFilesByDirectoryDepth();
        if (typeof globPatterns === "string" || globPatterns instanceof Array)
            return Array.from(getFilteredSourceFiles());
        else
            return Array.from(sourceFiles);
        function* getFilteredSourceFiles() {
            const sourceFilePaths = Array.from(getSourceFilePaths());
            const matchedPaths = common.matchGlobs(sourceFilePaths, globPatterns, fileSystemWrapper.getCurrentDirectory());
            for (const matchedPath of matchedPaths)
                yield compilerFactory.getSourceFileFromCacheFromFilePath(fileSystemWrapper.getStandardizedAbsolutePath(matchedPath));
            function* getSourceFilePaths() {
                for (const sourceFile of sourceFiles)
                    yield sourceFile.getFilePath();
            }
        }
    }
    *_getProjectSourceFilesByDirectoryDepth() {
        const { compilerFactory, inProjectCoordinator } = this._context;
        for (const sourceFile of compilerFactory.getSourceFilesByDirectoryDepth()) {
            if (inProjectCoordinator.isSourceFileInProject(sourceFile))
                yield sourceFile;
        }
    }
    *_getProjectDirectoriesByDirectoryDepth() {
        const { compilerFactory, inProjectCoordinator } = this._context;
        for (const directory of compilerFactory.getDirectoriesByDepth()) {
            if (inProjectCoordinator.isDirectoryInProject(directory))
                yield directory;
        }
    }
    getAmbientModule(moduleName) {
        moduleName = normalizeAmbientModuleName(moduleName);
        return this.getAmbientModules().find(s => s.getName() === moduleName);
    }
    getAmbientModuleOrThrow(moduleName) {
        return common.errors.throwIfNullOrUndefined(this.getAmbientModule(moduleName), () => `Could not find ambient module with name: ${normalizeAmbientModuleName(moduleName)}`);
    }
    getAmbientModules() {
        return this.getTypeChecker().getAmbientModules();
    }
    save() {
        return __awaiter(this, void 0, void 0, function* () {
            yield this._context.fileSystemWrapper.flush();
            yield Promise.all(this._getUnsavedSourceFiles().map(f => f.save()));
        });
    }
    saveSync() {
        this._context.fileSystemWrapper.flushSync();
        for (const file of this._getUnsavedSourceFiles())
            file.saveSync();
    }
    enableLogging(enabled = true) {
        this._context.logger.setEnabled(enabled);
    }
    _getUnsavedSourceFiles() {
        return Array.from(getUnsavedIterator(this._context.compilerFactory.getSourceFilesByDirectoryDepth()));
        function* getUnsavedIterator(sourceFiles) {
            for (const sourceFile of sourceFiles) {
                if (!sourceFile.isSaved())
                    yield sourceFile;
            }
        }
    }
    getPreEmitDiagnostics() {
        return this._context.getPreEmitDiagnostics();
    }
    getLanguageService() {
        return this._context.languageService;
    }
    getProgram() {
        return this._context.program;
    }
    getTypeChecker() {
        return this._context.typeChecker;
    }
    getFileSystem() {
        return this._context.fileSystemWrapper.getFileSystem();
    }
    emit(emitOptions = {}) {
        return this._context.program.emit(emitOptions);
    }
    emitSync(emitOptions = {}) {
        return this._context.program.emitSync(emitOptions);
    }
    emitToMemory(emitOptions = {}) {
        return this._context.program.emitToMemory(emitOptions);
    }
    getCompilerOptions() {
        return this._context.compilerOptions.get();
    }
    getConfigFileParsingDiagnostics() {
        return this.getProgram().getConfigFileParsingDiagnostics();
    }
    createWriter() {
        return this._context.createWriter();
    }
    forgetNodesCreatedInBlock(block) {
        return this._context.compilerFactory.forgetNodesCreatedInBlock(block);
    }
    formatDiagnosticsWithColorAndContext(diagnostics, opts = {}) {
        return common.ts.formatDiagnosticsWithColorAndContext(diagnostics.map(d => d.compilerObject), {
            getCurrentDirectory: () => this._context.fileSystemWrapper.getCurrentDirectory(),
            getCanonicalFileName: fileName => fileName,
            getNewLine: () => { var _a; return (_a = opts.newLineChar) !== null && _a !== void 0 ? _a : common.runtime.getEndOfLine(); },
        });
    }
    getModuleResolutionHost() {
        return this._context.getModuleResolutionHost();
    }
}
function normalizeAmbientModuleName(moduleName) {
    if (isQuote(moduleName[0]) && isQuote(moduleName[moduleName.length - 1]))
        moduleName = moduleName.substring(1, moduleName.length - 1);
    return `"${moduleName}"`;
    function isQuote(char) {
        return char === `"` || char === "'";
    }
}

const structurePrinterFactory = new StructurePrinterFactory(() => {
    throw new common.errors.NotImplementedError("Not implemented scenario for getting code format settings when using a writer function. Please open an issue.");
});
class Writers {
    constructor() {
    }
    static object(obj) {
        return (writer) => {
            const keyNames = Object.keys(obj);
            writer.write("{");
            if (keyNames.length > 0) {
                writer.indent(() => {
                    writeObject();
                });
            }
            writer.write("}");
            function writeObject() {
                for (let i = 0; i < keyNames.length; i++) {
                    if (i > 0)
                        writer.write(",").newLine();
                    const keyName = keyNames[i];
                    const value = obj[keyName];
                    writer.write(keyName);
                    if (value != null) {
                        writer.write(": ");
                        writeValue(writer, value);
                    }
                }
                writer.newLine();
            }
        };
    }
    static objectType(structure) {
        return (writer) => {
            writer.write("{");
            if (anyPropertyHasValue(structure)) {
                writer.indent(() => {
                    structurePrinterFactory.forTypeElementMemberedNode().printText(writer, structure);
                });
            }
            writer.write("}");
        };
    }
    static unionType(firstType, secondType, ...additionalTypes) {
        return getWriteFunctionForUnionOrIntersectionType("|", [firstType, secondType, ...additionalTypes]);
    }
    static intersectionType(firstType, secondType, ...additionalTypes) {
        return getWriteFunctionForUnionOrIntersectionType("&", [firstType, secondType, ...additionalTypes]);
    }
    static assertion(type, assertionType) {
        return (writer) => {
            writeValue(writer, type);
            writer.spaceIfLastNot().write("as ");
            writeValue(writer, assertionType);
        };
    }
    static returnStatement(value) {
        return (writer) => {
            writer.write("return ");
            writer.hangingIndentUnlessBlock(() => {
                writeValue(writer, value);
                writer.write(";");
            });
        };
    }
}
function getWriteFunctionForUnionOrIntersectionType(separator, args) {
    return (writer) => {
        writeSeparatedByString(writer, ` ${separator} `, args);
    };
}
function anyPropertyHasValue(obj) {
    for (const key of Object.keys(obj)) {
        if (obj[key] == null)
            continue;
        if (obj[key] instanceof Array && obj[key].length === 0)
            continue;
        return true;
    }
    return false;
}
function writeSeparatedByString(writer, separator, values) {
    for (let i = 0; i < values.length; i++) {
        writer.conditionalWrite(i > 0, separator);
        writeValue(writer, values[i]);
    }
}
function writeValue(writer, value) {
    if (value instanceof Function)
        value(writer);
    else
        writer.write(value.toString());
}

const { InvalidOperationError, FileNotFoundError, ArgumentError, ArgumentNullOrWhitespaceError, ArgumentOutOfRangeError, ArgumentTypeError, BaseError, DirectoryNotFoundError, NotImplementedError, NotSupportedError, PathNotFoundError } = common.errors;
const WriterFunctions = Writers;
const TypeGuards = Node;

Object.defineProperty(exports, 'CompilerOptionsContainer', {
    enumerable: true,
    get: function () {
        return common.CompilerOptionsContainer;
    }
});
Object.defineProperty(exports, 'DiagnosticCategory', {
    enumerable: true,
    get: function () {
        return common.DiagnosticCategory;
    }
});
Object.defineProperty(exports, 'EmitHint', {
    enumerable: true,
    get: function () {
        return common.EmitHint;
    }
});
Object.defineProperty(exports, 'InMemoryFileSystemHost', {
    enumerable: true,
    get: function () {
        return common.InMemoryFileSystemHost;
    }
});
Object.defineProperty(exports, 'LanguageVariant', {
    enumerable: true,
    get: function () {
        return common.LanguageVariant;
    }
});
Object.defineProperty(exports, 'ModuleKind', {
    enumerable: true,
    get: function () {
        return common.ModuleKind;
    }
});
Object.defineProperty(exports, 'ModuleResolutionKind', {
    enumerable: true,
    get: function () {
        return common.ModuleResolutionKind;
    }
});
Object.defineProperty(exports, 'NewLineKind', {
    enumerable: true,
    get: function () {
        return common.NewLineKind;
    }
});
Object.defineProperty(exports, 'NodeFlags', {
    enumerable: true,
    get: function () {
        return common.NodeFlags;
    }
});
Object.defineProperty(exports, 'ObjectFlags', {
    enumerable: true,
    get: function () {
        return common.ObjectFlags;
    }
});
Object.defineProperty(exports, 'ResolutionHosts', {
    enumerable: true,
    get: function () {
        return common.ResolutionHosts;
    }
});
Object.defineProperty(exports, 'ScriptKind', {
    enumerable: true,
    get: function () {
        return common.ScriptKind;
    }
});
Object.defineProperty(exports, 'ScriptTarget', {
    enumerable: true,
    get: function () {
        return common.ScriptTarget;
    }
});
Object.defineProperty(exports, 'SettingsContainer', {
    enumerable: true,
    get: function () {
        return common.SettingsContainer;
    }
});
Object.defineProperty(exports, 'SymbolFlags', {
    enumerable: true,
    get: function () {
        return common.SymbolFlags;
    }
});
Object.defineProperty(exports, 'SyntaxKind', {
    enumerable: true,
    get: function () {
        return common.SyntaxKind;
    }
});
Object.defineProperty(exports, 'TypeFlags', {
    enumerable: true,
    get: function () {
        return common.TypeFlags;
    }
});
Object.defineProperty(exports, 'TypeFormatFlags', {
    enumerable: true,
    get: function () {
        return common.TypeFormatFlags;
    }
});
Object.defineProperty(exports, 'ts', {
    enumerable: true,
    get: function () {
        return common.ts;
    }
});
Object.defineProperty(exports, 'CodeBlockWriter', {
    enumerable: true,
    get: function () {
        return CodeBlockWriter__default['default'];
    }
});
exports.AbstractableNode = AbstractableNode;
exports.AmbientableNode = AmbientableNode;
exports.ArgumentError = ArgumentError;
exports.ArgumentNullOrWhitespaceError = ArgumentNullOrWhitespaceError;
exports.ArgumentOutOfRangeError = ArgumentOutOfRangeError;
exports.ArgumentTypeError = ArgumentTypeError;
exports.ArgumentedNode = ArgumentedNode;
exports.ArrayBindingPattern = ArrayBindingPattern;
exports.ArrayDestructuringAssignment = ArrayDestructuringAssignment;
exports.ArrayDestructuringAssignmentBase = ArrayDestructuringAssignmentBase;
exports.ArrayLiteralExpression = ArrayLiteralExpression;
exports.ArrayTypeNode = ArrayTypeNode;
exports.ArrowFunction = ArrowFunction;
exports.ArrowFunctionBase = ArrowFunctionBase;
exports.AsExpression = AsExpression;
exports.AsExpressionBase = AsExpressionBase;
exports.AssignmentExpression = AssignmentExpression;
exports.AssignmentExpressionBase = AssignmentExpressionBase;
exports.AsyncableNode = AsyncableNode;
exports.AwaitExpression = AwaitExpression;
exports.AwaitExpressionBase = AwaitExpressionBase;
exports.AwaitableNode = AwaitableNode;
exports.BaseError = BaseError;
exports.BaseExpressionedNode = BaseExpressionedNode;
exports.BigIntLiteral = BigIntLiteral;
exports.BigIntLiteralBase = BigIntLiteralBase;
exports.BinaryExpression = BinaryExpression;
exports.BinaryExpressionBase = BinaryExpressionBase;
exports.BindingElement = BindingElement;
exports.BindingElementBase = BindingElementBase;
exports.BindingNamedNode = BindingNamedNode;
exports.Block = Block;
exports.BlockBase = BlockBase;
exports.BodiedNode = BodiedNode;
exports.BodyableNode = BodyableNode;
exports.BreakStatement = BreakStatement;
exports.CallExpression = CallExpression;
exports.CallExpressionBase = CallExpressionBase;
exports.CallSignatureDeclaration = CallSignatureDeclaration;
exports.CallSignatureDeclarationBase = CallSignatureDeclarationBase;
exports.CaseBlock = CaseBlock;
exports.CaseBlockBase = CaseBlockBase;
exports.CaseClause = CaseClause;
exports.CaseClauseBase = CaseClauseBase;
exports.CatchClause = CatchClause;
exports.CatchClauseBase = CatchClauseBase;
exports.ChildOrderableNode = ChildOrderableNode;
exports.ClassDeclaration = ClassDeclaration;
exports.ClassDeclarationBase = ClassDeclarationBase;
exports.ClassElement = ClassElement;
exports.ClassExpression = ClassExpression;
exports.ClassExpressionBase = ClassExpressionBase;
exports.ClassLikeDeclarationBase = ClassLikeDeclarationBase;
exports.ClassLikeDeclarationBaseSpecific = ClassLikeDeclarationBaseSpecific;
exports.ClassStaticBlockDeclaration = ClassStaticBlockDeclaration;
exports.ClassStaticBlockDeclarationBase = ClassStaticBlockDeclarationBase;
exports.CodeAction = CodeAction;
exports.CodeFixAction = CodeFixAction;
exports.CombinedCodeActions = CombinedCodeActions;
exports.CommaListExpression = CommaListExpression;
exports.CommaListExpressionBase = CommaListExpressionBase;
exports.CommentClassElement = CommentClassElement;
exports.CommentEnumMember = CommentEnumMember;
exports.CommentObjectLiteralElement = CommentObjectLiteralElement;
exports.CommentRange = CommentRange;
exports.CommentStatement = CommentStatement;
exports.CommentTypeElement = CommentTypeElement;
exports.CommonIdentifierBase = CommonIdentifierBase;
exports.CompilerCommentClassElement = CompilerCommentClassElement;
exports.CompilerCommentEnumMember = CompilerCommentEnumMember;
exports.CompilerCommentNode = CompilerCommentNode;
exports.CompilerCommentObjectLiteralElement = CompilerCommentObjectLiteralElement;
exports.CompilerCommentStatement = CompilerCommentStatement;
exports.CompilerCommentTypeElement = CompilerCommentTypeElement;
exports.ComputedPropertyName = ComputedPropertyName;
exports.ComputedPropertyNameBase = ComputedPropertyNameBase;
exports.ConditionalExpression = ConditionalExpression;
exports.ConditionalExpressionBase = ConditionalExpressionBase;
exports.ConditionalTypeNode = ConditionalTypeNode;
exports.ConstructSignatureDeclaration = ConstructSignatureDeclaration;
exports.ConstructSignatureDeclarationBase = ConstructSignatureDeclarationBase;
exports.ConstructorDeclaration = ConstructorDeclaration;
exports.ConstructorDeclarationBase = ConstructorDeclarationBase;
exports.ConstructorDeclarationOverloadBase = ConstructorDeclarationOverloadBase;
exports.ConstructorTypeNode = ConstructorTypeNode;
exports.ConstructorTypeNodeBase = ConstructorTypeNodeBase;
exports.ContinueStatement = ContinueStatement;
exports.DebuggerStatement = DebuggerStatement;
exports.DebuggerStatementBase = DebuggerStatementBase;
exports.DecoratableNode = DecoratableNode;
exports.Decorator = Decorator;
exports.DecoratorBase = DecoratorBase;
exports.DefaultClause = DefaultClause;
exports.DefaultClauseBase = DefaultClauseBase;
exports.DefinitionInfo = DefinitionInfo;
exports.DeleteExpression = DeleteExpression;
exports.DeleteExpressionBase = DeleteExpressionBase;
exports.Diagnostic = Diagnostic;
exports.DiagnosticMessageChain = DiagnosticMessageChain;
exports.DiagnosticWithLocation = DiagnosticWithLocation;
exports.Directory = Directory;
exports.DirectoryEmitResult = DirectoryEmitResult;
exports.DirectoryNotFoundError = DirectoryNotFoundError;
exports.DoStatement = DoStatement;
exports.DoStatementBase = DoStatementBase;
exports.DocumentSpan = DocumentSpan;
exports.DotDotDotTokenableNode = DotDotDotTokenableNode;
exports.ElementAccessExpression = ElementAccessExpression;
exports.ElementAccessExpressionBase = ElementAccessExpressionBase;
exports.EmitOutput = EmitOutput;
exports.EmitResult = EmitResult;
exports.EmptyStatement = EmptyStatement;
exports.EmptyStatementBase = EmptyStatementBase;
exports.EnumDeclaration = EnumDeclaration;
exports.EnumDeclarationBase = EnumDeclarationBase;
exports.EnumMember = EnumMember;
exports.EnumMemberBase = EnumMemberBase;
exports.ExclamationTokenableNode = ExclamationTokenableNode;
exports.ExportAssignment = ExportAssignment;
exports.ExportAssignmentBase = ExportAssignmentBase;
exports.ExportDeclaration = ExportDeclaration;
exports.ExportDeclarationBase = ExportDeclarationBase;
exports.ExportGetableNode = ExportGetableNode;
exports.ExportSpecifier = ExportSpecifier;
exports.ExportSpecifierBase = ExportSpecifierBase;
exports.ExportableNode = ExportableNode;
exports.Expression = Expression;
exports.ExpressionStatement = ExpressionStatement;
exports.ExpressionStatementBase = ExpressionStatementBase;
exports.ExpressionWithTypeArguments = ExpressionWithTypeArguments;
exports.ExpressionWithTypeArgumentsBase = ExpressionWithTypeArgumentsBase;
exports.ExpressionableNode = ExpressionableNode;
exports.ExpressionedNode = ExpressionedNode;
exports.ExtendsClauseableNode = ExtendsClauseableNode;
exports.ExternalModuleReference = ExternalModuleReference;
exports.ExternalModuleReferenceBase = ExternalModuleReferenceBase;
exports.FalseLiteral = FalseLiteral;
exports.FalseLiteralBase = FalseLiteralBase;
exports.FileNotFoundError = FileNotFoundError;
exports.FileReference = FileReference;
exports.FileTextChanges = FileTextChanges;
exports.ForInStatement = ForInStatement;
exports.ForInStatementBase = ForInStatementBase;
exports.ForOfStatement = ForOfStatement;
exports.ForOfStatementBase = ForOfStatementBase;
exports.ForStatement = ForStatement;
exports.ForStatementBase = ForStatementBase;
exports.FunctionDeclaration = FunctionDeclaration;
exports.FunctionDeclarationBase = FunctionDeclarationBase;
exports.FunctionDeclarationOverloadBase = FunctionDeclarationOverloadBase;
exports.FunctionExpression = FunctionExpression;
exports.FunctionExpressionBase = FunctionExpressionBase;
exports.FunctionLikeDeclaration = FunctionLikeDeclaration;
exports.FunctionOrConstructorTypeNodeBase = FunctionOrConstructorTypeNodeBase;
exports.FunctionOrConstructorTypeNodeBaseBase = FunctionOrConstructorTypeNodeBaseBase;
exports.FunctionTypeNode = FunctionTypeNode;
exports.FunctionTypeNodeBase = FunctionTypeNodeBase;
exports.GeneratorableNode = GeneratorableNode;
exports.GetAccessorDeclaration = GetAccessorDeclaration;
exports.GetAccessorDeclarationBase = GetAccessorDeclarationBase;
exports.HeritageClause = HeritageClause;
exports.HeritageClauseableNode = HeritageClauseableNode;
exports.Identifier = Identifier;
exports.IdentifierBase = IdentifierBase;
exports.IfStatement = IfStatement;
exports.IfStatementBase = IfStatementBase;
exports.ImplementationLocation = ImplementationLocation;
exports.ImplementsClauseableNode = ImplementsClauseableNode;
exports.ImportClause = ImportClause;
exports.ImportClauseBase = ImportClauseBase;
exports.ImportDeclaration = ImportDeclaration;
exports.ImportDeclarationBase = ImportDeclarationBase;
exports.ImportEqualsDeclaration = ImportEqualsDeclaration;
exports.ImportEqualsDeclarationBase = ImportEqualsDeclarationBase;
exports.ImportExpression = ImportExpression;
exports.ImportExpressionBase = ImportExpressionBase;
exports.ImportExpressionedNode = ImportExpressionedNode;
exports.ImportSpecifier = ImportSpecifier;
exports.ImportSpecifierBase = ImportSpecifierBase;
exports.ImportTypeNode = ImportTypeNode;
exports.ImportTypeNodeBase = ImportTypeNodeBase;
exports.IndexSignatureDeclaration = IndexSignatureDeclaration;
exports.IndexSignatureDeclarationBase = IndexSignatureDeclarationBase;
exports.IndexedAccessTypeNode = IndexedAccessTypeNode;
exports.InferTypeNode = InferTypeNode;
exports.InitializerExpressionGetableNode = InitializerExpressionGetableNode;
exports.InitializerExpressionableNode = InitializerExpressionableNode;
exports.InterfaceDeclaration = InterfaceDeclaration;
exports.InterfaceDeclarationBase = InterfaceDeclarationBase;
exports.IntersectionTypeNode = IntersectionTypeNode;
exports.InvalidOperationError = InvalidOperationError;
exports.IterationStatement = IterationStatement;
exports.JSDoc = JSDoc;
exports.JSDocAugmentsTag = JSDocAugmentsTag;
exports.JSDocAuthorTag = JSDocAuthorTag;
exports.JSDocBase = JSDocBase;
exports.JSDocCallbackTag = JSDocCallbackTag;
exports.JSDocClassTag = JSDocClassTag;
exports.JSDocDeprecatedTag = JSDocDeprecatedTag;
exports.JSDocEnumTag = JSDocEnumTag;
exports.JSDocFunctionType = JSDocFunctionType;
exports.JSDocFunctionTypeBase = JSDocFunctionTypeBase;
exports.JSDocImplementsTag = JSDocImplementsTag;
exports.JSDocLink = JSDocLink;
exports.JSDocLinkCode = JSDocLinkCode;
exports.JSDocLinkPlain = JSDocLinkPlain;
exports.JSDocMemberName = JSDocMemberName;
exports.JSDocOverrideTag = JSDocOverrideTag;
exports.JSDocParameterTag = JSDocParameterTag;
exports.JSDocParameterTagBase = JSDocParameterTagBase;
exports.JSDocPrivateTag = JSDocPrivateTag;
exports.JSDocPropertyLikeTag = JSDocPropertyLikeTag;
exports.JSDocPropertyTag = JSDocPropertyTag;
exports.JSDocPropertyTagBase = JSDocPropertyTagBase;
exports.JSDocProtectedTag = JSDocProtectedTag;
exports.JSDocPublicTag = JSDocPublicTag;
exports.JSDocReadonlyTag = JSDocReadonlyTag;
exports.JSDocReturnTag = JSDocReturnTag;
exports.JSDocReturnTagBase = JSDocReturnTagBase;
exports.JSDocSeeTag = JSDocSeeTag;
exports.JSDocSeeTagBase = JSDocSeeTagBase;
exports.JSDocSignature = JSDocSignature;
exports.JSDocTag = JSDocTag;
exports.JSDocTagBase = JSDocTagBase;
exports.JSDocTagInfo = JSDocTagInfo;
exports.JSDocTemplateTag = JSDocTemplateTag;
exports.JSDocTemplateTagBase = JSDocTemplateTagBase;
exports.JSDocText = JSDocText;
exports.JSDocThisTag = JSDocThisTag;
exports.JSDocThisTagBase = JSDocThisTagBase;
exports.JSDocType = JSDocType;
exports.JSDocTypeExpression = JSDocTypeExpression;
exports.JSDocTypeExpressionableTag = JSDocTypeExpressionableTag;
exports.JSDocTypeParameteredTag = JSDocTypeParameteredTag;
exports.JSDocTypeTag = JSDocTypeTag;
exports.JSDocTypedefTag = JSDocTypedefTag;
exports.JSDocUnknownTag = JSDocUnknownTag;
exports.JSDocableNode = JSDocableNode;
exports.JsxAttribute = JsxAttribute;
exports.JsxAttributeBase = JsxAttributeBase;
exports.JsxAttributedNode = JsxAttributedNode;
exports.JsxClosingElement = JsxClosingElement;
exports.JsxClosingElementBase = JsxClosingElementBase;
exports.JsxClosingFragment = JsxClosingFragment;
exports.JsxElement = JsxElement;
exports.JsxElementBase = JsxElementBase;
exports.JsxExpression = JsxExpression;
exports.JsxExpressionBase = JsxExpressionBase;
exports.JsxFragment = JsxFragment;
exports.JsxOpeningElement = JsxOpeningElement;
exports.JsxOpeningElementBase = JsxOpeningElementBase;
exports.JsxOpeningFragment = JsxOpeningFragment;
exports.JsxSelfClosingElement = JsxSelfClosingElement;
exports.JsxSelfClosingElementBase = JsxSelfClosingElementBase;
exports.JsxSpreadAttribute = JsxSpreadAttribute;
exports.JsxSpreadAttributeBase = JsxSpreadAttributeBase;
exports.JsxTagNamedNode = JsxTagNamedNode;
exports.JsxText = JsxText;
exports.JsxTextBase = JsxTextBase;
exports.LabeledStatement = LabeledStatement;
exports.LabeledStatementBase = LabeledStatementBase;
exports.LanguageService = LanguageService;
exports.LeftHandSideExpression = LeftHandSideExpression;
exports.LeftHandSideExpressionedNode = LeftHandSideExpressionedNode;
exports.LiteralExpression = LiteralExpression;
exports.LiteralExpressionBase = LiteralExpressionBase;
exports.LiteralLikeNode = LiteralLikeNode;
exports.LiteralTypeNode = LiteralTypeNode;
exports.ManipulationError = ManipulationError;
exports.ManipulationSettingsContainer = ManipulationSettingsContainer;
exports.MappedTypeNode = MappedTypeNode;
exports.MemberExpression = MemberExpression;
exports.MemoryEmitResult = MemoryEmitResult;
exports.MetaProperty = MetaProperty;
exports.MetaPropertyBase = MetaPropertyBase;
exports.MethodDeclaration = MethodDeclaration;
exports.MethodDeclarationBase = MethodDeclarationBase;
exports.MethodDeclarationOverloadBase = MethodDeclarationOverloadBase;
exports.MethodSignature = MethodSignature;
exports.MethodSignatureBase = MethodSignatureBase;
exports.ModifierableNode = ModifierableNode;
exports.ModuleBlock = ModuleBlock;
exports.ModuleBlockBase = ModuleBlockBase;
exports.ModuleChildableNode = ModuleChildableNode;
exports.ModuleDeclaration = ModuleDeclaration;
exports.ModuleDeclarationBase = ModuleDeclarationBase;
exports.ModuleNamedNode = ModuleNamedNode;
exports.ModuledNode = ModuledNode;
exports.NameableNode = NameableNode;
exports.NamedExports = NamedExports;
exports.NamedExportsBase = NamedExportsBase;
exports.NamedImports = NamedImports;
exports.NamedImportsBase = NamedImportsBase;
exports.NamedNode = NamedNode;
exports.NamedNodeBase = NamedNodeBase;
exports.NamedTupleMember = NamedTupleMember;
exports.NamedTupleMemberBase = NamedTupleMemberBase;
exports.NamespaceExport = NamespaceExport;
exports.NamespaceExportBase = NamespaceExportBase;
exports.NamespaceImport = NamespaceImport;
exports.NamespaceImportBase = NamespaceImportBase;
exports.NewExpression = NewExpression;
exports.NewExpressionBase = NewExpressionBase;
exports.NoSubstitutionTemplateLiteral = NoSubstitutionTemplateLiteral;
exports.NoSubstitutionTemplateLiteralBase = NoSubstitutionTemplateLiteralBase;
exports.Node = Node;
exports.NonNullExpression = NonNullExpression;
exports.NonNullExpressionBase = NonNullExpressionBase;
exports.NotEmittedStatement = NotEmittedStatement;
exports.NotEmittedStatementBase = NotEmittedStatementBase;
exports.NotImplementedError = NotImplementedError;
exports.NotSupportedError = NotSupportedError;
exports.NullLiteral = NullLiteral;
exports.NullLiteralBase = NullLiteralBase;
exports.NumericLiteral = NumericLiteral;
exports.NumericLiteralBase = NumericLiteralBase;
exports.ObjectBindingPattern = ObjectBindingPattern;
exports.ObjectDestructuringAssignment = ObjectDestructuringAssignment;
exports.ObjectDestructuringAssignmentBase = ObjectDestructuringAssignmentBase;
exports.ObjectLiteralElement = ObjectLiteralElement;
exports.ObjectLiteralExpression = ObjectLiteralExpression;
exports.ObjectLiteralExpressionBase = ObjectLiteralExpressionBase;
exports.OmittedExpression = OmittedExpression;
exports.OmittedExpressionBase = OmittedExpressionBase;
exports.OutputFile = OutputFile;
exports.OverloadableNode = OverloadableNode;
exports.OverrideableNode = OverrideableNode;
exports.ParameterDeclaration = ParameterDeclaration;
exports.ParameterDeclarationBase = ParameterDeclarationBase;
exports.ParameteredNode = ParameteredNode;
exports.ParenthesizedExpression = ParenthesizedExpression;
exports.ParenthesizedExpressionBase = ParenthesizedExpressionBase;
exports.ParenthesizedTypeNode = ParenthesizedTypeNode;
exports.PartiallyEmittedExpression = PartiallyEmittedExpression;
exports.PartiallyEmittedExpressionBase = PartiallyEmittedExpressionBase;
exports.PathNotFoundError = PathNotFoundError;
exports.PostfixUnaryExpression = PostfixUnaryExpression;
exports.PostfixUnaryExpressionBase = PostfixUnaryExpressionBase;
exports.PrefixUnaryExpression = PrefixUnaryExpression;
exports.PrefixUnaryExpressionBase = PrefixUnaryExpressionBase;
exports.PrimaryExpression = PrimaryExpression;
exports.PrivateIdentifier = PrivateIdentifier;
exports.PrivateIdentifierBase = PrivateIdentifierBase;
exports.Program = Program;
exports.Project = Project;
exports.PropertyAccessExpression = PropertyAccessExpression;
exports.PropertyAccessExpressionBase = PropertyAccessExpressionBase;
exports.PropertyAssignment = PropertyAssignment;
exports.PropertyAssignmentBase = PropertyAssignmentBase;
exports.PropertyDeclaration = PropertyDeclaration;
exports.PropertyDeclarationBase = PropertyDeclarationBase;
exports.PropertyNamedNode = PropertyNamedNode;
exports.PropertySignature = PropertySignature;
exports.PropertySignatureBase = PropertySignatureBase;
exports.QualifiedName = QualifiedName;
exports.QuestionDotTokenableNode = QuestionDotTokenableNode;
exports.QuestionTokenableNode = QuestionTokenableNode;
exports.ReadonlyableNode = ReadonlyableNode;
exports.RefactorEditInfo = RefactorEditInfo;
exports.ReferenceEntry = ReferenceEntry;
exports.ReferenceFindableNode = ReferenceFindableNode;
exports.ReferencedSymbol = ReferencedSymbol;
exports.ReferencedSymbolDefinitionInfo = ReferencedSymbolDefinitionInfo;
exports.RegularExpressionLiteral = RegularExpressionLiteral;
exports.RegularExpressionLiteralBase = RegularExpressionLiteralBase;
exports.RenameLocation = RenameLocation;
exports.RenameableNode = RenameableNode;
exports.ReturnStatement = ReturnStatement;
exports.ReturnStatementBase = ReturnStatementBase;
exports.ReturnTypedNode = ReturnTypedNode;
exports.ScopeableNode = ScopeableNode;
exports.ScopedNode = ScopedNode;
exports.SetAccessorDeclaration = SetAccessorDeclaration;
exports.SetAccessorDeclarationBase = SetAccessorDeclarationBase;
exports.ShorthandPropertyAssignment = ShorthandPropertyAssignment;
exports.ShorthandPropertyAssignmentBase = ShorthandPropertyAssignmentBase;
exports.Signature = Signature;
exports.SignaturedDeclaration = SignaturedDeclaration;
exports.SourceFile = SourceFile;
exports.SourceFileBase = SourceFileBase;
exports.SpreadAssignment = SpreadAssignment;
exports.SpreadAssignmentBase = SpreadAssignmentBase;
exports.SpreadElement = SpreadElement;
exports.SpreadElementBase = SpreadElementBase;
exports.Statement = Statement;
exports.StatementBase = StatementBase;
exports.StatementedNode = StatementedNode;
exports.StaticableNode = StaticableNode;
exports.StringLiteral = StringLiteral;
exports.StringLiteralBase = StringLiteralBase;
exports.Structure = Structure;
exports.SuperElementAccessExpression = SuperElementAccessExpression;
exports.SuperElementAccessExpressionBase = SuperElementAccessExpressionBase;
exports.SuperExpression = SuperExpression;
exports.SuperExpressionBase = SuperExpressionBase;
exports.SuperExpressionedNode = SuperExpressionedNode;
exports.SuperPropertyAccessExpression = SuperPropertyAccessExpression;
exports.SuperPropertyAccessExpressionBase = SuperPropertyAccessExpressionBase;
exports.SwitchStatement = SwitchStatement;
exports.SwitchStatementBase = SwitchStatementBase;
exports.Symbol = Symbol;
exports.SymbolDisplayPart = SymbolDisplayPart;
exports.SyntaxList = SyntaxList;
exports.TaggedTemplateExpression = TaggedTemplateExpression;
exports.TemplateExpression = TemplateExpression;
exports.TemplateExpressionBase = TemplateExpressionBase;
exports.TemplateHead = TemplateHead;
exports.TemplateHeadBase = TemplateHeadBase;
exports.TemplateLiteralTypeNode = TemplateLiteralTypeNode;
exports.TemplateMiddle = TemplateMiddle;
exports.TemplateMiddleBase = TemplateMiddleBase;
exports.TemplateSpan = TemplateSpan;
exports.TemplateSpanBase = TemplateSpanBase;
exports.TemplateTail = TemplateTail;
exports.TemplateTailBase = TemplateTailBase;
exports.TextChange = TextChange;
exports.TextInsertableNode = TextInsertableNode;
exports.TextRange = TextRange;
exports.TextSpan = TextSpan;
exports.ThisExpression = ThisExpression;
exports.ThisExpressionBase = ThisExpressionBase;
exports.ThisTypeNode = ThisTypeNode;
exports.ThrowStatement = ThrowStatement;
exports.ThrowStatementBase = ThrowStatementBase;
exports.TrueLiteral = TrueLiteral;
exports.TrueLiteralBase = TrueLiteralBase;
exports.TryStatement = TryStatement;
exports.TryStatementBase = TryStatementBase;
exports.TupleTypeNode = TupleTypeNode;
exports.Type = Type;
exports.TypeAliasDeclaration = TypeAliasDeclaration;
exports.TypeAliasDeclarationBase = TypeAliasDeclarationBase;
exports.TypeArgumentedNode = TypeArgumentedNode;
exports.TypeAssertion = TypeAssertion;
exports.TypeAssertionBase = TypeAssertionBase;
exports.TypeChecker = TypeChecker;
exports.TypeElement = TypeElement;
exports.TypeElementMemberedNode = TypeElementMemberedNode;
exports.TypeGuards = TypeGuards;
exports.TypeLiteralNode = TypeLiteralNode;
exports.TypeLiteralNodeBase = TypeLiteralNodeBase;
exports.TypeNode = TypeNode;
exports.TypeOfExpression = TypeOfExpression;
exports.TypeOfExpressionBase = TypeOfExpressionBase;
exports.TypeParameter = TypeParameter;
exports.TypeParameterDeclaration = TypeParameterDeclaration;
exports.TypeParameterDeclarationBase = TypeParameterDeclarationBase;
exports.TypeParameteredNode = TypeParameteredNode;
exports.TypePredicateNode = TypePredicateNode;
exports.TypeReferenceNode = TypeReferenceNode;
exports.TypedNode = TypedNode;
exports.UnaryExpression = UnaryExpression;
exports.UnaryExpressionedNode = UnaryExpressionedNode;
exports.UnionTypeNode = UnionTypeNode;
exports.UnwrappableNode = UnwrappableNode;
exports.UpdateExpression = UpdateExpression;
exports.VariableDeclaration = VariableDeclaration;
exports.VariableDeclarationBase = VariableDeclarationBase;
exports.VariableDeclarationList = VariableDeclarationList;
exports.VariableDeclarationListBase = VariableDeclarationListBase;
exports.VariableStatement = VariableStatement;
exports.VariableStatementBase = VariableStatementBase;
exports.VoidExpression = VoidExpression;
exports.VoidExpressionBase = VoidExpressionBase;
exports.WhileStatement = WhileStatement;
exports.WhileStatementBase = WhileStatementBase;
exports.WithStatement = WithStatement;
exports.WithStatementBase = WithStatementBase;
exports.WriterFunctions = WriterFunctions;
exports.Writers = Writers;
exports.YieldExpression = YieldExpression;
exports.YieldExpressionBase = YieldExpressionBase;
exports.createWrappedNode = createWrappedNode;
exports.forEachStructureChild = forEachStructureChild;
exports.getCompilerOptionsFromTsConfig = getCompilerOptionsFromTsConfig;
exports.getScopeForNode = getScopeForNode;
exports.insertOverloads = insertOverloads;
exports.printNode = printNode;
exports.setScopeForNode = setScopeForNode;
