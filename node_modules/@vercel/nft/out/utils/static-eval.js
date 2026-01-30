"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.wildcardRegEx = exports.WILDCARD = exports.FUNCTION = exports.UNKNOWN = void 0;
exports.evaluate = evaluate;
async function evaluate(ast, vars = {}, computeBranches = true) {
    const state = {
        computeBranches,
        vars,
    };
    return walk(ast);
    // walk returns:
    // 1. Single known value: { value: value }
    // 2. Conditional value: { test, ifTrue, else }
    // 3. Unknown value: undefined
    function walk(node) {
        const visitor = visitors[node.type];
        if (visitor) {
            return visitor.call(state, node, walk);
        }
        return undefined;
    }
}
exports.UNKNOWN = Symbol();
exports.FUNCTION = Symbol();
exports.WILDCARD = '\x1a';
exports.wildcardRegEx = /\x1a/g;
function countWildcards(str) {
    exports.wildcardRegEx.lastIndex = 0;
    let cnt = 0;
    while (exports.wildcardRegEx.exec(str))
        cnt++;
    return cnt;
}
const visitors = {
    ArrayExpression: async function ArrayExpression(node, walk) {
        const arr = [];
        for (let i = 0, l = node.elements.length; i < l; i++) {
            if (node.elements[i] === null) {
                arr.push(null);
                continue;
            }
            const x = await walk(node.elements[i]);
            if (!x)
                return;
            if ('value' in x === false)
                return;
            arr.push(x.value);
        }
        return { value: arr };
    },
    ArrowFunctionExpression: async function (node, walk) {
        // () => val support only
        if (node.params.length === 0 &&
            !node.generator &&
            !node.async &&
            node.expression) {
            const innerValue = await walk(node.body);
            if (!innerValue || !('value' in innerValue))
                return;
            return {
                value: {
                    [exports.FUNCTION]: () => innerValue.value,
                },
            };
        }
        return undefined;
    },
    BinaryExpression: async function BinaryExpression(node, walk) {
        const op = node.operator;
        let l = await walk(node.left);
        if (!l && op !== '+')
            return;
        let r = await walk(node.right);
        if (!l && !r)
            return;
        if (!l) {
            // UNKNOWN + 'str' -> wildcard string value
            if (this.computeBranches &&
                r &&
                'value' in r &&
                typeof r.value === 'string')
                return {
                    value: exports.WILDCARD + r.value,
                    wildcards: [node.left, ...(r.wildcards || [])],
                };
            return;
        }
        if (!r) {
            // 'str' + UKNOWN -> wildcard string value
            if (this.computeBranches && op === '+') {
                if (l && 'value' in l && typeof l.value === 'string')
                    return {
                        value: l.value + exports.WILDCARD,
                        wildcards: [...(l.wildcards || []), node.right],
                    };
            }
            // A || UNKNOWN -> A if A is truthy
            if (!('test' in l) && op === '||' && l.value)
                return l;
            return;
        }
        if ('test' in l && 'value' in r) {
            const v = r.value;
            if (op === '==')
                return { test: l.test, ifTrue: l.ifTrue == v, else: l.else == v };
            if (op === '===')
                return { test: l.test, ifTrue: l.ifTrue === v, else: l.else === v };
            if (op === '!=')
                return { test: l.test, ifTrue: l.ifTrue != v, else: l.else != v };
            if (op === '!==')
                return { test: l.test, ifTrue: l.ifTrue !== v, else: l.else !== v };
            if (op === '+')
                return { test: l.test, ifTrue: l.ifTrue + v, else: l.else + v };
            if (op === '-')
                return { test: l.test, ifTrue: l.ifTrue - v, else: l.else - v };
            if (op === '*')
                return { test: l.test, ifTrue: l.ifTrue * v, else: l.else * v };
            if (op === '/')
                return { test: l.test, ifTrue: l.ifTrue / v, else: l.else / v };
            if (op === '%')
                return { test: l.test, ifTrue: l.ifTrue % v, else: l.else % v };
            if (op === '<')
                return { test: l.test, ifTrue: l.ifTrue < v, else: l.else < v };
            if (op === '<=')
                return { test: l.test, ifTrue: l.ifTrue <= v, else: l.else <= v };
            if (op === '>')
                return { test: l.test, ifTrue: l.ifTrue > v, else: l.else > v };
            if (op === '>=')
                return { test: l.test, ifTrue: l.ifTrue >= v, else: l.else >= v };
            if (op === '|')
                return { test: l.test, ifTrue: l.ifTrue | v, else: l.else | v };
            if (op === '&')
                return { test: l.test, ifTrue: l.ifTrue & v, else: l.else & v };
            if (op === '^')
                return { test: l.test, ifTrue: l.ifTrue ^ v, else: l.else ^ v };
            if (op === '&&')
                return { test: l.test, ifTrue: l.ifTrue && v, else: l.else && v };
            if (op === '||')
                return { test: l.test, ifTrue: l.ifTrue || v, else: l.else || v };
        }
        else if ('test' in r && 'value' in l) {
            const v = l.value;
            if (op === '==')
                return { test: r.test, ifTrue: v == r.ifTrue, else: v == r.else };
            if (op === '===')
                return { test: r.test, ifTrue: v === r.ifTrue, else: v === r.else };
            if (op === '!=')
                return { test: r.test, ifTrue: v != r.ifTrue, else: v != r.else };
            if (op === '!==')
                return { test: r.test, ifTrue: v !== r.ifTrue, else: v !== r.else };
            if (op === '+')
                return { test: r.test, ifTrue: v + r.ifTrue, else: v + r.else };
            if (op === '-')
                return { test: r.test, ifTrue: v - r.ifTrue, else: v - r.else };
            if (op === '*')
                return { test: r.test, ifTrue: v * r.ifTrue, else: v * r.else };
            if (op === '/')
                return { test: r.test, ifTrue: v / r.ifTrue, else: v / r.else };
            if (op === '%')
                return { test: r.test, ifTrue: v % r.ifTrue, else: v % r.else };
            if (op === '<')
                return { test: r.test, ifTrue: v < r.ifTrue, else: v < r.else };
            if (op === '<=')
                return { test: r.test, ifTrue: v <= r.ifTrue, else: v <= r.else };
            if (op === '>')
                return { test: r.test, ifTrue: v > r.ifTrue, else: v > r.else };
            if (op === '>=')
                return { test: r.test, ifTrue: v >= r.ifTrue, else: v >= r.else };
            if (op === '|')
                return { test: r.test, ifTrue: v | r.ifTrue, else: v | r.else };
            if (op === '&')
                return { test: r.test, ifTrue: v & r.ifTrue, else: v & r.else };
            if (op === '^')
                return { test: r.test, ifTrue: v ^ r.ifTrue, else: v ^ r.else };
            if (op === '&&')
                return { test: r.test, ifTrue: v && r.ifTrue, else: l && r.else };
            if (op === '||')
                return { test: r.test, ifTrue: v || r.ifTrue, else: l || r.else };
        }
        else if ('value' in l && 'value' in r) {
            if (op === '==')
                return { value: l.value == r.value };
            if (op === '===')
                return { value: l.value === r.value };
            if (op === '!=')
                return { value: l.value != r.value };
            if (op === '!==')
                return { value: l.value !== r.value };
            if (op === '+') {
                const val = { value: l.value + r.value };
                let wildcards = [];
                if ('wildcards' in l && l.wildcards) {
                    wildcards = wildcards.concat(l.wildcards);
                }
                if ('wildcards' in r && r.wildcards) {
                    wildcards = wildcards.concat(r.wildcards);
                }
                if (wildcards.length > 0) {
                    val.wildcards = wildcards;
                }
                return val;
            }
            if (op === '-')
                return { value: l.value - r.value };
            if (op === '*')
                return { value: l.value * r.value };
            if (op === '/')
                return { value: l.value / r.value };
            if (op === '%')
                return { value: l.value % r.value };
            if (op === '<')
                return { value: l.value < r.value };
            if (op === '<=')
                return { value: l.value <= r.value };
            if (op === '>')
                return { value: l.value > r.value };
            if (op === '>=')
                return { value: l.value >= r.value };
            if (op === '|')
                return { value: l.value | r.value };
            if (op === '&')
                return { value: l.value & r.value };
            if (op === '^')
                return { value: l.value ^ r.value };
            if (op === '&&')
                return { value: l.value && r.value };
            if (op === '||')
                return { value: l.value || r.value };
        }
        return;
    },
    CallExpression: async function CallExpression(node, walk) {
        const callee = await walk(node.callee);
        if (!callee || 'test' in callee)
            return;
        let fn = callee.value;
        if (typeof fn === 'object' && fn !== null)
            fn = fn[exports.FUNCTION];
        if (typeof fn !== 'function')
            return;
        let ctx = null;
        if (node.callee.object) {
            ctx = await walk(node.callee.object);
            ctx = ctx && 'value' in ctx && ctx.value ? ctx.value : null;
        }
        // we allow one conditional argument to create a conditional expression
        let predicate;
        let args = [];
        let argsElse;
        let allWildcards = node.arguments.length > 0 && node.callee.property?.name !== 'concat';
        const wildcards = [];
        for (let i = 0, l = node.arguments.length; i < l; i++) {
            let x = await walk(node.arguments[i]);
            if (x) {
                allWildcards = false;
                if ('value' in x && typeof x.value === 'string' && x.wildcards)
                    x.wildcards.forEach((w) => wildcards.push(w));
            }
            else {
                if (!this.computeBranches)
                    return;
                // this works because provided static functions
                // operate on known string inputs
                x = { value: exports.WILDCARD };
                wildcards.push(node.arguments[i]);
            }
            if ('test' in x) {
                if (wildcards.length)
                    return;
                if (predicate)
                    return;
                predicate = x.test;
                argsElse = args.concat([]);
                args.push(x.ifTrue);
                argsElse.push(x.else);
            }
            else {
                args.push(x.value);
                if (argsElse)
                    argsElse.push(x.value);
            }
        }
        if (allWildcards)
            return;
        try {
            const result = await fn.apply(ctx, args);
            if (result === exports.UNKNOWN)
                return;
            if (!predicate) {
                if (wildcards.length) {
                    if (typeof result !== 'string' ||
                        countWildcards(result) !== wildcards.length)
                        return;
                    return { value: result, wildcards };
                }
                return { value: result };
            }
            const resultElse = await fn.apply(ctx, argsElse);
            if (result === exports.UNKNOWN)
                return;
            return { test: predicate, ifTrue: result, else: resultElse };
        }
        catch (e) {
            return;
        }
    },
    ConditionalExpression: async function ConditionalExpression(node, walk) {
        const val = await walk(node.test);
        if (val && 'value' in val)
            return val.value ? walk(node.consequent) : walk(node.alternate);
        if (!this.computeBranches)
            return;
        const thenValue = await walk(node.consequent);
        if (!thenValue || 'wildcards' in thenValue || 'test' in thenValue)
            return;
        const elseValue = await walk(node.alternate);
        if (!elseValue || 'wildcards' in elseValue || 'test' in elseValue)
            return;
        return {
            test: node.test,
            ifTrue: thenValue.value,
            else: elseValue.value,
        };
    },
    ExpressionStatement: async function ExpressionStatement(node, walk) {
        return walk(node.expression);
    },
    Identifier: async function Identifier(node, _walk) {
        if (Object.hasOwnProperty.call(this.vars, node.name))
            return this.vars[node.name];
        return undefined;
    },
    Literal: async function Literal(node, _walk) {
        return { value: node.value };
    },
    MemberExpression: async function MemberExpression(node, walk) {
        const obj = await walk(node.object);
        if (!obj || 'test' in obj || typeof obj.value === 'function') {
            return undefined;
        }
        if (node.property.type === 'Identifier') {
            if (typeof obj.value === 'string' && node.property.name === 'concat') {
                return {
                    value: {
                        [exports.FUNCTION]: (...args) => obj.value.concat(args),
                    },
                };
            }
            if (typeof obj.value === 'object' && obj.value !== null) {
                const objValue = obj.value;
                if (node.computed) {
                    // See if we can compute the computed property
                    const computedProp = await walk(node.property);
                    if (computedProp && 'value' in computedProp && computedProp.value) {
                        const val = objValue[computedProp.value];
                        if (val === exports.UNKNOWN)
                            return undefined;
                        return { value: val };
                    }
                    // Special case for empty object
                    if (!objValue[exports.UNKNOWN] && Object.keys(obj).length === 0) {
                        return { value: undefined };
                    }
                }
                else if (node.property.name in objValue) {
                    const val = objValue[node.property.name];
                    if (val === exports.UNKNOWN)
                        return undefined;
                    return { value: val };
                }
                else if (objValue[exports.UNKNOWN])
                    return undefined;
            }
            else {
                return { value: undefined };
            }
        }
        const prop = await walk(node.property);
        if (!prop || 'test' in prop)
            return undefined;
        if (typeof obj.value === 'object' && obj.value !== null) {
            //@ts-ignore
            if (prop.value in obj.value) {
                //@ts-ignore
                const val = obj.value[prop.value];
                if (val === exports.UNKNOWN)
                    return undefined;
                return { value: val };
            }
            //@ts-ignore
            else if (obj.value[exports.UNKNOWN]) {
                return undefined;
            }
        }
        else {
            return { value: undefined };
        }
        return undefined;
    },
    MetaProperty: async function MetaProperty(node) {
        if (node.meta.name === 'import' && node.property.name === 'meta')
            return { value: this.vars['import.meta'] };
        return undefined;
    },
    NewExpression: async function NewExpression(node, walk) {
        // new URL('./local', parent)
        const cls = await walk(node.callee);
        if (cls && 'value' in cls && cls.value === URL && node.arguments.length) {
            const arg = await walk(node.arguments[0]);
            if (!arg)
                return undefined;
            let parent = null;
            if (node.arguments[1]) {
                parent = await walk(node.arguments[1]);
                if (!parent || !('value' in parent))
                    return undefined;
            }
            if ('value' in arg) {
                if (parent) {
                    try {
                        return { value: new URL(arg.value, parent.value) };
                    }
                    catch {
                        return undefined;
                    }
                }
                try {
                    return { value: new URL(arg.value) };
                }
                catch {
                    return undefined;
                }
            }
            else {
                const test = arg.test;
                if (parent) {
                    try {
                        return {
                            test,
                            ifTrue: new URL(arg.ifTrue, parent.value),
                            else: new URL(arg.else, parent.value),
                        };
                    }
                    catch {
                        return undefined;
                    }
                }
                try {
                    return {
                        test,
                        ifTrue: new URL(arg.ifTrue),
                        else: new URL(arg.else),
                    };
                }
                catch {
                    return undefined;
                }
            }
        }
        return undefined;
    },
    ObjectExpression: async function ObjectExpression(node, walk) {
        const obj = {};
        for (let i = 0; i < node.properties.length; i++) {
            const prop = node.properties[i];
            const keyValue = prop.computed
                ? walk(prop.key)
                : prop.key && { value: prop.key.name || prop.key.value };
            if (!keyValue || 'test' in keyValue)
                return;
            const value = await walk(prop.value);
            if (!value || 'test' in value)
                return;
            //@ts-ignore
            if (value.value === exports.UNKNOWN)
                return;
            //@ts-ignore
            obj[keyValue.value] = value.value;
        }
        return { value: obj };
    },
    SequenceExpression: async function SequenceExpression(node, walk) {
        if ('expressions' in node &&
            node.expressions.length === 2 &&
            node.expressions[0].type === 'Literal' &&
            node.expressions[0].value === 0 &&
            node.expressions[1].type === 'MemberExpression') {
            const arg = await walk(node.expressions[1]);
            return arg;
        }
        return undefined;
    },
    TemplateLiteral: async function TemplateLiteral(node, walk) {
        let val = { value: '' };
        for (var i = 0; i < node.expressions.length; i++) {
            if ('value' in val) {
                val.value += node.quasis[i].value.cooked;
            }
            else {
                val.ifTrue += node.quasis[i].value.cooked;
                val.else += node.quasis[i].value.cooked;
            }
            let exprValue = await walk(node.expressions[i]);
            if (!exprValue) {
                if (!this.computeBranches)
                    return undefined;
                exprValue = { value: exports.WILDCARD, wildcards: [node.expressions[i]] };
            }
            if ('value' in exprValue) {
                if ('value' in val) {
                    val.value += exprValue.value;
                    if (exprValue.wildcards)
                        val.wildcards = [...(val.wildcards || []), ...exprValue.wildcards];
                }
                else {
                    if (exprValue.wildcards)
                        return;
                    val.ifTrue += exprValue.value;
                    val.else += exprValue.value;
                }
            }
            else if ('value' in val) {
                if ('wildcards' in val) {
                    // only support a single branch in a template
                    return;
                }
                val = {
                    test: exprValue.test,
                    ifTrue: val.value + exprValue.ifTrue,
                    else: val.value + exprValue.else,
                };
            }
            else {
                // only support a single branch in a template
                return;
            }
        }
        if ('value' in val) {
            val.value += node.quasis[i].value.cooked;
        }
        else {
            val.ifTrue += node.quasis[i].value.cooked;
            val.else += node.quasis[i].value.cooked;
        }
        return val;
    },
    ThisExpression: async function ThisExpression(_node, _walk) {
        if (Object.hasOwnProperty.call(this.vars, 'this'))
            return this.vars['this'];
        return undefined;
    },
    UnaryExpression: async function UnaryExpression(node, walk) {
        const val = await walk(node.argument);
        if (!val)
            return undefined;
        if ('value' in val && 'wildcards' in val === false) {
            if (node.operator === '+')
                return { value: +val.value };
            if (node.operator === '-')
                return { value: -val.value };
            if (node.operator === '~')
                return { value: ~val.value };
            if (node.operator === '!')
                return { value: !val.value };
        }
        else if ('test' in val && 'wildcards' in val === false) {
            if (node.operator === '+')
                return { test: val.test, ifTrue: +val.ifTrue, else: +val.else };
            if (node.operator === '-')
                return { test: val.test, ifTrue: -val.ifTrue, else: -val.else };
            if (node.operator === '~')
                return { test: val.test, ifTrue: ~val.ifTrue, else: ~val.else };
            if (node.operator === '!')
                return { test: val.test, ifTrue: !val.ifTrue, else: !val.else };
        }
        return undefined;
    },
};
visitors.LogicalExpression = visitors.BinaryExpression;
