"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.handleWrappers = handleWrappers;
const estree_walker_1 = require("estree-walker");
function isUndefinedOrVoid(node) {
    return ((node.type === 'Identifier' && node.name === 'undefined') ||
        (node.type === 'UnaryExpression' &&
            node.operator === 'void' &&
            node.argument.type === 'Literal' &&
            node.argument.value === 0));
}
// Wrapper detection pretransforms to enable static analysis
function handleWrappers(ast) {
    // UglifyJS will convert function wrappers into !function(){}
    let wrapper;
    if (ast.body.length === 1 &&
        ast.body[0].type === 'ExpressionStatement' &&
        ast.body[0].expression.type === 'UnaryExpression' &&
        ast.body[0].expression.operator === '!' &&
        ast.body[0].expression.argument.type === 'CallExpression' &&
        ast.body[0].expression.argument.callee.type === 'FunctionExpression' &&
        ast.body[0].expression.argument.arguments.length === 1)
        wrapper = ast.body[0].expression.argument;
    else if (ast.body.length === 1 &&
        ast.body[0].type === 'ExpressionStatement' &&
        ast.body[0].expression.type === 'CallExpression' &&
        ast.body[0].expression.callee.type === 'FunctionExpression' &&
        (ast.body[0].expression.arguments.length === 1 ||
            ast.body[0].expression.arguments.length === 0))
        wrapper = ast.body[0].expression;
    else if (ast.body.length === 1 &&
        ast.body[0].type === 'ExpressionStatement' &&
        ast.body[0].expression.type === 'AssignmentExpression' &&
        ast.body[0].expression.left.type === 'MemberExpression' &&
        ast.body[0].expression.left.object.type === 'Identifier' &&
        ast.body[0].expression.left.object.name === 'module' &&
        ast.body[0].expression.left.property.type === 'Identifier' &&
        ast.body[0].expression.left.property.name === 'exports' &&
        ast.body[0].expression.right.type === 'CallExpression' &&
        ast.body[0].expression.right.callee.type === 'FunctionExpression' &&
        ast.body[0].expression.right.arguments.length === 1)
        wrapper = ast.body[0].expression.right;
    if (wrapper) {
        let browserifyReturn;
        let webpackModuleObj;
        // When.js-style AMD wrapper:
        //   (function (define) { 'use strict' define(function (require) { ... }) })
        //   (typeof define === 'function' && define.amd ? define : function (factory) { module.exports = factory(require); })
        // ->
        //   (function (define) { 'use strict' define(function () { ... }) })
        //   (typeof define === 'function' && define.amd ? define : function (factory) { module.exports = factory(require); })
        if (wrapper.arguments[0] &&
            wrapper.arguments[0].type === 'ConditionalExpression' &&
            wrapper.arguments[0].test.type === 'LogicalExpression' &&
            wrapper.arguments[0].test.operator === '&&' &&
            wrapper.arguments[0].test.left.type === 'BinaryExpression' &&
            wrapper.arguments[0].test.left.operator === '===' &&
            wrapper.arguments[0].test.left.left.type === 'UnaryExpression' &&
            wrapper.arguments[0].test.left.left.operator === 'typeof' &&
            'name' in wrapper.arguments[0].test.left.left.argument &&
            wrapper.arguments[0].test.left.left.argument.name === 'define' &&
            wrapper.arguments[0].test.left.right.type === 'Literal' &&
            wrapper.arguments[0].test.left.right.value === 'function' &&
            wrapper.arguments[0].test.right.type === 'MemberExpression' &&
            wrapper.arguments[0].test.right.object.type === 'Identifier' &&
            wrapper.arguments[0].test.right.property.type === 'Identifier' &&
            wrapper.arguments[0].test.right.property.name === 'amd' &&
            wrapper.arguments[0].test.right.computed === false &&
            wrapper.arguments[0].alternate.type === 'FunctionExpression' &&
            wrapper.arguments[0].alternate.params.length === 1 &&
            wrapper.arguments[0].alternate.params[0].type === 'Identifier' &&
            wrapper.arguments[0].alternate.body.body.length === 1 &&
            wrapper.arguments[0].alternate.body.body[0].type ===
                'ExpressionStatement' &&
            wrapper.arguments[0].alternate.body.body[0].expression.type ===
                'AssignmentExpression' &&
            wrapper.arguments[0].alternate.body.body[0].expression.left.type ===
                'MemberExpression' &&
            wrapper.arguments[0].alternate.body.body[0].expression.left.object
                .type === 'Identifier' &&
            wrapper.arguments[0].alternate.body.body[0].expression.left.object
                .name === 'module' &&
            wrapper.arguments[0].alternate.body.body[0].expression.left.property
                .type === 'Identifier' &&
            wrapper.arguments[0].alternate.body.body[0].expression.left.property
                .name === 'exports' &&
            wrapper.arguments[0].alternate.body.body[0].expression.left.computed ===
                false &&
            wrapper.arguments[0].alternate.body.body[0].expression.right.type ===
                'CallExpression' &&
            wrapper.arguments[0].alternate.body.body[0].expression.right.callee
                .type === 'Identifier' &&
            wrapper.arguments[0].alternate.body.body[0].expression.right.callee
                .name === wrapper.arguments[0].alternate.params[0].name &&
            'body' in wrapper.callee &&
            'body' in wrapper.callee.body &&
            Array.isArray(wrapper.callee.body.body) &&
            wrapper.arguments[0].alternate.body.body[0].expression.right.arguments
                .length === 1 &&
            wrapper.arguments[0].alternate.body.body[0].expression.right.arguments[0]
                .type === 'Identifier' &&
            wrapper.arguments[0].alternate.body.body[0].expression.right.arguments[0]
                .name === 'require') {
            let body = wrapper.callee.body.body;
            if (body[0].type === 'ExpressionStatement' &&
                body[0].expression.type === 'Literal' &&
                body[0].expression.value === 'use strict') {
                body = body.slice(1);
            }
            if (body.length === 1 &&
                body[0].type === 'ExpressionStatement' &&
                body[0].expression.type === 'CallExpression' &&
                body[0].expression.callee.type === 'Identifier' &&
                body[0].expression.callee.name ===
                    wrapper.arguments[0].test.right.object.name &&
                body[0].expression.arguments.length === 1 &&
                body[0].expression.arguments[0].type === 'FunctionExpression' &&
                body[0].expression.arguments[0].params.length === 1 &&
                body[0].expression.arguments[0].params[0].type === 'Identifier' &&
                body[0].expression.arguments[0].params[0].name === 'require') {
                const arg = body[0].expression.arguments[0];
                arg.params = [];
                try {
                    // @ts-ignore If it doesn't exist that's ok
                    delete arg.scope.declarations.require;
                }
                catch (e) { }
            }
        }
        // Browserify-style wrapper
        //   (function(f){if(typeof exports==="object"&&typeof module!=="undefined"){module.exports=f()}else if(typeof define==="function"&&define.amd){define([],f)}else{var g;if(typeof window!=="undefined"){g=window}else if(typeof global!=="undefined"){g=global}else if(typeof self!=="undefined"){g=self}else{g=this}g.bugsnag = f()}})(function(){var define,module,exports;return (function(){function r(e,n,t){function o(i,f){if(!n[i]){if(!e[i]){var c="function"==typeof require&&require;if(!f&&c)return c(i,!0);if(u)return u(i,!0);var a=new Error("Cannot find module '"+i+"'");throw a.code="MODULE_NOT_FOUND",a}var p=n[i]={exports:{}};e[i][0].call(p.exports,function(r){var n=e[i][1][r];return o(n||r)},p,p.exports,r,e,n,t)}return n[i].exports}for(var u="function"==typeof require&&require,i=0;i<t.length;i++)o(t[i]);return o}return r})()({
        //   1:[function(require,module,exports){
        //     ...code...
        //   },{"external":undefined}], 2: ...
        //   },{},[24])(24)
        //   });
        // ->
        //   (function(f){if(typeof exports==="object"&&typeof module!=="undefined"){module.exports=f()}else if(typeof define==="function"&&define.amd){define([],f)}else{var g;if(typeof window!=="undefined"){g=window}else if(typeof global!=="undefined"){g=global}else if(typeof self!=="undefined"){g=self}else{g=this}g.bugsnag = f()}})(function(){var define,module,exports;return (function(){function r(e,n,t){function o(i,f){if(!n[i]){if(!e[i]){var c="function"==typeof require&&require;if(!f&&c)return c(i,!0);if(u)return u(i,!0);var a=new Error("Cannot find module '"+i+"'");throw a.code="MODULE_NOT_FOUND",a}var p=n[i]={exports:{}};e[i][0].call(p.exports,function(r){var n=e[i][1][r];return o(n||r)},p,p.exports,r,e,n,t)}return n[i].exports}for(var u="function"==typeof require&&require,i=0;i<t.length;i++)o(t[i]);return o}return r})()({
        //   1:[function(require,module,exports){
        //     ...code...
        //   },{"external":undefined}], 2: ...
        //   },{
        //     "external": { exports: require('external') }
        //   },[24])(24)
        //   });
        else if (wrapper.arguments[0] &&
            wrapper.arguments[0].type === 'FunctionExpression' &&
            wrapper.arguments[0].params.length === 0 &&
            (wrapper.arguments[0].body.body.length === 1 ||
                (wrapper.arguments[0].body.body.length === 2 &&
                    wrapper.arguments[0].body.body[0].type === 'VariableDeclaration' &&
                    wrapper.arguments[0].body.body[0].declarations.length === 3 &&
                    wrapper.arguments[0].body.body[0].declarations.every((decl) => decl.init === null && decl.id.type === 'Identifier'))) &&
            wrapper.arguments[0].body.body[wrapper.arguments[0].body.body.length - 1]
                .type === 'ReturnStatement' &&
            (browserifyReturn = wrapper.arguments[0].body.body[wrapper.arguments[0].body.body.length - 1]) &&
            browserifyReturn.argument?.type === 'CallExpression' &&
            browserifyReturn.argument.arguments.length &&
            browserifyReturn.argument.arguments.every((arg) => arg && arg.type === 'Literal' && typeof arg.value === 'number') &&
            browserifyReturn.argument.callee.type === 'CallExpression' &&
            (browserifyReturn.argument.callee.callee.type === 'FunctionExpression' ||
                (browserifyReturn.argument.callee.callee.type === 'CallExpression' &&
                    browserifyReturn.argument.callee.callee.callee.type ===
                        'FunctionExpression' &&
                    browserifyReturn.argument.callee.callee.arguments.length === 0)) &&
            // (dont go deeper into browserify loader internals than this)
            browserifyReturn.argument.callee.arguments.length === 3 &&
            browserifyReturn.argument.callee.arguments[0].type ===
                'ObjectExpression' &&
            browserifyReturn.argument.callee.arguments[1].type ===
                'ObjectExpression' &&
            browserifyReturn.argument.callee.arguments[2].type === 'ArrayExpression') {
            const modules = browserifyReturn.argument.callee.arguments[0].properties;
            // verify modules is the expected data structure
            // in the process, extract external requires
            const externals = {};
            if (modules.every((m) => {
                if (m.type !== 'Property' ||
                    m.computed !== false ||
                    m.key.type !== 'Literal' ||
                    typeof m.key.value !== 'number' ||
                    m.value.type !== 'ArrayExpression' ||
                    m.value.elements.length !== 2 ||
                    !m.value.elements[0] ||
                    !m.value.elements[1] ||
                    m.value.elements[0].type !== 'FunctionExpression' ||
                    m.value.elements[1].type !== 'ObjectExpression') {
                    return false;
                }
                // detect externals from undefined moduleMap values
                const moduleMap = m.value.elements[1].properties;
                for (const prop of moduleMap) {
                    if (prop.type !== 'Property' ||
                        (prop.value.type !== 'Identifier' &&
                            prop.value.type !== 'Literal' &&
                            !isUndefinedOrVoid(prop.value)) ||
                        !((prop.key.type === 'Literal' &&
                            typeof prop.key.value === 'string') ||
                            prop.key.type === 'Identifier') ||
                        prop.computed) {
                        return false;
                    }
                    if (isUndefinedOrVoid(prop.value)) {
                        if (prop.key.type === 'Identifier') {
                            externals[prop.key.name] = {
                                type: 'Literal',
                                // @ts-ignore start can be undefined
                                start: prop.key.start,
                                // @ts-ignore end can be undefined
                                end: prop.key.end,
                                value: prop.key.name,
                                raw: JSON.stringify(prop.key.name),
                            };
                        }
                        else if (prop.key.type === 'Literal') {
                            externals[String(prop.key.value)] = prop.key;
                        }
                    }
                }
                return true;
            })) {
                // if we have externals, inline them into the browserify cache for webpack to pick up
                const externalIds = Object.keys(externals);
                const cache = browserifyReturn.argument.callee.arguments[1];
                cache.properties = externalIds.map((ext) => {
                    return {
                        type: 'Property',
                        method: false,
                        shorthand: false,
                        computed: false,
                        kind: 'init',
                        key: externals[ext],
                        value: {
                            type: 'ObjectExpression',
                            properties: [
                                {
                                    type: 'Property',
                                    kind: 'init',
                                    method: false,
                                    shorthand: false,
                                    computed: false,
                                    key: {
                                        type: 'Identifier',
                                        name: 'exports',
                                    },
                                    value: {
                                        type: 'CallExpression',
                                        optional: false,
                                        callee: {
                                            type: 'Identifier',
                                            name: 'require',
                                        },
                                        arguments: [externals[ext]],
                                    },
                                },
                            ],
                        },
                    };
                });
            }
        }
        // UMD wrapper
        //    (function (factory) {
        //      if (typeof module === "object" && typeof module.exports === "object") {
        //         var v = factory(require, exports);
        //         if (v !== undefined) module.exports = v;
        //     }
        //     else if (typeof define === "function" && define.amd) {
        //         define(["require", "exports", "./impl/format", "./impl/edit", "./impl/scanner", "./impl/parser"], factory);
        //     }
        //   })(function (require, exports) {
        //     // ...
        //   }
        // ->
        //   (function (factory) {
        //     if (typeof module === "object" && typeof module.exports === "object") {
        //         var v = factory(require, exports);
        //         if (v !== undefined) module.exports = v;
        //     }
        //     else if (typeof define === "function" && define.amd) {
        //         define(["require", "exports", "./impl/format", "./impl/edit", "./impl/scanner", "./impl/parser"], factory);
        //     }
        //   })(function () {
        //     // ...
        //   }
        else if (wrapper.arguments[0] &&
            wrapper.arguments[0].type === 'FunctionExpression' &&
            wrapper.arguments[0].params.length === 2 &&
            wrapper.arguments[0].params[0].type === 'Identifier' &&
            wrapper.arguments[0].params[1].type === 'Identifier' &&
            'body' in wrapper.callee &&
            'body' in wrapper.callee.body &&
            Array.isArray(wrapper.callee.body.body) &&
            wrapper.callee.body.body.length === 1) {
            const statement = wrapper.callee.body.body[0];
            if (statement.type === 'IfStatement' &&
                statement.test.type === 'LogicalExpression' &&
                statement.test.operator === '&&' &&
                statement.test.left.type === 'BinaryExpression' &&
                statement.test.left.left.type === 'UnaryExpression' &&
                statement.test.left.left.operator === 'typeof' &&
                statement.test.left.left.argument.type === 'Identifier' &&
                statement.test.left.left.argument.name === 'module' &&
                statement.test.left.right.type === 'Literal' &&
                statement.test.left.right.value === 'object' &&
                statement.test.right.type === 'BinaryExpression' &&
                statement.test.right.left.type === 'UnaryExpression' &&
                statement.test.right.left.operator === 'typeof' &&
                statement.test.right.left.argument.type === 'MemberExpression' &&
                statement.test.right.left.argument.object.type === 'Identifier' &&
                statement.test.right.left.argument.object.name === 'module' &&
                statement.test.right.left.argument.property.type === 'Identifier' &&
                statement.test.right.left.argument.property.name === 'exports' &&
                statement.test.right.right.type === 'Literal' &&
                statement.test.right.right.value === 'object' &&
                statement.consequent.type === 'BlockStatement' &&
                statement.consequent.body.length > 0) {
                let callSite;
                if (statement.consequent.body[0].type === 'VariableDeclaration' &&
                    statement.consequent.body[0].declarations[0].init &&
                    statement.consequent.body[0].declarations[0].init.type ===
                        'CallExpression')
                    callSite = statement.consequent.body[0].declarations[0].init;
                else if (statement.consequent.body[0].type === 'ExpressionStatement' &&
                    statement.consequent.body[0].expression.type === 'CallExpression')
                    callSite = statement.consequent.body[0].expression;
                else if (statement.consequent.body[0].type === 'ExpressionStatement' &&
                    statement.consequent.body[0].expression.type ===
                        'AssignmentExpression' &&
                    statement.consequent.body[0].expression.operator === '=' &&
                    statement.consequent.body[0].expression.right.type ===
                        'CallExpression')
                    callSite = statement.consequent.body[0].expression.right;
                if (callSite &&
                    callSite.callee.type === 'Identifier' &&
                    'params' in wrapper.callee &&
                    wrapper.callee.params.length > 0 &&
                    'name' in wrapper.callee.params[0] &&
                    callSite.callee.name === wrapper.callee.params[0].name &&
                    callSite.arguments.length === 2 &&
                    callSite.arguments[0].type === 'Identifier' &&
                    callSite.arguments[0].name === 'require' &&
                    callSite.arguments[1].type === 'Identifier' &&
                    callSite.arguments[1].name === 'exports') {
                    const funcExpression = wrapper.arguments[0];
                    funcExpression.params = [];
                    try {
                        // @ts-ignore If scope doesn't exist that's ok
                        const scope = funcExpression.scope;
                        delete scope.declarations.require;
                        delete scope.declarations.exports;
                    }
                    catch (e) { }
                }
            }
        }
        // Webpack wrapper
        //
        //   module.exports = (function(e) {
        //     var t = {};
        //     function r(n) { /*...*/ }
        //   })([
        //     function (e, t) {
        //       e.exports = require("fs");
        //     },
        //     function(e, t, r) {
        //       const n = r(0);
        //       const ns = r.n(n);
        //       ns.a.export;
        //     }
        //   ]);
        // ->
        //   module.exports = (function(e) {
        //     var t = {};
        //     function r(n) { /*...*/ }
        //   })([
        //     function (e, t) {
        //       e.exports = require("fs");
        //     },
        //     function(e, t, r) {
        //       const n = require("fs");
        //       const ns = Object.assign(a => n, { a: n });
        //     }
        //   ]);
        //
        // OR !(function (){})() | (function () {})() variants
        // OR { 0: function..., 'some-id': function () ... } registry variants
        // OR Webpack 5 non-runtime variant:
        //
        //   (function() {
        //     var exports = {};
        //     exports.id = 223;
        //     exports.ids = [223];
        //     exports.modules = { ... };
        //     var __webpack_require__ = require("../../webpack-runtime.js");
        //     ...
        //   })()
        //
        else if ((wrapper.callee.type === 'FunctionExpression' &&
            wrapper.callee.body.body.length > 2 &&
            wrapper.callee.body.body[0].type === 'VariableDeclaration' &&
            wrapper.callee.body.body[0].declarations.length === 1 &&
            wrapper.callee.body.body[0].declarations[0].type ===
                'VariableDeclarator' &&
            wrapper.callee.body.body[0].declarations[0].id.type === 'Identifier' &&
            wrapper.callee.body.body[0].declarations[0].init &&
            ((wrapper.callee.body.body[0].declarations[0].init.type ===
                'ObjectExpression' &&
                wrapper.callee.body.body[0].declarations[0].init.properties.length ===
                    0) ||
                (wrapper.callee.body.body[0].declarations[0].init.type ===
                    'CallExpression' &&
                    wrapper.callee.body.body[0].declarations[0].init.arguments
                        .length === 1)) &&
            ((wrapper.callee.body.body[1] &&
                wrapper.callee.body.body[1].type === 'FunctionDeclaration' &&
                wrapper.callee.body.body[1].params.length === 1 &&
                wrapper.callee.body.body[1].body.body.length >= 3) ||
                (wrapper.callee.body.body[2] &&
                    wrapper.callee.body.body[2].type === 'FunctionDeclaration' &&
                    wrapper.callee.body.body[2].params.length === 1 &&
                    wrapper.callee.body.body[2].body.body.length >= 3)) &&
            wrapper.arguments[0] &&
            ((wrapper.arguments[0].type === 'ArrayExpression' &&
                (webpackModuleObj = wrapper.arguments[0]) &&
                wrapper.arguments[0].elements.length > 0 &&
                wrapper.arguments[0].elements.every((el) => el && el.type === 'FunctionExpression')) ||
                (wrapper.arguments[0].type === 'ObjectExpression' &&
                    (webpackModuleObj = wrapper.arguments[0]) &&
                    wrapper.arguments[0].properties &&
                    wrapper.arguments[0].properties.length > 0 &&
                    wrapper.arguments[0].properties.every((prop) => prop &&
                        prop.type === 'Property' &&
                        !prop.computed &&
                        prop.key &&
                        prop.key.type === 'Literal' &&
                        (typeof prop.key.value === 'string' ||
                            typeof prop.key.value === 'number') &&
                        prop.value &&
                        prop.value.type === 'FunctionExpression')))) ||
            (wrapper.arguments.length === 0 &&
                wrapper.callee.type === 'FunctionExpression' &&
                wrapper.callee.params.length === 0 &&
                wrapper.callee.body.type === 'BlockStatement' &&
                wrapper.callee.body.body.length > 5 &&
                wrapper.callee.body.body[0].type === 'VariableDeclaration' &&
                wrapper.callee.body.body[0].declarations.length === 1 &&
                wrapper.callee.body.body[0].declarations[0].id.type === 'Identifier' &&
                wrapper.callee.body.body[1].type === 'ExpressionStatement' &&
                wrapper.callee.body.body[1].expression.type ===
                    'AssignmentExpression' &&
                wrapper.callee.body.body[2].type === 'ExpressionStatement' &&
                wrapper.callee.body.body[2].expression.type ===
                    'AssignmentExpression' &&
                wrapper.callee.body.body[3].type === 'ExpressionStatement' &&
                wrapper.callee.body.body[3].expression.type ===
                    'AssignmentExpression' &&
                wrapper.callee.body.body[3].expression.left.type ===
                    'MemberExpression' &&
                wrapper.callee.body.body[3].expression.left.object.type ===
                    'Identifier' &&
                wrapper.callee.body.body[3].expression.left.object.name ===
                    wrapper.callee.body.body[0].declarations[0].id.name &&
                wrapper.callee.body.body[3].expression.left.property.type ===
                    'Identifier' &&
                wrapper.callee.body.body[3].expression.left.property.name ===
                    'modules' &&
                wrapper.callee.body.body[3].expression.right.type ===
                    'ObjectExpression' &&
                wrapper.callee.body.body[3].expression.right.properties.every((prop) => prop &&
                    prop.type === 'Property' &&
                    !prop.computed &&
                    prop.key &&
                    prop.key.type === 'Literal' &&
                    (typeof prop.key.value === 'string' ||
                        typeof prop.key.value === 'number') &&
                    prop.value &&
                    prop.value.type === 'FunctionExpression') &&
                (webpackModuleObj = wrapper.callee.body.body[3].expression.right) &&
                ((wrapper.callee.body.body[4].type === 'VariableDeclaration' &&
                    wrapper.callee.body.body[4].declarations.length === 1 &&
                    wrapper.callee.body.body[4].declarations[0].init &&
                    wrapper.callee.body.body[4].declarations[0].init.type ===
                        'CallExpression' &&
                    wrapper.callee.body.body[4].declarations[0].init.callee.type ===
                        'Identifier' &&
                    wrapper.callee.body.body[4].declarations[0].init.callee.name ===
                        'require') ||
                    (wrapper.callee.body.body[5].type === 'VariableDeclaration' &&
                        wrapper.callee.body.body[5].declarations.length === 1 &&
                        wrapper.callee.body.body[5].declarations[0].init &&
                        wrapper.callee.body.body[5].declarations[0].init.type ===
                            'CallExpression' &&
                        wrapper.callee.body.body[5].declarations[0].init.callee.type ===
                            'Identifier' &&
                        wrapper.callee.body.body[5].declarations[0].init.callee.name ===
                            'require')))) {
            const externalMap = new Map();
            let modules;
            if (webpackModuleObj.type === 'ArrayExpression')
                modules = webpackModuleObj.elements.filter((el) => el?.type === 'FunctionExpression').map((el, i) => [String(i), el]);
            // Structure already checked in conditional above
            else
                modules = webpackModuleObj.properties.map((prop) => [
                    String(prop.key.value),
                    prop.value,
                ]);
            for (const [k, m] of modules) {
                const statement = m.body.body.length === 1
                    ? m.body.body[0]
                    : (m.body.body.length === 2 ||
                        (m.body.body.length === 3 &&
                            m.body.body[2].type === 'EmptyStatement')) &&
                        m.body.body[0].type === 'ExpressionStatement' &&
                        m.body.body[0].expression.type === 'Literal' &&
                        m.body.body[0].expression.value === 'use strict'
                        ? m.body.body[1]
                        : null;
                if (statement &&
                    statement.type === 'ExpressionStatement' &&
                    statement.expression.type === 'AssignmentExpression' &&
                    statement.expression.operator === '=' &&
                    statement.expression.left.type === 'MemberExpression' &&
                    statement.expression.left.object.type === 'Identifier' &&
                    'params' in m &&
                    m.params.length > 0 &&
                    'name' in m.params[0] &&
                    statement.expression.left.object.name === m.params[0].name &&
                    statement.expression.left.property.type === 'Identifier' &&
                    statement.expression.left.property.name === 'exports' &&
                    statement.expression.right.type === 'CallExpression' &&
                    statement.expression.right.callee.type === 'Identifier' &&
                    statement.expression.right.callee.name === 'require' &&
                    statement.expression.right.arguments.length === 1 &&
                    statement.expression.right.arguments[0].type === 'Literal') {
                    externalMap.set(k, statement.expression.right.arguments[0].value);
                }
            }
            for (const [, m] of modules) {
                if ('params' in m &&
                    m.params.length === 3 &&
                    m.params[2].type === 'Identifier') {
                    const assignedVars = new Map();
                    (0, estree_walker_1.walk)(m.body, {
                        enter(_node, _maybeParent) {
                            const node = _node;
                            const maybeParent = _maybeParent;
                            if (node.type === 'CallExpression' &&
                                node.callee.type === 'Identifier' &&
                                'name' in m.params[2] &&
                                node.callee.name === m.params[2].name &&
                                node.arguments.length === 1 &&
                                node.arguments[0].type === 'Literal') {
                                const externalId = externalMap.get(String(node.arguments[0].value));
                                if (externalId) {
                                    const replacement = {
                                        type: 'CallExpression',
                                        optional: false,
                                        callee: {
                                            type: 'Identifier',
                                            name: 'require',
                                        },
                                        arguments: [
                                            {
                                                type: 'Literal',
                                                value: externalId,
                                            },
                                        ],
                                    };
                                    const parent = maybeParent;
                                    if ('right' in parent && parent.right === node) {
                                        parent.right = replacement;
                                    }
                                    else if ('left' in parent && parent.left === node) {
                                        parent.left = replacement;
                                    }
                                    else if ('object' in parent && parent.object === node) {
                                        parent.object = replacement;
                                    }
                                    else if ('callee' in parent && parent.callee === node) {
                                        parent.callee = replacement;
                                    }
                                    else if ('arguments' in parent &&
                                        parent.arguments.some((arg) => arg === node)) {
                                        parent.arguments = parent.arguments.map((arg) => arg === node ? replacement : arg);
                                    }
                                    else if ('init' in parent && parent.init === node) {
                                        if (parent.type === 'VariableDeclarator' &&
                                            parent.id.type === 'Identifier')
                                            assignedVars.set(parent.id.name, externalId);
                                        parent.init = replacement;
                                    }
                                }
                            }
                            else if (node.type === 'CallExpression' &&
                                node.callee.type === 'MemberExpression' &&
                                node.callee.object.type === 'Identifier' &&
                                'name' in m.params[2] &&
                                node.callee.object.name === m.params[2].name &&
                                node.callee.property.type === 'Identifier' &&
                                node.callee.property.name === 'n' &&
                                node.arguments.length === 1 &&
                                node.arguments[0].type === 'Identifier') {
                                if (maybeParent &&
                                    'init' in maybeParent &&
                                    maybeParent.init === node) {
                                    const req = node.arguments[0];
                                    const callExpression = {
                                        type: 'CallExpression',
                                        optional: false,
                                        callee: {
                                            type: 'MemberExpression',
                                            computed: false,
                                            optional: false,
                                            object: {
                                                type: 'Identifier',
                                                name: 'Object',
                                            },
                                            property: {
                                                type: 'Identifier',
                                                name: 'assign',
                                            },
                                        },
                                        arguments: [
                                            {
                                                type: 'ArrowFunctionExpression',
                                                expression: true,
                                                params: [],
                                                body: req,
                                            },
                                            {
                                                type: 'ObjectExpression',
                                                properties: [
                                                    {
                                                        type: 'Property',
                                                        kind: 'init',
                                                        method: false,
                                                        computed: false,
                                                        shorthand: false,
                                                        key: {
                                                            type: 'Identifier',
                                                            name: 'a',
                                                        },
                                                        value: req,
                                                    },
                                                ],
                                            },
                                        ],
                                    };
                                    maybeParent.init = callExpression;
                                }
                            }
                        },
                    });
                }
            }
        }
    }
}
