"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __commonJS = (cb, mod) => function __require() {
  return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
};
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// ../../node_modules/.pnpm/path-to-regexp@6.1.0/node_modules/path-to-regexp/dist/index.js
var require_dist = __commonJS({
  "../../node_modules/.pnpm/path-to-regexp@6.1.0/node_modules/path-to-regexp/dist/index.js"(exports) {
    "use strict";
    Object.defineProperty(exports, "__esModule", { value: true });
    function lexer(str) {
      var tokens = [];
      var i = 0;
      while (i < str.length) {
        var char = str[i];
        if (char === "*" || char === "+" || char === "?") {
          tokens.push({ type: "MODIFIER", index: i, value: str[i++] });
          continue;
        }
        if (char === "\\") {
          tokens.push({ type: "ESCAPED_CHAR", index: i++, value: str[i++] });
          continue;
        }
        if (char === "{") {
          tokens.push({ type: "OPEN", index: i, value: str[i++] });
          continue;
        }
        if (char === "}") {
          tokens.push({ type: "CLOSE", index: i, value: str[i++] });
          continue;
        }
        if (char === ":") {
          var name = "";
          var j = i + 1;
          while (j < str.length) {
            var code = str.charCodeAt(j);
            if (
              // `0-9`
              code >= 48 && code <= 57 || // `A-Z`
              code >= 65 && code <= 90 || // `a-z`
              code >= 97 && code <= 122 || // `_`
              code === 95
            ) {
              name += str[j++];
              continue;
            }
            break;
          }
          if (!name)
            throw new TypeError("Missing parameter name at " + i);
          tokens.push({ type: "NAME", index: i, value: name });
          i = j;
          continue;
        }
        if (char === "(") {
          var count = 1;
          var pattern = "";
          var j = i + 1;
          if (str[j] === "?") {
            throw new TypeError('Pattern cannot start with "?" at ' + j);
          }
          while (j < str.length) {
            if (str[j] === "\\") {
              pattern += str[j++] + str[j++];
              continue;
            }
            if (str[j] === ")") {
              count--;
              if (count === 0) {
                j++;
                break;
              }
            } else if (str[j] === "(") {
              count++;
              if (str[j + 1] !== "?") {
                throw new TypeError("Capturing groups are not allowed at " + j);
              }
            }
            pattern += str[j++];
          }
          if (count)
            throw new TypeError("Unbalanced pattern at " + i);
          if (!pattern)
            throw new TypeError("Missing pattern at " + i);
          tokens.push({ type: "PATTERN", index: i, value: pattern });
          i = j;
          continue;
        }
        tokens.push({ type: "CHAR", index: i, value: str[i++] });
      }
      tokens.push({ type: "END", index: i, value: "" });
      return tokens;
    }
    function parse(str, options) {
      if (options === void 0) {
        options = {};
      }
      var tokens = lexer(str);
      var _a = options.prefixes, prefixes = _a === void 0 ? "./" : _a;
      var defaultPattern = "[^" + escapeString(options.delimiter || "/#?") + "]+?";
      var result = [];
      var key = 0;
      var i = 0;
      var path2 = "";
      var tryConsume = function(type) {
        if (i < tokens.length && tokens[i].type === type)
          return tokens[i++].value;
      };
      var mustConsume = function(type) {
        var value2 = tryConsume(type);
        if (value2 !== void 0)
          return value2;
        var _a2 = tokens[i], nextType = _a2.type, index = _a2.index;
        throw new TypeError("Unexpected " + nextType + " at " + index + ", expected " + type);
      };
      var consumeText = function() {
        var result2 = "";
        var value2;
        while (value2 = tryConsume("CHAR") || tryConsume("ESCAPED_CHAR")) {
          result2 += value2;
        }
        return result2;
      };
      while (i < tokens.length) {
        var char = tryConsume("CHAR");
        var name = tryConsume("NAME");
        var pattern = tryConsume("PATTERN");
        if (name || pattern) {
          var prefix = char || "";
          if (prefixes.indexOf(prefix) === -1) {
            path2 += prefix;
            prefix = "";
          }
          if (path2) {
            result.push(path2);
            path2 = "";
          }
          result.push({
            name: name || key++,
            prefix,
            suffix: "",
            pattern: pattern || defaultPattern,
            modifier: tryConsume("MODIFIER") || ""
          });
          continue;
        }
        var value = char || tryConsume("ESCAPED_CHAR");
        if (value) {
          path2 += value;
          continue;
        }
        if (path2) {
          result.push(path2);
          path2 = "";
        }
        var open = tryConsume("OPEN");
        if (open) {
          var prefix = consumeText();
          var name_1 = tryConsume("NAME") || "";
          var pattern_1 = tryConsume("PATTERN") || "";
          var suffix = consumeText();
          mustConsume("CLOSE");
          result.push({
            name: name_1 || (pattern_1 ? key++ : ""),
            pattern: name_1 && !pattern_1 ? defaultPattern : pattern_1,
            prefix,
            suffix,
            modifier: tryConsume("MODIFIER") || ""
          });
          continue;
        }
        mustConsume("END");
      }
      return result;
    }
    exports.parse = parse;
    function compile(str, options) {
      return tokensToFunction(parse(str, options), options);
    }
    exports.compile = compile;
    function tokensToFunction(tokens, options) {
      if (options === void 0) {
        options = {};
      }
      var reFlags = flags(options);
      var _a = options.encode, encode = _a === void 0 ? function(x) {
        return x;
      } : _a, _b = options.validate, validate = _b === void 0 ? true : _b;
      var matches = tokens.map(function(token) {
        if (typeof token === "object") {
          return new RegExp("^(?:" + token.pattern + ")$", reFlags);
        }
      });
      return function(data) {
        var path2 = "";
        for (var i = 0; i < tokens.length; i++) {
          var token = tokens[i];
          if (typeof token === "string") {
            path2 += token;
            continue;
          }
          var value = data ? data[token.name] : void 0;
          var optional = token.modifier === "?" || token.modifier === "*";
          var repeat = token.modifier === "*" || token.modifier === "+";
          if (Array.isArray(value)) {
            if (!repeat) {
              throw new TypeError('Expected "' + token.name + '" to not repeat, but got an array');
            }
            if (value.length === 0) {
              if (optional)
                continue;
              throw new TypeError('Expected "' + token.name + '" to not be empty');
            }
            for (var j = 0; j < value.length; j++) {
              var segment = encode(value[j], token);
              if (validate && !matches[i].test(segment)) {
                throw new TypeError('Expected all "' + token.name + '" to match "' + token.pattern + '", but got "' + segment + '"');
              }
              path2 += token.prefix + segment + token.suffix;
            }
            continue;
          }
          if (typeof value === "string" || typeof value === "number") {
            var segment = encode(String(value), token);
            if (validate && !matches[i].test(segment)) {
              throw new TypeError('Expected "' + token.name + '" to match "' + token.pattern + '", but got "' + segment + '"');
            }
            path2 += token.prefix + segment + token.suffix;
            continue;
          }
          if (optional)
            continue;
          var typeOfMessage = repeat ? "an array" : "a string";
          throw new TypeError('Expected "' + token.name + '" to be ' + typeOfMessage);
        }
        return path2;
      };
    }
    exports.tokensToFunction = tokensToFunction;
    function match(str, options) {
      var keys = [];
      var re = pathToRegexp(str, keys, options);
      return regexpToFunction(re, keys, options);
    }
    exports.match = match;
    function regexpToFunction(re, keys, options) {
      if (options === void 0) {
        options = {};
      }
      var _a = options.decode, decode = _a === void 0 ? function(x) {
        return x;
      } : _a;
      return function(pathname) {
        var m = re.exec(pathname);
        if (!m)
          return false;
        var path2 = m[0], index = m.index;
        var params = /* @__PURE__ */ Object.create(null);
        var _loop_1 = function(i2) {
          if (m[i2] === void 0)
            return "continue";
          var key = keys[i2 - 1];
          if (key.modifier === "*" || key.modifier === "+") {
            params[key.name] = m[i2].split(key.prefix + key.suffix).map(function(value) {
              return decode(value, key);
            });
          } else {
            params[key.name] = decode(m[i2], key);
          }
        };
        for (var i = 1; i < m.length; i++) {
          _loop_1(i);
        }
        return { path: path2, index, params };
      };
    }
    exports.regexpToFunction = regexpToFunction;
    function escapeString(str) {
      return str.replace(/([.+*?=^!:${}()[\]|/\\])/g, "\\$1");
    }
    function flags(options) {
      return options && options.sensitive ? "" : "i";
    }
    function regexpToRegexp(path2, keys) {
      if (!keys)
        return path2;
      var groups = path2.source.match(/\((?!\?)/g);
      if (groups) {
        for (var i = 0; i < groups.length; i++) {
          keys.push({
            name: i,
            prefix: "",
            suffix: "",
            modifier: "",
            pattern: ""
          });
        }
      }
      return path2;
    }
    function arrayToRegexp(paths, keys, options) {
      var parts = paths.map(function(path2) {
        return pathToRegexp(path2, keys, options).source;
      });
      return new RegExp("(?:" + parts.join("|") + ")", flags(options));
    }
    function stringToRegexp(path2, keys, options) {
      return tokensToRegexp(parse(path2, options), keys, options);
    }
    function tokensToRegexp(tokens, keys, options) {
      if (options === void 0) {
        options = {};
      }
      var _a = options.strict, strict = _a === void 0 ? false : _a, _b = options.start, start = _b === void 0 ? true : _b, _c = options.end, end = _c === void 0 ? true : _c, _d = options.encode, encode = _d === void 0 ? function(x) {
        return x;
      } : _d;
      var endsWith = "[" + escapeString(options.endsWith || "") + "]|$";
      var delimiter = "[" + escapeString(options.delimiter || "/#?") + "]";
      var route = start ? "^" : "";
      for (var _i = 0, tokens_1 = tokens; _i < tokens_1.length; _i++) {
        var token = tokens_1[_i];
        if (typeof token === "string") {
          route += escapeString(encode(token));
        } else {
          var prefix = escapeString(encode(token.prefix));
          var suffix = escapeString(encode(token.suffix));
          if (token.pattern) {
            if (keys)
              keys.push(token);
            if (prefix || suffix) {
              if (token.modifier === "+" || token.modifier === "*") {
                var mod = token.modifier === "*" ? "?" : "";
                route += "(?:" + prefix + "((?:" + token.pattern + ")(?:" + suffix + prefix + "(?:" + token.pattern + "))*)" + suffix + ")" + mod;
              } else {
                route += "(?:" + prefix + "(" + token.pattern + ")" + suffix + ")" + token.modifier;
              }
            } else {
              route += "(" + token.pattern + ")" + token.modifier;
            }
          } else {
            route += "(?:" + prefix + suffix + ")" + token.modifier;
          }
        }
      }
      if (end) {
        if (!strict)
          route += delimiter + "?";
        route += !options.endsWith ? "$" : "(?=" + endsWith + ")";
      } else {
        var endToken = tokens[tokens.length - 1];
        var isEndDelimited = typeof endToken === "string" ? delimiter.indexOf(endToken[endToken.length - 1]) > -1 : (
          // tslint:disable-next-line
          endToken === void 0
        );
        if (!strict) {
          route += "(?:" + delimiter + "(?=" + endsWith + "))?";
        }
        if (!isEndDelimited) {
          route += "(?=" + delimiter + "|" + endsWith + ")";
        }
      }
      return new RegExp(route, flags(options));
    }
    exports.tokensToRegexp = tokensToRegexp;
    function pathToRegexp(path2, keys, options) {
      if (path2 instanceof RegExp)
        return regexpToRegexp(path2, keys);
      if (Array.isArray(path2))
        return arrayToRegexp(path2, keys, options);
      return stringToRegexp(path2, keys, options);
    }
    exports.pathToRegexp = pathToRegexp;
  }
});

// ../../node_modules/.pnpm/path-to-regexp@6.3.0/node_modules/path-to-regexp/dist/index.js
var require_dist2 = __commonJS({
  "../../node_modules/.pnpm/path-to-regexp@6.3.0/node_modules/path-to-regexp/dist/index.js"(exports) {
    "use strict";
    Object.defineProperty(exports, "__esModule", { value: true });
    exports.pathToRegexp = exports.tokensToRegexp = exports.regexpToFunction = exports.match = exports.tokensToFunction = exports.compile = exports.parse = void 0;
    function lexer(str) {
      var tokens = [];
      var i = 0;
      while (i < str.length) {
        var char = str[i];
        if (char === "*" || char === "+" || char === "?") {
          tokens.push({ type: "MODIFIER", index: i, value: str[i++] });
          continue;
        }
        if (char === "\\") {
          tokens.push({ type: "ESCAPED_CHAR", index: i++, value: str[i++] });
          continue;
        }
        if (char === "{") {
          tokens.push({ type: "OPEN", index: i, value: str[i++] });
          continue;
        }
        if (char === "}") {
          tokens.push({ type: "CLOSE", index: i, value: str[i++] });
          continue;
        }
        if (char === ":") {
          var name = "";
          var j = i + 1;
          while (j < str.length) {
            var code = str.charCodeAt(j);
            if (
              // `0-9`
              code >= 48 && code <= 57 || // `A-Z`
              code >= 65 && code <= 90 || // `a-z`
              code >= 97 && code <= 122 || // `_`
              code === 95
            ) {
              name += str[j++];
              continue;
            }
            break;
          }
          if (!name)
            throw new TypeError("Missing parameter name at ".concat(i));
          tokens.push({ type: "NAME", index: i, value: name });
          i = j;
          continue;
        }
        if (char === "(") {
          var count = 1;
          var pattern = "";
          var j = i + 1;
          if (str[j] === "?") {
            throw new TypeError('Pattern cannot start with "?" at '.concat(j));
          }
          while (j < str.length) {
            if (str[j] === "\\") {
              pattern += str[j++] + str[j++];
              continue;
            }
            if (str[j] === ")") {
              count--;
              if (count === 0) {
                j++;
                break;
              }
            } else if (str[j] === "(") {
              count++;
              if (str[j + 1] !== "?") {
                throw new TypeError("Capturing groups are not allowed at ".concat(j));
              }
            }
            pattern += str[j++];
          }
          if (count)
            throw new TypeError("Unbalanced pattern at ".concat(i));
          if (!pattern)
            throw new TypeError("Missing pattern at ".concat(i));
          tokens.push({ type: "PATTERN", index: i, value: pattern });
          i = j;
          continue;
        }
        tokens.push({ type: "CHAR", index: i, value: str[i++] });
      }
      tokens.push({ type: "END", index: i, value: "" });
      return tokens;
    }
    function parse(str, options) {
      if (options === void 0) {
        options = {};
      }
      var tokens = lexer(str);
      var _a = options.prefixes, prefixes = _a === void 0 ? "./" : _a, _b = options.delimiter, delimiter = _b === void 0 ? "/#?" : _b;
      var result = [];
      var key = 0;
      var i = 0;
      var path2 = "";
      var tryConsume = function(type) {
        if (i < tokens.length && tokens[i].type === type)
          return tokens[i++].value;
      };
      var mustConsume = function(type) {
        var value2 = tryConsume(type);
        if (value2 !== void 0)
          return value2;
        var _a2 = tokens[i], nextType = _a2.type, index = _a2.index;
        throw new TypeError("Unexpected ".concat(nextType, " at ").concat(index, ", expected ").concat(type));
      };
      var consumeText = function() {
        var result2 = "";
        var value2;
        while (value2 = tryConsume("CHAR") || tryConsume("ESCAPED_CHAR")) {
          result2 += value2;
        }
        return result2;
      };
      var isSafe = function(value2) {
        for (var _i = 0, delimiter_1 = delimiter; _i < delimiter_1.length; _i++) {
          var char2 = delimiter_1[_i];
          if (value2.indexOf(char2) > -1)
            return true;
        }
        return false;
      };
      var safePattern = function(prefix2) {
        var prev = result[result.length - 1];
        var prevText = prefix2 || (prev && typeof prev === "string" ? prev : "");
        if (prev && !prevText) {
          throw new TypeError('Must have text between two parameters, missing text after "'.concat(prev.name, '"'));
        }
        if (!prevText || isSafe(prevText))
          return "[^".concat(escapeString(delimiter), "]+?");
        return "(?:(?!".concat(escapeString(prevText), ")[^").concat(escapeString(delimiter), "])+?");
      };
      while (i < tokens.length) {
        var char = tryConsume("CHAR");
        var name = tryConsume("NAME");
        var pattern = tryConsume("PATTERN");
        if (name || pattern) {
          var prefix = char || "";
          if (prefixes.indexOf(prefix) === -1) {
            path2 += prefix;
            prefix = "";
          }
          if (path2) {
            result.push(path2);
            path2 = "";
          }
          result.push({
            name: name || key++,
            prefix,
            suffix: "",
            pattern: pattern || safePattern(prefix),
            modifier: tryConsume("MODIFIER") || ""
          });
          continue;
        }
        var value = char || tryConsume("ESCAPED_CHAR");
        if (value) {
          path2 += value;
          continue;
        }
        if (path2) {
          result.push(path2);
          path2 = "";
        }
        var open = tryConsume("OPEN");
        if (open) {
          var prefix = consumeText();
          var name_1 = tryConsume("NAME") || "";
          var pattern_1 = tryConsume("PATTERN") || "";
          var suffix = consumeText();
          mustConsume("CLOSE");
          result.push({
            name: name_1 || (pattern_1 ? key++ : ""),
            pattern: name_1 && !pattern_1 ? safePattern(prefix) : pattern_1,
            prefix,
            suffix,
            modifier: tryConsume("MODIFIER") || ""
          });
          continue;
        }
        mustConsume("END");
      }
      return result;
    }
    exports.parse = parse;
    function compile(str, options) {
      return tokensToFunction(parse(str, options), options);
    }
    exports.compile = compile;
    function tokensToFunction(tokens, options) {
      if (options === void 0) {
        options = {};
      }
      var reFlags = flags(options);
      var _a = options.encode, encode = _a === void 0 ? function(x) {
        return x;
      } : _a, _b = options.validate, validate = _b === void 0 ? true : _b;
      var matches = tokens.map(function(token) {
        if (typeof token === "object") {
          return new RegExp("^(?:".concat(token.pattern, ")$"), reFlags);
        }
      });
      return function(data) {
        var path2 = "";
        for (var i = 0; i < tokens.length; i++) {
          var token = tokens[i];
          if (typeof token === "string") {
            path2 += token;
            continue;
          }
          var value = data ? data[token.name] : void 0;
          var optional = token.modifier === "?" || token.modifier === "*";
          var repeat = token.modifier === "*" || token.modifier === "+";
          if (Array.isArray(value)) {
            if (!repeat) {
              throw new TypeError('Expected "'.concat(token.name, '" to not repeat, but got an array'));
            }
            if (value.length === 0) {
              if (optional)
                continue;
              throw new TypeError('Expected "'.concat(token.name, '" to not be empty'));
            }
            for (var j = 0; j < value.length; j++) {
              var segment = encode(value[j], token);
              if (validate && !matches[i].test(segment)) {
                throw new TypeError('Expected all "'.concat(token.name, '" to match "').concat(token.pattern, '", but got "').concat(segment, '"'));
              }
              path2 += token.prefix + segment + token.suffix;
            }
            continue;
          }
          if (typeof value === "string" || typeof value === "number") {
            var segment = encode(String(value), token);
            if (validate && !matches[i].test(segment)) {
              throw new TypeError('Expected "'.concat(token.name, '" to match "').concat(token.pattern, '", but got "').concat(segment, '"'));
            }
            path2 += token.prefix + segment + token.suffix;
            continue;
          }
          if (optional)
            continue;
          var typeOfMessage = repeat ? "an array" : "a string";
          throw new TypeError('Expected "'.concat(token.name, '" to be ').concat(typeOfMessage));
        }
        return path2;
      };
    }
    exports.tokensToFunction = tokensToFunction;
    function match(str, options) {
      var keys = [];
      var re = pathToRegexp(str, keys, options);
      return regexpToFunction(re, keys, options);
    }
    exports.match = match;
    function regexpToFunction(re, keys, options) {
      if (options === void 0) {
        options = {};
      }
      var _a = options.decode, decode = _a === void 0 ? function(x) {
        return x;
      } : _a;
      return function(pathname) {
        var m = re.exec(pathname);
        if (!m)
          return false;
        var path2 = m[0], index = m.index;
        var params = /* @__PURE__ */ Object.create(null);
        var _loop_1 = function(i2) {
          if (m[i2] === void 0)
            return "continue";
          var key = keys[i2 - 1];
          if (key.modifier === "*" || key.modifier === "+") {
            params[key.name] = m[i2].split(key.prefix + key.suffix).map(function(value) {
              return decode(value, key);
            });
          } else {
            params[key.name] = decode(m[i2], key);
          }
        };
        for (var i = 1; i < m.length; i++) {
          _loop_1(i);
        }
        return { path: path2, index, params };
      };
    }
    exports.regexpToFunction = regexpToFunction;
    function escapeString(str) {
      return str.replace(/([.+*?=^!:${}()[\]|/\\])/g, "\\$1");
    }
    function flags(options) {
      return options && options.sensitive ? "" : "i";
    }
    function regexpToRegexp(path2, keys) {
      if (!keys)
        return path2;
      var groupsRegex = /\((?:\?<(.*?)>)?(?!\?)/g;
      var index = 0;
      var execResult = groupsRegex.exec(path2.source);
      while (execResult) {
        keys.push({
          // Use parenthesized substring match if available, index otherwise
          name: execResult[1] || index++,
          prefix: "",
          suffix: "",
          modifier: "",
          pattern: ""
        });
        execResult = groupsRegex.exec(path2.source);
      }
      return path2;
    }
    function arrayToRegexp(paths, keys, options) {
      var parts = paths.map(function(path2) {
        return pathToRegexp(path2, keys, options).source;
      });
      return new RegExp("(?:".concat(parts.join("|"), ")"), flags(options));
    }
    function stringToRegexp(path2, keys, options) {
      return tokensToRegexp(parse(path2, options), keys, options);
    }
    function tokensToRegexp(tokens, keys, options) {
      if (options === void 0) {
        options = {};
      }
      var _a = options.strict, strict = _a === void 0 ? false : _a, _b = options.start, start = _b === void 0 ? true : _b, _c = options.end, end = _c === void 0 ? true : _c, _d = options.encode, encode = _d === void 0 ? function(x) {
        return x;
      } : _d, _e = options.delimiter, delimiter = _e === void 0 ? "/#?" : _e, _f = options.endsWith, endsWith = _f === void 0 ? "" : _f;
      var endsWithRe = "[".concat(escapeString(endsWith), "]|$");
      var delimiterRe = "[".concat(escapeString(delimiter), "]");
      var route = start ? "^" : "";
      for (var _i = 0, tokens_1 = tokens; _i < tokens_1.length; _i++) {
        var token = tokens_1[_i];
        if (typeof token === "string") {
          route += escapeString(encode(token));
        } else {
          var prefix = escapeString(encode(token.prefix));
          var suffix = escapeString(encode(token.suffix));
          if (token.pattern) {
            if (keys)
              keys.push(token);
            if (prefix || suffix) {
              if (token.modifier === "+" || token.modifier === "*") {
                var mod = token.modifier === "*" ? "?" : "";
                route += "(?:".concat(prefix, "((?:").concat(token.pattern, ")(?:").concat(suffix).concat(prefix, "(?:").concat(token.pattern, "))*)").concat(suffix, ")").concat(mod);
              } else {
                route += "(?:".concat(prefix, "(").concat(token.pattern, ")").concat(suffix, ")").concat(token.modifier);
              }
            } else {
              if (token.modifier === "+" || token.modifier === "*") {
                throw new TypeError('Can not repeat "'.concat(token.name, '" without a prefix and suffix'));
              }
              route += "(".concat(token.pattern, ")").concat(token.modifier);
            }
          } else {
            route += "(?:".concat(prefix).concat(suffix, ")").concat(token.modifier);
          }
        }
      }
      if (end) {
        if (!strict)
          route += "".concat(delimiterRe, "?");
        route += !options.endsWith ? "$" : "(?=".concat(endsWithRe, ")");
      } else {
        var endToken = tokens[tokens.length - 1];
        var isEndDelimited = typeof endToken === "string" ? delimiterRe.indexOf(endToken[endToken.length - 1]) > -1 : endToken === void 0;
        if (!strict) {
          route += "(?:".concat(delimiterRe, "(?=").concat(endsWithRe, "))?");
        }
        if (!isEndDelimited) {
          route += "(?=".concat(delimiterRe, "|").concat(endsWithRe, ")");
        }
      }
      return new RegExp(route, flags(options));
    }
    exports.tokensToRegexp = tokensToRegexp;
    function pathToRegexp(path2, keys, options) {
      if (path2 instanceof RegExp)
        return regexpToRegexp(path2, keys);
      if (Array.isArray(path2))
        return arrayToRegexp(path2, keys, options);
      return stringToRegexp(path2, keys, options);
    }
    exports.pathToRegexp = pathToRegexp;
  }
});

// ../routing-utils/dist/superstatic.js
var require_superstatic = __commonJS({
  "../routing-utils/dist/superstatic.js"(exports, module2) {
    "use strict";
    var __defProp2 = Object.defineProperty;
    var __getOwnPropDesc2 = Object.getOwnPropertyDescriptor;
    var __getOwnPropNames2 = Object.getOwnPropertyNames;
    var __hasOwnProp2 = Object.prototype.hasOwnProperty;
    var __export2 = (target, all) => {
      for (var name in all)
        __defProp2(target, name, { get: all[name], enumerable: true });
    };
    var __copyProps2 = (to, from, except, desc) => {
      if (from && typeof from === "object" || typeof from === "function") {
        for (let key of __getOwnPropNames2(from))
          if (!__hasOwnProp2.call(to, key) && key !== except)
            __defProp2(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc2(from, key)) || desc.enumerable });
      }
      return to;
    };
    var __toCommonJS2 = (mod) => __copyProps2(__defProp2({}, "__esModule", { value: true }), mod);
    var superstatic_exports = {};
    __export2(superstatic_exports, {
      collectHasSegments: () => collectHasSegments,
      convertCleanUrls: () => convertCleanUrls,
      convertHeaders: () => convertHeaders,
      convertRedirects: () => convertRedirects,
      convertRewrites: () => convertRewrites,
      convertTrailingSlash: () => convertTrailingSlash,
      getCleanUrls: () => getCleanUrls2,
      pathToRegexp: () => pathToRegexp,
      sourceToRegex: () => sourceToRegex2
    });
    module2.exports = __toCommonJS2(superstatic_exports);
    var import_url = require("url");
    var import_path_to_regexp = require_dist();
    var import_path_to_regexp_updated = require_dist2();
    function cloneKeys(keys) {
      if (typeof keys === "undefined") {
        return void 0;
      }
      return keys.slice(0);
    }
    function compareKeys(left, right) {
      const leftSerialized = typeof left === "undefined" ? "undefined" : left.toString();
      const rightSerialized = typeof right === "undefined" ? "undefined" : right.toString();
      return leftSerialized === rightSerialized;
    }
    function pathToRegexp(callerId, path2, keys, options) {
      const newKeys = cloneKeys(keys);
      const currentRegExp = (0, import_path_to_regexp.pathToRegexp)(path2, keys, options);
      try {
        const currentKeys = keys;
        const newRegExp = (0, import_path_to_regexp_updated.pathToRegexp)(path2, newKeys, options);
        const isDiffRegExp = currentRegExp.toString() !== newRegExp.toString();
        if (process.env.FORCE_PATH_TO_REGEXP_LOG || isDiffRegExp) {
          const message = JSON.stringify({
            path: path2,
            currentRegExp: currentRegExp.toString(),
            newRegExp: newRegExp.toString()
          });
          console.error(`[vc] PATH TO REGEXP PATH DIFF @ #${callerId}: ${message}`);
        }
        const isDiffKeys = !compareKeys(keys, newKeys);
        if (process.env.FORCE_PATH_TO_REGEXP_LOG || isDiffKeys) {
          const message = JSON.stringify({
            isDiffKeys,
            currentKeys,
            newKeys
          });
          console.error(`[vc] PATH TO REGEXP KEYS DIFF @ #${callerId}: ${message}`);
        }
      } catch (err) {
        const error = err;
        const message = JSON.stringify({
          path: path2,
          error: error.message
        });
        console.error(`[vc] PATH TO REGEXP ERROR @ #${callerId}: ${message}`);
      }
      return currentRegExp;
    }
    var UN_NAMED_SEGMENT = "__UN_NAMED_SEGMENT__";
    function getCleanUrls2(filePaths) {
      const htmlFiles = filePaths.map(toRoute).filter((f) => f.endsWith(".html")).map((f) => ({
        html: f,
        clean: f.slice(0, -5)
      }));
      return htmlFiles;
    }
    function convertCleanUrls(cleanUrls, trailingSlash, status = 308) {
      const routes = [];
      if (cleanUrls) {
        const loc = trailingSlash ? "/$1/" : "/$1";
        routes.push({
          src: "^/(?:(.+)/)?index(?:\\.html)?/?$",
          headers: { Location: loc },
          status
        });
        routes.push({
          src: "^/(.*)\\.html/?$",
          headers: { Location: loc },
          status
        });
      }
      return routes;
    }
    function convertRedirects(redirects, defaultStatus = 308) {
      return redirects.map((r) => {
        const { src, segments } = sourceToRegex2(r.source);
        const hasSegments = collectHasSegments(r.has);
        normalizeHasKeys(r.has);
        normalizeHasKeys(r.missing);
        try {
          const loc = replaceSegments(segments, hasSegments, r.destination, true);
          let status;
          if (typeof r.permanent === "boolean") {
            status = r.permanent ? 308 : 307;
          } else if (r.statusCode) {
            status = r.statusCode;
          } else {
            status = defaultStatus;
          }
          const route = {
            src,
            headers: { Location: loc },
            status
          };
          if (typeof r.env !== "undefined") {
            route.env = r.env;
          }
          if (r.has) {
            route.has = r.has;
          }
          if (r.missing) {
            route.missing = r.missing;
          }
          return route;
        } catch (e) {
          throw new Error(`Failed to parse redirect: ${JSON.stringify(r)}`);
        }
      });
    }
    function convertRewrites(rewrites, internalParamNames) {
      return rewrites.map((r) => {
        const { src, segments } = sourceToRegex2(r.source);
        const hasSegments = collectHasSegments(r.has);
        normalizeHasKeys(r.has);
        normalizeHasKeys(r.missing);
        try {
          const dest = replaceSegments(
            segments,
            hasSegments,
            r.destination,
            false,
            internalParamNames
          );
          const route = { src, dest, check: true };
          if (typeof r.env !== "undefined") {
            route.env = r.env;
          }
          if (r.has) {
            route.has = r.has;
          }
          if (r.missing) {
            route.missing = r.missing;
          }
          if (r.statusCode) {
            route.status = r.statusCode;
          }
          return route;
        } catch (e) {
          throw new Error(`Failed to parse rewrite: ${JSON.stringify(r)}`);
        }
      });
    }
    function convertHeaders(headers) {
      return headers.map((h) => {
        const obj = {};
        const { src, segments } = sourceToRegex2(h.source);
        const hasSegments = collectHasSegments(h.has);
        normalizeHasKeys(h.has);
        normalizeHasKeys(h.missing);
        const namedSegments = segments.filter((name) => name !== UN_NAMED_SEGMENT);
        const indexes = {};
        segments.forEach((name, index) => {
          indexes[name] = toSegmentDest(index);
        });
        hasSegments.forEach((name) => {
          indexes[name] = "$" + name;
        });
        h.headers.forEach(({ key, value }) => {
          if (namedSegments.length > 0 || hasSegments.length > 0) {
            if (key.includes(":")) {
              key = safelyCompile(key, indexes);
            }
            if (value.includes(":")) {
              value = safelyCompile(value, indexes);
            }
          }
          obj[key] = value;
        });
        const route = {
          src,
          headers: obj,
          continue: true
        };
        if (h.has) {
          route.has = h.has;
        }
        if (h.missing) {
          route.missing = h.missing;
        }
        return route;
      });
    }
    function convertTrailingSlash(enable, status = 308) {
      const routes = [];
      if (enable) {
        routes.push({
          src: "^/\\.well-known(?:/.*)?$"
        });
        routes.push({
          src: "^/((?:[^/]+/)*[^/\\.]+)$",
          headers: { Location: "/$1/" },
          status
        });
        routes.push({
          src: "^/((?:[^/]+/)*[^/]+\\.\\w+)/$",
          headers: { Location: "/$1" },
          status
        });
      } else {
        routes.push({
          src: "^/(.*)\\/$",
          headers: { Location: "/$1" },
          status
        });
      }
      return routes;
    }
    function sourceToRegex2(source) {
      const keys = [];
      const r = pathToRegexp("632", source, keys, {
        strict: true,
        sensitive: true,
        delimiter: "/"
      });
      const segments = keys.map((k) => k.name).map((name) => {
        if (typeof name !== "string") {
          return UN_NAMED_SEGMENT;
        }
        return name;
      });
      return { src: r.source, segments };
    }
    var namedGroupsRegex = /\(\?<([a-zA-Z][a-zA-Z0-9_]*)>/g;
    var normalizeHasKeys = (hasItems = []) => {
      for (const hasItem of hasItems) {
        if ("key" in hasItem && hasItem.type === "header") {
          hasItem.key = hasItem.key.toLowerCase();
        }
      }
      return hasItems;
    };
    function getStringValueForRegex(value) {
      if (typeof value === "string") {
        return value;
      }
      if (value && typeof value === "object" && value !== null) {
        if ("re" in value && typeof value.re === "string") {
          return value.re;
        }
      }
      return null;
    }
    function collectHasSegments(has) {
      const hasSegments = /* @__PURE__ */ new Set();
      for (const hasItem of has || []) {
        if (!hasItem.value && "key" in hasItem) {
          hasSegments.add(hasItem.key);
        }
        const stringValue = getStringValueForRegex(hasItem.value);
        if (stringValue) {
          for (const match of stringValue.matchAll(namedGroupsRegex)) {
            if (match[1]) {
              hasSegments.add(match[1]);
            }
          }
          if (hasItem.type === "host") {
            hasSegments.add("host");
          }
        }
      }
      return [...hasSegments];
    }
    var escapeSegment = (str, segmentName) => str.replace(new RegExp(`:${segmentName}`, "g"), `__ESC_COLON_${segmentName}`);
    var unescapeSegments = (str) => str.replace(/__ESC_COLON_/gi, ":");
    function replaceSegments(segments, hasItemSegments, destination, isRedirect, internalParamNames) {
      const namedSegments = segments.filter((name) => name !== UN_NAMED_SEGMENT);
      const canNeedReplacing = destination.includes(":") && namedSegments.length > 0 || hasItemSegments.length > 0 || !isRedirect;
      if (!canNeedReplacing) {
        return destination;
      }
      let escapedDestination = destination;
      const indexes = {};
      segments.forEach((name, index) => {
        indexes[name] = toSegmentDest(index);
        escapedDestination = escapeSegment(escapedDestination, name);
      });
      hasItemSegments.forEach((name) => {
        indexes[name] = "$" + name;
        escapedDestination = escapeSegment(escapedDestination, name);
      });
      const parsedDestination = (0, import_url.parse)(escapedDestination, true);
      delete parsedDestination.href;
      delete parsedDestination.path;
      delete parsedDestination.search;
      delete parsedDestination.host;
      let { pathname, hash, query, hostname, ...rest } = parsedDestination;
      pathname = unescapeSegments(pathname || "");
      hash = unescapeSegments(hash || "");
      hostname = unescapeSegments(hostname || "");
      let destParams = /* @__PURE__ */ new Set();
      const pathnameKeys = [];
      const hashKeys = [];
      const hostnameKeys = [];
      try {
        pathToRegexp("528", pathname, pathnameKeys);
        pathToRegexp("834", hash || "", hashKeys);
        pathToRegexp("712", hostname || "", hostnameKeys);
      } catch (_) {
      }
      destParams = new Set(
        [...pathnameKeys, ...hashKeys, ...hostnameKeys].map((key) => key.name).filter((val) => typeof val === "string")
      );
      pathname = safelyCompile(pathname, indexes, true);
      hash = hash ? safelyCompile(hash, indexes, true) : null;
      hostname = hostname ? safelyCompile(hostname, indexes, true) : null;
      for (const [key, strOrArray] of Object.entries(query)) {
        if (Array.isArray(strOrArray)) {
          query[key] = strOrArray.map(
            (str) => safelyCompile(unescapeSegments(str), indexes, true)
          );
        } else {
          query[key] = safelyCompile(
            unescapeSegments(strOrArray),
            indexes,
            true
          );
        }
      }
      const paramKeys = Object.keys(indexes);
      const needsQueryUpdating = (
        // we do not consider an internal param since it is added automatically
        !isRedirect && !paramKeys.some(
          (param) => !(internalParamNames && internalParamNames.includes(param)) && destParams.has(param)
        )
      );
      if (needsQueryUpdating) {
        for (const param of paramKeys) {
          if (!(param in query) && param !== UN_NAMED_SEGMENT) {
            query[param] = indexes[param];
          }
        }
      }
      destination = (0, import_url.format)({
        ...rest,
        hostname,
        pathname,
        query,
        hash
      });
      return destination.replace(/%24/g, "$");
    }
    function safelyCompile(value, indexes, attemptDirectCompile) {
      if (!value) {
        return value;
      }
      if (attemptDirectCompile) {
        try {
          return (0, import_path_to_regexp.compile)(value, { validate: false })(indexes);
        } catch (e) {
        }
      }
      for (const key of Object.keys(indexes)) {
        if (value.includes(`:${key}`)) {
          value = value.replace(
            new RegExp(`:${key}\\*`, "g"),
            `:${key}--ESCAPED_PARAM_ASTERISK`
          ).replace(
            new RegExp(`:${key}\\?`, "g"),
            `:${key}--ESCAPED_PARAM_QUESTION`
          ).replace(new RegExp(`:${key}\\+`, "g"), `:${key}--ESCAPED_PARAM_PLUS`).replace(
            new RegExp(`:${key}(?!\\w)`, "g"),
            `--ESCAPED_PARAM_COLON${key}`
          );
        }
      }
      value = value.replace(/(:|\*|\?|\+|\(|\)|\{|\})/g, "\\$1").replace(/--ESCAPED_PARAM_PLUS/g, "+").replace(/--ESCAPED_PARAM_COLON/g, ":").replace(/--ESCAPED_PARAM_QUESTION/g, "?").replace(/--ESCAPED_PARAM_ASTERISK/g, "*");
      return (0, import_path_to_regexp.compile)(`/${value}`, { validate: false })(indexes).slice(1);
    }
    function toSegmentDest(index) {
      const i = index + 1;
      return "$" + i.toString();
    }
    function toRoute(filePath) {
      return filePath.startsWith("/") ? filePath : "/" + filePath;
    }
  }
});

// ../routing-utils/dist/append.js
var require_append = __commonJS({
  "../routing-utils/dist/append.js"(exports, module2) {
    "use strict";
    var __defProp2 = Object.defineProperty;
    var __getOwnPropDesc2 = Object.getOwnPropertyDescriptor;
    var __getOwnPropNames2 = Object.getOwnPropertyNames;
    var __hasOwnProp2 = Object.prototype.hasOwnProperty;
    var __export2 = (target, all) => {
      for (var name in all)
        __defProp2(target, name, { get: all[name], enumerable: true });
    };
    var __copyProps2 = (to, from, except, desc) => {
      if (from && typeof from === "object" || typeof from === "function") {
        for (let key of __getOwnPropNames2(from))
          if (!__hasOwnProp2.call(to, key) && key !== except)
            __defProp2(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc2(from, key)) || desc.enumerable });
      }
      return to;
    };
    var __toCommonJS2 = (mod) => __copyProps2(__defProp2({}, "__esModule", { value: true }), mod);
    var append_exports = {};
    __export2(append_exports, {
      appendRoutesToPhase: () => appendRoutesToPhase2
    });
    module2.exports = __toCommonJS2(append_exports);
    var import_index = require_dist3();
    function appendRoutesToPhase2({
      routes: prevRoutes,
      newRoutes,
      phase
    }) {
      const routes = prevRoutes ? [...prevRoutes] : [];
      if (newRoutes === null || newRoutes.length === 0) {
        return routes;
      }
      let isInPhase = false;
      let insertIndex = -1;
      routes.forEach((r, i) => {
        if ((0, import_index.isHandler)(r)) {
          if (r.handle === phase) {
            isInPhase = true;
          } else if (isInPhase) {
            insertIndex = i;
            isInPhase = false;
          }
        }
      });
      if (isInPhase) {
        routes.push(...newRoutes);
      } else if (phase === null) {
        const lastPhase = routes.findIndex((r) => (0, import_index.isHandler)(r) && r.handle);
        if (lastPhase === -1) {
          routes.push(...newRoutes);
        } else {
          routes.splice(lastPhase, 0, ...newRoutes);
        }
      } else if (insertIndex > -1) {
        routes.splice(insertIndex, 0, ...newRoutes);
      } else {
        routes.push({ handle: phase });
        routes.push(...newRoutes);
      }
      return routes;
    }
  }
});

