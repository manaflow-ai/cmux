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

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/constants.js
var require_constants = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/constants.js"(exports, module2) {
    var SEMVER_SPEC_VERSION = "2.0.0";
    var MAX_LENGTH = 256;
    var MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER || /* istanbul ignore next */
    9007199254740991;
    var MAX_SAFE_COMPONENT_LENGTH = 16;
    var RELEASE_TYPES = [
      "major",
      "premajor",
      "minor",
      "preminor",
      "patch",
      "prepatch",
      "prerelease"
    ];
    module2.exports = {
      MAX_LENGTH,
      MAX_SAFE_COMPONENT_LENGTH,
      MAX_SAFE_INTEGER,
      RELEASE_TYPES,
      SEMVER_SPEC_VERSION,
      FLAG_INCLUDE_PRERELEASE: 1,
      FLAG_LOOSE: 2
    };
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/debug.js
var require_debug = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/debug.js"(exports, module2) {
    var debug4 = typeof process === "object" && process.env && process.env.NODE_DEBUG && /\bsemver\b/i.test(process.env.NODE_DEBUG) ? (...args) => console.error("SEMVER", ...args) : () => {
    };
    module2.exports = debug4;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/re.js
var require_re = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/re.js"(exports, module2) {
    var { MAX_SAFE_COMPONENT_LENGTH } = require_constants();
    var debug4 = require_debug();
    exports = module2.exports = {};
    var re = exports.re = [];
    var safeRe = exports.safeRe = [];
    var src = exports.src = [];
    var t = exports.t = {};
    var R = 0;
    var createToken = (name, value, isGlobal) => {
      const safe = value.split("\\s*").join("\\s{0,1}").split("\\s+").join("\\s");
      const index = R++;
      debug4(name, index, value);
      t[name] = index;
      src[index] = value;
      re[index] = new RegExp(value, isGlobal ? "g" : void 0);
      safeRe[index] = new RegExp(safe, isGlobal ? "g" : void 0);
    };
    createToken("NUMERICIDENTIFIER", "0|[1-9]\\d*");
    createToken("NUMERICIDENTIFIERLOOSE", "[0-9]+");
    createToken("NONNUMERICIDENTIFIER", "\\d*[a-zA-Z-][a-zA-Z0-9-]*");
    createToken("MAINVERSION", `(${src[t.NUMERICIDENTIFIER]})\\.(${src[t.NUMERICIDENTIFIER]})\\.(${src[t.NUMERICIDENTIFIER]})`);
    createToken("MAINVERSIONLOOSE", `(${src[t.NUMERICIDENTIFIERLOOSE]})\\.(${src[t.NUMERICIDENTIFIERLOOSE]})\\.(${src[t.NUMERICIDENTIFIERLOOSE]})`);
    createToken("PRERELEASEIDENTIFIER", `(?:${src[t.NUMERICIDENTIFIER]}|${src[t.NONNUMERICIDENTIFIER]})`);
    createToken("PRERELEASEIDENTIFIERLOOSE", `(?:${src[t.NUMERICIDENTIFIERLOOSE]}|${src[t.NONNUMERICIDENTIFIER]})`);
    createToken("PRERELEASE", `(?:-(${src[t.PRERELEASEIDENTIFIER]}(?:\\.${src[t.PRERELEASEIDENTIFIER]})*))`);
    createToken("PRERELEASELOOSE", `(?:-?(${src[t.PRERELEASEIDENTIFIERLOOSE]}(?:\\.${src[t.PRERELEASEIDENTIFIERLOOSE]})*))`);
    createToken("BUILDIDENTIFIER", "[0-9A-Za-z-]+");
    createToken("BUILD", `(?:\\+(${src[t.BUILDIDENTIFIER]}(?:\\.${src[t.BUILDIDENTIFIER]})*))`);
    createToken("FULLPLAIN", `v?${src[t.MAINVERSION]}${src[t.PRERELEASE]}?${src[t.BUILD]}?`);
    createToken("FULL", `^${src[t.FULLPLAIN]}$`);
    createToken("LOOSEPLAIN", `[v=\\s]*${src[t.MAINVERSIONLOOSE]}${src[t.PRERELEASELOOSE]}?${src[t.BUILD]}?`);
    createToken("LOOSE", `^${src[t.LOOSEPLAIN]}$`);
    createToken("GTLT", "((?:<|>)?=?)");
    createToken("XRANGEIDENTIFIERLOOSE", `${src[t.NUMERICIDENTIFIERLOOSE]}|x|X|\\*`);
    createToken("XRANGEIDENTIFIER", `${src[t.NUMERICIDENTIFIER]}|x|X|\\*`);
    createToken("XRANGEPLAIN", `[v=\\s]*(${src[t.XRANGEIDENTIFIER]})(?:\\.(${src[t.XRANGEIDENTIFIER]})(?:\\.(${src[t.XRANGEIDENTIFIER]})(?:${src[t.PRERELEASE]})?${src[t.BUILD]}?)?)?`);
    createToken("XRANGEPLAINLOOSE", `[v=\\s]*(${src[t.XRANGEIDENTIFIERLOOSE]})(?:\\.(${src[t.XRANGEIDENTIFIERLOOSE]})(?:\\.(${src[t.XRANGEIDENTIFIERLOOSE]})(?:${src[t.PRERELEASELOOSE]})?${src[t.BUILD]}?)?)?`);
    createToken("XRANGE", `^${src[t.GTLT]}\\s*${src[t.XRANGEPLAIN]}$`);
    createToken("XRANGELOOSE", `^${src[t.GTLT]}\\s*${src[t.XRANGEPLAINLOOSE]}$`);
    createToken("COERCE", `${"(^|[^\\d])(\\d{1,"}${MAX_SAFE_COMPONENT_LENGTH}})(?:\\.(\\d{1,${MAX_SAFE_COMPONENT_LENGTH}}))?(?:\\.(\\d{1,${MAX_SAFE_COMPONENT_LENGTH}}))?(?:$|[^\\d])`);
    createToken("COERCERTL", src[t.COERCE], true);
    createToken("LONETILDE", "(?:~>?)");
    createToken("TILDETRIM", `(\\s*)${src[t.LONETILDE]}\\s+`, true);
    exports.tildeTrimReplace = "$1~";
    createToken("TILDE", `^${src[t.LONETILDE]}${src[t.XRANGEPLAIN]}$`);
    createToken("TILDELOOSE", `^${src[t.LONETILDE]}${src[t.XRANGEPLAINLOOSE]}$`);
    createToken("LONECARET", "(?:\\^)");
    createToken("CARETTRIM", `(\\s*)${src[t.LONECARET]}\\s+`, true);
    exports.caretTrimReplace = "$1^";
    createToken("CARET", `^${src[t.LONECARET]}${src[t.XRANGEPLAIN]}$`);
    createToken("CARETLOOSE", `^${src[t.LONECARET]}${src[t.XRANGEPLAINLOOSE]}$`);
    createToken("COMPARATORLOOSE", `^${src[t.GTLT]}\\s*(${src[t.LOOSEPLAIN]})$|^$`);
    createToken("COMPARATOR", `^${src[t.GTLT]}\\s*(${src[t.FULLPLAIN]})$|^$`);
    createToken("COMPARATORTRIM", `(\\s*)${src[t.GTLT]}\\s*(${src[t.LOOSEPLAIN]}|${src[t.XRANGEPLAIN]})`, true);
    exports.comparatorTrimReplace = "$1$2$3";
    createToken("HYPHENRANGE", `^\\s*(${src[t.XRANGEPLAIN]})\\s+-\\s+(${src[t.XRANGEPLAIN]})\\s*$`);
    createToken("HYPHENRANGELOOSE", `^\\s*(${src[t.XRANGEPLAINLOOSE]})\\s+-\\s+(${src[t.XRANGEPLAINLOOSE]})\\s*$`);
    createToken("STAR", "(<|>)?=?\\s*\\*");
    createToken("GTE0", "^\\s*>=\\s*0\\.0\\.0\\s*$");
    createToken("GTE0PRE", "^\\s*>=\\s*0\\.0\\.0-0\\s*$");
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/parse-options.js
var require_parse_options = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/parse-options.js"(exports, module2) {
    var looseOption = Object.freeze({ loose: true });
    var emptyOpts = Object.freeze({});
    var parseOptions = (options) => {
      if (!options) {
        return emptyOpts;
      }
      if (typeof options !== "object") {
        return looseOption;
      }
      return options;
    };
    module2.exports = parseOptions;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/identifiers.js
var require_identifiers = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/internal/identifiers.js"(exports, module2) {
    var numeric = /^[0-9]+$/;
    var compareIdentifiers = (a, b) => {
      const anum = numeric.test(a);
      const bnum = numeric.test(b);
      if (anum && bnum) {
        a = +a;
        b = +b;
      }
      return a === b ? 0 : anum && !bnum ? -1 : bnum && !anum ? 1 : a < b ? -1 : 1;
    };
    var rcompareIdentifiers = (a, b) => compareIdentifiers(b, a);
    module2.exports = {
      compareIdentifiers,
      rcompareIdentifiers
    };
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/classes/semver.js
var require_semver = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/classes/semver.js"(exports, module2) {
    var debug4 = require_debug();
    var { MAX_LENGTH, MAX_SAFE_INTEGER } = require_constants();
    var { safeRe: re, t } = require_re();
    var parseOptions = require_parse_options();
    var { compareIdentifiers } = require_identifiers();
    var SemVer = class _SemVer {
      constructor(version2, options) {
        options = parseOptions(options);
        if (version2 instanceof _SemVer) {
          if (version2.loose === !!options.loose && version2.includePrerelease === !!options.includePrerelease) {
            return version2;
          } else {
            version2 = version2.version;
          }
        } else if (typeof version2 !== "string") {
          throw new TypeError(`Invalid version. Must be a string. Got type "${typeof version2}".`);
        }
        if (version2.length > MAX_LENGTH) {
          throw new TypeError(
            `version is longer than ${MAX_LENGTH} characters`
          );
        }
        debug4("SemVer", version2, options);
        this.options = options;
        this.loose = !!options.loose;
        this.includePrerelease = !!options.includePrerelease;
        const m = version2.trim().match(options.loose ? re[t.LOOSE] : re[t.FULL]);
        if (!m) {
          throw new TypeError(`Invalid Version: ${version2}`);
        }
        this.raw = version2;
        this.major = +m[1];
        this.minor = +m[2];
        this.patch = +m[3];
        if (this.major > MAX_SAFE_INTEGER || this.major < 0) {
          throw new TypeError("Invalid major version");
        }
        if (this.minor > MAX_SAFE_INTEGER || this.minor < 0) {
          throw new TypeError("Invalid minor version");
        }
        if (this.patch > MAX_SAFE_INTEGER || this.patch < 0) {
          throw new TypeError("Invalid patch version");
        }
        if (!m[4]) {
          this.prerelease = [];
        } else {
          this.prerelease = m[4].split(".").map((id) => {
            if (/^[0-9]+$/.test(id)) {
              const num = +id;
              if (num >= 0 && num < MAX_SAFE_INTEGER) {
                return num;
              }
            }
            return id;
          });
        }
        this.build = m[5] ? m[5].split(".") : [];
        this.format();
      }
      format() {
        this.version = `${this.major}.${this.minor}.${this.patch}`;
        if (this.prerelease.length) {
          this.version += `-${this.prerelease.join(".")}`;
        }
        return this.version;
      }
      toString() {
        return this.version;
      }
      compare(other) {
        debug4("SemVer.compare", this.version, this.options, other);
        if (!(other instanceof _SemVer)) {
          if (typeof other === "string" && other === this.version) {
            return 0;
          }
          other = new _SemVer(other, this.options);
        }
        if (other.version === this.version) {
          return 0;
        }
        return this.compareMain(other) || this.comparePre(other);
      }
      compareMain(other) {
        if (!(other instanceof _SemVer)) {
          other = new _SemVer(other, this.options);
        }
        return compareIdentifiers(this.major, other.major) || compareIdentifiers(this.minor, other.minor) || compareIdentifiers(this.patch, other.patch);
      }
      comparePre(other) {
        if (!(other instanceof _SemVer)) {
          other = new _SemVer(other, this.options);
        }
        if (this.prerelease.length && !other.prerelease.length) {
          return -1;
        } else if (!this.prerelease.length && other.prerelease.length) {
          return 1;
        } else if (!this.prerelease.length && !other.prerelease.length) {
          return 0;
        }
        let i = 0;
        do {
          const a = this.prerelease[i];
          const b = other.prerelease[i];
          debug4("prerelease compare", i, a, b);
          if (a === void 0 && b === void 0) {
            return 0;
          } else if (b === void 0) {
            return 1;
          } else if (a === void 0) {
            return -1;
          } else if (a === b) {
            continue;
          } else {
            return compareIdentifiers(a, b);
          }
        } while (++i);
      }
      compareBuild(other) {
        if (!(other instanceof _SemVer)) {
          other = new _SemVer(other, this.options);
        }
        let i = 0;
        do {
          const a = this.build[i];
          const b = other.build[i];
          debug4("prerelease compare", i, a, b);
          if (a === void 0 && b === void 0) {
            return 0;
          } else if (b === void 0) {
            return 1;
          } else if (a === void 0) {
            return -1;
          } else if (a === b) {
            continue;
          } else {
            return compareIdentifiers(a, b);
          }
        } while (++i);
      }
      // preminor will bump the version up to the next minor release, and immediately
      // down to pre-release. premajor and prepatch work the same way.
      inc(release, identifier, identifierBase) {
        switch (release) {
          case "premajor":
            this.prerelease.length = 0;
            this.patch = 0;
            this.minor = 0;
            this.major++;
            this.inc("pre", identifier, identifierBase);
            break;
          case "preminor":
            this.prerelease.length = 0;
            this.patch = 0;
            this.minor++;
            this.inc("pre", identifier, identifierBase);
            break;
          case "prepatch":
            this.prerelease.length = 0;
            this.inc("patch", identifier, identifierBase);
            this.inc("pre", identifier, identifierBase);
            break;
          case "prerelease":
            if (this.prerelease.length === 0) {
              this.inc("patch", identifier, identifierBase);
            }
            this.inc("pre", identifier, identifierBase);
            break;
          case "major":
            if (this.minor !== 0 || this.patch !== 0 || this.prerelease.length === 0) {
              this.major++;
            }
            this.minor = 0;
            this.patch = 0;
            this.prerelease = [];
            break;
          case "minor":
            if (this.patch !== 0 || this.prerelease.length === 0) {
              this.minor++;
            }
            this.patch = 0;
            this.prerelease = [];
            break;
          case "patch":
            if (this.prerelease.length === 0) {
              this.patch++;
            }
            this.prerelease = [];
            break;
          case "pre": {
            const base = Number(identifierBase) ? 1 : 0;
            if (!identifier && identifierBase === false) {
              throw new Error("invalid increment argument: identifier is empty");
            }
            if (this.prerelease.length === 0) {
              this.prerelease = [base];
            } else {
              let i = this.prerelease.length;
              while (--i >= 0) {
                if (typeof this.prerelease[i] === "number") {
                  this.prerelease[i]++;
                  i = -2;
                }
              }
              if (i === -1) {
                if (identifier === this.prerelease.join(".") && identifierBase === false) {
                  throw new Error("invalid increment argument: identifier already exists");
                }
                this.prerelease.push(base);
              }
            }
            if (identifier) {
              let prerelease = [identifier, base];
              if (identifierBase === false) {
                prerelease = [identifier];
              }
              if (compareIdentifiers(this.prerelease[0], identifier) === 0) {
                if (isNaN(this.prerelease[1])) {
                  this.prerelease = prerelease;
                }
              } else {
                this.prerelease = prerelease;
              }
            }
            break;
          }
          default:
            throw new Error(`invalid increment argument: ${release}`);
        }
        this.raw = this.format();
        if (this.build.length) {
          this.raw += `+${this.build.join(".")}`;
        }
        return this;
      }
    };
    module2.exports = SemVer;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/parse.js
