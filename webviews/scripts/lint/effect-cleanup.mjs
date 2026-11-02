// ESLint-compatible rule, shared by vp lint and the blocking effect-cleanup check.
const functions = new Set(["ArrowFunctionExpression", "FunctionExpression", "FunctionDeclaration"]);
const hooks = new Set(["useEffect", "useLayoutEffect", "useInsertionEffect"]);
const globals = new Set(["window", "globalThis", "self"]);

export const intervalCleanup = {
  meta: {
    type: "problem",
    schema: [],
    messages: {
      cleanup: "Return an effect cleanup that clears this interval's handle on every exit after it starts.",
    },
  },
  create(context) {
    const source = context.sourceCode;
    const intervals = [];
    const effects = [];
    const variable = (node) => {
      if (node?.type !== "Identifier") return undefined;
      for (let scope = source.getScope(node); scope; scope = scope.upper) {
        const found = scope.set.get(node.name);
        if (found) return found;
      }
    };
    const isGlobal = (node) => !variable(node)?.defs.length;
    const isTimer = (node, name) =>
      (node?.type === "Identifier" && node.name === name && isGlobal(node)) ||
      (node?.type === "MemberExpression" &&
        !node.computed &&
        node.property.name === name &&
        globals.has(node.object.name) &&
        isGlobal(node.object));
    const imported = (node, names) =>
      variable(node)?.defs.some(
        (def) =>
          def.type === "ImportBinding" &&
          def.parent.source.value === "react" &&
          def.node.type === "ImportSpecifier" &&
          names.has(def.node.imported.name),
      );
    const isEffect = (node) =>
      imported(node, hooks) ||
      (node?.type === "MemberExpression" &&
        !node.computed &&
        hooks.has(node.property.name) &&
        variable(node.object)?.defs.some(
          (def) =>
            def.type === "ImportBinding" &&
            def.parent.source.value === "react" &&
            ["ImportNamespaceSpecifier", "ImportDefaultSpecifier"].includes(def.node.type),
        ));
    const resolveFunction = (node) => {
      if (functions.has(node?.type)) return node;
      const binding = variable(node);
      // Reading only the declaration would wrongly accept a cleanup function
      // replaced later with a no-op.
      if (binding?.references.some((reference) => reference.isWrite() && !reference.init)) return undefined;
      const def = binding?.defs[0];
      if (def?.type === "FunctionName") return def.node;
      if (functions.has(def?.node?.init?.type)) return def.node.init;
    };
    // Use the parser's visitor keys so TS annotations and parent links cannot
    // accidentally be treated as executable expressions.
    function walk(node, visit, descendFunctions = true) {
      if (!node) return;
      visit(node);
      if (!descendFunctions && functions.has(node.type)) return;
      for (const key of source.visitorKeys[node.type] ?? []) {
        const value = node[key];
        for (const child of Array.isArray(value) ? value : [value]) {
          if (child?.type) walk(child, visit, descendFunctions);
        }
      }
    }
    function sameHandle(node, handle) {
      return node?.type === "Identifier" && variable(node) === handle;
    }
    function writesHandle(node, handle) {
      if (!node) return false;
      if (sameHandle(node, handle)) return true;
      if (node.type === "ArrayPattern" || node.type === "ObjectPattern") {
        return (
          node.elements?.some((child) => writesHandle(child, handle)) ||
          node.properties?.some((child) => writesHandle(child.value ?? child.argument, handle))
        );
      }
      if (node.type === "AssignmentPattern") return writesHandle(node.left, handle);
      if (node.type === "RestElement") return writesHandle(node.argument, handle);
      return false;
    }
    function clears(node, handle, seen = new Set()) {
      if (!node || seen.has(node)) return false;
      seen = new Set([...seen, node]);
      if (node.type === "CallExpression") {
        if (isTimer(node.callee, "clearInterval") && sameHandle(node.arguments[0], handle)) return true;
        const called = resolveFunction(node.callee);
        return called && !called.async ? clears(called.body, handle, seen) : false;
      }
      if (node.type === "ExpressionStatement") return clears(node.expression, handle, seen);
      if (node.type === "ReturnStatement") return clears(node.argument, handle, seen);
      if (node.type === "BlockStatement") {
        for (const statement of node.body) {
          if (clears(statement, handle, seen)) return true;
          // A return before clearInterval makes the latter unreachable.
          if (["ReturnStatement", "ThrowStatement"].includes(statement.type)) return false;
          let suspends = false;
          walk(
            statement,
            (child) => {
              if (child.type === "AwaitExpression") suspends = true;
            },
            false,
          );
          if (suspends) return false;
          if (exits(statement)) return false;
        }
        return false;
      }
      if (node.type === "IfStatement") {
        // Guarding an optional handle is safe; a random condition isn't cleanup.
        if (sameHandle(node.test, handle)) return clears(node.consequent, handle, seen);
        if (
          node.test.type === "BinaryExpression" &&
          ["!=", "!=="].includes(node.test.operator) &&
          sameHandle(node.test.left, handle) &&
          ((node.test.right.type === "Literal" && node.test.right.value === null) ||
            (node.test.right.type === "Identifier" &&
              node.test.right.name === "undefined" &&
              isGlobal(node.test.right)))
        ) {
          return clears(node.consequent, handle, seen);
        }
        return clears(node.consequent, handle, seen) && clears(node.alternate, handle, seen);
      }
      if (node.type === "LogicalExpression" && node.operator === "&&" && sameHandle(node.left, handle)) {
        return clears(node.right, handle, seen);
      }
      if (node.type === "TryStatement") return clears(node.finalizer, handle, seen);
      // Do not count an uncalled nested function or asynchronous callback.
      return false;
    }
    function exits(node) {
      let exit = false;
      walk(
        node,
        (child) => {
          if (["ReturnStatement", "ThrowStatement"].includes(child.type)) exit = true;
        },
        false,
      );
      return exit;
    }
    // Track whether this specific interval has started along each effect path.
    // An inactive branch may fall through without returning any cleanup.
    function effectCleans(effect, interval, handle) {
      let valid = true;
      const containsStart = (node) => {
        let found = false;
        walk(node, (child) => {
          if (child === interval) found = true;
        });
        return found;
      };
      const cleanup = (node) => {
        const fn = resolveFunction(node);
        if (!fn || fn.async) return false;
        let starts = false;
        const visited = new Set();
        function inspect(called) {
          if (visited.has(called)) return;
          visited.add(called);
          walk(called.body, (child) => {
            if (child.type !== "CallExpression") return;
            if (isTimer(child.callee, "setInterval")) starts = true;
            const helper = resolveFunction(child.callee);
            if (helper) inspect(helper);
          });
        }
        inspect(fn);
        return !starts && clears(fn.body, handle);
      };
      function flow(node, started) {
        if (!node) return [started];
        if (node.type === "BlockStatement") {
          let paths = [started];
          for (const statement of node.body) paths = [...new Set(paths.flatMap((path) => flow(statement, path)))];
          return paths;
        }
        if (node.type === "IfStatement") {
          const active = started || containsStart(node.test);
          return [...flow(node.consequent, active), ...flow(node.alternate, active)];
        }
        if (node.type === "ReturnStatement") {
          if ((started || containsStart(node.argument)) && !cleanup(node.argument)) valid = false;
          return [];
        }
        if (node.type === "ThrowStatement") {
          if (started || containsStart(node.argument)) valid = false;
          return [];
        }
        // Complex control flow is conservative: an exit can bypass the later
        // cleanup return. Do not silently approve paths we cannot establish.
        if (exits(node)) {
          if (started || containsStart(node)) valid = false;
        }
        return [started || containsStart(node)];
      }
      const remaining = flow(effect.body, false);
      return valid && !remaining.includes(true);
    }
    function overwritten(effect, interval, handle) {
      const writes = [];
      walk(effect.body, (node) => {
        if (node.type === "AssignmentExpression" && writesHandle(node.left, handle)) writes.push(node);
        if (node.type === "UpdateExpression" && writesHandle(node.argument, handle)) writes.push(node);
      });
      return writes.some((write) => {
        // A later assignment must release the old handle first. Also inspect
        // assignments inside callbacks that may run again after the first start.
        if (
          write.range[0] < interval.range[0] &&
          write.parent.type === "ExpressionStatement" &&
          write.parent.parent === effect.body
        )
          return false;
        if (
          write === interval.parent &&
          writes.length === 1 &&
          write.parent.type === "ExpressionStatement" &&
          write.parent.parent === effect.body
        )
          return false;
        let statement = write;
        while (statement.parent && statement.parent.type !== "BlockStatement") statement = statement.parent;
        const block = statement.parent;
        if (!block || block.type !== "BlockStatement") return true;
        // The closest prior lifetime operation must be a synchronous clear.
        for (const previous of block.body.slice(0, block.body.indexOf(statement)).reverse()) {
          if (clears(previous, handle)) return false;
          let starts = false;
          walk(
            previous,
            (child) => {
              if (child.type === "CallExpression" && isTimer(child.callee, "setInterval")) starts = true;
            },
            false,
          );
          if (starts) return true;
        }
        return true;
      });
    }
    function check(effect, interval) {
      let assignment = interval.parent;
      while (["ConditionalExpression", "LogicalExpression", "TSAsExpression"].includes(assignment?.type)) {
        assignment = assignment.parent;
      }
      const target =
        assignment?.type === "VariableDeclarator"
          ? assignment.id
          : assignment?.type === "AssignmentExpression"
            ? assignment.left
            : undefined;
      const handle = variable(target);
      // A local binding has stable identity at teardown. Mutable ref.current
      // handles must first be captured locally, so a later write cannot leak it.
      let scopeOwner = handle?.scope.block;
      while (scopeOwner && scopeOwner !== effect) scopeOwner = scopeOwner.parent;
      if (!handle || !scopeOwner || effect.async || overwritten(effect, interval, handle)) return false;
      return effectCleans(effect, interval, handle);
    }
    return {
      CallExpression(node) {
        if (isTimer(node.callee, "setInterval")) intervals.push(node);
        if (isEffect(node.callee)) {
          function register(callback) {
            const direct = resolveFunction(callback);
            if (direct) {
              if (!effects.includes(direct)) effects.push(direct);
            } else if (callback?.type === "ConditionalExpression") {
              register(callback.consequent);
              register(callback.alternate);
            } else if (callback?.type === "LogicalExpression") {
              register(callback.left);
              register(callback.right);
            }
          }
          register(node.arguments[0]);
        }
      },
      "Program:exit"() {
        for (const interval of intervals) {
          // The nearest effect owns it, including intervals started by its local
          // event callbacks. A different effect's cleanup cannot satisfy it.
          let owner;
          for (let parent = interval.parent; parent; parent = parent.parent) {
            if (effects.includes(parent)) {
              owner = parent;
              break;
            }
          }
          if (owner && !check(owner, interval)) context.report({ node: interval, messageId: "cleanup" });
        }
      },
    };
  },
};

export default {
  meta: { name: "cmux-lifecycle" },
  rules: { "effect-interval-cleanup": intervalCleanup },
};