// ../routing-utils/dist/merge.js
var require_merge = __commonJS({
  "../routing-utils/dist/merge.js"(exports, module2) {
    "use strict";
    var __defProp2 = Object.defineProperty;
    var __getOwnPropDesc2 = Object.getOwnPropertyDescriptor;
    var __getOwnPropNames2 = Object.getOwnPropertyNames;
    var __hasOwnProp2 = Object.prototype.hasOwnProperty;
    var __export2 = (target, all) => {
      for (var name in all)
        __defProp2(target, name, { get: all[name], enumerable: true });
    };
    var __copyProps2 = (to, from, except, desc) => {
      if (from && typeof from === "object" || typeof from === "function") {
        for (let key of __getOwnPropNames2(from))
          if (!__hasOwnProp2.call(to, key) && key !== except)
            __defProp2(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc2(from, key)) || desc.enumerable });
      }
      return to;
    };
    var __toCommonJS2 = (mod) => __copyProps2(__defProp2({}, "__esModule", { value: true }), mod);
    var merge_exports = {};
    __export2(merge_exports, {
      mergeRoutes: () => mergeRoutes2
    });
    module2.exports = __toCommonJS2(merge_exports);
    var import_index = require_dist3();
    function getBuilderRoutesMapping(builds) {
      const builderRoutes = {};
      for (const { entrypoint, routes, use } of builds) {
        if (routes) {
          if (!builderRoutes[entrypoint]) {
            builderRoutes[entrypoint] = {};
          }
          builderRoutes[entrypoint][use] = routes;
        }
      }
      return builderRoutes;
    }
    function getCheckAndContinue(routes) {
      const checks = [];
      const continues = [];
      const others = [];
      for (const route of routes) {
        if ((0, import_index.isHandler)(route)) {
          throw new Error(
            `Unexpected route found in getCheckAndContinue(): ${JSON.stringify(
              route
            )}`
          );
        } else if (route.check && !route.override) {
          checks.push(route);
        } else if (route.continue && !route.override) {
          continues.push(route);
        } else {
          others.push(route);
        }
      }
      return { checks, continues, others };
    }
    function mergeRoutes2({ userRoutes, builds }) {
      const userHandleMap = /* @__PURE__ */ new Map();
      let userPrevHandle = null;
      (userRoutes || []).forEach((route) => {
        if ((0, import_index.isHandler)(route)) {
          userPrevHandle = route.handle;
        } else {
          const routes = userHandleMap.get(userPrevHandle);
          if (!routes) {
            userHandleMap.set(userPrevHandle, [route]);
          } else {
            routes.push(route);
          }
        }
      });
      const builderHandleMap = /* @__PURE__ */ new Map();
      const builderRoutes = getBuilderRoutesMapping(builds);
      const sortedPaths = Object.keys(builderRoutes).sort();
      sortedPaths.forEach((path2) => {
        const br = builderRoutes[path2];
        const sortedBuilders = Object.keys(br).sort();
        sortedBuilders.forEach((use) => {
          let builderPrevHandle = null;
          br[use].forEach((route) => {
            if ((0, import_index.isHandler)(route)) {
              builderPrevHandle = route.handle;
            } else {
              const routes = builderHandleMap.get(builderPrevHandle);
              if (!routes) {
                builderHandleMap.set(builderPrevHandle, [route]);
              } else {
                routes.push(route);
              }
            }
          });
        });
      });
      const outputRoutes = [];
      const uniqueHandleValues = /* @__PURE__ */ new Set([
        null,
        ...userHandleMap.keys(),
        ...builderHandleMap.keys()
      ]);
      for (const handle of uniqueHandleValues) {
        const userRoutes2 = userHandleMap.get(handle) || [];
        const builderRoutes2 = builderHandleMap.get(handle) || [];
        const builderSorted = getCheckAndContinue(builderRoutes2);
        if (handle !== null && (userRoutes2.length > 0 || builderRoutes2.length > 0)) {
          outputRoutes.push({ handle });
        }
        outputRoutes.push(...builderSorted.continues);
        outputRoutes.push(...userRoutes2);
        outputRoutes.push(...builderSorted.checks);
        outputRoutes.push(...builderSorted.others);
      }
      return outputRoutes;
    }
  }
});