var require_parse = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/parse.js"(exports, module2) {
    var SemVer = require_semver();
    var parse = (version2, options, throwErrors = false) => {
      if (version2 instanceof SemVer) {
        return version2;
      }
      try {
        return new SemVer(version2, options);
      } catch (er) {
        if (!throwErrors) {
          return null;
        }
        throw er;
      }
    };
    module2.exports = parse;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/valid.js
var require_valid = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/valid.js"(exports, module2) {
    var parse = require_parse();
    var valid = (version2, options) => {
      const v = parse(version2, options);
      return v ? v.version : null;
    };
    module2.exports = valid;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/clean.js
var require_clean = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/clean.js"(exports, module2) {
    var parse = require_parse();
    var clean = (version2, options) => {
      const s = parse(version2.trim().replace(/^[=v]+/, ""), options);
      return s ? s.version : null;
    };
    module2.exports = clean;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/inc.js
var require_inc = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/inc.js"(exports, module2) {
    var SemVer = require_semver();
    var inc = (version2, release, options, identifier, identifierBase) => {
      if (typeof options === "string") {
        identifierBase = identifier;
        identifier = options;
        options = void 0;
      }
      try {
        return new SemVer(
          version2 instanceof SemVer ? version2.version : version2,
          options
        ).inc(release, identifier, identifierBase).version;
      } catch (er) {
        return null;
      }
    };
    module2.exports = inc;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/diff.js
var require_diff = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/diff.js"(exports, module2) {
    var parse = require_parse();
    var diff = (version1, version2) => {
      const v1 = parse(version1, null, true);
      const v2 = parse(version2, null, true);
      const comparison = v1.compare(v2);
      if (comparison === 0) {
        return null;
      }
      const v1Higher = comparison > 0;
      const highVersion = v1Higher ? v1 : v2;
      const lowVersion = v1Higher ? v2 : v1;
      const highHasPre = !!highVersion.prerelease.length;
      const lowHasPre = !!lowVersion.prerelease.length;
      if (lowHasPre && !highHasPre) {
        if (!lowVersion.patch && !lowVersion.minor) {
          return "major";
        }
        if (highVersion.patch) {
          return "patch";
        }
        if (highVersion.minor) {
          return "minor";
        }
        return "major";
      }
      const prefix = highHasPre ? "pre" : "";
      if (v1.major !== v2.major) {
        return prefix + "major";
      }
      if (v1.minor !== v2.minor) {
        return prefix + "minor";
      }
      if (v1.patch !== v2.patch) {
        return prefix + "patch";
      }
      return "prerelease";
    };
    module2.exports = diff;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/major.js
var require_major = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/major.js"(exports, module2) {
    var SemVer = require_semver();
    var major = (a, loose) => new SemVer(a, loose).major;
    module2.exports = major;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/minor.js
var require_minor = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/minor.js"(exports, module2) {
    var SemVer = require_semver();
    var minor = (a, loose) => new SemVer(a, loose).minor;
    module2.exports = minor;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/patch.js
var require_patch = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/patch.js"(exports, module2) {
    var SemVer = require_semver();
    var patch = (a, loose) => new SemVer(a, loose).patch;
    module2.exports = patch;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/prerelease.js
var require_prerelease = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/prerelease.js"(exports, module2) {
    var parse = require_parse();
    var prerelease = (version2, options) => {
      const parsed = parse(version2, options);
      return parsed && parsed.prerelease.length ? parsed.prerelease : null;
    };
    module2.exports = prerelease;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/compare.js
var require_compare = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/compare.js"(exports, module2) {
    var SemVer = require_semver();
    var compare = (a, b, loose) => new SemVer(a, loose).compare(new SemVer(b, loose));
    module2.exports = compare;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/rcompare.js
var require_rcompare = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/rcompare.js"(exports, module2) {
    var compare = require_compare();
    var rcompare = (a, b, loose) => compare(b, a, loose);
    module2.exports = rcompare;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/compare-loose.js
var require_compare_loose = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/compare-loose.js"(exports, module2) {
    var compare = require_compare();
    var compareLoose = (a, b) => compare(a, b, true);
    module2.exports = compareLoose;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/compare-build.js
var require_compare_build = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/compare-build.js"(exports, module2) {
    var SemVer = require_semver();
    var compareBuild = (a, b, loose) => {
      const versionA = new SemVer(a, loose);
      const versionB = new SemVer(b, loose);
      return versionA.compare(versionB) || versionA.compareBuild(versionB);
    };
    module2.exports = compareBuild;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/sort.js
var require_sort = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/sort.js"(exports, module2) {
    var compareBuild = require_compare_build();
    var sort = (list, loose) => list.sort((a, b) => compareBuild(a, b, loose));
    module2.exports = sort;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/rsort.js
var require_rsort = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/rsort.js"(exports, module2) {
    var compareBuild = require_compare_build();
    var rsort = (list, loose) => list.sort((a, b) => compareBuild(b, a, loose));
    module2.exports = rsort;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/gt.js
var require_gt = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/gt.js"(exports, module2) {
    var compare = require_compare();
    var gt = (a, b, loose) => compare(a, b, loose) > 0;
    module2.exports = gt;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/lt.js
var require_lt = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/lt.js"(exports, module2) {
    var compare = require_compare();
    var lt = (a, b, loose) => compare(a, b, loose) < 0;
    module2.exports = lt;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/eq.js
var require_eq = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/eq.js"(exports, module2) {
    var compare = require_compare();
    var eq = (a, b, loose) => compare(a, b, loose) === 0;
    module2.exports = eq;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/neq.js
var require_neq = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/neq.js"(exports, module2) {
    var compare = require_compare();
    var neq = (a, b, loose) => compare(a, b, loose) !== 0;
    module2.exports = neq;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/gte.js
var require_gte = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/gte.js"(exports, module2) {
    var compare = require_compare();
    var gte = (a, b, loose) => compare(a, b, loose) >= 0;
    module2.exports = gte;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/lte.js
var require_lte = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/lte.js"(exports, module2) {
    var compare = require_compare();
    var lte = (a, b, loose) => compare(a, b, loose) <= 0;
    module2.exports = lte;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/cmp.js
var require_cmp = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/cmp.js"(exports, module2) {
    var eq = require_eq();
    var neq = require_neq();
    var gt = require_gt();
    var gte = require_gte();
    var lt = require_lt();
    var lte = require_lte();
    var cmp = (a, op, b, loose) => {
      switch (op) {
        case "===":
          if (typeof a === "object") {
            a = a.version;
          }
          if (typeof b === "object") {
            b = b.version;
          }
          return a === b;
        case "!==":
          if (typeof a === "object") {
            a = a.version;
          }
          if (typeof b === "object") {
            b = b.version;
          }
          return a !== b;
        case "":
        case "=":
        case "==":
          return eq(a, b, loose);
        case "!=":
          return neq(a, b, loose);
        case ">":
          return gt(a, b, loose);
        case ">=":
          return gte(a, b, loose);
        case "<":
          return lt(a, b, loose);
        case "<=":
          return lte(a, b, loose);
        default:
          throw new TypeError(`Invalid operator: ${op}`);
      }
    };
    module2.exports = cmp;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/coerce.js
var require_coerce = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/coerce.js"(exports, module2) {
    var SemVer = require_semver();
    var parse = require_parse();
    var { safeRe: re, t } = require_re();
    var coerce = (version2, options) => {
      if (version2 instanceof SemVer) {
        return version2;
      }
      if (typeof version2 === "number") {
        version2 = String(version2);
      }
      if (typeof version2 !== "string") {
        return null;
      }
      options = options || {};
      let match = null;
      if (!options.rtl) {
        match = version2.match(re[t.COERCE]);
      } else {
        let next;
        while ((next = re[t.COERCERTL].exec(version2)) && (!match || match.index + match[0].length !== version2.length)) {
          if (!match || next.index + next[0].length !== match.index + match[0].length) {
            match = next;
          }
          re[t.COERCERTL].lastIndex = next.index + next[1].length + next[2].length;
        }
        re[t.COERCERTL].lastIndex = -1;
      }
      if (match === null) {
        return null;
      }
      return parse(`${match[2]}.${match[3] || "0"}.${match[4] || "0"}`, options);
    };
    module2.exports = coerce;
  }
});

// ../../node_modules/.pnpm/yallist@4.0.0/node_modules/yallist/iterator.js
var require_iterator = __commonJS({
  "../../node_modules/.pnpm/yallist@4.0.0/node_modules/yallist/iterator.js"(exports, module2) {
    "use strict";
    module2.exports = function(Yallist) {
      Yallist.prototype[Symbol.iterator] = function* () {
        for (let walker = this.head; walker; walker = walker.next) {
          yield walker.value;
        }
      };
    };
  }
});

// ../../node_modules/.pnpm/yallist@4.0.0/node_modules/yallist/yallist.js
var require_yallist = __commonJS({
  "../../node_modules/.pnpm/yallist@4.0.0/node_modules/yallist/yallist.js"(exports, module2) {
    "use strict";
    module2.exports = Yallist;
    Yallist.Node = Node2;
    Yallist.create = Yallist;
    function Yallist(list) {
      var self = this;
      if (!(self instanceof Yallist)) {
        self = new Yallist();
      }
      self.tail = null;
      self.head = null;
      self.length = 0;
      if (list && typeof list.forEach === "function") {
        list.forEach(function(item) {
          self.push(item);
        });
      } else if (arguments.length > 0) {
        for (var i = 0, l = arguments.length; i < l; i++) {
          self.push(arguments[i]);
        }
      }
      return self;
    }
    Yallist.prototype.removeNode = function(node) {
      if (node.list !== this) {
        throw new Error("removing node which does not belong to this list");
      }
      var next = node.next;
      var prev = node.prev;
      if (next) {
        next.prev = prev;
      }
      if (prev) {
        prev.next = next;
      }
      if (node === this.head) {
        this.head = next;
      }
      if (node === this.tail) {
        this.tail = prev;
      }
      node.list.length--;
      node.next = null;
      node.prev = null;
      node.list = null;
      return next;
    };
    Yallist.prototype.unshiftNode = function(node) {
      if (node === this.head) {
        return;
      }
      if (node.list) {
        node.list.removeNode(node);
      }
      var head = this.head;
      node.list = this;
      node.next = head;
      if (head) {
        head.prev = node;
      }
      this.head = node;
      if (!this.tail) {
        this.tail = node;
      }
      this.length++;
    };
    Yallist.prototype.pushNode = function(node) {
      if (node === this.tail) {
        return;
      }
      if (node.list) {
        node.list.removeNode(node);
      }
      var tail = this.tail;
      node.list = this;
      node.prev = tail;
      if (tail) {
        tail.next = node;
      }
      this.tail = node;
      if (!this.head) {
        this.head = node;
      }
      this.length++;
    };
    Yallist.prototype.push = function() {
      for (var i = 0, l = arguments.length; i < l; i++) {
        push(this, arguments[i]);
      }
      return this.length;
    };
    Yallist.prototype.unshift = function() {
      for (var i = 0, l = arguments.length; i < l; i++) {
        unshift(this, arguments[i]);
      }
      return this.length;
    };
    Yallist.prototype.pop = function() {
      if (!this.tail) {
        return void 0;
      }
      var res = this.tail.value;
      this.tail = this.tail.prev;
      if (this.tail) {
        this.tail.next = null;
      } else {
        this.head = null;
      }
      this.length--;
      return res;
    };
    Yallist.prototype.shift = function() {
      if (!this.head) {
        return void 0;
      }
      var res = this.head.value;
      this.head = this.head.next;
      if (this.head) {
        this.head.prev = null;
      } else {
        this.tail = null;
      }
      this.length--;
      return res;
    };
    Yallist.prototype.forEach = function(fn, thisp) {
      thisp = thisp || this;
      for (var walker = this.head, i = 0; walker !== null; i++) {
        fn.call(thisp, walker.value, i, this);
        walker = walker.next;
      }
    };
    Yallist.prototype.forEachReverse = function(fn, thisp) {
      thisp = thisp || this;
      for (var walker = this.tail, i = this.length - 1; walker !== null; i--) {
        fn.call(thisp, walker.value, i, this);
        walker = walker.prev;
      }
    };
    Yallist.prototype.get = function(n) {
      for (var i = 0, walker = this.head; walker !== null && i < n; i++) {
        walker = walker.next;
      }
      if (i === n && walker !== null) {
        return walker.value;
      }
    };
    Yallist.prototype.getReverse = function(n) {
      for (var i = 0, walker = this.tail; walker !== null && i < n; i++) {
        walker = walker.prev;
      }
      if (i === n && walker !== null) {
        return walker.value;
      }
    };
    Yallist.prototype.map = function(fn, thisp) {
      thisp = thisp || this;
      var res = new Yallist();
      for (var walker = this.head; walker !== null; ) {
        res.push(fn.call(thisp, walker.value, this));
        walker = walker.next;
      }
      return res;
    };
    Yallist.prototype.mapReverse = function(fn, thisp) {
      thisp = thisp || this;
      var res = new Yallist();
      for (var walker = this.tail; walker !== null; ) {
        res.push(fn.call(thisp, walker.value, this));
        walker = walker.prev;
      }
      return res;
    };
    Yallist.prototype.reduce = function(fn, initial) {
      var acc;
      var walker = this.head;
      if (arguments.length > 1) {
        acc = initial;
      } else if (this.head) {
        walker = this.head.next;
        acc = this.head.value;
      } else {
        throw new TypeError("Reduce of empty list with no initial value");
      }
      for (var i = 0; walker !== null; i++) {
        acc = fn(acc, walker.value, i);
        walker = walker.next;
      }
      return acc;
    };
    Yallist.prototype.reduceReverse = function(fn, initial) {
      var acc;
      var walker = this.tail;
      if (arguments.length > 1) {
        acc = initial;
      } else if (this.tail) {
        walker = this.tail.prev;
        acc = this.tail.value;
      } else {
        throw new TypeError("Reduce of empty list with no initial value");
      }
      for (var i = this.length - 1; walker !== null; i--) {
        acc = fn(acc, walker.value, i);
        walker = walker.prev;
      }
      return acc;
    };
    Yallist.prototype.toArray = function() {
      var arr = new Array(this.length);
      for (var i = 0, walker = this.head; walker !== null; i++) {
        arr[i] = walker.value;
        walker = walker.next;
      }
      return arr;
    };
    Yallist.prototype.toArrayReverse = function() {
      var arr = new Array(this.length);
      for (var i = 0, walker = this.tail; walker !== null; i++) {
        arr[i] = walker.value;
        walker = walker.prev;
      }
      return arr;
    };
    Yallist.prototype.slice = function(from, to) {
      to = to || this.length;
      if (to < 0) {
        to += this.length;
      }
      from = from || 0;
      if (from < 0) {
        from += this.length;
      }
      var ret = new Yallist();
      if (to < from || to < 0) {
        return ret;
      }
      if (from < 0) {
        from = 0;
      }
      if (to > this.length) {
        to = this.length;
      }
      for (var i = 0, walker = this.head; walker !== null && i < from; i++) {
        walker = walker.next;
      }
      for (; walker !== null && i < to; i++, walker = walker.next) {
        ret.push(walker.value);
      }
      return ret;
    };
    Yallist.prototype.sliceReverse = function(from, to) {
      to = to || this.length;
      if (to < 0) {
        to += this.length;
      }
      from = from || 0;
      if (from < 0) {
        from += this.length;
      }
      var ret = new Yallist();
      if (to < from || to < 0) {
        return ret;
      }
      if (from < 0) {
        from = 0;
      }
      if (to > this.length) {
        to = this.length;
      }
      for (var i = this.length, walker = this.tail; walker !== null && i > to; i--) {
        walker = walker.prev;
      }
      for (; walker !== null && i > from; i--, walker = walker.prev) {
        ret.push(walker.value);
      }
      return ret;
    };
    Yallist.prototype.splice = function(start, deleteCount, ...nodes) {
      if (start > this.length) {
        start = this.length - 1;
      }
      if (start < 0) {
        start = this.length + start;
      }
      for (var i = 0, walker = this.head; walker !== null && i < start; i++) {
        walker = walker.next;
      }
      var ret = [];
      for (var i = 0; walker && i < deleteCount; i++) {
        ret.push(walker.value);
        walker = this.removeNode(walker);
      }
      if (walker === null) {
        walker = this.tail;
      }
      if (walker !== this.head && walker !== this.tail) {
        walker = walker.prev;
      }
      for (var i = 0; i < nodes.length; i++) {
        walker = insert(this, walker, nodes[i]);
      }
      return ret;
    };
    Yallist.prototype.reverse = function() {
      var head = this.head;
      var tail = this.tail;
      for (var walker = head; walker !== null; walker = walker.prev) {
        var p = walker.prev;
        walker.prev = walker.next;
        walker.next = p;
      }
      this.head = tail;
      this.tail = head;
      return this;
    };
    function insert(self, node, value) {
      var inserted = node === self.head ? new Node2(value, null, node, self) : new Node2(value, node, node.next, self);
      if (inserted.next === null) {
        self.tail = inserted;
      }
      if (inserted.prev === null) {
        self.head = inserted;
      }
      self.length++;
      return inserted;
    }
    function push(self, item) {
      self.tail = new Node2(item, self.tail, null, self);
      if (!self.head) {
        self.head = self.tail;
      }
      self.length++;
    }
    function unshift(self, item) {
      self.head = new Node2(item, null, self.head, self);
      if (!self.tail) {
        self.tail = self.head;
      }
      self.length++;
    }
    function Node2(value, prev, next, list) {
      if (!(this instanceof Node2)) {
        return new Node2(value, prev, next, list);
      }
      this.list = list;
      this.value = value;
      if (prev) {
        prev.next = this;
        this.prev = prev;
      } else {
        this.prev = null;
      }
      if (next) {
        next.prev = this;
        this.next = next;
      } else {
        this.next = null;
      }
    }
    try {
      require_iterator()(Yallist);
    } catch (er) {
    }
  }
});

