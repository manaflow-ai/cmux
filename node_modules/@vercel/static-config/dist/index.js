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
var src_exports = {};
__export(src_exports, {
  BaseFunctionConfigSchema: () => BaseFunctionConfigSchema,
  getConfig: () => getConfig
});
module.exports = __toCommonJS(src_exports);
var import_ts_morph = require("ts-morph");
var import_validation = require("./validation");
const BaseFunctionConfigSchema = {
  type: "object",
  properties: {
    architecture: {
      type: "string",
      enum: ["x86_64", "arm64"]
    },
    runtime: { type: "string" },
    memory: { type: "number" },
    maxDuration: { type: "number" },
    supportsCancellation: {
      type: "boolean"
    },
    regions: {
      oneOf: [
        {
          type: "array",
          items: { type: "string" }
        },
        {
          enum: ["all", "default", "auto"]
        }
      ]
    },
    preferredRegion: {
      oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }]
    }
  }
};
function getConfig(project, sourcePath, schema) {
  const sourceFile = project.addSourceFileAtPath(sourcePath);
  const configNode = getConfigNode(sourceFile);
  if (!configNode)
    return null;
  const config = getValue(configNode);
  return (0, import_validation.validate)(schema || BaseFunctionConfigSchema, config);
}
function getConfigNode(sourceFile) {
  return sourceFile.getDescendantsOfKind(import_ts_morph.SyntaxKind.ObjectLiteralExpression).find((objectLiteral) => {
    const varDec = objectLiteral.getParentIfKind(
      import_ts_morph.SyntaxKind.VariableDeclaration
    );
    if (varDec?.getName() !== "config")
      return false;
    const varDecList = varDec.getParentIfKind(
      import_ts_morph.SyntaxKind.VariableDeclarationList
    );
    const isConst = (varDecList?.getFlags() ?? 0) & import_ts_morph.NodeFlags.Const;
    if (!isConst)
      return false;
    const exp = varDecList?.getParentIfKind(import_ts_morph.SyntaxKind.VariableStatement);
    if (!exp?.isExported())
      return false;
    return true;
  });
}
function getValue(valueNode) {
  if (import_ts_morph.Node.isStringLiteral(valueNode)) {
    return eval(valueNode.getText());
  } else if (import_ts_morph.Node.isNumericLiteral(valueNode)) {
    return Number(valueNode.getText());
  } else if (import_ts_morph.Node.isTrueLiteral(valueNode)) {
    return true;
  } else if (import_ts_morph.Node.isFalseLiteral(valueNode)) {
    return false;
  } else if (import_ts_morph.Node.isNullLiteral(valueNode)) {
    return null;
  } else if (import_ts_morph.Node.isArrayLiteralExpression(valueNode)) {
    return getArray(valueNode);
  } else if (import_ts_morph.Node.isObjectLiteralExpression(valueNode)) {
    return getObject(valueNode);
  } else if (import_ts_morph.Node.isIdentifier(valueNode) && valueNode.getText() === "undefined") {
    return void 0;
  }
  throw new Error(
    `Unhandled type: "${valueNode.getKindName()}" ${valueNode.getText()}`
  );
}
function getObject(obj) {
  const rtn = {};
  for (const prop of obj.getProperties()) {
    if (!import_ts_morph.Node.isPropertyAssignment(prop))
      continue;
    const [nameNode, _colon, valueNode2] = prop.getChildren();
    const name = nameNode.getText();
    rtn[name] = getValue(valueNode2);
  }
  return rtn;
}
function getArray(arr) {
  const elementNodes = arr.getElements();
  const rtn = new Array(elementNodes.length);
  for (let i = 0; i < elementNodes.length; i++) {
    rtn[i] = getValue(elementNodes[i]);
  }
  return rtn;
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  BaseFunctionConfigSchema,
  getConfig
});