// ../routing-utils/dist/schemas.js
var require_schemas = __commonJS({
  "../routing-utils/dist/schemas.js"(exports, module2) {
    "use strict";
    var __defProp2 = Object.defineProperty;
    var __getOwnPropDesc2 = Object.getOwnPropertyDescriptor;
    var __getOwnPropNames2 = Object.getOwnPropertyNames;
    var __hasOwnProp2 = Object.prototype.hasOwnProperty;
    var __export2 = (target, all) => {
      for (var name in all)
        __defProp2(target, name, { get: all[name], enumerable: true });
    };
    var __copyProps2 = (to, from, except, desc) => {
      if (from && typeof from === "object" || typeof from === "function") {
        for (let key of __getOwnPropNames2(from))
          if (!__hasOwnProp2.call(to, key) && key !== except)
            __defProp2(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc2(from, key)) || desc.enumerable });
      }
      return to;
    };
    var __toCommonJS2 = (mod) => __copyProps2(__defProp2({}, "__esModule", { value: true }), mod);
    var schemas_exports = {};
    __export2(schemas_exports, {
      bulkRedirectsSchema: () => bulkRedirectsSchema,
      cleanUrlsSchema: () => cleanUrlsSchema,
      hasSchema: () => hasSchema,
      headersSchema: () => headersSchema,
      redirectsSchema: () => redirectsSchema,
      rewritesSchema: () => rewritesSchema,
      routesSchema: () => routesSchema,
      trailingSlashSchema: () => trailingSlashSchema
    });
    module2.exports = __toCommonJS2(schemas_exports);
    var mitigateSchema = {
      description: "Mitigation action to take on a route",
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: {
          description: "The mitigation action to take",
          type: "string",
          enum: ["challenge", "deny"]
        }
      }
    };
    var matchableValueSchema = {
      description: "A value to match against. Can be a string (regex) or a condition operation object",
      anyOf: [
        {
          description: "A regular expression used to match thev value. Named groups can be used in the destination.",
          type: "string",
          maxLength: 4096
        },
        {
          description: "A condition operation object",
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: {
            eq: {
              description: "Equal to",
              anyOf: [
                {
                  type: "string",
                  maxLength: 4096
                },
                {
                  type: "number"
                }
              ]
            },
            neq: {
              description: "Not equal",
              type: "string",
              maxLength: 4096
            },
            inc: {
              description: "In array",
              type: "array",
              items: {
                type: "string",
                maxLength: 4096
              }
            },
            ninc: {
              description: "Not in array",
              type: "array",
              items: {
                type: "string",
                maxLength: 4096
              }
            },
            pre: {
              description: "Starts with",
              type: "string",
              maxLength: 4096
            },
            suf: {
              description: "Ends with",
              type: "string",
              maxLength: 4096
            },
            re: {
              description: "Regex",
              type: "string",
              maxLength: 4096
            },
            gt: {
              description: "Greater than",
              type: "number"
            },
            gte: {
              description: "Greater than or equal to",
              type: "number"
            },
            lt: {
              description: "Less than",
              type: "number"
            },
            lte: {
              description: "Less than or equal to",
              type: "number"
            }
          }
        }
      ]
    };
    var hasSchema = {
      description: "An array of requirements that are needed to match",
      type: "array",
      maxItems: 16,
      items: {
        anyOf: [
          {
            type: "object",
            additionalProperties: false,
            required: ["type", "value"],
            properties: {
              type: {
                description: "The type of request element to check",
                type: "string",
                enum: ["host"]
              },
              value: matchableValueSchema
            }
          },
          {
            type: "object",
            additionalProperties: false,
            required: ["type", "key"],
            properties: {
              type: {
                description: "The type of request element to check",
                type: "string",
                enum: ["header", "cookie", "query"]
              },
              key: {
                description: "The name of the element contained in the particular type",
                type: "string",
                maxLength: 4096
              },
              value: matchableValueSchema
            }
          }
        ]
      }
    };
    var transformsSchema = {
      description: "A list of transform rules to adjust the query parameters of a request or HTTP headers of request or response",
      type: "array",
      minItems: 1,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["type", "op", "target"],
        properties: {
          type: {
            description: "The scope of the transform to apply",
            type: "string",
            enum: ["request.headers", "request.query", "response.headers"]
          },
          op: {
            description: "The operation to perform on the target",
            type: "string",
            enum: ["append", "set", "delete"]
          },
          target: {
            description: "The target of the transform",
            type: "object",
            required: ["key"],
            properties: {
              // re is not supported for transforms. Once supported, replace target.key with matchableValueSchema
              key: {
                description: "A value to match against. Can be a string or a condition operation object (without regex support)",
                anyOf: [
                  {
                    description: "A valid header name (letters, numbers, hyphens, underscores)",
                    type: "string",
                    maxLength: 4096
                  },
                  {
                    description: "A condition operation object",
                    type: "object",
                    additionalProperties: false,
                    minProperties: 1,
                    properties: {
                      eq: {
                        description: "Equal to",
                        anyOf: [
                          {
                            type: "string",
                            maxLength: 4096
                          },
                          {
                            type: "number"
                          }
                        ]
                      },
                      neq: {
                        description: "Not equal",
                        type: "string",
                        maxLength: 4096
                      },
                      inc: {
                        description: "In array",
                        type: "array",
                        items: {
                          type: "string",
                          maxLength: 4096
                        }
                      },
                      ninc: {
                        description: "Not in array",
                        type: "array",
                        items: {
                          type: "string",
                          maxLength: 4096
                        }
                      },
                      pre: {
                        description: "Starts with",
                        type: "string",
                        maxLength: 4096
                      },
                      suf: {
                        description: "Ends with",
                        type: "string",
                        maxLength: 4096
                      },
                      gt: {
                        description: "Greater than",
                        type: "number"
                      },
                      gte: {
                        description: "Greater than or equal to",
                        type: "number"
                      },
                      lt: {
                        description: "Less than",
                        type: "number"
                      },
                      lte: {
                        description: "Less than or equal to",
                        type: "number"
                      }
                    }
                  }
                ]
              }
            }
          },
          args: {
            description: "The arguments to the operation",
            anyOf: [
              {
                type: "string",
                maxLength: 4096
              },
              {
                type: "array",
                minItems: 1,
                items: {
                  type: "string",
                  maxLength: 4096
                }
              }
            ]
          },
          env: {
            description: "An array of environment variable names that should be replaced at runtime in the args value",
            type: "array",
            minItems: 1,
            maxItems: 64,
            items: {
              type: "string",
              maxLength: 256
            }
          }
        },
        allOf: [
          {
            if: {
              properties: {
                op: {
                  enum: ["append", "set"]
                }
              }
            },
            then: {
              required: ["args"]
            }
          },
          {
            if: {
              allOf: [
                {
                  properties: {
                    type: {
                      enum: ["request.headers", "response.headers"]
                    }
                  }
                },
                {
                  properties: {
                    op: {
                      enum: ["set", "append"]
                    }
                  }
                }
              ]
            },
            then: {
              properties: {
                target: {
                  properties: {
                    key: {
                      if: {
                        type: "string"
                      },
                      then: {
                        pattern: "^[a-zA-Z0-9_-]+$"
                      }
                    }
                  }
                },
                args: {
                  anyOf: [
                    {
                      type: "string",
                      pattern: "^[a-zA-Z0-9_ :;.,\"'?!(){}\\[\\]@<>=+*#$&`|~\\^%/-]+$"
                    },
                    {
                      type: "array",
                      items: {
                        type: "string",
                        pattern: "^[a-zA-Z0-9_ :;.,\"'?!(){}\\[\\]@<>=+*#$&`|~\\^%/-]+$"
                      }
                    }
                  ]
                }
              }
            }
          }
        ]
      }
    };
    var routesSchema = {
      type: "array",
      deprecated: true,
      description: "A list of routes objects used to rewrite paths to point towards other internal or external paths",
      example: [{ dest: "https://docs.example.com", src: "/docs" }],
      items: {
        anyOf: [
          {
            type: "object",
            required: ["src"],
            additionalProperties: false,
            properties: {
              src: {
                type: "string",
                maxLength: 4096
              },
              dest: {
                type: "string",
                maxLength: 4096
              },
              headers: {
                type: "object",
                additionalProperties: false,
                minProperties: 1,
                maxProperties: 100,
                patternProperties: {
                  "^.{1,256}$": {
                    type: "string",
                    maxLength: 32768
                  }
                }
              },
              methods: {
                type: "array",
                maxItems: 10,
                items: {
                  type: "string",
                  maxLength: 32
                }
              },
              caseSensitive: {
                type: "boolean"
              },
              important: {
                type: "boolean"
              },
              user: {
                type: "boolean"
              },
              continue: {
                type: "boolean"
              },
              override: {
                type: "boolean"
              },
              check: {
                type: "boolean"
              },
              isInternal: {
                type: "boolean"
              },
              status: {
                type: "integer",
                minimum: 100,
                maximum: 999
              },
              locale: {
                type: "object",
                additionalProperties: false,
                minProperties: 1,
                properties: {
                  redirect: {
                    type: "object",
                    additionalProperties: false,
                    minProperties: 1,
                    maxProperties: 100,
                    patternProperties: {
                      "^.{1,256}$": {
                        type: "string",
                        maxLength: 4096
                      }
                    }
                  },
                  value: {
                    type: "string",
                    maxLength: 4096
                  },
                  path: {
                    type: "string",
                    maxLength: 4096
                  },
                  cookie: {
                    type: "string",
                    maxLength: 4096
                  },
                  default: {
                    type: "string",
                    maxLength: 4096
                  }
                }
              },
              middleware: { type: "number" },
              middlewarePath: { type: "string" },
              middlewareRawSrc: {
                type: "array",
                items: {
                  type: "string"
                }
              },
              has: hasSchema,
              missing: hasSchema,
              mitigate: mitigateSchema,
              transforms: transformsSchema,
              env: {
                description: "An array of environment variable names that should be replaced at runtime in the destination or headers",
                type: "array",
                minItems: 1,
                maxItems: 64,
                items: {
                  type: "string",
                  maxLength: 256
                }
              },
              respectOriginCacheControl: {
                description: "When set to true (default), external rewrites will respect the Cache-Control header from the origin. When false, caching is disabled for this rewrite.",
                type: "boolean"
              }
            }
          },
          {
            type: "object",
            required: ["handle"],
            additionalProperties: false,
            properties: {
              handle: {
                type: "string",
                maxLength: 32,
                enum: ["error", "filesystem", "hit", "miss", "resource", "rewrite"]
              }
            }
          }
        ]
      }
    };
    var rewritesSchema = {
      type: "array",
      maxItems: 2048,
      description: "A list of rewrite definitions.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["source", "destination"],
        properties: {
          source: {
            description: "A pattern that matches each incoming pathname (excluding querystring).",
            type: "string",
            maxLength: 4096
          },
          destination: {
            description: "An absolute pathname to an existing resource or an external URL.",
            type: "string",
            maxLength: 4096
          },
          has: hasSchema,
          missing: hasSchema,
          statusCode: {
            description: "An optional integer to override the status code of the response.",
            type: "integer",
            minimum: 100,
            maximum: 999
          },
          env: {
            description: "An array of environment variable names that should be replaced at runtime in the destination",
            type: "array",
            minItems: 1,
            maxItems: 64,
            items: {
              type: "string",
              maxLength: 256
            }
          },
          respectOriginCacheControl: {
            description: "When set to true (default), external rewrites will respect the Cache-Control header from the origin. When false, caching is disabled for this rewrite.",
            type: "boolean"
          }
        }
      }
    };
    var redirectsSchema = {
      title: "Redirects",
      type: "array",
      maxItems: 2048,
      description: "A list of redirect definitions.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["source", "destination"],
        properties: {
          source: {
            description: "A pattern that matches each incoming pathname (excluding querystring).",
            type: "string",
            maxLength: 4096
          },
          destination: {
            description: "A location destination defined as an absolute pathname or external URL.",
            type: "string",
            maxLength: 4096
          },
          permanent: {
            description: "A boolean to toggle between permanent and temporary redirect. When `true`, the status code is `308`. When `false` the status code is `307`.",
            type: "boolean"
          },
          statusCode: {
            description: "An optional integer to define the status code of the redirect.",
            private: true,
            type: "integer",
            minimum: 100,
            maximum: 999
          },
          has: hasSchema,
          missing: hasSchema,
          env: {
            description: "An array of environment variable names that should be replaced at runtime in the destination",
            type: "array",
            minItems: 1,
            maxItems: 64,
            items: {
              type: "string",
              maxLength: 256
            }
          }
        }
      }
    };
    var headersSchema = {
      type: "array",
      maxItems: 2048,
      description: "A list of header definitions.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["source", "headers"],
        properties: {
          source: {
            description: "A pattern that matches each incoming pathname (excluding querystring)",
            type: "string",
            maxLength: 4096
          },
          headers: {
            description: "An array of key/value pairs representing each response header.",
            type: "array",
            maxItems: 1024,
            items: {
              type: "object",
              additionalProperties: false,
              required: ["key", "value"],
              properties: {
                key: {
                  type: "string",
                  maxLength: 4096
                },
                value: {
                  type: "string",
                  maxLength: 32768
                }
              }
            }
          },
          has: hasSchema,
          missing: hasSchema
        }
      }
    };
    var cleanUrlsSchema = {
      description: "When set to `true`, all HTML files and Serverless Functions will have their extension removed. When visiting a path that ends with the extension, a 308 response will redirect the client to the extensionless path.",
      type: "boolean"
    };
    var trailingSlashSchema = {
      description: "When `false`, visiting a path that ends with a forward slash will respond with a `308` status code and redirect to the path without the trailing slash.",
      type: "boolean"
    };
    var bulkRedirectsSchema = {
      type: "array",
      description: "A list of bulk redirect definitions.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["source", "destination"],
        properties: {
          source: {
            description: "The exact URL path or pattern to match.",
            type: "string",
            maxLength: 2048
          },
          destination: {
            description: "The target URL path where traffic should be redirected.",
            type: "string",
            maxLength: 2048
          },
          permanent: {
            description: "A boolean to toggle between permanent and temporary redirect. When `true`, the status code is `308`. When `false` the status code is `307`.",
            type: "boolean"
          },
          statusCode: {
            description: "An optional integer to define the status code of the redirect.",
            type: "integer",
            enum: [301, 302, 307, 308]
          },
          sensitive: {
            description: "A boolean to toggle between case-sensitive and case-insensitive redirect. When `true`, the redirect is case-sensitive. When `false` the redirect is case-insensitive.",
            type: "boolean"
          },
          query: {
            description: "Whether the query string should be preserved by the redirect. The default is `false`.",
            type: "boolean"
          }
        }
      }
    };
  }
});