// ../../node_modules/.pnpm/lru-cache@6.0.0/node_modules/lru-cache/index.js
var require_lru_cache = __commonJS({
  "../../node_modules/.pnpm/lru-cache@6.0.0/node_modules/lru-cache/index.js"(exports, module2) {
    "use strict";
    var Yallist = require_yallist();
    var MAX = Symbol("max");
    var LENGTH = Symbol("length");
    var LENGTH_CALCULATOR = Symbol("lengthCalculator");
    var ALLOW_STALE = Symbol("allowStale");
    var MAX_AGE = Symbol("maxAge");
    var DISPOSE = Symbol("dispose");
    var NO_DISPOSE_ON_SET = Symbol("noDisposeOnSet");
    var LRU_LIST = Symbol("lruList");
    var CACHE = Symbol("cache");
    var UPDATE_AGE_ON_GET = Symbol("updateAgeOnGet");
    var naiveLength = () => 1;
    var LRUCache = class {
      constructor(options) {
        if (typeof options === "number")
          options = { max: options };
        if (!options)
          options = {};
        if (options.max && (typeof options.max !== "number" || options.max < 0))
          throw new TypeError("max must be a non-negative number");
        const max = this[MAX] = options.max || Infinity;
        const lc = options.length || naiveLength;
        this[LENGTH_CALCULATOR] = typeof lc !== "function" ? naiveLength : lc;
        this[ALLOW_STALE] = options.stale || false;
        if (options.maxAge && typeof options.maxAge !== "number")
          throw new TypeError("maxAge must be a number");
        this[MAX_AGE] = options.maxAge || 0;
        this[DISPOSE] = options.dispose;
        this[NO_DISPOSE_ON_SET] = options.noDisposeOnSet || false;
        this[UPDATE_AGE_ON_GET] = options.updateAgeOnGet || false;
        this.reset();
      }
      // resize the cache when the max changes.
      set max(mL) {
        if (typeof mL !== "number" || mL < 0)
          throw new TypeError("max must be a non-negative number");
        this[MAX] = mL || Infinity;
        trim(this);
      }
      get max() {
        return this[MAX];
      }
      set allowStale(allowStale) {
        this[ALLOW_STALE] = !!allowStale;
      }
      get allowStale() {
        return this[ALLOW_STALE];
      }
      set maxAge(mA) {
        if (typeof mA !== "number")
          throw new TypeError("maxAge must be a non-negative number");
        this[MAX_AGE] = mA;
        trim(this);
      }
      get maxAge() {
        return this[MAX_AGE];
      }
      // resize the cache when the lengthCalculator changes.
      set lengthCalculator(lC) {
        if (typeof lC !== "function")
          lC = naiveLength;
        if (lC !== this[LENGTH_CALCULATOR]) {
          this[LENGTH_CALCULATOR] = lC;
          this[LENGTH] = 0;
          this[LRU_LIST].forEach((hit) => {
            hit.length = this[LENGTH_CALCULATOR](hit.value, hit.key);
            this[LENGTH] += hit.length;
          });
        }
        trim(this);
      }
      get lengthCalculator() {
        return this[LENGTH_CALCULATOR];
      }
      get length() {
        return this[LENGTH];
      }
      get itemCount() {
        return this[LRU_LIST].length;
      }
      rforEach(fn, thisp) {
        thisp = thisp || this;
        for (let walker = this[LRU_LIST].tail; walker !== null; ) {
          const prev = walker.prev;
          forEachStep(this, fn, walker, thisp);
          walker = prev;
        }
      }
      forEach(fn, thisp) {
        thisp = thisp || this;
        for (let walker = this[LRU_LIST].head; walker !== null; ) {
          const next = walker.next;
          forEachStep(this, fn, walker, thisp);
          walker = next;
        }
      }
      keys() {
        return this[LRU_LIST].toArray().map((k) => k.key);
      }
      values() {
        return this[LRU_LIST].toArray().map((k) => k.value);
      }
      reset() {
        if (this[DISPOSE] && this[LRU_LIST] && this[LRU_LIST].length) {
          this[LRU_LIST].forEach((hit) => this[DISPOSE](hit.key, hit.value));
        }
        this[CACHE] = /* @__PURE__ */ new Map();
        this[LRU_LIST] = new Yallist();
        this[LENGTH] = 0;
      }
      dump() {
        return this[LRU_LIST].map((hit) => isStale(this, hit) ? false : {
          k: hit.key,
          v: hit.value,
          e: hit.now + (hit.maxAge || 0)
        }).toArray().filter((h) => h);
      }
      dumpLru() {
        return this[LRU_LIST];
      }
      set(key, value, maxAge) {
        maxAge = maxAge || this[MAX_AGE];
        if (maxAge && typeof maxAge !== "number")
          throw new TypeError("maxAge must be a number");
        const now = maxAge ? Date.now() : 0;
        const len = this[LENGTH_CALCULATOR](value, key);
        if (this[CACHE].has(key)) {
          if (len > this[MAX]) {
            del(this, this[CACHE].get(key));
            return false;
          }
          const node = this[CACHE].get(key);
          const item = node.value;
          if (this[DISPOSE]) {
            if (!this[NO_DISPOSE_ON_SET])
              this[DISPOSE](key, item.value);
          }
          item.now = now;
          item.maxAge = maxAge;
          item.value = value;
          this[LENGTH] += len - item.length;
          item.length = len;
          this.get(key);
          trim(this);
          return true;
        }
        const hit = new Entry(key, value, len, now, maxAge);
        if (hit.length > this[MAX]) {
          if (this[DISPOSE])
            this[DISPOSE](key, value);
          return false;
        }
        this[LENGTH] += hit.length;
        this[LRU_LIST].unshift(hit);
        this[CACHE].set(key, this[LRU_LIST].head);
        trim(this);
        return true;
      }
      has(key) {
        if (!this[CACHE].has(key))
          return false;
        const hit = this[CACHE].get(key).value;
        return !isStale(this, hit);
      }
      get(key) {
        return get(this, key, true);
      }
      peek(key) {
        return get(this, key, false);
      }
      pop() {
        const node = this[LRU_LIST].tail;
        if (!node)
          return null;
        del(this, node);
        return node.value;
      }
      del(key) {
        del(this, this[CACHE].get(key));
      }
      load(arr) {
        this.reset();
        const now = Date.now();
        for (let l = arr.length - 1; l >= 0; l--) {
          const hit = arr[l];
          const expiresAt = hit.e || 0;
          if (expiresAt === 0)
            this.set(hit.k, hit.v);
          else {
            const maxAge = expiresAt - now;
            if (maxAge > 0) {
              this.set(hit.k, hit.v, maxAge);
            }
          }
        }
      }
      prune() {
        this[CACHE].forEach((value, key) => get(this, key, false));
      }
    };
    var get = (self, key, doUse) => {
      const node = self[CACHE].get(key);
      if (node) {
        const hit = node.value;
        if (isStale(self, hit)) {
          del(self, node);
          if (!self[ALLOW_STALE])
            return void 0;
        } else {
          if (doUse) {
            if (self[UPDATE_AGE_ON_GET])
              node.value.now = Date.now();
            self[LRU_LIST].unshiftNode(node);
          }
        }
        return hit.value;
      }
    };
    var isStale = (self, hit) => {
      if (!hit || !hit.maxAge && !self[MAX_AGE])
        return false;
      const diff = Date.now() - hit.now;
      return hit.maxAge ? diff > hit.maxAge : self[MAX_AGE] && diff > self[MAX_AGE];
    };
    var trim = (self) => {
      if (self[LENGTH] > self[MAX]) {
        for (let walker = self[LRU_LIST].tail; self[LENGTH] > self[MAX] && walker !== null; ) {
          const prev = walker.prev;
          del(self, walker);
          walker = prev;
        }
      }
    };
    var del = (self, node) => {
      if (node) {
        const hit = node.value;
        if (self[DISPOSE])
          self[DISPOSE](hit.key, hit.value);
        self[LENGTH] -= hit.length;
        self[CACHE].delete(hit.key);
        self[LRU_LIST].removeNode(node);
      }
    };
    var Entry = class {
      constructor(key, value, length, now, maxAge) {
        this.key = key;
        this.value = value;
        this.length = length;
        this.now = now;
        this.maxAge = maxAge || 0;
      }
    };
    var forEachStep = (self, fn, node, thisp) => {
      let hit = node.value;
      if (isStale(self, hit)) {
        del(self, node);
        if (!self[ALLOW_STALE])
          hit = void 0;
      }
      if (hit)
        fn.call(thisp, hit.value, hit.key, self);
    };
    module2.exports = LRUCache;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/classes/range.js
var require_range = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/classes/range.js"(exports, module2) {
    var Range = class _Range {
      constructor(range, options) {
        options = parseOptions(options);
        if (range instanceof _Range) {
          if (range.loose === !!options.loose && range.includePrerelease === !!options.includePrerelease) {
            return range;
          } else {
            return new _Range(range.raw, options);
          }
        }
        if (range instanceof Comparator) {
          this.raw = range.value;
          this.set = [[range]];
          this.format();
          return this;
        }
        this.options = options;
        this.loose = !!options.loose;
        this.includePrerelease = !!options.includePrerelease;
        this.raw = range.trim().split(/\s+/).join(" ");
        this.set = this.raw.split("||").map((r) => this.parseRange(r)).filter((c) => c.length);
        if (!this.set.length) {
          throw new TypeError(`Invalid SemVer Range: ${this.raw}`);
        }
        if (this.set.length > 1) {
          const first = this.set[0];
          this.set = this.set.filter((c) => !isNullSet(c[0]));
          if (this.set.length === 0) {
            this.set = [first];
          } else if (this.set.length > 1) {
            for (const c of this.set) {
              if (c.length === 1 && isAny(c[0])) {
                this.set = [c];
                break;
              }
            }
          }
        }
        this.format();
      }
      format() {
        this.range = this.set.map((comps) => comps.join(" ").trim()).join("||").trim();
        return this.range;
      }
      toString() {
        return this.range;
      }
      parseRange(range) {
        const memoOpts = (this.options.includePrerelease && FLAG_INCLUDE_PRERELEASE) | (this.options.loose && FLAG_LOOSE);
        const memoKey = memoOpts + ":" + range;
        const cached = cache.get(memoKey);
        if (cached) {
          return cached;
        }
        const loose = this.options.loose;
        const hr = loose ? re[t.HYPHENRANGELOOSE] : re[t.HYPHENRANGE];
        range = range.replace(hr, hyphenReplace(this.options.includePrerelease));
        debug4("hyphen replace", range);
        range = range.replace(re[t.COMPARATORTRIM], comparatorTrimReplace);
        debug4("comparator trim", range);
        range = range.replace(re[t.TILDETRIM], tildeTrimReplace);
        range = range.replace(re[t.CARETTRIM], caretTrimReplace);
        let rangeList = range.split(" ").map((comp) => parseComparator(comp, this.options)).join(" ").split(/\s+/).map((comp) => replaceGTE0(comp, this.options));
        if (loose) {
          rangeList = rangeList.filter((comp) => {
            debug4("loose invalid filter", comp, this.options);
            return !!comp.match(re[t.COMPARATORLOOSE]);
          });
        }
        debug4("range list", rangeList);
        const rangeMap = /* @__PURE__ */ new Map();
        const comparators = rangeList.map((comp) => new Comparator(comp, this.options));
        for (const comp of comparators) {
          if (isNullSet(comp)) {
            return [comp];
          }
          rangeMap.set(comp.value, comp);
        }
        if (rangeMap.size > 1 && rangeMap.has("")) {
          rangeMap.delete("");
        }
        const result = [...rangeMap.values()];
        cache.set(memoKey, result);
        return result;
      }
      intersects(range, options) {
        if (!(range instanceof _Range)) {
          throw new TypeError("a Range is required");
        }
        return this.set.some((thisComparators) => {
          return isSatisfiable(thisComparators, options) && range.set.some((rangeComparators) => {
            return isSatisfiable(rangeComparators, options) && thisComparators.every((thisComparator) => {
              return rangeComparators.every((rangeComparator) => {
                return thisComparator.intersects(rangeComparator, options);
              });
            });
          });
        });
      }
      // if ANY of the sets match ALL of its comparators, then pass
      test(version2) {
        if (!version2) {
          return false;
        }
        if (typeof version2 === "string") {
          try {
            version2 = new SemVer(version2, this.options);
          } catch (er) {
            return false;
          }
        }
        for (let i = 0; i < this.set.length; i++) {
          if (testSet(this.set[i], version2, this.options)) {
            return true;
          }
        }
        return false;
      }
    };
    module2.exports = Range;
    var LRU = require_lru_cache();
    var cache = new LRU({ max: 1e3 });
    var parseOptions = require_parse_options();
    var Comparator = require_comparator();
    var debug4 = require_debug();
    var SemVer = require_semver();
    var {
      safeRe: re,
      t,
      comparatorTrimReplace,
      tildeTrimReplace,
      caretTrimReplace
    } = require_re();
    var { FLAG_INCLUDE_PRERELEASE, FLAG_LOOSE } = require_constants();
    var isNullSet = (c) => c.value === "<0.0.0-0";
    var isAny = (c) => c.value === "";
    var isSatisfiable = (comparators, options) => {
      let result = true;
      const remainingComparators = comparators.slice();
      let testComparator = remainingComparators.pop();
      while (result && remainingComparators.length) {
        result = remainingComparators.every((otherComparator) => {
          return testComparator.intersects(otherComparator, options);
        });
        testComparator = remainingComparators.pop();
      }
      return result;
    };
    var parseComparator = (comp, options) => {
      debug4("comp", comp, options);
      comp = replaceCarets(comp, options);
      debug4("caret", comp);
      comp = replaceTildes(comp, options);
      debug4("tildes", comp);
      comp = replaceXRanges(comp, options);
      debug4("xrange", comp);
      comp = replaceStars(comp, options);
      debug4("stars", comp);
      return comp;
    };
    var isX = (id) => !id || id.toLowerCase() === "x" || id === "*";
    var replaceTildes = (comp, options) => {
      return comp.trim().split(/\s+/).map((c) => replaceTilde(c, options)).join(" ");
    };
    var replaceTilde = (comp, options) => {
      const r = options.loose ? re[t.TILDELOOSE] : re[t.TILDE];
      return comp.replace(r, (_, M, m, p, pr) => {
        debug4("tilde", comp, _, M, m, p, pr);
        let ret;
        if (isX(M)) {
          ret = "";
        } else if (isX(m)) {
          ret = `>=${M}.0.0 <${+M + 1}.0.0-0`;
        } else if (isX(p)) {
          ret = `>=${M}.${m}.0 <${M}.${+m + 1}.0-0`;
        } else if (pr) {
          debug4("replaceTilde pr", pr);
          ret = `>=${M}.${m}.${p}-${pr} <${M}.${+m + 1}.0-0`;
        } else {
          ret = `>=${M}.${m}.${p} <${M}.${+m + 1}.0-0`;
        }
        debug4("tilde return", ret);
        return ret;
      });
    };
    var replaceCarets = (comp, options) => {
      return comp.trim().split(/\s+/).map((c) => replaceCaret(c, options)).join(" ");
    };
    var replaceCaret = (comp, options) => {
      debug4("caret", comp, options);
      const r = options.loose ? re[t.CARETLOOSE] : re[t.CARET];
      const z = options.includePrerelease ? "-0" : "";
      return comp.replace(r, (_, M, m, p, pr) => {
        debug4("caret", comp, _, M, m, p, pr);
        let ret;
        if (isX(M)) {
          ret = "";
        } else if (isX(m)) {
          ret = `>=${M}.0.0${z} <${+M + 1}.0.0-0`;
        } else if (isX(p)) {
          if (M === "0") {
            ret = `>=${M}.${m}.0${z} <${M}.${+m + 1}.0-0`;
          } else {
            ret = `>=${M}.${m}.0${z} <${+M + 1}.0.0-0`;
          }
        } else if (pr) {
          debug4("replaceCaret pr", pr);
          if (M === "0") {
            if (m === "0") {
              ret = `>=${M}.${m}.${p}-${pr} <${M}.${m}.${+p + 1}-0`;
            } else {
              ret = `>=${M}.${m}.${p}-${pr} <${M}.${+m + 1}.0-0`;
            }
          } else {
            ret = `>=${M}.${m}.${p}-${pr} <${+M + 1}.0.0-0`;
          }
        } else {
          debug4("no pr");
          if (M === "0") {
            if (m === "0") {
              ret = `>=${M}.${m}.${p}${z} <${M}.${m}.${+p + 1}-0`;
            } else {
              ret = `>=${M}.${m}.${p}${z} <${M}.${+m + 1}.0-0`;
            }
          } else {
            ret = `>=${M}.${m}.${p} <${+M + 1}.0.0-0`;
          }
        }
        debug4("caret return", ret);
        return ret;
      });
    };
    var replaceXRanges = (comp, options) => {
      debug4("replaceXRanges", comp, options);
      return comp.split(/\s+/).map((c) => replaceXRange(c, options)).join(" ");
    };
    var replaceXRange = (comp, options) => {
      comp = comp.trim();
      const r = options.loose ? re[t.XRANGELOOSE] : re[t.XRANGE];
      return comp.replace(r, (ret, gtlt, M, m, p, pr) => {
        debug4("xRange", comp, ret, gtlt, M, m, p, pr);
        const xM = isX(M);
        const xm = xM || isX(m);
        const xp = xm || isX(p);
        const anyX = xp;
        if (gtlt === "=" && anyX) {
          gtlt = "";
        }
        pr = options.includePrerelease ? "-0" : "";
        if (xM) {
          if (gtlt === ">" || gtlt === "<") {
            ret = "<0.0.0-0";
          } else {
            ret = "*";
          }
        } else if (gtlt && anyX) {
          if (xm) {
            m = 0;
          }
          p = 0;
          if (gtlt === ">") {
            gtlt = ">=";
            if (xm) {
              M = +M + 1;
              m = 0;
              p = 0;
            } else {
              m = +m + 1;
              p = 0;
            }
          } else if (gtlt === "<=") {
            gtlt = "<";
            if (xm) {
              M = +M + 1;
            } else {
              m = +m + 1;
            }
          }
          if (gtlt === "<") {
            pr = "-0";
          }
          ret = `${gtlt + M}.${m}.${p}${pr}`;
        } else if (xm) {
          ret = `>=${M}.0.0${pr} <${+M + 1}.0.0-0`;
        } else if (xp) {
          ret = `>=${M}.${m}.0${pr} <${M}.${+m + 1}.0-0`;
        }
        debug4("xRange return", ret);
        return ret;
      });
    };
    var replaceStars = (comp, options) => {
      debug4("replaceStars", comp, options);
      return comp.trim().replace(re[t.STAR], "");
    };
    var replaceGTE0 = (comp, options) => {
      debug4("replaceGTE0", comp, options);
      return comp.trim().replace(re[options.includePrerelease ? t.GTE0PRE : t.GTE0], "");
    };
    var hyphenReplace = (incPr) => ($0, from, fM, fm, fp, fpr, fb, to, tM, tm, tp, tpr, tb) => {
      if (isX(fM)) {
        from = "";
      } else if (isX(fm)) {
        from = `>=${fM}.0.0${incPr ? "-0" : ""}`;
      } else if (isX(fp)) {
        from = `>=${fM}.${fm}.0${incPr ? "-0" : ""}`;
      } else if (fpr) {
        from = `>=${from}`;
      } else {
        from = `>=${from}${incPr ? "-0" : ""}`;
      }
      if (isX(tM)) {
        to = "";
      } else if (isX(tm)) {
        to = `<${+tM + 1}.0.0-0`;
      } else if (isX(tp)) {
        to = `<${tM}.${+tm + 1}.0-0`;
      } else if (tpr) {
        to = `<=${tM}.${tm}.${tp}-${tpr}`;
      } else if (incPr) {
        to = `<${tM}.${tm}.${+tp + 1}-0`;
      } else {
        to = `<=${to}`;
      }
      return `${from} ${to}`.trim();
    };
    var testSet = (set, version2, options) => {
      for (let i = 0; i < set.length; i++) {
        if (!set[i].test(version2)) {
          return false;
        }
      }
      if (version2.prerelease.length && !options.includePrerelease) {
        for (let i = 0; i < set.length; i++) {
          debug4(set[i].semver);
          if (set[i].semver === Comparator.ANY) {
            continue;
          }
          if (set[i].semver.prerelease.length > 0) {
            const allowed = set[i].semver;
            if (allowed.major === version2.major && allowed.minor === version2.minor && allowed.patch === version2.patch) {
              return true;
            }
          }
        }
        return false;
      }
      return true;
    };
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/classes/comparator.js
var require_comparator = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/classes/comparator.js"(exports, module2) {
    var ANY = Symbol("SemVer ANY");
    var Comparator = class _Comparator {
      static get ANY() {
        return ANY;
      }
      constructor(comp, options) {
        options = parseOptions(options);
        if (comp instanceof _Comparator) {
          if (comp.loose === !!options.loose) {
            return comp;
          } else {
            comp = comp.value;
          }
        }
        comp = comp.trim().split(/\s+/).join(" ");
        debug4("comparator", comp, options);
        this.options = options;
        this.loose = !!options.loose;
        this.parse(comp);
        if (this.semver === ANY) {
          this.value = "";
        } else {
          this.value = this.operator + this.semver.version;
        }
        debug4("comp", this);
      }
      parse(comp) {
        const r = this.options.loose ? re[t.COMPARATORLOOSE] : re[t.COMPARATOR];
        const m = comp.match(r);
        if (!m) {
          throw new TypeError(`Invalid comparator: ${comp}`);
        }
        this.operator = m[1] !== void 0 ? m[1] : "";
        if (this.operator === "=") {
          this.operator = "";
        }
        if (!m[2]) {
          this.semver = ANY;
        } else {
          this.semver = new SemVer(m[2], this.options.loose);
        }
      }
      toString() {
        return this.value;
      }
      test(version2) {
        debug4("Comparator.test", version2, this.options.loose);
        if (this.semver === ANY || version2 === ANY) {
          return true;
        }
        if (typeof version2 === "string") {
          try {
            version2 = new SemVer(version2, this.options);
          } catch (er) {
            return false;
          }
        }
        return cmp(version2, this.operator, this.semver, this.options);
      }
      intersects(comp, options) {
        if (!(comp instanceof _Comparator)) {
          throw new TypeError("a Comparator is required");
        }
        if (this.operator === "") {
          if (this.value === "") {
            return true;
          }
          return new Range(comp.value, options).test(this.value);
        } else if (comp.operator === "") {
          if (comp.value === "") {
            return true;
          }
          return new Range(this.value, options).test(comp.semver);
        }
        options = parseOptions(options);
        if (options.includePrerelease && (this.value === "<0.0.0-0" || comp.value === "<0.0.0-0")) {
          return false;
        }
        if (!options.includePrerelease && (this.value.startsWith("<0.0.0") || comp.value.startsWith("<0.0.0"))) {
          return false;
        }
        if (this.operator.startsWith(">") && comp.operator.startsWith(">")) {
          return true;
        }
        if (this.operator.startsWith("<") && comp.operator.startsWith("<")) {
          return true;
        }
        if (this.semver.version === comp.semver.version && this.operator.includes("=") && comp.operator.includes("=")) {
          return true;
        }
        if (cmp(this.semver, "<", comp.semver, options) && this.operator.startsWith(">") && comp.operator.startsWith("<")) {
          return true;
        }
        if (cmp(this.semver, ">", comp.semver, options) && this.operator.startsWith("<") && comp.operator.startsWith(">")) {
          return true;
        }
        return false;
      }
    };
    module2.exports = Comparator;
    var parseOptions = require_parse_options();
    var { safeRe: re, t } = require_re();
    var cmp = require_cmp();
    var debug4 = require_debug();
    var SemVer = require_semver();
    var Range = require_range();
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/satisfies.js
var require_satisfies = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/functions/satisfies.js"(exports, module2) {
    var Range = require_range();
    var satisfies = (version2, range, options) => {
      try {
        range = new Range(range, options);
      } catch (er) {
        return false;
      }
      return range.test(version2);
    };
    module2.exports = satisfies;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/to-comparators.js
var require_to_comparators = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/to-comparators.js"(exports, module2) {
    var Range = require_range();
    var toComparators = (range, options) => new Range(range, options).set.map((comp) => comp.map((c) => c.value).join(" ").trim().split(" "));
    module2.exports = toComparators;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/max-satisfying.js
var require_max_satisfying = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/max-satisfying.js"(exports, module2) {
    var SemVer = require_semver();
    var Range = require_range();
    var maxSatisfying = (versions, range, options) => {
      let max = null;
      let maxSV = null;
      let rangeObj = null;
      try {
        rangeObj = new Range(range, options);
      } catch (er) {
        return null;
      }
      versions.forEach((v) => {
        if (rangeObj.test(v)) {
          if (!max || maxSV.compare(v) === -1) {
            max = v;
            maxSV = new SemVer(max, options);
          }
        }
      });
      return max;
    };
    module2.exports = maxSatisfying;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/min-satisfying.js
var require_min_satisfying = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/min-satisfying.js"(exports, module2) {
    var SemVer = require_semver();
    var Range = require_range();
    var minSatisfying = (versions, range, options) => {
      let min = null;
      let minSV = null;
      let rangeObj = null;
      try {
        rangeObj = new Range(range, options);
      } catch (er) {
        return null;
      }
      versions.forEach((v) => {
        if (rangeObj.test(v)) {
          if (!min || minSV.compare(v) === 1) {
            min = v;
            minSV = new SemVer(min, options);
          }
        }
      });
      return min;
    };
    module2.exports = minSatisfying;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/min-version.js
var require_min_version = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/min-version.js"(exports, module2) {
    var SemVer = require_semver();
    var Range = require_range();
    var gt = require_gt();
    var minVersion = (range, loose) => {
      range = new Range(range, loose);
      let minver = new SemVer("0.0.0");
      if (range.test(minver)) {
        return minver;
      }
      minver = new SemVer("0.0.0-0");
      if (range.test(minver)) {
        return minver;
      }
      minver = null;
      for (let i = 0; i < range.set.length; ++i) {
        const comparators = range.set[i];
        let setMin = null;
        comparators.forEach((comparator) => {
          const compver = new SemVer(comparator.semver.version);
          switch (comparator.operator) {
            case ">":
              if (compver.prerelease.length === 0) {
                compver.patch++;
              } else {
                compver.prerelease.push(0);
              }
              compver.raw = compver.format();
            case "":
            case ">=":
              if (!setMin || gt(compver, setMin)) {
                setMin = compver;
              }
              break;
            case "<":
            case "<=":
              break;
            default:
              throw new Error(`Unexpected operation: ${comparator.operator}`);
          }
        });
        if (setMin && (!minver || gt(minver, setMin))) {
          minver = setMin;
        }
      }
      if (minver && range.test(minver)) {
        return minver;
      }
      return null;
    };
    module2.exports = minVersion;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/valid.js
var require_valid2 = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/valid.js"(exports, module2) {
    var Range = require_range();
    var validRange = (range, options) => {
      try {
        return new Range(range, options).range || "*";
      } catch (er) {
        return null;
      }
    };
    module2.exports = validRange;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/outside.js
var require_outside = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/outside.js"(exports, module2) {
    var SemVer = require_semver();
    var Comparator = require_comparator();
    var { ANY } = Comparator;
    var Range = require_range();
    var satisfies = require_satisfies();
    var gt = require_gt();
    var lt = require_lt();
    var lte = require_lte();
    var gte = require_gte();
    var outside = (version2, range, hilo, options) => {
      version2 = new SemVer(version2, options);
      range = new Range(range, options);
      let gtfn, ltefn, ltfn, comp, ecomp;
      switch (hilo) {
        case ">":
          gtfn = gt;
          ltefn = lte;
          ltfn = lt;
          comp = ">";
          ecomp = ">=";
          break;
        case "<":
          gtfn = lt;
          ltefn = gte;
          ltfn = gt;
          comp = "<";
          ecomp = "<=";
          break;
        default:
          throw new TypeError('Must provide a hilo val of "<" or ">"');
      }
      if (satisfies(version2, range, options)) {
        return false;
      }
      for (let i = 0; i < range.set.length; ++i) {
        const comparators = range.set[i];
        let high = null;
        let low = null;
        comparators.forEach((comparator) => {
          if (comparator.semver === ANY) {
            comparator = new Comparator(">=0.0.0");
          }
          high = high || comparator;
          low = low || comparator;
          if (gtfn(comparator.semver, high.semver, options)) {
            high = comparator;
          } else if (ltfn(comparator.semver, low.semver, options)) {
            low = comparator;
          }
        });
        if (high.operator === comp || high.operator === ecomp) {
          return false;
        }
        if ((!low.operator || low.operator === comp) && ltefn(version2, low.semver)) {
          return false;
        } else if (low.operator === ecomp && ltfn(version2, low.semver)) {
          return false;
        }
      }
      return true;
    };
    module2.exports = outside;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/gtr.js
var require_gtr = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/gtr.js"(exports, module2) {
    var outside = require_outside();
    var gtr = (version2, range, options) => outside(version2, range, ">", options);
    module2.exports = gtr;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/ltr.js
var require_ltr = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/ltr.js"(exports, module2) {
    var outside = require_outside();
    var ltr = (version2, range, options) => outside(version2, range, "<", options);
    module2.exports = ltr;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/intersects.js
var require_intersects = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/intersects.js"(exports, module2) {
    var Range = require_range();
    var intersects = (r1, r2, options) => {
      r1 = new Range(r1, options);
      r2 = new Range(r2, options);
      return r1.intersects(r2, options);
    };
    module2.exports = intersects;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/simplify.js
var require_simplify = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/simplify.js"(exports, module2) {
    var satisfies = require_satisfies();
    var compare = require_compare();
    module2.exports = (versions, range, options) => {
      const set = [];
      let first = null;
      let prev = null;
      const v = versions.sort((a, b) => compare(a, b, options));
      for (const version2 of v) {
        const included = satisfies(version2, range, options);
        if (included) {
          prev = version2;
          if (!first) {
            first = version2;
          }
        } else {
          if (prev) {
            set.push([first, prev]);
          }
          prev = null;
          first = null;
        }
      }
      if (first) {
        set.push([first, null]);
      }
      const ranges = [];
      for (const [min, max] of set) {
        if (min === max) {
          ranges.push(min);
        } else if (!max && min === v[0]) {
          ranges.push("*");
        } else if (!max) {
          ranges.push(`>=${min}`);
        } else if (min === v[0]) {
          ranges.push(`<=${max}`);
        } else {
          ranges.push(`${min} - ${max}`);
        }
      }
      const simplified = ranges.join(" || ");
      const original = typeof range.raw === "string" ? range.raw : String(range);
      return simplified.length < original.length ? simplified : range;
    };
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/subset.js
var require_subset = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/ranges/subset.js"(exports, module2) {
    var Range = require_range();
    var Comparator = require_comparator();
    var { ANY } = Comparator;
    var satisfies = require_satisfies();
    var compare = require_compare();
    var subset = (sub, dom, options = {}) => {
      if (sub === dom) {
        return true;
      }
      sub = new Range(sub, options);
      dom = new Range(dom, options);
      let sawNonNull = false;
      OUTER:
        for (const simpleSub of sub.set) {
          for (const simpleDom of dom.set) {
            const isSub = simpleSubset(simpleSub, simpleDom, options);
            sawNonNull = sawNonNull || isSub !== null;
            if (isSub) {
              continue OUTER;
            }
          }
          if (sawNonNull) {
            return false;
          }
        }
      return true;
    };
    var minimumVersionWithPreRelease = [new Comparator(">=0.0.0-0")];
    var minimumVersion = [new Comparator(">=0.0.0")];
    var simpleSubset = (sub, dom, options) => {
      if (sub === dom) {
        return true;
      }
      if (sub.length === 1 && sub[0].semver === ANY) {
        if (dom.length === 1 && dom[0].semver === ANY) {
          return true;
        } else if (options.includePrerelease) {
          sub = minimumVersionWithPreRelease;
        } else {
          sub = minimumVersion;
        }
      }
      if (dom.length === 1 && dom[0].semver === ANY) {
        if (options.includePrerelease) {
          return true;
        } else {
          dom = minimumVersion;
        }
      }
      const eqSet = /* @__PURE__ */ new Set();
      let gt, lt;
      for (const c of sub) {
        if (c.operator === ">" || c.operator === ">=") {
          gt = higherGT(gt, c, options);
        } else if (c.operator === "<" || c.operator === "<=") {
          lt = lowerLT(lt, c, options);
        } else {
          eqSet.add(c.semver);
        }
      }
      if (eqSet.size > 1) {
        return null;
      }
      let gtltComp;
      if (gt && lt) {
        gtltComp = compare(gt.semver, lt.semver, options);
        if (gtltComp > 0) {
          return null;
        } else if (gtltComp === 0 && (gt.operator !== ">=" || lt.operator !== "<=")) {
          return null;
        }
      }
      for (const eq of eqSet) {
        if (gt && !satisfies(eq, String(gt), options)) {
          return null;
        }
        if (lt && !satisfies(eq, String(lt), options)) {
          return null;
        }
        for (const c of dom) {
          if (!satisfies(eq, String(c), options)) {
            return false;
          }
        }
        return true;
      }
      let higher, lower;
      let hasDomLT, hasDomGT;
      let needDomLTPre = lt && !options.includePrerelease && lt.semver.prerelease.length ? lt.semver : false;
      let needDomGTPre = gt && !options.includePrerelease && gt.semver.prerelease.length ? gt.semver : false;
      if (needDomLTPre && needDomLTPre.prerelease.length === 1 && lt.operator === "<" && needDomLTPre.prerelease[0] === 0) {
        needDomLTPre = false;
      }
      for (const c of dom) {
        hasDomGT = hasDomGT || c.operator === ">" || c.operator === ">=";
        hasDomLT = hasDomLT || c.operator === "<" || c.operator === "<=";
        if (gt) {
          if (needDomGTPre) {
            if (c.semver.prerelease && c.semver.prerelease.length && c.semver.major === needDomGTPre.major && c.semver.minor === needDomGTPre.minor && c.semver.patch === needDomGTPre.patch) {
              needDomGTPre = false;
            }
          }
          if (c.operator === ">" || c.operator === ">=") {
            higher = higherGT(gt, c, options);
            if (higher === c && higher !== gt) {
              return false;
            }
          } else if (gt.operator === ">=" && !satisfies(gt.semver, String(c), options)) {
            return false;
          }
        }
        if (lt) {
          if (needDomLTPre) {
            if (c.semver.prerelease && c.semver.prerelease.length && c.semver.major === needDomLTPre.major && c.semver.minor === needDomLTPre.minor && c.semver.patch === needDomLTPre.patch) {
              needDomLTPre = false;
            }
          }
          if (c.operator === "<" || c.operator === "<=") {
            lower = lowerLT(lt, c, options);
            if (lower === c && lower !== lt) {
              return false;
            }
          } else if (lt.operator === "<=" && !satisfies(lt.semver, String(c), options)) {
            return false;
          }
        }
        if (!c.operator && (lt || gt) && gtltComp !== 0) {
          return false;
        }
      }
      if (gt && hasDomLT && !lt && gtltComp !== 0) {
        return false;
      }
      if (lt && hasDomGT && !gt && gtltComp !== 0) {
        return false;
      }
      if (needDomGTPre || needDomLTPre) {
        return false;
      }
      return true;
    };
    var higherGT = (a, b, options) => {
      if (!a) {
        return b;
      }
      const comp = compare(a.semver, b.semver, options);
      return comp > 0 ? a : comp < 0 ? b : b.operator === ">" && a.operator === ">=" ? b : a;
    };
    var lowerLT = (a, b, options) => {
      if (!a) {
        return b;
      }
      const comp = compare(a.semver, b.semver, options);
      return comp < 0 ? a : comp > 0 ? b : b.operator === "<" && a.operator === "<=" ? b : a;
    };
    module2.exports = subset;
  }
});

