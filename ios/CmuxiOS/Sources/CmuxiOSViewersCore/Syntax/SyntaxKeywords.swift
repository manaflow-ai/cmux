/// Keyword sets per language family (a value table, not state).
enum SyntaxKeywords {
    static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default",
        "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard",
        "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open", "operator", "private",
        "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super",
        "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while", "package", "consuming", "borrowing",
        "sending", "isolated", "lazy", "weak", "unowned", "mutating", "override", "final", "convenience", "required",
    ]
    static let cFamily: Set<String> = [
        "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "delete", "do", "double",
        "else", "enum", "extern", "false", "final", "float", "for", "fun", "func", "go", "goto", "if", "implements", "import",
        "in", "int", "interface", "is", "long", "map", "namespace", "new", "null", "nullptr", "object", "override", "package",
        "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "string", "struct", "super",
        "switch", "template", "this", "throw", "throws", "true", "try", "typedef", "typename", "union", "unsigned", "using",
        "val", "var", "virtual", "void", "volatile", "when", "while", "chan", "defer", "range", "select", "type", "nil",
        "async", "await", "let", "self", "id", "instancetype", "YES", "NO",
    ]
    static let script: Set<String> = [
        "abstract", "any", "as", "async", "await", "boolean", "break", "case", "catch", "class", "const", "constructor",
        "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally",
        "for", "from", "function", "get", "if", "implements", "import", "in", "infer", "instanceof", "interface", "keyof",
        "let", "namespace", "never", "new", "null", "number", "of", "private", "protected", "public", "readonly", "return",
        "satisfies", "set", "static", "string", "super", "switch", "this", "throw", "true", "try", "type", "typeof",
        "undefined", "unknown", "var", "void", "while", "yield",
    ]
    static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for",
        "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
        "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "defer", "comptime", "try",
        "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "bool", "str", "char",
    ]
    static let python: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
        "pass", "raise", "return", "try", "while", "with", "yield", "self", "match", "case",
    ]
    static let ruby: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
        "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then",
        "true", "undef", "unless", "until", "when", "while", "yield", "require", "attr_reader", "attr_accessor",
    ]
    static let shell: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return",
        "local", "export", "readonly", "set", "unset", "shift", "exit", "echo", "cd", "source", "trap", "eval", "exec",
    ]
    static let sql: Set<String> = [
        "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table",
        "index", "drop", "alter", "add", "primary", "key", "foreign", "references", "join", "left", "right", "inner", "outer",
        "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "null", "is", "in", "like", "between",
        "case", "when", "then", "else", "end", "union", "all", "exists", "default", "unique", "integer", "text", "varchar",
        "boolean", "begin", "commit", "rollback", "returning", "with", "if",
    ]
}