// ../routing-utils/dist/types.js
var require_types = __commonJS({
  "../routing-utils/dist/types.js"(exports, module2) {
    "use strict";
    var __defProp2 = Object.defineProperty;
    var __getOwnPropDesc2 = Object.getOwnPropertyDescriptor;
    var __getOwnPropNames2 = Object.getOwnPropertyNames;
    var __hasOwnProp2 = Object.prototype.hasOwnProperty;
    var __copyProps2 = (to, from, except, desc) => {
      if (from && typeof from === "object" || typeof from === "function") {
        for (let key of __getOwnPropNames2(from))
          if (!__hasOwnProp2.call(to, key) && key !== except)
            __defProp2(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc2(from, key)) || desc.enumerable });
      }
      return to;
    };
    var __toCommonJS2 = (mod) => __copyProps2(__defProp2({}, "__esModule", { value: true }), mod);
    var types_exports = {};
    module2.exports = __toCommonJS2(types_exports);
  }
});

// ../routing-utils/dist/index.js
var require_dist3 = __commonJS({
  "../routing-utils/dist/index.js"(exports, module2) {
    "use strict";
    var __defProp2 = Object.defineProperty;
    var __getOwnPropDesc2 = Object.getOwnPropertyDescriptor;
    var __getOwnPropNames2 = Object.getOwnPropertyNames;
    var __hasOwnProp2 = Object.prototype.hasOwnProperty;
    var __export2 = (target, all) => {
      for (var name in all)
        __defProp2(target, name, { get: all[name], enumerable: true });
    };
    var __copyProps2 = (to, from, except, desc) => {
      if (from && typeof from === "object" || typeof from === "function") {
        for (let key of __getOwnPropNames2(from))
          if (!__hasOwnProp2.call(to, key) && key !== except)
            __defProp2(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc2(from, key)) || desc.enumerable });
      }
      return to;
    };
    var __reExport = (target, mod, secondTarget) => (__copyProps2(target, mod, "default"), secondTarget && __copyProps2(secondTarget, mod, "default"));
    var __toCommonJS2 = (mod) => __copyProps2(__defProp2({}, "__esModule", { value: true }), mod);
    var src_exports2 = {};
    __export2(src_exports2, {
      appendRoutesToPhase: () => import_append.appendRoutesToPhase,
      getCleanUrls: () => import_superstatic2.getCleanUrls,
      getTransformedRoutes: () => getTransformedRoutes2,
      isHandler: () => isHandler,
      isValidHandleValue: () => isValidHandleValue,
      mergeRoutes: () => import_merge.mergeRoutes,
      normalizeRoutes: () => normalizeRoutes,
      sourceToRegex: () => import_superstatic2.sourceToRegex
    });
    module2.exports = __toCommonJS2(src_exports2);
    var import_url = require("url");
    var import_superstatic = require_superstatic();
    var import_append = require_append();
    var import_merge = require_merge();
    __reExport(src_exports2, require_schemas(), module2.exports);
    var import_superstatic2 = require_superstatic();
    __reExport(src_exports2, require_types(), module2.exports);
    var VALID_HANDLE_VALUES = [
      "filesystem",
      "hit",
      "miss",
      "rewrite",
      "error",
      "resource"
    ];
    var validHandleValues = new Set(VALID_HANDLE_VALUES);
    function isHandler(route) {
      return typeof route.handle !== "undefined";
    }
    function isValidHandleValue(handle) {
      return validHandleValues.has(handle);
    }
    function normalizeRoutes(inputRoutes) {
      if (!inputRoutes || inputRoutes.length === 0) {
        return { routes: inputRoutes, error: null };
      }
      const routes = [];
      const handling = [];
      const errors = [];
      inputRoutes.forEach((r, i) => {
        const route = { ...r };
        routes.push(route);
        const keys = Object.keys(route);
        if (isHandler(route)) {
          const { handle } = route;
          if (keys.length !== 1) {
            const unknownProp = keys.find((prop) => prop !== "handle");
            errors.push(
              `Route at index ${i} has unknown property \`${unknownProp}\`.`
            );
          } else if (!isValidHandleValue(handle)) {
            errors.push(
              `Route at index ${i} has unknown handle value \`handle: ${handle}\`.`
            );
          } else if (handling.includes(handle)) {
            errors.push(
              `Route at index ${i} is a duplicate. Please use one \`handle: ${handle}\` at most.`
            );
          } else {
            handling.push(handle);
          }
        } else if (route.src) {
          if (!route.src.startsWith("^")) {
            route.src = `^${route.src}`;
          }
          if (!route.src.endsWith("$")) {
            route.src = `${route.src}$`;
          }
          route.src = route.src.replace(/\\\//g, "/");
          const regError = checkRegexSyntax("Route", i, route.src);
          if (regError) {
            errors.push(regError);
          }
          const handleValue = handling[handling.length - 1];
          if (handleValue === "hit") {
            if (route.dest) {
              errors.push(
                `Route at index ${i} cannot define \`dest\` after \`handle: hit\`.`
              );
            }
            if (route.status) {
              errors.push(
                `Route at index ${i} cannot define \`status\` after \`handle: hit\`.`
              );
            }
            if (!route.continue) {
              errors.push(
                `Route at index ${i} must define \`continue: true\` after \`handle: hit\`.`
              );
            }
          } else if (handleValue === "miss") {
            if (route.dest && !route.check) {
              errors.push(
                `Route at index ${i} must define \`check: true\` after \`handle: miss\`.`
              );
            } else if (!route.dest && !route.continue) {
              errors.push(
                `Route at index ${i} must define \`continue: true\` after \`handle: miss\`.`
              );
            }
          }
        } else {
          errors.push(
            `Route at index ${i} must define either \`handle\` or \`src\` property.`
          );
        }
      });
      const error = errors.length > 0 ? createError(
        "invalid_route",
        errors,
        "https://vercel.link/routes-json",
        "Learn More"
      ) : null;
      return { routes, error };
    }
    function checkRegexSyntax(type, index, src) {
      try {
        new RegExp(src);
      } catch (err) {
        const prop = type === "Route" ? "src" : "source";
        return `${type} at index ${index} has invalid \`${prop}\` regular expression "${src}".`;
      }
      return null;
    }
    function checkPatternSyntax(type, index, {
      source,
      destination,
      has
    }) {
      let sourceSegments = /* @__PURE__ */ new Set();
      const destinationSegments = /* @__PURE__ */ new Set();
      try {
        sourceSegments = new Set((0, import_superstatic.sourceToRegex)(source).segments);
      } catch (err) {
        return {
          message: `${type} at index ${index} has invalid \`source\` pattern "${source}".`,
          link: "https://vercel.link/invalid-route-source-pattern"
        };
      }
      if (destination) {
        try {
          const { hostname, pathname, query } = (0, import_url.parse)(destination, true);
          (0, import_superstatic.sourceToRegex)(hostname || "").segments.forEach(
            (name) => destinationSegments.add(name)
          );
          (0, import_superstatic.sourceToRegex)(pathname || "").segments.forEach(
            (name) => destinationSegments.add(name)
          );
          for (const strOrArray of Object.values(query)) {
            const value = Array.isArray(strOrArray) ? strOrArray[0] : strOrArray;
            (0, import_superstatic.sourceToRegex)(value || "").segments.forEach(
              (name) => destinationSegments.add(name)
            );
          }
        } catch (err) {
        }
        const hasSegments = (0, import_superstatic.collectHasSegments)(has);
        for (const segment of destinationSegments) {
          if (!sourceSegments.has(segment) && !hasSegments.includes(segment)) {
            return {
              message: `${type} at index ${index} has segment ":${segment}" in \`destination\` property but not in \`source\` or \`has\` property.`,
              link: "https://vercel.link/invalid-route-destination-segment"
            };
          }
        }
      }
      return null;
    }
    function checkRedirect(r, index) {
      if (typeof r.permanent !== "undefined" && typeof r.statusCode !== "undefined") {
        return `Redirect at index ${index} cannot define both \`permanent\` and \`statusCode\` properties.`;
      }
      return null;
    }
    function createError(code, allErrors, link, action) {
      const errors = Array.isArray(allErrors) ? allErrors : [allErrors];
      const message = errors[0];
      const error = {
        name: "RouteApiError",
        code,
        message,
        link,
        action,
        errors
      };
      return error;
    }
    function notEmpty(value) {
      return value !== null && value !== void 0;
    }
    function getTransformedRoutes2(vercelConfig) {
      const { cleanUrls, rewrites, redirects, headers, trailingSlash } = vercelConfig;
      let { routes = null } = vercelConfig;
      if (routes) {
        const hasNewProperties = typeof cleanUrls !== "undefined" || typeof trailingSlash !== "undefined" || typeof redirects !== "undefined" || typeof headers !== "undefined" || typeof rewrites !== "undefined";
        if (hasNewProperties) {
          const error = createError(
            "invalid_mixed_routes",
            "If `rewrites`, `redirects`, `headers`, `cleanUrls` or `trailingSlash` are used, then `routes` cannot be present.",
            "https://vercel.link/mix-routing-props",
            "Learn More"
          );
          return { routes, error };
        }
        return normalizeRoutes(routes);
      }
      if (typeof cleanUrls !== "undefined") {
        const normalized = normalizeRoutes(
          (0, import_superstatic.convertCleanUrls)(cleanUrls, trailingSlash)
        );
        if (normalized.error) {
          normalized.error.code = "invalid_clean_urls";
          return { routes, error: normalized.error };
        }
        routes = routes || [];
        routes.push(...normalized.routes || []);
      }
      if (typeof trailingSlash !== "undefined") {
        const normalized = normalizeRoutes((0, import_superstatic.convertTrailingSlash)(trailingSlash));
        if (normalized.error) {
          normalized.error.code = "invalid_trailing_slash";
          return { routes, error: normalized.error };
        }
        routes = routes || [];
        routes.push(...normalized.routes || []);
      }
      if (typeof redirects !== "undefined") {
        const code = "invalid_redirect";
        const regexErrorMessage = redirects.map((r, i) => checkRegexSyntax("Redirect", i, r.source)).find(notEmpty);
        if (regexErrorMessage) {
          return {
            routes,
            error: createError(
              "invalid_redirect",
              regexErrorMessage,
              "https://vercel.link/invalid-route-source-pattern",
              "Learn More"
            )
          };
        }
        const patternError = redirects.map((r, i) => checkPatternSyntax("Redirect", i, r)).find(notEmpty);
        if (patternError) {
          return {
            routes,
            error: createError(
              code,
              patternError.message,
              patternError.link,
              "Learn More"
            )
          };
        }
        const redirectErrorMessage = redirects.map(checkRedirect).find(notEmpty);
        if (redirectErrorMessage) {
          return {
            routes,
            error: createError(
              code,
              redirectErrorMessage,
              "https://vercel.link/redirects-json",
              "Learn More"
            )
          };
        }
        const normalized = normalizeRoutes((0, import_superstatic.convertRedirects)(redirects));
        if (normalized.error) {
          normalized.error.code = code;
          return { routes, error: normalized.error };
        }
        routes = routes || [];
        routes.push(...normalized.routes || []);
      }
      if (typeof headers !== "undefined") {
        const code = "invalid_header";
        const regexErrorMessage = headers.map((r, i) => checkRegexSyntax("Header", i, r.source)).find(notEmpty);
        if (regexErrorMessage) {
          return {
            routes,
            error: createError(
              code,
              regexErrorMessage,
              "https://vercel.link/invalid-route-source-pattern",
              "Learn More"
            )
          };
        }
        const patternError = headers.map((r, i) => checkPatternSyntax("Header", i, r)).find(notEmpty);
        if (patternError) {
          return {
            routes,
            error: createError(
              code,
              patternError.message,
              patternError.link,
              "Learn More"
            )
          };
        }
        const normalized = normalizeRoutes((0, import_superstatic.convertHeaders)(headers));
        if (normalized.error) {
          normalized.error.code = code;
          return { routes, error: normalized.error };
        }
        routes = routes || [];
        routes.push(...normalized.routes || []);
      }
      if (typeof rewrites !== "undefined") {
        const code = "invalid_rewrite";
        const regexErrorMessage = rewrites.map((r, i) => checkRegexSyntax("Rewrite", i, r.source)).find(notEmpty);
        if (regexErrorMessage) {
          return {
            routes,
            error: createError(
              code,
              regexErrorMessage,
              "https://vercel.link/invalid-route-source-pattern",
              "Learn More"
            )
          };
        }
        const patternError = rewrites.map((r, i) => checkPatternSyntax("Rewrite", i, r)).find(notEmpty);
        if (patternError) {
          return {
            routes,
            error: createError(
              code,
              patternError.message,
              patternError.link,
              "Learn More"
            )
          };
        }
        const normalized = normalizeRoutes((0, import_superstatic.convertRewrites)(rewrites));
        if (normalized.error) {
          normalized.error.code = code;
          return { routes, error: normalized.error };
        }
        routes = routes || [];
        routes.push({ handle: "filesystem" });
        routes.push(...normalized.routes || []);
      }
      return { routes, error: null };
    }
  }
});