// ../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/index.js
var require_semver2 = __commonJS({
  "../../node_modules/.pnpm/semver@7.5.2/node_modules/semver/index.js"(exports, module2) {
    var internalRe = require_re();
    var constants = require_constants();
    var SemVer = require_semver();
    var identifiers = require_identifiers();
    var parse = require_parse();
    var valid = require_valid();
    var clean = require_clean();
    var inc = require_inc();
    var diff = require_diff();
    var major = require_major();
    var minor = require_minor();
    var patch = require_patch();
    var prerelease = require_prerelease();
    var compare = require_compare();
    var rcompare = require_rcompare();
    var compareLoose = require_compare_loose();
    var compareBuild = require_compare_build();
    var sort = require_sort();
    var rsort = require_rsort();
    var gt = require_gt();
    var lt = require_lt();
    var eq = require_eq();
    var neq = require_neq();
    var gte = require_gte();
    var lte = require_lte();
    var cmp = require_cmp();
    var coerce = require_coerce();
    var Comparator = require_comparator();
    var Range = require_range();
    var satisfies = require_satisfies();
    var toComparators = require_to_comparators();
    var maxSatisfying = require_max_satisfying();
    var minSatisfying = require_min_satisfying();
    var minVersion = require_min_version();
    var validRange = require_valid2();
    var outside = require_outside();
    var gtr = require_gtr();
    var ltr = require_ltr();
    var intersects = require_intersects();
    var simplifyRange = require_simplify();
    var subset = require_subset();
    module2.exports = {
      parse,
      valid,
      clean,
      inc,
      diff,
      major,
      minor,
      patch,
      prerelease,
      compare,
      rcompare,
      compareLoose,
      compareBuild,
      sort,
      rsort,
      gt,
      lt,
      eq,
      neq,
      gte,
      lte,
      cmp,
      coerce,
      Comparator,
      Range,
      satisfies,
      toComparators,
      maxSatisfying,
      minSatisfying,
      minVersion,
      validRange,
      outside,
      gtr,
      ltr,
      intersects,
      simplifyRange,
      subset,
      SemVer,
      re: internalRe.re,
      src: internalRe.src,
      tokens: internalRe.t,
      SEMVER_SPEC_VERSION: constants.SEMVER_SPEC_VERSION,
      RELEASE_TYPES: constants.RELEASE_TYPES,
      compareIdentifiers: identifiers.compareIdentifiers,
      rcompareIdentifiers: identifiers.rcompareIdentifiers
    };
  }
});

