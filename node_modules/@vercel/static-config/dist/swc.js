"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
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
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var swc_exports = {};
__export(swc_exports, {
  UnsupportedValueError: () => UnsupportedValueError,
  extractExportedConstValue: () => extractExportedConstValue,
  getConfig: () => getConfig
});
module.exports = __toCommonJS(swc_exports);
var import_validation = require("./validation");
class UnsupportedValueError extends Error {
}
function extractValue(node) {
  if (node.type === "NullLiteral") {
    return null;
  } else if (node.type === "BooleanLiteral") {
    return node.value;
  } else if (node.type === "StringLiteral") {
    return node.value;
  } else if (node.type === "NumericLiteral") {
    return node.value;
  } else if (node.type === "Identifier") {
    switch (node.value) {
      case "undefined":
        return void 0;
      default:
        throw new UnsupportedValueError();
    }
  } else if (node.type === "ArrayExpression") {
    const arr = [];
    for (const elem of node.elements) {
      if (elem) {
        if (elem.spread) {
          throw new UnsupportedValueError();
        }
        arr.push(extractValue(elem.expression));
      } else {
        arr.push(void 0);
      }
    }
    return arr;
  } else if (node.type === "ObjectExpression") {
    const obj = {};
    for (const prop of node.properties) {
      if (prop.type !== "KeyValueProperty") {
        throw new UnsupportedValueError();
      }
      let key;
      if (prop.key.type === "Identifier") {
        key = prop.key.value;
      } else if (prop.key.type === "StringLiteral") {
        key = prop.key.value;
      } else {
        throw new UnsupportedValueError();
      }
      obj[key] = extractValue(prop.value);
    }
    return obj;
  } else {
    throw new UnsupportedValueError();
  }
}
function extractExportedConstValue(module2, exportedName) {
  for (const moduleItem of module2.body) {
    if (moduleItem.type !== "ExportDeclaration") {
      continue;
    }
    const { declaration } = moduleItem;
    if (declaration.type !== "VariableDeclaration") {
      continue;
    }
    if (declaration.kind !== "const") {
      continue;
    }
    for (const decl of declaration.declarations) {
      if (decl.id.type === "Identifier" && decl.id.value === exportedName && decl.init) {
        return extractValue(decl.init);
      }
    }
  }
  return null;
}
function getConfig(module2, schema) {
  const data = extractExportedConstValue(module2, "config");
  if (!data) {
    return null;
  }
  if (schema) {
    (0, import_validation.validate)(schema, data);
  }
  return data;
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  UnsupportedValueError,
  extractExportedConstValue,
  getConfig
});