// src/index.ts
var src_exports = {};
__export(src_exports, {
  generateVercelBuildOutputAPI3Output: () => generateVercelBuildOutputAPI3Output
});
module.exports = __toCommonJS(src_exports);
var import_routing_utils = __toESM(require_dist3());
var import_fs_extra4 = require("fs-extra");

// src/schemas.ts
var import_typebox = require("@sinclair/typebox");
var import_custom = require("@sinclair/typebox/custom");
var import_compiler = require("@sinclair/typebox/compiler");
import_custom.Custom.Set("StringEnum", (schema, value) => {
  return schema.enum.includes(value);
});
function StringEnum(values) {
  return import_typebox.Type.Unsafe({
    [import_typebox.Kind]: "StringEnum",
    type: "string",
    enum: values
  });
}
var GatsbyPageSchema = import_typebox.Type.Object({
  mode: StringEnum(["SSG", "DSG", "SSR"]),
  path: import_typebox.Type.String()
});
var GatsbyFunctionSchema = import_typebox.Type.Object({
  functionRoute: import_typebox.Type.String(),
  originalAbsoluteFilePath: import_typebox.Type.String()
});
import_compiler.TypeCompiler.Compile(GatsbyFunctionSchema);
var GatsbyRedirectSchema = import_typebox.Type.Object({
  fromPath: import_typebox.Type.String(),
  toPath: import_typebox.Type.String(),
  isPermanent: import_typebox.Type.Optional(import_typebox.Type.Boolean()),
  statusCode: import_typebox.Type.Optional(import_typebox.Type.Number())
});
var GatsbyConfigSchema = import_typebox.Type.Object({
  trailingSlash: import_typebox.Type.Optional(
    StringEnum(["always", "never", "ignore", "legacy"])
  ),
  pathPrefix: import_typebox.Type.Optional(import_typebox.Type.String())
});
var GatsbyStateSchema = import_typebox.Type.Object({
  pages: import_typebox.Type.Array(import_typebox.Type.Tuple([import_typebox.Type.String(), GatsbyPageSchema])),
  redirects: import_typebox.Type.Array(GatsbyRedirectSchema),
  functions: import_typebox.Type.Array(GatsbyFunctionSchema),
  config: GatsbyConfigSchema
});
var validateGatsbyState = import_compiler.TypeCompiler.Compile(GatsbyStateSchema);