// src/index.ts
var src_exports = {};
__export(src_exports, {
  build: () => build3,
  prepareCache: () => prepareCache,
  version: () => version
});
module.exports = __toCommonJS(src_exports);

// src/build-vite.ts
var import_fs2 = require("fs");
var import_path2 = require("path");
var import_error_utils = require("@vercel/error-utils");
var import_nft = require("@vercel/nft");
var import_build_utils3 = require("@vercel/build-utils");

// src/utils.ts
var import_semver = __toESM(require_semver2());
var import_fs = require("fs");
var import_path = require("path");
var import_build_utils = require("@vercel/build-utils");
var import_build_utils2 = require("@vercel/build-utils");
var import_module = require("module");
var import_path_to_regexp = require("path-to-regexp");
var import_path_to_regexp_updated = require("path-to-regexp-updated");
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
function pathToRegexp(callerId, path, keys, options) {
  const newKeys = cloneKeys(keys);
  const currentRegExp = (0, import_path_to_regexp.pathToRegexp)(path, keys, options);
  try {
    const currentKeys = keys;
    const newRegExp = (0, import_path_to_regexp_updated.pathToRegexp)(path, newKeys, options);
    const isDiffRegExp = currentRegExp.toString() !== newRegExp.toString();
    if (process.env.FORCE_PATH_TO_REGEXP_LOG || isDiffRegExp) {
      const message = JSON.stringify({
        path,
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
      path,
      error: error.message
    });
    console.error(`[vc] PATH TO REGEXP ERROR @ #${callerId}: ${message}`);
  }
  return currentRegExp;
}
var require_ = (0, import_module.createRequire)(__filename);
var SPLAT_PATH = "/:params*";
var entryExts = [".js", ".jsx", ".ts", ".tsx"];
function findEntry(dir, basename5) {
  for (const ext of entryExts) {
    const file = (0, import_path.resolve)(dir, basename5 + ext);
    if ((0, import_fs.existsSync)(file))
      return (0, import_path.relative)(dir, file);
  }
  return void 0;
}
var configExts = [".js", ".cjs", ".mjs"];
function findConfig(dir, basename5, exts = configExts) {
  for (const ext of exts) {
    const name = basename5 + ext;
    const file = (0, import_path.join)(dir, name);
    if ((0, import_fs.existsSync)(file))
      return file;
  }
  return void 0;
}
function isEdgeRuntime(runtime) {
  return runtime === "edge" || runtime === "experimental-edge";
}
function getResolvedRouteConfig(route, routes, configs, isHydrogen2) {
  let runtime;
  let regions;
  let maxDuration;
  let memory;
  for (const currentRoute of getRouteIterator(route, routes)) {
    const staticConfig = configs.get(currentRoute);
    if (staticConfig) {
      if (typeof runtime === "undefined" && staticConfig.runtime) {
        runtime = isEdgeRuntime(staticConfig.runtime) ? "edge" : "nodejs";
      }
      if (typeof regions === "undefined") {
        regions = staticConfig.regions;
      }
      if (typeof maxDuration === "undefined") {
        maxDuration = staticConfig.maxDuration;
      }
      if (typeof memory === "undefined") {
        memory = staticConfig.memory;
      }
    }
  }
  if (Array.isArray(regions)) {
    regions = Array.from(new Set(regions)).sort();
  }
  if (isHydrogen2 || runtime === "edge") {
    return { runtime: "edge", regions };
  }
  if (regions && !Array.isArray(regions)) {
    throw new Error(
      `"regions" for route "${route.id}" must be an array of strings`
    );
  }
  return { runtime: "nodejs", regions, maxDuration, memory };
}
function calculateRouteConfigHash(config) {
  const str = JSON.stringify(config);
  return Buffer.from(str).toString("base64url");
}
function isLayoutRoute(routeId, routes) {
  return routes.some((r) => r.parentId === routeId);
}
function* getRouteIterator(route, routes) {
  let currentRoute = route;
  do {
    yield currentRoute;
    if (currentRoute.parentId) {
      currentRoute = routes[currentRoute.parentId];
    } else {
      break;
    }
  } while (currentRoute);
}
function getPathFromRoute(input, routes) {
  let route = input;
  if (route.id === "root" || !route.path && route.index || route.path === "/") {
    route = { ...route, path: "index" };
  }
  const pathParts = [];
  const rePathParts = [];
  for (const currentRoute of getRouteIterator(route, routes)) {
    if (!currentRoute.path)
      continue;
    const currentRouteParts = currentRoute.path.split("/").reverse();
    for (const part of currentRouteParts) {
      if (part.endsWith("?")) {
        if (part.startsWith(":")) {
          pathParts.push(`(${part.substring(0, part.length - 1)})`);
          rePathParts.push(part);
        } else {
          const p = `(${part.substring(0, part.length - 1)})`;
          pathParts.push(p);
          rePathParts.push(`${p}?`);
        }
      } else {
        pathParts.push(part);
        rePathParts.push(part);
      }
    }
  }
  if (pathParts.length > 1 && pathParts[0] === "index") {
    pathParts.shift();
    rePathParts.shift();
  }
  const path = pathParts.reverse().join("/");
  let rePath = rePathParts.reverse().join("/");
  rePath = rePath === "*" ? SPLAT_PATH : `/${rePath.replace(/\/\*$/, SPLAT_PATH)}`;
  return { path, rePath };
}
function getRegExpFromPath(rePath) {
  const keys = [];
  const re = pathToRegexp("923", rePath, keys);
  return keys.length > 0 ? re : false;
}
async function chdirAndReadConfig(remixRunDevPath, dir, packageJsonPath) {
  const { readConfig } = await import((0, import_path.join)(remixRunDevPath, "dist/config.js"));
  const originalCwd = process.cwd();
  let modifiedPackageJson = false;
  const pkgRaw = await import_fs.promises.readFile(packageJsonPath, "utf8");
  const pkg = JSON.parse(pkgRaw);
  if (!pkg.dependencies?.["isbot"]) {
    pkg.dependencies.isbot = "latest";
    await import_fs.promises.writeFile(packageJsonPath, JSON.stringify(pkg));
    modifiedPackageJson = true;
  }
  const warn = console.warn;
  console.warn = import_build_utils.debug;
  let remixConfig;
  try {
    process.chdir(dir);
    remixConfig = await readConfig(dir);
  } finally {
    console.warn = warn;
    process.chdir(originalCwd);
    if (modifiedPackageJson) {
      await import_fs.promises.writeFile(packageJsonPath, pkgRaw);
    }
  }
  return remixConfig;
}
function resolveSemverMinMax(min, max, version2) {
  const floored = import_semver.default.intersects(version2, `>= ${min}`) ? version2 : min;
  return import_semver.default.intersects(floored, `<= ${max}`) ? floored : max;
}
async function ensureResolvable(start, base, pkgName) {
  try {
    const resolvedPkgPath = require_.resolve(`${pkgName}/package.json`, {
      paths: [start]
    });
    const resolvedPath = (0, import_path.dirname)(resolvedPkgPath);
    if (!(0, import_path.relative)(base, resolvedPath).startsWith(`..${import_path.sep}`)) {
      (0, import_build_utils.debug)(`"${pkgName}" resolved to '${resolvedPath}'`);
      return resolvedPath;
    }
  } catch (err) {
    if (err.code !== "MODULE_NOT_FOUND") {
      throw err;
    }
  }
  const pnpmDir = await (0, import_build_utils2.walkParentDirs)({
    base,
    start,
    filename: "node_modules/.pnpm"
  });
  if (pnpmDir) {
    const prefix = `${pkgName.replace("/", "+")}@`;
    const packages = await import_fs.promises.readdir(pnpmDir);
    const match = packages.find((p) => p.startsWith(prefix));
    if (match) {
      const pkgDir = (0, import_path.join)(pnpmDir, match, "node_modules", pkgName);
      await ensureSymlink(pkgDir, (0, import_path.join)(start, "node_modules"), pkgName);
      return pkgDir;
    }
  }
  const npmDir = await (0, import_build_utils2.walkParentDirs)({
    base,
    start,
    filename: "node_modules/.store"
  });
  if (npmDir) {
    const prefix = `${(0, import_path.basename)(pkgName)}@`;
    const prefixDir = (0, import_path.join)(npmDir, (0, import_path.dirname)(pkgName));
    const packages = await import_fs.promises.readdir(prefixDir);
    const match = packages.find((p) => p.startsWith(prefix));
    if (match) {
      const pkgDir = (0, import_path.join)(prefixDir, match, "node_modules", pkgName);
      await ensureSymlink(pkgDir, (0, import_path.join)(start, "node_modules"), pkgName);
      return pkgDir;
    }
  }
  throw new Error(
    `Failed to resolve "${pkgName}". To fix this error, add "${pkgName}" to "dependencies" in your \`package.json\` file.`
  );
}
async function ensureSymlink(target, nodeModulesDir, pkgName) {
  const symlinkPath = (0, import_path.join)(nodeModulesDir, pkgName);
  const symlinkDir = (0, import_path.dirname)(symlinkPath);
  const relativeTarget = (0, import_path.relative)(symlinkDir, target);
  try {
    const existingTarget = await import_fs.promises.readlink(symlinkPath);
    if (existingTarget === relativeTarget) {
      return;
    } else {
      await import_fs.promises.unlink(symlinkPath);
    }
  } catch (err) {
    if (err.code !== "ENOENT" && err.code !== "EINVAL") {
      throw err;
    }
  }
  await import_fs.promises.mkdir(symlinkDir, { recursive: true });
  await import_fs.promises.symlink(relativeTarget, symlinkPath);
  (0, import_build_utils.debug)(`Created symlink for "${pkgName}"`);
}
async function isESM(remixConfigPath) {
  switch ((0, import_path.extname)(remixConfigPath)) {
    case ".mjs": {
      return true;
    }
    case ".cjs": {
      return false;
    }
    default: {
      if (import_semver.default.gte(process.version, "20.19.0")) {
        const { type } = JSON.parse(
          await import_fs.promises.readFile(
            (0, import_path.join)((0, import_path.dirname)(remixConfigPath), "package.json"),
            "utf8"
          )
        );
        if (type === "module") {
          return true;
        }
      }
      try {
        require_(remixConfigPath);
        return false;
      } catch (err) {
        return err.code === "ERR_REQUIRE_ESM";
      }
    }
  }
}
function hasScript(scriptName, pkg) {
  const scripts = pkg?.scripts || {};
  return typeof scripts[scriptName] === "string";
}
async function getPackageVersion(name, dir, base) {
  const resolvedPath = require_.resolve(name, { paths: [dir] });
  const pkgPath = await (0, import_build_utils2.walkParentDirs)({
    base,
    start: (0, import_path.dirname)(resolvedPath),
    filename: "package.json"
  });
  if (!pkgPath) {
    throw new Error(`Failed to find \`package.json\` file for "${name}"`);
  }
  const { version: version2 } = JSON.parse(
    await import_fs.promises.readFile(pkgPath, "utf8")
  );
  if (typeof version2 !== "string") {
    throw new Error(`Missing "version" field`);
  }
  return version2;
}
function logNftWarnings(warnings, required) {
  for (const warning of warnings) {
    const m = warning.message.match(/^Failed to resolve dependency "(.+)"/);
    if (m) {
      if (m[1] === required) {
        throw new Error(
          `Missing required "${required}" package. Please add it to your \`package.json\` file.`
        );
      } else {
        console.warn(`WARN: ${m[0]}`);
      }
    } else {
      (0, import_build_utils.debug)(`Warning from trace: ${warning.message}`);
    }
  }
}
function isVite(dir) {
  const viteConfig = findConfig(dir, "vite.config", [
    ".js",
    ".ts",
    ".mjs",
    ".mts"
  ]);
  if (!viteConfig)
    return false;
  const remixConfig = findConfig(dir, "remix.config");
  if (!remixConfig)
    return true;
  const pkg = JSON.parse(
    (0, import_fs.readFileSync)((0, import_path.join)(dir, "package.json"), "utf8")
  );
  if (pkg.scripts?.build && /\bvite:build\b/.test(pkg.scripts.build)) {
    return true;
  }
  const viteConfigContents = (0, import_fs.readFileSync)(viteConfig, "utf8");
  if (/['"]@remix-run\/dev['"]/.test(viteConfigContents)) {
    return true;
  }
  return false;
}

// src/build-vite.ts
var DEFAULTS_PATH = (0, import_path2.join)(__dirname, "../defaults");
var edgeServerSrcPromise = import_fs2.promises.readFile(
  (0, import_path2.join)(DEFAULTS_PATH, "server-edge.mjs"),
  "utf-8"
);
var nodeServerSrcPromise = import_fs2.promises.readFile(
  (0, import_path2.join)(DEFAULTS_PATH, "server-node.mjs"),
  "utf-8"
);
var reactRouterServerSrcPromise = import_fs2.promises.readFile(
  (0, import_path2.join)(DEFAULTS_PATH, "server-react-router.mjs"),
  "utf-8"
);
var COMMON_NODE_RUNTIME_SETTINGS = {
  traceFunction: traceNodeFiles,
  createRuntimeFunction: createNodeFunction
};
var COMMON_EDGE_RUNTIME_SETTINGS = {
  traceFunction: traceEdgeFiles,
  createRuntimeFunction: createEdgeFunction
};
var REMIX_FRAMEWORK_SETTINGS = {
  primaryPackageName: "@remix-run/dev",
  buildCommand: "remix build",
  buildResultFilePath: ".vercel/remix-build-result.json",
  presetDocumentationLink: "https://vercel.com/docs/frameworks/remix#vercel-vite-preset",
  slug: "remix",
  sourceSearchValue: "@remix-run/dev/server-build",
  edge: {
    ...COMMON_EDGE_RUNTIME_SETTINGS,
    serverSourcePromise: edgeServerSrcPromise,
    traceWarningTag: "@remix-run/server-runtime"
  },
  node: {
    ...COMMON_NODE_RUNTIME_SETTINGS,
    serverSourcePromise: nodeServerSrcPromise,
    traceWarningTag: "@remix-run/node",
    options: {}
  },
  getRuntimeSettings(runtime) {
    if (runtime === "edge") {
      return this.edge;
    }
    return this.node;
  },
  createRenderFunction({
    nodeVersion,
    entrypointDir,
    rootDir,
    serverBuildPath,
    serverEntryPoint,
    frameworkVersion,
    config
  }) {
    return createRenderFunction({
      entrypointDir,
      rootDir,
      serverBuildPath,
      serverEntryPoint,
      frameworkVersion,
      config,
      frameworkRuntimeSettings: this.getRuntimeSettings(config.runtime),
      sourceSearchValue: this.sourceSearchValue,
      frameworkSlug: this.slug,
      nodeVersion
    });
  }
};
var REACT_ROUTER_FRAMEWORK_SETTINGS = {
  primaryPackageName: "react-router",
  buildCommand: "react-router build",
  buildResultFilePath: ".vercel/react-router-build-result.json",
  presetDocumentationLink: "https://vercel.com/docs/frameworks/react-router#vercel-react-router-preset",
  slug: "react-router",
  sourceSearchValue: "virtual:react-router/server-build",
  // React Router uses the same server source for both node and edge
  edge: {
    ...COMMON_EDGE_RUNTIME_SETTINGS,
    serverSourcePromise: reactRouterServerSrcPromise,
    traceWarningTag: "react-router"
  },
  node: {
    ...COMMON_NODE_RUNTIME_SETTINGS,
    serverSourcePromise: reactRouterServerSrcPromise,
    traceWarningTag: "react-router",
    options: { useWebApi: true }
  },
  getRuntimeSettings(runtime) {
    if (runtime === "edge") {
      return this.edge;
    }
    return this.node;
  },
  createRenderFunction({
    nodeVersion,
    entrypointDir,
    rootDir,
    serverBuildPath,
    serverEntryPoint,
    frameworkVersion,
    config
  }) {
    return createRenderFunction({
      entrypointDir,
      rootDir,
      serverBuildPath,
      serverEntryPoint,
      frameworkVersion,
      config,
      frameworkRuntimeSettings: this.getRuntimeSettings(config.runtime),
      sourceSearchValue: this.sourceSearchValue,
      frameworkSlug: this.slug,
      nodeVersion
    });
  }
};
async function determineHandler({
  rootDir,
  serverBuildPath,
  serverEntryPoint,
  serverSourcePromise,
  sourceSearchValue
}) {
  let handler = (0, import_path2.relative)(rootDir, serverBuildPath);
  let handlerPath = (0, import_path2.join)(rootDir, handler);
  if (!serverEntryPoint) {
    const baseServerBuildPath = (0, import_path2.basename)(serverBuildPath, ".js");
    handler = (0, import_path2.join)((0, import_path2.dirname)(handler), `server-${baseServerBuildPath}.mjs`);
    handlerPath = (0, import_path2.join)(rootDir, handler);
    const serverSource = await serverSourcePromise;
    await import_fs2.promises.writeFile(
      handlerPath,
      serverSource.replace(sourceSearchValue, `./${baseServerBuildPath}.js`)
    );
  }
  return { handler, handlerPath };
}
var build = async ({
  entrypoint,
  workPath,
  repoRootPath,
  config,
  meta = {}
}) => {
  const { installCommand, buildCommand } = config;
  const mountpoint = (0, import_path2.dirname)(entrypoint);
  const entrypointFsDirname = (0, import_path2.join)(workPath, mountpoint);
  const frameworkSettings = config.framework === "react-router" ? REACT_ROUTER_FRAMEWORK_SETTINGS : REMIX_FRAMEWORK_SETTINGS;
  const nodeVersion = await (0, import_build_utils3.getNodeVersion)(
    entrypointFsDirname,
    void 0,
    config,
    meta
  );
  const {
    cliType,
    lockfileVersion,
    packageJson,
    packageJsonPackageManager,
    turboSupportsCorepackHome
  } = await (0, import_build_utils3.scanParentDirs)(entrypointFsDirname, true);
  const spawnEnv = (0, import_build_utils3.getEnvForPackageManager)({
    cliType,
    lockfileVersion,
    packageJsonPackageManager,
    env: process.env,
    turboSupportsCorepackHome,
    projectCreatedAt: config.projectSettings?.createdAt
  });
  if (typeof installCommand === "string") {
    if (installCommand.trim()) {
      console.log(`Running "install" command: \`${installCommand}\`...`);
      await (0, import_build_utils3.execCommand)(installCommand, {
        env: spawnEnv,
        cwd: entrypointFsDirname
      });
    } else {
      console.log(`Skipping "install" command...`);
    }
  } else {
    await (0, import_build_utils3.runNpmInstall)(
      entrypointFsDirname,
      [],
      { env: spawnEnv },
      meta,
      config.projectSettings?.createdAt
    );
  }
  const frameworkVersion = await getPackageVersion(
    frameworkSettings.primaryPackageName,
    entrypointFsDirname,
    repoRootPath
  );
  if (buildCommand) {
    (0, import_build_utils3.debug)(`Executing build command "${buildCommand}"`);
    await (0, import_build_utils3.execCommand)(buildCommand, {
      env: spawnEnv,
      cwd: entrypointFsDirname
    });
  } else {
    if (hasScript("vercel-build", packageJson)) {
      (0, import_build_utils3.debug)(`Executing "vercel-build" script`);
      await (0, import_build_utils3.runPackageJsonScript)(
        entrypointFsDirname,
        "vercel-build",
        { env: spawnEnv },
        config.projectSettings?.createdAt
      );
    } else if (hasScript("build", packageJson)) {
      (0, import_build_utils3.debug)(`Executing "build" script`);
      await (0, import_build_utils3.runPackageJsonScript)(
        entrypointFsDirname,
        "build",
        { env: spawnEnv },
        config.projectSettings?.createdAt
      );
    } else {
      await (0, import_build_utils3.execCommand)(frameworkSettings.buildCommand, {
        env: spawnEnv,
        cwd: entrypointFsDirname
      });
    }
  }
  const buildOutputPath = (0, import_path2.join)(entrypointFsDirname, ".vercel/output");
  let buildOutputVersion;
  try {
    const boaConfigPath = (0, import_path2.join)(buildOutputPath, "config.json");
    const buildResultContents = await import_fs2.promises.readFile(boaConfigPath, "utf8");
    buildOutputVersion = JSON.parse(buildResultContents).version;
  } catch (err) {
    if ((0, import_error_utils.isErrnoException)(err) && err.code === "ENOENT") {
    } else {
      (0, import_build_utils3.debug)(
        `Error reading ".vercel/output/config.json": ${(0, import_error_utils.errorToString)(err)}`
      );
    }
  }
  if (buildOutputVersion) {
    if (buildOutputVersion !== 3) {
      throw new Error(
        `The "version" property in ".vercel/output/config.json" must be 3 (received ${buildOutputVersion})`
      );
    }
    return { buildOutputVersion: 3, buildOutputPath };
  }
  const buildResultJsonPath = (0, import_path2.join)(
    entrypointFsDirname,
    frameworkSettings.buildResultFilePath
  );
  let buildResult;
  try {
    const buildResultContents = (0, import_fs2.readFileSync)(buildResultJsonPath, "utf8");
    buildResult = JSON.parse(buildResultContents);
  } catch (err) {
    if (!(0, import_error_utils.isErrnoException)(err) || err.code !== "ENOENT") {
      throw err;
    }
    const buildDirectory2 = (0, import_path2.join)(entrypointFsDirname, "build");
    if ((0, import_fs2.statSync)(buildDirectory2).isDirectory()) {
      console.warn("WARN: The `vercelPreset()` Preset was not detected.");
      console.warn(
        `See ${frameworkSettings.presetDocumentationLink} for more information`
      );
      buildResult = {
        buildManifest: {
          routes: {
            root: {
              path: "",
              id: "root",
              file: "app/root.tsx",
              config: {}
            },
            "routes/_index": {
              file: "app/routes/_index.tsx",
              id: "routes/_index",
              index: true,
              parentId: "root",
              config: {}
            }
          }
        },
        remixConfig: {
          buildDirectory: buildDirectory2
        }
      };
      const serverPath = "build/server/index.js";
      if ((0, import_fs2.existsSync)((0, import_path2.join)(entrypointFsDirname, serverPath))) {
        buildResult.buildManifest.routeIdToServerBundleId = {
          "routes/_index": ""
        };
        buildResult.buildManifest.serverBundles = {
          "": {
            id: "",
            file: serverPath,
            config: {}
          }
        };
      }
    }
  }
  if (!buildResult) {
    throw new Error(
      `Could not determine build output directory. Please configure the \`vercelPreset()\` Preset from the \`@vercel/${frameworkSettings.slug}\` npm package`
    );
  }
  const { buildManifest, viteConfig } = buildResult;
  const buildDirectory = "remixConfig" in buildResult ? buildResult.remixConfig.buildDirectory : buildResult.reactRouterConfig.buildDirectory;
  const staticDir = (0, import_path2.join)(buildDirectory, "client");
  const serverBundles = Object.values(buildManifest.serverBundles ?? {});
  const [staticFiles, ...functions] = await Promise.all([
    (0, import_build_utils3.glob)("**", staticDir),
    ...serverBundles.map((bundle) => {
      return frameworkSettings.createRenderFunction({
        nodeVersion,
        entrypointDir: entrypointFsDirname,
        rootDir: repoRootPath,
        serverBuildPath: (0, import_path2.join)(entrypointFsDirname, bundle.file),
        serverEntryPoint: void 0,
        frameworkVersion,
        config: bundle.config
      });
    })
  ]);
  const functionsMap = /* @__PURE__ */ new Map();
  for (let i = 0; i < serverBundles.length; i++) {
    functionsMap.set(serverBundles[i].id, functions[i]);
  }
  const output = staticFiles;
  const assetsDir = viteConfig?.build?.assetsDir || "assets";
  const routes = [
    {
      src: `^/${assetsDir}/(.*)$`,
      headers: { "cache-control": "public, max-age=31536000, immutable" },
      continue: true
    },
    {
      handle: "filesystem"
    }
  ];
  for (const [id, functionId] of Object.entries(
    buildManifest.routeIdToServerBundleId ?? {}
  )) {
    const route = buildManifest.routes[id];
    const { path, rePath } = getPathFromRoute(route, buildManifest.routes);
    if (!path) {
      continue;
    }
    const func = functionsMap.get(functionId);
    if (!func) {
      throw new Error(`Could not determine server bundle for "${id}"`);
    }
    output[path] = func;
    const re = getRegExpFromPath(rePath);
    if (re) {
      routes.push({
        src: re.source,
        dest: path
      });
    }
  }
  routes.push({
    src: "/(.*)",
    dest: "/"
  });
  return { routes, output, framework: { version: frameworkVersion } };
};
async function traceEdgeFiles({
  handlerPath,
  rootDir,
  entrypointDir
}) {
  const EDGE_TRACE_CONDITIONS = [
    "edge-light",
    "browser",
    "module",
    "import",
    "require"
  ];
  async function edgeReadFile(fsPath) {
    let source;
    try {
      source = await import_fs2.promises.readFile(fsPath);
    } catch (err) {
      if (err.code === "ENOENT" || err.code === "EISDIR") {
        return null;
      }
      throw err;
    }
    if ((0, import_path2.basename)(fsPath) === "package.json") {
      const pkgJson = JSON.parse(source.toString());
      for (const prop of ["browser", "module"]) {
        const val = pkgJson[prop];
        if (typeof val === "string") {
          pkgJson.main = val;
          source = JSON.stringify(pkgJson);
          break;
        }
      }
    }
    return source;
  }
  return await (0, import_nft.nodeFileTrace)([handlerPath], {
    base: rootDir,
    processCwd: entrypointDir,
    conditions: EDGE_TRACE_CONDITIONS,
    readFile: edgeReadFile
  });
}
async function traceNodeFiles({
  handlerPath,
  rootDir,
  entrypointDir
}) {
  return await (0, import_nft.nodeFileTrace)([handlerPath], {
    base: rootDir,
    processCwd: entrypointDir
  });
}
async function getFilesFromTrace({
  fileList,
  rootDir
}) {
  const files = {};
  for (const file of fileList) {
    files[file] = await import_build_utils3.FileFsRef.fromFsPath({ fsPath: (0, import_path2.join)(rootDir, file) });
  }
  return files;
}
function createEdgeFunction({
  files,
  handler,
  config,
  frameworkSlug,
  frameworkVersion
}) {
  return new import_build_utils3.EdgeFunction({
    deploymentTarget: "v8-worker",
    files,
    entrypoint: handler,
    regions: config.regions,
    framework: {
      slug: frameworkSlug,
      version: frameworkVersion
    }
  });
}
function createNodeFunction({
  files,
  handler,
  config,
  frameworkSlug,
  frameworkVersion,
  nodeVersion,
  useWebApi
}) {
  return new import_build_utils3.NodejsLambda({
    shouldAddHelpers: false,
    shouldAddSourcemapSupport: false,
    operationType: "SSR",
    supportsResponseStreaming: true,
    files,
    handler,
    runtime: nodeVersion.runtime,
    regions: config.regions,
    memory: config.memory,
    maxDuration: config.maxDuration,
    useWebApi,
    framework: {
      slug: frameworkSlug,
      version: frameworkVersion
    },
    shouldDisableAutomaticFetchInstrumentation: process.env.VERCEL_TRACING_DISABLE_AUTOMATIC_FETCH_INSTRUMENTATION === "1"
  });
}
async function createRenderFunction({
  rootDir,
  serverBuildPath,
  serverEntryPoint,
  entrypointDir,
  config,
  frameworkVersion,
  frameworkRuntimeSettings,
  sourceSearchValue,
  frameworkSlug,
  nodeVersion
}) {
  const { handler, handlerPath } = await determineHandler({
    rootDir,
    serverBuildPath,
    serverEntryPoint,
    serverSourcePromise: frameworkRuntimeSettings.serverSourcePromise,
    sourceSearchValue
  });
  const trace = await frameworkRuntimeSettings.traceFunction({
    handlerPath,
    rootDir,
    entrypointDir
  });
  logNftWarnings(trace.warnings, frameworkRuntimeSettings.traceWarningTag);
  const files = await getFilesFromTrace({ fileList: trace.fileList, rootDir });
  const fn = frameworkRuntimeSettings.createRuntimeFunction({
    files,
    handler,
    config,
    frameworkSlug,
    frameworkVersion,
    nodeVersion,
    useWebApi: frameworkRuntimeSettings.options?.useWebApi
  });
  return fn;
}

// src/build-legacy.ts
var import_ts_morph2 = require("ts-morph");
var import_fs3 = require("fs");
var import_path4 = require("path");
var import_build_utils4 = require("@vercel/build-utils");
var import_static_config = require("@vercel/static-config");
var import_nft2 = require("@vercel/nft");

// src/hydrogen.ts
var import_path3 = require("path");
var import_ts_morph = require("ts-morph");
function patchHydrogenServer(project, serverEntryPoint) {
  const sourceFile = project.addSourceFileAtPath(serverEntryPoint);
  const defaultExportSymbol = sourceFile.getDescendantsOfKind(
    import_ts_morph.SyntaxKind.ExportAssignment
  )[0];
  const envProperties = [];
  if (!defaultExportSymbol) {
    console.log(
      `WARN: No default export found in "${(0, import_path3.basename)(serverEntryPoint)}"`
    );
    return;
  }
  const objectLiteral = defaultExportSymbol.getFirstChildByKind(
    import_ts_morph.SyntaxKind.ObjectLiteralExpression
  );
  if (!import_ts_morph.Node.isObjectLiteralExpression(objectLiteral)) {
    console.log(
      `WARN: Default export in "${(0, import_path3.basename)(
        serverEntryPoint
      )}" does not conform to Oxygen syntax`
    );
    return;
  }
  const fetchMethod = objectLiteral.getProperty("fetch");
  if (!fetchMethod || !import_ts_morph.Node.isMethodDeclaration(fetchMethod)) {
    console.log(
      `WARN: Default export in "${(0, import_path3.basename)(
        serverEntryPoint
      )}" does not conform to Oxygen syntax`
    );
    return;
  }
  const parameters = fetchMethod.getParameters();
  const envParam = parameters[1];
  const envParamName = envParam.getName();
  if (envParam) {
    fetchMethod.forEachDescendant((node) => {
      if (import_ts_morph.Node.isPropertyAccessExpression(node) && node.getExpression().getText() === envParamName) {
        envProperties.push(node.getName());
      }
    });
  }
  fetchMethod.forEachDescendant((node) => {
    if (import_ts_morph.Node.isCallExpression(node) && node.getExpression().getText() === "caches.open") {
      node.replaceWithText(`undefined /* ${node.getText()} */`);
    }
  });
  parameters.splice(1, 1);
  const newFunction = `export default async function(${parameters.map((p) => p.getText()).join(", ")}) ${fetchMethod.getBody().getText()}`;
  defaultExportSymbol.replaceWithText(newFunction);
  const defaultEnvVars = {
    SESSION_SECRET: "foobar",
    PUBLIC_STORE_DOMAIN: "mock.shop"
  };
  const envCode = `const env = { ${envProperties.map((name) => `${name}: process.env.${name}`).join(", ")} };
${Object.entries(defaultEnvVars).map(
    ([k, v]) => `if (!env.${k}) { env.${k} = ${JSON.stringify(
      v
    )}; console.warn('Warning: ${JSON.stringify(
      k
    )} env var not set - using default value ${JSON.stringify(v)}'); }`
  ).join("\n")}`;
  const updatedCodeString = sourceFile.getFullText();
  return `${envCode}
${updatedCodeString}`;
}

// src/build-legacy.ts
var DEFAULTS_PATH2 = (0, import_path4.join)(__dirname, "../defaults");
var edgeServerSrcPromise2 = import_fs3.promises.readFile(
  (0, import_path4.join)(DEFAULTS_PATH2, "server-edge.mjs"),
  "utf-8"
);
var nodeServerSrcPromise2 = import_fs3.promises.readFile(
  (0, import_path4.join)(DEFAULTS_PATH2, "server-node.mjs"),
  "utf-8"
);
var VERCEL_REMIX_MIN_VERSION = "1.10.0";
var VERCEL_REMIX_RUN_DEV_MIN_VERSION = "1.15.0";
var { VERCEL_REMIX_RUN_DEV_MAX_VERSION } = JSON.parse(
  (0, import_fs3.readFileSync)((0, import_path4.join)(__dirname, "../package.json"), "utf8")
);
var build2 = async ({
  entrypoint,
  files,
  workPath,
  repoRootPath,
  config,
  meta = {}
}) => {
  const { installCommand, buildCommand } = config;
  await (0, import_build_utils4.download)(files, workPath, meta);
  const mountpoint = (0, import_path4.dirname)(entrypoint);
  const entrypointFsDirname = (0, import_path4.join)(workPath, mountpoint);
  const nodeVersion = await (0, import_build_utils4.getNodeVersion)(
    entrypointFsDirname,
    void 0,
    config,
    meta
  );
  const {
    cliType,
    packageJsonPath,
    lockfileVersion,
    lockfilePath,
    packageJsonPackageManager,
    turboSupportsCorepackHome
  } = await (0, import_build_utils4.scanParentDirs)(entrypointFsDirname, true);
  if (!packageJsonPath) {
    throw new Error("Failed to locate `package.json` file in your project");
  }
  const [lockfileRaw, pkgRaw] = await Promise.all([
    lockfilePath ? import_fs3.promises.readFile(lockfilePath) : null,
    import_fs3.promises.readFile(packageJsonPath, "utf8")
  ]);
  const pkg = JSON.parse(pkgRaw);
  const spawnEnv = (0, import_build_utils4.getEnvForPackageManager)({
    cliType,
    lockfileVersion,
    packageJsonPackageManager,
    env: process.env,
    turboSupportsCorepackHome,
    projectCreatedAt: config.projectSettings?.createdAt
  });
  if (typeof installCommand === "string") {
    if (installCommand.trim()) {
      console.log(`Running "install" command: \`${installCommand}\`...`);
      await (0, import_build_utils4.execCommand)(installCommand, {
        env: spawnEnv,
        cwd: entrypointFsDirname
      });
    } else {
      console.log(`Skipping "install" command...`);
    }
  } else {
    await (0, import_build_utils4.runNpmInstall)(
      entrypointFsDirname,
      [],
      { env: spawnEnv },
      meta,
      config.projectSettings?.createdAt
    );
  }
  const isHydrogen2 = Boolean(
    pkg.dependencies?.["@shopify/remix-oxygen"] || pkg.devDependencies?.["@shopify/remix-oxygen"]
  );
  const remixRunDevPath = await ensureResolvable(
    entrypointFsDirname,
    repoRootPath,
    "@remix-run/dev"
  );
  const remixRunDevPkg = JSON.parse(
    (0, import_fs3.readFileSync)((0, import_path4.join)(remixRunDevPath, "package.json"), "utf8")
  );
  const remixVersion = remixRunDevPkg.version;
  const remixConfig = await chdirAndReadConfig(
    remixRunDevPath,
    entrypointFsDirname,
    packageJsonPath
  );
  const { serverEntryPoint, appDirectory } = remixConfig;
  const remixRoutes = Object.values(remixConfig.routes);
  let depsModified = false;
  const remixRunDevPkgVersion = pkg.dependencies?.["@remix-run/dev"] || pkg.devDependencies?.["@remix-run/dev"];
  const serverBundlesMap = /* @__PURE__ */ new Map();
  const resolvedConfigsMap = /* @__PURE__ */ new Map();
  const project = new import_ts_morph2.Project();
  const staticConfigsMap = /* @__PURE__ */ new Map();
  for (const route of remixRoutes) {
    const routePath = (0, import_path4.join)(remixConfig.appDirectory, route.file);
    let staticConfig = (0, import_static_config.getConfig)(project, routePath);
    if (staticConfig && isHydrogen2) {
      console.log(
        "WARN: `export const config` is currently not supported for Hydrogen v2 apps"
      );
      staticConfig = null;
    }
    staticConfigsMap.set(route, staticConfig);
  }
  for (const route of remixRoutes) {
    const config2 = getResolvedRouteConfig(
      route,
      remixConfig.routes,
      staticConfigsMap,
      isHydrogen2
    );
    resolvedConfigsMap.set(route, config2);
  }
  for (const route of remixRoutes) {
    if (isLayoutRoute(route.id, remixRoutes))
      continue;
    const config2 = resolvedConfigsMap.get(route);
    if (!config2) {
      throw new Error(`Expected resolved config for "${route.id}"`);
    }
    const hash = calculateRouteConfigHash(config2);
    let routesForHash = serverBundlesMap.get(hash);
    if (!Array.isArray(routesForHash)) {
      routesForHash = [];
      serverBundlesMap.set(hash, routesForHash);
    }
    routesForHash.push(route);
  }
  let serverBundles = Array.from(
    serverBundlesMap.entries()
  ).map(([hash, routes2]) => {
    const runtime = resolvedConfigsMap.get(routes2[0])?.runtime ?? "nodejs";
    return {
      serverBuildPath: isHydrogen2 ? (0, import_path4.relative)(entrypointFsDirname, remixConfig.serverBuildPath) : `${(0, import_path4.relative)(
        entrypointFsDirname,
        (0, import_path4.dirname)(remixConfig.serverBuildPath)
      )}/build-${runtime}-${hash}.js`,
      routes: routes2.map((r) => r.id)
    };
  });
  if (!isHydrogen2 && serverBundles.length === 1) {
    serverBundles[0].serverBuildPath = "build/index.js";
  }
  if (serverBundles.length > 1 && !isHydrogen2 && remixRunDevPkg.name !== "@vercel/remix-run-dev" && !remixRunDevPkgVersion?.startsWith("https:")) {
    const remixDevForkVersion = resolveSemverMinMax(
      VERCEL_REMIX_RUN_DEV_MIN_VERSION,
      VERCEL_REMIX_RUN_DEV_MAX_VERSION,
      remixVersion
    );
    if (pkg.devDependencies["@remix-run/dev"]) {
      delete pkg.devDependencies["@remix-run/dev"];
      pkg.devDependencies["@vercel/remix-run-dev"] = remixDevForkVersion;
    } else {
      delete pkg.dependencies["@remix-run/dev"];
      pkg.dependencies["@vercel/remix-run-dev"] = remixDevForkVersion;
    }
    depsModified = true;
  }
  const userEntryServerFile = findEntry(appDirectory, "entry.server");
  if (!userEntryServerFile) {
    await import_fs3.promises.copyFile(
      (0, import_path4.join)(DEFAULTS_PATH2, "entry.server.jsx"),
      (0, import_path4.join)(appDirectory, "entry.server.jsx")
    );
    if (!pkg.dependencies["@vercel/remix"]) {
      const vercelRemixVersion = resolveSemverMinMax(
        VERCEL_REMIX_MIN_VERSION,
        VERCEL_REMIX_RUN_DEV_MAX_VERSION,
        remixVersion
      );
      pkg.dependencies["@vercel/remix"] = vercelRemixVersion;
      depsModified = true;
    }
  }
  if (depsModified) {
    await import_fs3.promises.writeFile(packageJsonPath, JSON.stringify(pkg, null, 2) + "\n");
    const nonCiEnv = { ...process.env };
    delete nonCiEnv.CI;
    delete nonCiEnv.VERCEL;
    delete nonCiEnv.NOW_BUILDER;
    await (0, import_build_utils4.runNpmInstall)(
      entrypointFsDirname,
      [],
      {
        env: nonCiEnv
      },
      void 0,
      config.projectSettings?.createdAt
    );
  }
  const userEntryClientFile = findEntry(
    remixConfig.appDirectory,
    "entry.client"
  );
  if (!userEntryClientFile) {
    await import_fs3.promises.copyFile(
      (0, import_path4.join)(DEFAULTS_PATH2, "entry.client.react.jsx"),
      (0, import_path4.join)(appDirectory, "entry.client.jsx")
    );
  }
  let remixConfigWrapped = false;
  let serverEntryPointAbs;
  let originalServerEntryPoint;
  const remixConfigPath = findConfig(entrypointFsDirname, "remix.config");
  const renamedRemixConfigPath = remixConfigPath ? `${remixConfigPath}.original${(0, import_path4.extname)(remixConfigPath)}` : void 0;
  try {
    if (!isHydrogen2 && remixConfigPath && renamedRemixConfigPath) {
      await import_fs3.promises.rename(remixConfigPath, renamedRemixConfigPath);
      let patchedConfig;
      if (await isESM(renamedRemixConfigPath)) {
        patchedConfig = `import config from './${(0, import_path4.basename)(
          renamedRemixConfigPath
        )}';
config.serverBuildTarget = undefined;
config.serverModuleFormat = '${pkg.type === "module" ? "esm" : "cjs"}';
config.serverPlatform = 'node';
config.serverBuildPath = undefined;
config.serverBundles = ${JSON.stringify(serverBundles)};
export default config;`;
      } else {
        patchedConfig = `const config = require('./${(0, import_path4.basename)(
          renamedRemixConfigPath
        )}');
config.serverBuildTarget = undefined;
config.serverModuleFormat = '${pkg.type === "module" ? "esm" : "cjs"}';
config.serverPlatform = 'node';
config.serverBuildPath = undefined;
config.serverBundles = ${JSON.stringify(serverBundles)};
module.exports = config;`;
      }
      await import_fs3.promises.writeFile(remixConfigPath, patchedConfig);
      remixConfigWrapped = true;
    }
    if (isHydrogen2) {
      if (remixConfig.serverEntryPoint) {
        serverEntryPointAbs = (0, import_path4.join)(
          entrypointFsDirname,
          remixConfig.serverEntryPoint
        );
        originalServerEntryPoint = await import_fs3.promises.readFile(
          serverEntryPointAbs,
          "utf8"
        );
        const patchedServerEntryPoint = patchHydrogenServer(
          project,
          serverEntryPointAbs
        );
        if (patchedServerEntryPoint) {
          (0, import_build_utils4.debug)(
            `Patched Hydrogen server file: ${remixConfig.serverEntryPoint}`
          );
          await import_fs3.promises.writeFile(serverEntryPointAbs, patchedServerEntryPoint);
        }
      } else {
        console.log('WARN: No "server" field found in Remix config');
      }
    }
    spawnEnv.NODE_ENV = "production";
    if (buildCommand) {
      (0, import_build_utils4.debug)(`Executing build command "${buildCommand}"`);
      await (0, import_build_utils4.execCommand)(buildCommand, {
        env: spawnEnv,
        cwd: entrypointFsDirname
      });
    } else {
      if (hasScript2("vercel-build", pkg)) {
        (0, import_build_utils4.debug)(`Executing "yarn vercel-build"`);
        await (0, import_build_utils4.runPackageJsonScript)(
          entrypointFsDirname,
          "vercel-build",
          { env: spawnEnv },
          config.projectSettings?.createdAt
        );
      } else if (hasScript2("build", pkg)) {
        (0, import_build_utils4.debug)(`Executing "yarn build"`);
        await (0, import_build_utils4.runPackageJsonScript)(
          entrypointFsDirname,
          "build",
          { env: spawnEnv },
          config.projectSettings?.createdAt
        );
      } else {
        await (0, import_build_utils4.execCommand)("remix build", {
          env: spawnEnv,
          cwd: entrypointFsDirname
        });
      }
    }
  } finally {
    const cleanupOps = [];
    if (remixConfigWrapped && remixConfigPath && renamedRemixConfigPath) {
      cleanupOps.push(
        import_fs3.promises.rename(renamedRemixConfigPath, remixConfigPath).then(() => (0, import_build_utils4.debug)(`Restored original "${remixConfigPath}" file`))
      );
    }
    if (serverEntryPointAbs && originalServerEntryPoint) {
      cleanupOps.push(
        import_fs3.promises.writeFile(serverEntryPointAbs, originalServerEntryPoint).then(() => (0, import_build_utils4.debug)(`Restored original "${serverEntryPointAbs}" file`))
      );
    }
    if (depsModified) {
      cleanupOps.push(
        import_fs3.promises.writeFile(packageJsonPath, pkgRaw).then(() => (0, import_build_utils4.debug)(`Restored original "${packageJsonPath}" file`))
      );
      if (lockfilePath && lockfileRaw) {
        cleanupOps.push(
          import_fs3.promises.writeFile(lockfilePath, lockfileRaw).then(() => (0, import_build_utils4.debug)(`Restored original "${lockfilePath}" file`))
        );
      }
    }
    await Promise.all(cleanupOps);
  }
  await Promise.all([
    ensureResolvable(
      entrypointFsDirname,
      repoRootPath,
      "@remix-run/server-runtime"
    ),
    !isHydrogen2 ? ensureResolvable(entrypointFsDirname, repoRootPath, "@remix-run/node") : null
  ]);
  const staticDir = (0, import_path4.join)(entrypointFsDirname, "public");
  const serverBundlesRespected = (0, import_fs3.existsSync)(
    (0, import_path4.join)(entrypointFsDirname, serverBundles[0].serverBuildPath)
  );
  if (!serverBundlesRespected) {
    console.warn(
      "WARN: `serverBundles` configuration failed. Falling back to a singular server bundle."
    );
    serverBundles = [
      {
        serverBuildPath: "build/index.js",
        routes: serverBundles.flatMap((b) => b.routes)
      }
    ];
  }
  const [staticFiles, buildAssets, ...functions] = await Promise.all([
    (0, import_build_utils4.glob)("**", staticDir),
    (0, import_build_utils4.glob)("**", remixConfig.assetsBuildDirectory),
    ...serverBundles.map((bundle) => {
      const firstRoute = remixConfig.routes[bundle.routes[0]];
      const config2 = resolvedConfigsMap.get(firstRoute) ?? {
        runtime: "nodejs"
      };
      const serverBuildPath = (0, import_path4.join)(entrypointFsDirname, bundle.serverBuildPath);
      if (config2.runtime === "edge") {
        return createRenderEdgeFunction(
          entrypointFsDirname,
          repoRootPath,
          serverBuildPath,
          serverEntryPoint,
          remixVersion,
          config2
        );
      }
      return createRenderNodeFunction(
        nodeVersion,
        entrypointFsDirname,
        repoRootPath,
        serverBuildPath,
        serverEntryPoint,
        remixVersion,
        config2
      );
    })
  ]);
  const transformedBuildAssets = (0, import_build_utils4.rename)(buildAssets, (name) => {
    return import_path4.posix.join("./", remixConfig.publicPath, name);
  });
  const output = {
    ...staticFiles,
    ...transformedBuildAssets
  };
  const routes = [
    {
      src: `^/${remixConfig.publicPath.replace(/^\/|\/$/g, "")}/(.*)$`,
      headers: { "cache-control": "public, max-age=31536000, immutable" },
      continue: true
    },
    {
      handle: "filesystem"
    }
  ];
  for (const route of remixRoutes) {
    if (isLayoutRoute(route.id, remixRoutes))
      continue;
    const { path, rePath } = getPathFromRoute(route, remixConfig.routes);
    if (!path) {
      continue;
    }
    const funcIndex = serverBundles.findIndex((bundle) => {
      return bundle.routes.includes(route.id);
    });
    const func = functions[funcIndex];
    if (!func) {
      throw new Error(`Could not determine server bundle for "${route.id}"`);
    }
    output[path] = func;
    const re = getRegExpFromPath(rePath);
    if (re) {
      routes.push({
        src: re.source,
        dest: path
      });
    }
  }
  if (!output["404"]) {
    const edgeFunctionIndex = Array.from(serverBundlesMap.values()).findIndex(
      (routes2) => {
        const runtime = resolvedConfigsMap.get(routes2[0])?.runtime;
        return runtime === "edge";
      }
    );
    const func = edgeFunctionIndex !== -1 ? functions[edgeFunctionIndex] : functions[0];
    output["404"] = func;
  }
  routes.push({
    src: "/(.*)",
    dest: "/404"
  });
  return { routes, output, framework: { version: remixVersion } };
};
function hasScript2(scriptName, pkg) {
  const scripts = pkg && pkg.scripts || {};
  return typeof scripts[scriptName] === "string";
}
async function createRenderNodeFunction(nodeVersion, entrypointDir, rootDir, serverBuildPath, serverEntryPoint, remixVersion, config) {
  const files = {};
  let handler = (0, import_path4.relative)(rootDir, serverBuildPath);
  let handlerPath = (0, import_path4.join)(rootDir, handler);
  if (!serverEntryPoint) {
    const baseServerBuildPath = (0, import_path4.basename)(serverBuildPath, ".js");
    handler = (0, import_path4.join)((0, import_path4.dirname)(handler), `server-${baseServerBuildPath}.mjs`);
    handlerPath = (0, import_path4.join)(rootDir, handler);
    const nodeServerSrc = await nodeServerSrcPromise2;
    await writeEntrypointFile(
      handlerPath,
      nodeServerSrc.replace(
        "@remix-run/dev/server-build",
        `./${baseServerBuildPath}.js`
      ),
      rootDir
    );
  }
  const trace = await (0, import_nft2.nodeFileTrace)([handlerPath], {
    base: rootDir,
    processCwd: entrypointDir
  });
  for (const warning of trace.warnings) {
    (0, import_build_utils4.debug)(`Warning from trace: ${warning.message}`);
  }
  for (const file of trace.fileList) {
    files[file] = await import_build_utils4.FileFsRef.fromFsPath({ fsPath: (0, import_path4.join)(rootDir, file) });
  }
  const fn = new import_build_utils4.NodejsLambda({
    files,
    handler,
    runtime: nodeVersion.runtime,
    shouldAddHelpers: false,
    shouldAddSourcemapSupport: false,
    operationType: "SSR",
    supportsResponseStreaming: true,
    regions: config.regions,
    memory: config.memory,
    maxDuration: config.maxDuration,
    framework: {
      slug: "remix",
      version: remixVersion
    },
    shouldDisableAutomaticFetchInstrumentation: process.env.VERCEL_TRACING_DISABLE_AUTOMATIC_FETCH_INSTRUMENTATION === "1"
  });
  return fn;
}
async function createRenderEdgeFunction(entrypointDir, rootDir, serverBuildPath, serverEntryPoint, remixVersion, config) {
  const files = {};
  let handler = (0, import_path4.relative)(rootDir, serverBuildPath);
  let handlerPath = (0, import_path4.join)(rootDir, handler);
  if (!serverEntryPoint) {
    const baseServerBuildPath = (0, import_path4.basename)(serverBuildPath, ".js");
    handler = (0, import_path4.join)((0, import_path4.dirname)(handler), `server-${baseServerBuildPath}.mjs`);
    handlerPath = (0, import_path4.join)(rootDir, handler);
    const edgeServerSrc = await edgeServerSrcPromise2;
    await writeEntrypointFile(
      handlerPath,
      edgeServerSrc.replace(
        "@remix-run/dev/server-build",
        `./${baseServerBuildPath}.js`
      ),
      rootDir
    );
  }
  let remixRunVercelPkgJson;
  const trace = await (0, import_nft2.nodeFileTrace)([handlerPath], {
    base: rootDir,
    processCwd: entrypointDir,
    conditions: ["edge-light", "browser", "module", "import", "require"],
    async readFile(fsPath) {
      let source;
      try {
        source = await import_fs3.promises.readFile(fsPath);
      } catch (err) {
        if (err.code === "ENOENT" || err.code === "EISDIR") {
          return null;
        }
        throw err;
      }
      if ((0, import_path4.basename)(fsPath) === "package.json") {
        const pkgJson = JSON.parse(source.toString());
        if (pkgJson.name === "@remix-run/vercel") {
          pkgJson.browser = "dist/edge.js";
          pkgJson.dependencies["@remix-run/server-runtime"] = pkgJson.dependencies["@remix-run/node"];
          if (!remixRunVercelPkgJson) {
            remixRunVercelPkgJson = JSON.stringify(pkgJson, null, 2) + "\n";
            const vercelEdgeEntrypointPath = (0, import_path4.join)(
              DEFAULTS_PATH2,
              "vercel-edge-entrypoint.js"
            );
            const vercelEdgeEntrypointDest = (0, import_path4.join)(
              (0, import_path4.dirname)(fsPath),
              "dist/edge.js"
            );
            await import_fs3.promises.copyFile(
              vercelEdgeEntrypointPath,
              vercelEdgeEntrypointDest
            );
          }
        }
        for (const prop of ["browser", "module"]) {
          const val = pkgJson[prop];
          if (typeof val === "string") {
            pkgJson.main = val;
            source = JSON.stringify(pkgJson);
            break;
          }
        }
      }
      return source;
    }
  });
  for (const warning of trace.warnings) {
    (0, import_build_utils4.debug)(`Warning from trace: ${warning.message}`);
  }
  for (const file of trace.fileList) {
    if (remixRunVercelPkgJson && file.endsWith(`@remix-run${import_path4.sep}vercel${import_path4.sep}package.json`)) {
      files[file] = new import_build_utils4.FileBlob({ data: remixRunVercelPkgJson });
    } else {
      files[file] = await import_build_utils4.FileFsRef.fromFsPath({ fsPath: (0, import_path4.join)(rootDir, file) });
    }
  }
  const fn = new import_build_utils4.EdgeFunction({
    files,
    deploymentTarget: "v8-worker",
    entrypoint: handler,
    regions: config.regions,
    framework: {
      slug: "remix",
      version: remixVersion
    }
  });
  return fn;
}
async function writeEntrypointFile(path, data, rootDir) {
  try {
    await import_fs3.promises.writeFile(path, data);
  } catch (err) {
    if (err.code === "ENOENT") {
      throw new Error(
        `The "${(0, import_path4.relative)(rootDir, (0, import_path4.dirname)(path))}" directory does not exist.`
      );
    }
    throw err;
  }
}