// src/helpers/functions.ts
var import_path3 = require("path");
var import_fs_extra3 = require("fs-extra");

// src/utils/symlink.ts
var import_path = __toESM(require("path"));
var import_fs_extra = require("fs-extra");
var removeTrailingSlash = (str) => str.replace(/\/$/, "");
var createSymlink = async (pathName, destName) => {
  const functionName = removeTrailingSlash(pathName).split(import_path.sep).pop();
  const dirPath = removeTrailingSlash(
    (0, import_path.join)(".vercel", "output", "functions", (0, import_path.normalize)((0, import_path.join)(pathName, "..")))
  );
  await (0, import_fs_extra.ensureDir)(dirPath);
  (0, import_fs_extra.symlinkSync)(
    import_path.default.relative(dirPath, (0, import_path.join)(".vercel", "output", "functions", destName)),
    import_path.default.join(dirPath, `${functionName}.func`)
  );
};

// src/handlers/build.ts
var import_path2 = require("path");
var import_build_utils = require("@vercel/build-utils");
var import_esbuild = require("esbuild");
var import_fs_extra2 = require("fs-extra");
var writeHandler = async ({
  outDir,
  handlerFile,
  prefix = ""
}) => {
  const { major } = await (0, import_build_utils.getNodeVersion)(process.cwd());
  try {
    await (0, import_esbuild.build)({
      entryPoints: [handlerFile],
      loader: { ".ts": "ts" },
      outfile: (0, import_path2.join)(outDir, "index.js"),
      format: "cjs",
      target: `node${major}`,
      platform: "node",
      bundle: true,
      minify: true,
      // prevents renaming edge cases from causing failures like:
      // https://github.com/node-fetch/node-fetch/issues/784
      keepNames: true,
      define: {
        "process.env.NODE_ENV": "'production'",
        vercel_pathPrefix: JSON.stringify(prefix)
      }
    });
  } catch (e) {
    console.error("Failed to build lambda handler", e.message);
  }
};
var writeVCConfig = async ({
  functionDir,
  handler = "index.js"
}) => {
  const { runtime } = await (0, import_build_utils.getNodeVersion)(process.cwd());
  const config = {
    runtime,
    handler,
    launcherType: "Nodejs",
    shouldAddHelpers: true
  };
  const configPath = (0, import_path2.join)(functionDir, ".vc-config.json");
  await (0, import_fs_extra2.writeJson)(configPath, config);
};
var writePrerenderConfig = (outputPath, group) => {
  const config = {
    group,
    expiration: 600
    // 10 minutes TODO: make this configurable?
  };
  (0, import_fs_extra2.ensureFileSync)(outputPath);
  return (0, import_fs_extra2.writeFileSync)(outputPath, JSON.stringify(config));
};
async function copyFunctionLibs({
  functionDir
}) {
  await Promise.allSettled(
    [
      {
        src: (0, import_path2.join)(".cache", "query-engine"),
        dest: (0, import_path2.join)(functionDir, ".cache", "query-engine")
      },
      {
        src: (0, import_path2.join)(".cache", "page-ssr"),
        dest: (0, import_path2.join)(functionDir, ".cache", "page-ssr")
      },
      {
        src: (0, import_path2.join)(".cache", "data", "datastore"),
        dest: (0, import_path2.join)(functionDir, ".cache", "data", "datastore")
      },
      {
        src: (0, import_path2.join)(".cache", "caches"),
        dest: (0, import_path2.join)(functionDir, ".cache", "caches")
      }
    ].map(({ src, dest }) => (0, import_fs_extra2.copy)(src, dest))
  );
}
async function copyHTMLFiles({ functionDir }) {
  for (const htmlFile of ["404", "500"]) {
    if (await (0, import_fs_extra2.pathExists)((0, import_path2.join)("public", `${htmlFile}.html`))) {
      try {
        await (0, import_fs_extra2.copyFile)(
          (0, import_path2.join)("public", `${htmlFile}.html`),
          (0, import_path2.join)(functionDir, `${htmlFile}.html`)
        );
      } catch (e) {
        console.error("Failed to copy HTML files", e.message);
        process.exit(1);
      }
    }
  }
}

// src/helpers/functions.ts
async function createServerlessFunctions(ssrRoutes, prefix) {
  let functionName;
  let functionDir;
  const handlerFile = (0, import_path3.join)(__dirname, "../templates/ssr-handler.js");
  await Promise.all(
    ssrRoutes.map(async (page, index) => {
      let pathName = page.path;
      const ssrPath = (0, import_path3.join)(prefix ?? "", pathName, "index.html");
      if (index === 0) {
        functionName = `${ssrPath}.func`;
        functionDir = (0, import_path3.join)(".vercel/output/functions", functionName);
        await (0, import_fs_extra3.ensureDir)(functionDir);
        await Promise.all([
          writeHandler({ outDir: functionDir, handlerFile, prefix }),
          copyFunctionLibs({ functionDir }),
          copyHTMLFiles({ functionDir }),
          writeVCConfig({ functionDir })
        ]);
      } else {
        await createSymlink(ssrPath, functionName);
      }
      if (page.mode === "DSG") {
        writePrerenderConfig(
          (0, import_path3.join)(
            ".vercel",
            "output",
            "functions",
            `${ssrPath}.prerender-config.json`
          ),
          index + 1
        );
      }
      if (!pathName || pathName === "/") {
        pathName = "index";
      }
      const pageDataPath = (0, import_path3.join)(
        prefix ?? "",
        "page-data",
        pathName,
        "page-data.json"
      );
      await createSymlink(pageDataPath, functionName);
      if (page.mode === "DSG") {
        writePrerenderConfig(
          (0, import_path3.join)(
            ".vercel",
            "output",
            "functions",
            `${pageDataPath}.prerender-config.json`
          ),
          index + 1
        );
      }
    })
  );
}
async function createAPIRoutes(functions, prefix) {
  const apiDir = (0, import_path3.join)(".vercel", "output", "functions", "api", prefix ?? "");
  await (0, import_fs_extra3.ensureDir)(apiDir);
  await Promise.allSettled(
    functions.map(async (func) => {
      const apiRouteDir = `${apiDir}/${func.functionRoute}.func`;
      const handlerFile = func.originalAbsoluteFilePath;
      await (0, import_fs_extra3.ensureDir)(apiRouteDir);
      await Promise.all([
        writeHandler({ outDir: apiRouteDir, handlerFile }),
        writeVCConfig({ functionDir: apiRouteDir })
      ]);
    })
  );
}