// src/build.ts
var build3 = (opts) => {
  return isVite(opts.workPath) ? build(opts) : build2(opts);
};

// src/prepare-cache.ts
var import_build_utils5 = require("@vercel/build-utils");
var import_path5 = require("path");
var prepareCache = async ({
  entrypoint,
  repoRootPath,
  workPath,
  config
}) => {
  const root = repoRootPath || workPath;
  const mountpoint = (0, import_path5.dirname)(entrypoint);
  const entrypointFsDirname = (0, import_path5.join)(workPath, mountpoint);
  let cacheDirFiles;
  if (!isVite(workPath)) {
    await (0, import_build_utils5.runNpmInstall)(
      entrypointFsDirname,
      [],
      {
        stdio: "ignore"
      },
      void 0,
      config.projectSettings?.createdAt
    );
    const packageJsonPath = (0, import_path5.join)(entrypointFsDirname, "package.json");
    const remixRunDevPath = (0, import_path5.dirname)(
      require_.resolve("@remix-run/dev/package.json", {
        paths: [entrypointFsDirname]
      })
    );
    const remixConfig = await chdirAndReadConfig(
      remixRunDevPath,
      entrypointFsDirname,
      packageJsonPath
    );
    cacheDirFiles = await (0, import_build_utils5.glob)(
      (0, import_path5.relative)(root, (0, import_path5.join)(remixConfig.cacheDirectory, "**")),
      root
    );
  }
  const defaultCacheFiles = await (0, import_build_utils5.glob)(import_build_utils5.defaultCachePathGlob, root);
  return { ...defaultCacheFiles, ...cacheDirFiles };
};

// src/index.ts
var version = 2;
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  build,
  prepareCache,
  version
});