// src/helpers/static.ts
var import_path4 = require("path");
var import_build_utils2 = require("@vercel/build-utils");
async function createStaticDir(prefix) {
  const publicDir = (0, import_path4.join)(process.cwd(), "public");
  const targetDir = (0, import_path4.join)(
    process.cwd(),
    ".vercel",
    "output",
    "static",
    prefix ?? ""
  );
  try {
    await (0, import_build_utils2.hardLinkDir)(publicDir, [targetDir]);
  } catch (err) {
    console.error(err);
    throw new Error(
      `Failed to hardlink (or copy) "public" dir files from "${publicDir}" to "${targetDir}".`
    );
  }
}

// src/index.ts
var import_path5 = require("path");
async function generateVercelBuildOutputAPI3Output({
  gatsbyStoreState
}) {
  const state = {
    pages: Array.from(gatsbyStoreState.pages.entries()),
    // must transform from a Map for validation
    redirects: gatsbyStoreState.redirects,
    functions: gatsbyStoreState.functions,
    config: gatsbyStoreState.config
  };
  if (validateGatsbyState.Check(state)) {
    console.log("\u25B2 Creating Vercel build output");
    const { pages, functions, config: gatsbyConfig } = state;
    const { pathPrefix = "" } = gatsbyConfig;
    const ssrRoutes = pages.map((p) => p[1]).filter((page) => page.mode === "SSR" || page.mode === "DSG");
    const ops = [];
    if (functions.length > 0) {
      ops.push(createAPIRoutes(functions, pathPrefix));
    }
    if (ssrRoutes.length > 0) {
      ops.push(createServerlessFunctions(ssrRoutes, pathPrefix));
    }
    await Promise.all(ops);
    await createStaticDir(pathPrefix);
    let trailingSlash = void 0;
    if (gatsbyConfig.trailingSlash === "always") {
      trailingSlash = true;
    } else if (gatsbyConfig.trailingSlash === "never") {
      trailingSlash = false;
    }
    const redirects = [];
    const rewrites = [];
    for (const {
      fromPath,
      toPath,
      isPermanent,
      statusCode
    } of state.redirects) {
      if (statusCode === 200) {
        rewrites.push({
          source: fromPath,
          destination: toPath
        });
      } else {
        redirects.push({
          source: fromPath,
          destination: toPath,
          permanent: isPermanent
        });
      }
    }
    const routes = (0, import_routing_utils.getTransformedRoutes)({
      trailingSlash,
      redirects,
      rewrites
    }).routes || [];
    routes.push({
      handle: "error"
    });
    if (pathPrefix) {
      routes.push({
        status: 404,
        src: "^(?!/api).*$",
        dest: (0, import_path5.join)(pathPrefix, "404.html")
      });
    }
    routes.push({
      status: 404,
      src: "^(?!/api).*$",
      dest: "404.html"
    });
    const config = {
      version: 3,
      routes: routes || void 0
    };
    await (0, import_fs_extra4.writeJson)(".vercel/output/config.json", config);
    console.log("Vercel output has been generated");
  } else {
    const errors = [...validateGatsbyState.Errors(state)];
    throw new Error(
      `Gatsby state validation failed:
${errors.map(
        (err) => `  - ${err.message}, got ${typeof err.value} (${JSON.stringify(
          err.value
        )}) at path "${err.path}"
`
      ).join(
        ""
      )}Please check your Gatsby configuration files, or file an issue at https://vercel.com/help#issues`
    );
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  generateVercelBuildOutputAPI3Output
});
