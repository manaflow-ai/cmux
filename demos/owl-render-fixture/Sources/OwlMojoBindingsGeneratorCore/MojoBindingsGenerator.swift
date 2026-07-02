import Foundation

public struct MojoFile: Equatable {
    public let module: String
    public let declarations: [MojoDeclaration]

    public init(module: String, declarations: [MojoDeclaration]) {
        self.module = module
        self.declarations = declarations
    }
}

public enum MojoDeclaration: Equatable {
    case enumeration(MojoEnum)
    case structure(MojoStruct)
    case interface(MojoInterface)

    public var name: String {
        switch self {
        case .enumeration(let declaration):
            return declaration.name
        case .structure(let declaration):
            return declaration.name
        case .interface(let declaration):
            return declaration.name
        }
    }

    public var kind: String {
        switch self {
        case .enumeration:
            return "enum"
        case .structure:
            return "struct"
        case .interface:
            return "interface"
        }
    }
}

public struct MojoEnum: Equatable {
    public let name: String
    public let cases: [MojoEnumCase]
}

public struct MojoEnumCase: Equatable {
    public let name: String
    public let rawValue: Int
}

public struct MojoStruct: Equatable {
    public let name: String
    public let fields: [MojoField]
}

public struct MojoField: Equatable {
    public let name: String
    public let type: MojoType
}

public struct MojoInterface: Equatable {
    public let name: String
    public let methods: [MojoMethod]
}

public struct MojoMethod: Equatable {
    public let name: String
    public let parameters: [MojoField]
    public let responseParameters: [MojoField]
}

public indirect enum MojoType: Equatable {
    case primitive(String)
    case named(String)
    case array(MojoType)
    case pendingRemote(String)
    case pendingReceiver(String)

    public var mojoName: String {
        switch self {
        case .primitive(let name), .named(let name):
            return name
        case .array(let element):
            return "array<\(element.mojoName)>"
        case .pendingRemote(let name):
            return "pending_remote<\(name)>"
        case .pendingReceiver(let name):
            return "pending_receiver<\(name)>"
        }
    }

    public var swiftName: String {
        switch self {
        case .primitive("bool"):
            return "Bool"
        case .primitive("float"):
            return "Float"
        case .primitive("int32"):
            return "Int32"
        case .primitive("uint8"):
            return "UInt8"
        case .primitive("uint32"):
            return "UInt32"
        case .primitive("uint64"):
            return "UInt64"
        case .primitive("string"):
            return "String"
        case .primitive(let name), .named(let name):
            return name
        case .array(let element):
            return "[\(element.swiftName)]"
        case .pendingRemote(let name):
            return "\(name)Remote"
        case .pendingReceiver(let name):
            return "\(name)Receiver"
        }
    }
}

public enum MojoParserError: Error, CustomStringConvertible {
    case expected(String, got: String?)
    case invalidTopLevel(String)
    case invalidType(String)
    case trailingTokens([String])

    public var description: String {
        switch self {
        case .expected(let expected, let got):
            return "expected \(expected), got \(got ?? "end of file")"
        case .invalidTopLevel(let token):
            return "invalid top-level token: \(token)"
        case .invalidType(let token):
            return "invalid type token: \(token)"
        case .trailingTokens(let tokens):
            return "unexpected trailing tokens: \(tokens.joined(separator: " "))"
        }
    }
}

public enum MojoParser {
    public static func parse(source: String) throws -> MojoFile {
        let tokens = tokenize(source)
        var parser = Parser(tokens: tokens)
        return try parser.parseFile()
    }

    static func tokenize(_ source: String) -> [String] {
        let stripped = source
            .components(separatedBy: .newlines)
            .map { line in
                guard let range = line.range(of: "//") else {
                    return line
                }
                return String(line[..<range.lowerBound])
            }
            .joined(separator: "\n")

        var tokens: [String] = []
        var current = ""
        var index = stripped.startIndex
        let symbols = Set("{}();,=<>")

        func flushCurrent() {
            guard !current.isEmpty else {
                return
            }
            tokens.append(current)
            current.removeAll()
        }

        while index < stripped.endIndex {
            let character = stripped[index]
            if character.isWhitespace {
                flushCurrent()
                index = stripped.index(after: index)
                continue
            }
            if symbols.contains(character) {
                flushCurrent()
                if character == "=" {
                    let next = stripped.index(after: index)
                    if next < stripped.endIndex, stripped[next] == ">" {
                        tokens.append("=>")
                        index = stripped.index(after: next)
                        continue
                    }
                }
                tokens.append(String(character))
                index = stripped.index(after: index)
                continue
            }
            current.append(character)
            index = stripped.index(after: index)
        }

        flushCurrent()
        return tokens
    }
}

private struct Parser {
    var tokens: [String]
    var index = 0

    mutating func parseFile() throws -> MojoFile {
        var module = ""
        var declarations: [MojoDeclaration] = []

        while let token = peek() {
            switch token {
            case "module":
                advance()
                module = try consumeIdentifier()
                try consume(";")
            case "import":
                try skipImport()
            case "enum":
                declarations.append(.enumeration(try parseEnum()))
            case "struct":
                declarations.append(.structure(try parseStruct()))
            case "interface":
                declarations.append(.interface(try parseInterface()))
            default:
                throw MojoParserError.invalidTopLevel(token)
            }
        }

        return MojoFile(module: module, declarations: declarations)
    }

    mutating func parseEnum() throws -> MojoEnum {
        try consume("enum")
        let name = try consumeIdentifier()
        try consume("{")
        var cases: [MojoEnumCase] = []

        while peek() != "}" {
            let caseName = try consumeIdentifier()
            try consume("=")
            guard let rawValue = Int(try consumeIdentifier()) else {
                throw MojoParserError.expected("integer", got: previous())
            }
            try consumeOptional(",")
            cases.append(MojoEnumCase(name: caseName, rawValue: rawValue))
        }

        try consume("}")
        try consume(";")
        return MojoEnum(name: name, cases: cases)
    }

    mutating func parseStruct() throws -> MojoStruct {
        try consume("struct")
        let name = try consumeIdentifier()
        try consume("{")
        var fields: [MojoField] = []

        while peek() != "}" {
            let type = try parseType()
            let name = try consumeIdentifier()
            try consume(";")
            fields.append(MojoField(name: name, type: type))
        }

        try consume("}")
        try consume(";")
        return MojoStruct(name: name, fields: fields)
    }

    mutating func parseInterface() throws -> MojoInterface {
        try consume("interface")
        let name = try consumeIdentifier()
        try consume("{")
        var methods: [MojoMethod] = []

        while peek() != "}" {
            let methodName = try consumeIdentifier()
            let parameters = try parseParameterList()
            var responseParameters: [MojoField] = []
            if peek() == "=>" {
                advance()
                responseParameters = try parseParameterList()
            }
            try consume(";")
            methods.append(MojoMethod(
                name: methodName,
                parameters: parameters,
                responseParameters: responseParameters
            ))
        }

        try consume("}")
        try consume(";")
        return MojoInterface(name: name, methods: methods)
    }

    mutating func parseParameterList() throws -> [MojoField] {
        try consume("(")
        var fields: [MojoField] = []
        while peek() != ")" {
            let type = try parseType()
            let name = try consumeIdentifier()
            fields.append(MojoField(name: name, type: type))
            try consumeOptional(",")
        }
        try consume(")")
        return fields
    }

    mutating func parseType() throws -> MojoType {
        let token = try consumeIdentifier()
        switch token {
        case "array":
            try consume("<")
            let element = try parseType()
            try consume(">")
            return .array(element)
        case "pending_remote":
            try consume("<")
            let name = try consumeIdentifier()
            try consume(">")
            return .pendingRemote(name)
        case "pending_receiver":
            try consume("<")
            let name = try consumeIdentifier()
            try consume(">")
            return .pendingReceiver(name)
        case "bool", "float", "int32", "uint8", "uint32", "uint64", "string":
            return .primitive(token)
        default:
            guard token.first?.isLetter == true else {
                throw MojoParserError.invalidType(token)
            }
            return .named(token)
        }
    }

    mutating func skipImport() throws {
        try consume("import")
        while peek() != ";" {
            guard peek() != nil else {
                throw MojoParserError.expected(";", got: nil)
            }
            advance()
        }
        try consume(";")
    }

    func peek() -> String? {
        guard index < tokens.count else {
            return nil
        }
        return tokens[index]
    }

    func previous() -> String? {
        guard index > 0 else {
            return nil
        }
        return tokens[index - 1]
    }

    mutating func advance() {
        index += 1
    }

    mutating func consume(_ token: String) throws {
        guard peek() == token else {
            throw MojoParserError.expected(token, got: peek())
        }
        advance()
    }

    mutating func consumeOptional(_ token: String) throws {
        if peek() == token {
            advance()
        }
    }

    mutating func consumeIdentifier() throws -> String {
        guard let token = peek() else {
            throw MojoParserError.expected("identifier", got: nil)
        }
        let symbols = Set(["{", "}", "(", ")", ";", ",", "=", "<", ">", "=>"])
        guard !symbols.contains(token) else {
            throw MojoParserError.expected("identifier", got: token)
        }
        advance()
        return token
    }
}

public enum MojoChecksum {
    public static func fnv1a64Hex(_ source: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "fnv1a64:%016llx", hash)
    }
}

public struct SwiftGenerationResult {
    public let swift: String
    public let checksum: String
}

public enum MojoSwiftGenerator {
    public static func generate(file: MojoFile, source: String) -> SwiftGenerationResult {
        let checksum = MojoChecksum.fnv1a64Hex(source)
        var output: [String] = [
            "// Generated from Mojo/OwlFresh.mojom by OwlMojoBindingsGenerator.",
            "// Do not edit by hand.",
            "import Foundation",
            "",
            "public struct MojoPendingRemote<Interface>: Equatable, Codable {",
            "    public let handle: UInt64",
            "",
            "    public init(handle: UInt64) {",
            "        self.handle = handle",
            "    }",
            "}",
            "",
            "public struct MojoPendingReceiver<Interface>: Equatable, Codable {",
            "    public let handle: UInt64",
            "",
            "    public init(handle: UInt64) {",
            "        self.handle = handle",
            "    }",
            "}",
            "",
            "public final class OwlFreshMojoPipeHandleAllocator {",
            "    private var nextHandle: UInt64",
            "",
            "    public init(startingAt firstHandle: UInt64 = 1) {",
            "        self.nextHandle = firstHandle",
            "    }",
            "",
            "    public func makeRemote<Interface>(_ interface: Interface.Type = Interface.self) -> MojoPendingRemote<Interface> {",
            "        MojoPendingRemote(handle: allocate())",
            "    }",
            "",
            "    public func makeReceiver<Interface>(_ interface: Interface.Type = Interface.self) -> MojoPendingReceiver<Interface> {",
            "        MojoPendingReceiver(handle: allocate())",
            "    }",
            "",
            "    private func allocate() -> UInt64 {",
            "        let handle = nextHandle",
            "        nextHandle += 1",
            "        return handle",
            "    }",
            "}",
            "",
            "public struct OwlFreshMojoTransportCall: Equatable, Codable {",
            "    public let interface: String",
            "    public let method: String",
            "    public let payloadType: String",
            "    public let payloadSummary: String",
            "",
            "    public init(interface: String, method: String, payloadType: String, payloadSummary: String) {",
            "        self.interface = interface",
            "        self.method = method",
            "        self.payloadType = payloadType",
            "        self.payloadSummary = payloadSummary",
            "    }",
            "}",
            "",
            "public final class OwlFreshMojoTransportRecorder {",
            "    public private(set) var recordedCalls: [OwlFreshMojoTransportCall] = []",
            "",
            "    public init() {}",
            "",
            "    public func record(interface: String, method: String, payloadType: String, payloadSummary: String) {",
            "        recordedCalls.append(OwlFreshMojoTransportCall(",
            "            interface: interface,",
            "            method: method,",
            "            payloadType: payloadType,",
            "            payloadSummary: payloadSummary",
            "        ))",
            "    }",
            "",
            "    public func reset() {",
            "        recordedCalls.removeAll()",
            "    }",
            "}",
            "",
            "public enum OwlFreshGeneratedMojoTransport {",
            "    public static let name = \"GeneratedOwlFreshMojoTransport\"",
            "}",
            "",
            "private enum MojoJSONCoding {",
            "    static func decodeUInt8<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> UInt8 {",
            "        if let value = try? container.decode(UInt8.self, forKey: key) {",
            "            return value",
            "        }",
            "        if let value = try? container.decode(Int64.self, forKey: key) {",
            "            if value >= 0, value <= Int64(UInt8.max) {",
            "                return UInt8(value)",
            "            }",
            "            guard let signed = Int8(exactly: value) else {",
            "                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: \"signed value cannot wrap to UInt8\")",
            "            }",
            "            return UInt8(bitPattern: signed)",
            "        }",
            "        if let value = try? container.decode(String.self, forKey: key), let parsed = UInt8(value) {",
            "            return parsed",
            "        }",
            "        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: \"expected UInt8-compatible value\")",
            "    }",
            "",
            "    static func decodeUInt32<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> UInt32 {",
            "        if let value = try? container.decode(UInt32.self, forKey: key) {",
            "            return value",
            "        }",
            "        if let value = try? container.decode(Int64.self, forKey: key) {",
            "            if value >= 0, value <= Int64(UInt32.max) {",
            "                return UInt32(value)",
            "            }",
            "            guard let signed = Int32(exactly: value) else {",
            "                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: \"signed value cannot wrap to UInt32\")",
            "            }",
            "            return UInt32(bitPattern: signed)",
            "        }",
            "        if let value = try? container.decode(String.self, forKey: key), let parsed = UInt32(value) {",
            "            return parsed",
            "        }",
            "        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: \"expected UInt32-compatible value\")",
            "    }",
            "",
            "    static func decodeUInt64<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> UInt64 {",
            "        if let value = try? container.decode(UInt64.self, forKey: key) {",
            "            return value",
            "        }",
            "        if let value = try? container.decode(Int64.self, forKey: key) {",
            "            if value >= 0 {",
            "                return UInt64(value)",
            "            }",
            "            return UInt64(bitPattern: value)",
            "        }",
            "        if let value = try? container.decode(String.self, forKey: key), let parsed = UInt64(value) {",
            "            return parsed",
            "        }",
            "        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: \"expected UInt64-compatible value\")",
            "    }",
            "}",
            "",
        ]

        for declaration in file.declarations {
            switch declaration {
            case .enumeration(let enumeration):
                output.append(generateEnum(enumeration))
            case .structure(let structure):
                output.append(generateStruct(structure.name, fields: structure.fields))
            case .interface(let interface):
                output.append(generateInterface(interface))
            }
            output.append("")
        }

        output.append(generatePipeBindings(file: file))
        output.append("")
        output.append(generateSchema(file: file, checksum: checksum))
        output.append("")
        return SwiftGenerationResult(swift: output.joined(separator: "\n"), checksum: checksum)
    }

    private static func generateEnum(_ enumeration: MojoEnum) -> String {
        var lines: [String] = [
            "public enum \(enumeration.name): UInt32, Codable, CaseIterable {",
        ]
        for enumCase in enumeration.cases {
            lines.append("    case \(swiftEnumCaseName(enumCase.name)) = \(enumCase.rawValue)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func generateStruct(_ name: String, fields: [MojoField]) -> String {
        var lines: [String] = [
            "public struct \(name): Equatable, Codable {",
        ]
        for field in fields {
            lines.append("    public let \(swiftPropertyName(field.name)): \(field.type.swiftName)")
        }
        lines.append("")
        let arguments = fields
            .map { field in "\(swiftPropertyName(field.name)): \(field.type.swiftName)" }
            .joined(separator: ", ")
        lines.append("    public init(\(arguments)) {")
        for field in fields {
            let property = swiftPropertyName(field.name)
            lines.append("        self.\(property) = \(property)")
        }
        lines.append("    }")
        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        lines.append("        let container = try decoder.container(keyedBy: CodingKeys.self)")
        for field in fields {
            let property = swiftPropertyName(field.name)
            lines.append("        self.\(property) = \(decodeExpression(type: field.type, property: property))")
        }
        lines.append("    }")
        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append("        var container = encoder.container(keyedBy: CodingKeys.self)")
        for field in fields {
            let property = swiftPropertyName(field.name)
            lines.append("        try container.encode(\(property), forKey: .\(property))")
        }
        lines.append("    }")
        lines.append("")
        lines.append("    private enum CodingKeys: String, CodingKey {")
        for field in fields {
            let property = swiftPropertyName(field.name)
            lines.append("        case \(property)")
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func decodeExpression(type: MojoType, property: String) -> String {
        switch type {
        case .primitive("uint8"):
            return "try MojoJSONCoding.decodeUInt8(from: container, forKey: .\(property))"
        case .primitive("uint32"):
            return "try MojoJSONCoding.decodeUInt32(from: container, forKey: .\(property))"
        case .primitive("uint64"):
            return "try MojoJSONCoding.decodeUInt64(from: container, forKey: .\(property))"
        default:
            return "try container.decode(\(type.swiftName).self, forKey: .\(property))"
        }
    }

    private static func generateInterface(_ interface: MojoInterface) -> String {
        var lines: [String] = [
            "public enum \(interface.name)MojoInterfaceMarker {}",
            "public typealias \(interface.name)Remote = MojoPendingRemote<\(interface.name)MojoInterfaceMarker>",
            "public typealias \(interface.name)Receiver = MojoPendingReceiver<\(interface.name)MojoInterfaceMarker>",
            "",
            "public protocol \(interface.name)MojoInterface {",
        ]

        for method in interface.methods {
            let signature = swiftMethodSignature(interface: interface, method: method)
            lines.append("    \(signature)")
        }
        lines.append("}")

        for method in interface.methods where shouldGenerateRequestStruct(method) {
            lines.append("")
            lines.append(generateStruct(requestStructName(interface: interface, method: method), fields: method.parameters))
        }

        for method in interface.methods where method.responseParameters.count > 1 {
            lines.append("")
            lines.append(generateStruct(responseStructName(interface: interface, method: method), fields: method.responseParameters))
        }

        lines.append("")
        lines.append(generateSinkProtocol(interface))
        lines.append("")
        lines.append(generateTransportClass(interface))

        return lines.joined(separator: "\n")
    }

    private static func generateSinkProtocol(_ interface: MojoInterface) -> String {
        var lines: [String] = [
            "public protocol \(interface.name)MojoSink: AnyObject {",
        ]
        for method in interface.methods {
            let signature = swiftMethodSignature(interface: interface, method: method)
            lines.append("    \(signature)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func generateTransportClass(_ interface: MojoInterface) -> String {
        var lines: [String] = [
            "public final class Generated\(interface.name)MojoTransport: \(interface.name)MojoInterface {",
            "    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }",
            "    private let sink: \(interface.name)MojoSink",
            "    private let recorder: OwlFreshMojoTransportRecorder",
            "",
            "    public init(sink: \(interface.name)MojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {",
            "        self.sink = sink",
            "        self.recorder = recorder",
            "    }",
            "",
            "    public func resetRecordedCalls() {",
            "        recorder.reset()",
            "    }",
            "",
            "    private func record(method: String, payloadType: String, payloadSummary: String) {",
            "        recorder.record(",
            "            interface: \"\(interface.name)\",",
            "            method: method,",
            "            payloadType: payloadType,",
            "            payloadSummary: payloadSummary",
            "        )",
            "    }",
        ]

        for method in interface.methods {
            lines.append("")
            lines.append(generateTransportMethod(interface: interface, method: method))
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func generateTransportMethod(interface: MojoInterface, method: MojoMethod) -> String {
        let signature = swiftMethodSignature(interface: interface, method: method)
        let methodName = lowerCamel(method.name)
        let payload = payloadExpression(interface: interface, method: method)
        var lines = [
            "    public \(signature) {",
            "        record(method: \"\(methodName)\", payloadType: \"\(payload.type)\", payloadSummary: \(payload.summary))",
        ]

        let call = sinkCall(interface: interface, method: method)
        if !method.responseParameters.isEmpty {
            lines.append("        return try await \(call)")
        } else {
            lines.append("        \(call)")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    private static func payloadExpression(interface: MojoInterface, method: MojoMethod) -> (type: String, summary: String) {
        if shouldGenerateRequestStruct(method) {
            return (requestStructName(interface: interface, method: method), "String(describing: request)")
        }
        if let parameter = method.parameters.first {
            let name = swiftPropertyName(parameter.name)
            return (parameter.type.swiftName, "String(describing: \(name))")
        }
        return ("Void", "\"\"")
    }

    private static func sinkCall(interface: MojoInterface, method: MojoMethod) -> String {
        let methodName = lowerCamel(method.name)
        if shouldGenerateRequestStruct(method) {
            return "sink.\(methodName)(request)"
        }
        if let parameter = method.parameters.first {
            return "sink.\(methodName)(\(swiftPropertyName(parameter.name)))"
        }
        return "sink.\(methodName)()"
    }

    private static func generatePipeBindings(file: MojoFile) -> String {
        let interfaces = file.declarations.compactMap { declaration -> MojoInterface? in
            guard case .interface(let interface) = declaration, interface.name != "OwlFreshClient" else {
                return nil
            }
            return interface
        }
        let conformances = interfaces
            .map { "    \($0.name)MojoSink" }
            .joined(separator: ",\n")
        var lines: [String] = [
            "public protocol OwlFreshMojoPipeBindings: AnyObject {",
        ]
        for interface in interfaces {
            for method in interface.methods {
                lines.append("    \(pipeSignature(interface: interface, method: method))")
            }
        }
        lines.append("}")
        lines.append("")
        lines.append("public final class GeneratedOwlFreshMojoPipeBoundSinks:")
        lines.append(conformances)
        lines.append("{")
        lines.append("    private let session: OpaquePointer?")
        lines.append("    private let pipe: OwlFreshMojoPipeBindings")
        lines.append("    private var lastError: Error?")
        lines.append("")
        lines.append("    public init(session: OpaquePointer?, pipe: OwlFreshMojoPipeBindings) {")
        lines.append("        self.session = session")
        lines.append("        self.pipe = pipe")
        lines.append("    }")
        lines.append("")
        lines.append("    public func throwIfFailed() throws {")
        lines.append("        if let error = lastError {")
        lines.append("            lastError = nil")
        lines.append("            throw error")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    private func forward(_ body: () throws -> Void) {")
        lines.append("        do {")
        lines.append("            try body()")
        lines.append("        } catch {")
        lines.append("            lastError = error")
        lines.append("        }")
        lines.append("    }")

        for interface in interfaces {
            for method in interface.methods {
                lines.append("")
                lines.append(generatePipeBoundSinkMethod(interface: interface, method: method))
            }
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func generatePipeBoundSinkMethod(interface: MojoInterface, method: MojoMethod) -> String {
        let signature = swiftMethodSignature(interface: interface, method: method)
        var lines = ["    public \(signature) {"]
        let call = pipeCall(interface: interface, method: method)
        if method.responseParameters.isEmpty {
            lines.append("        forward {")
            lines.append("            try \(call)")
            lines.append("        }")
        } else {
            lines.append("        return try \(call)")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    private static func pipeSignature(interface: MojoInterface, method: MojoMethod) -> String {
        let methodName = pipeMethodName(interface: interface, method: method)
        let response = responseType(method)
        if shouldGenerateRequestStruct(method) {
            return "func \(methodName)(_ session: OpaquePointer?, request: \(requestStructName(interface: interface, method: method))) throws\(pipeResponseSuffix(response))"
        }
        if let parameter = method.parameters.first {
            return "func \(methodName)(_ session: OpaquePointer?, \(swiftPropertyName(parameter.name)): \(parameter.type.swiftName)) throws\(pipeResponseSuffix(response))"
        }
        return "func \(methodName)(_ session: OpaquePointer?) throws\(pipeResponseSuffix(response))"
    }

    private static func pipeResponseSuffix(_ response: String) -> String {
        response.replacingOccurrences(of: " async throws", with: "")
    }

    private static func pipeCall(interface: MojoInterface, method: MojoMethod) -> String {
        let methodName = pipeMethodName(interface: interface, method: method)
        if shouldGenerateRequestStruct(method) {
            return "pipe.\(methodName)(session, request: request)"
        }
        if let parameter = method.parameters.first {
            let name = swiftPropertyName(parameter.name)
            return "pipe.\(methodName)(session, \(name): \(name))"
        }
        return "pipe.\(methodName)(session)"
    }

    private static func pipeMethodName(interface: MojoInterface, method: MojoMethod) -> String {
        let interfaceName = interface.name.hasPrefix("OwlFresh")
            ? String(interface.name.dropFirst("OwlFresh".count))
            : interface.name
        return lowerCamel(interfaceName) + method.name
    }

    private static func generateSchema(file: MojoFile, checksum: String) -> String {
        let declarationRows = file.declarations
            .map { declaration in
                "        MojoSchemaDeclaration(kind: \"\(declaration.kind)\", name: \"\(declaration.name)\")"
            }
            .joined(separator: ",\n")
        return """
        public struct MojoSchemaDeclaration: Equatable, Codable {
            public let kind: String
            public let name: String
        }

        public enum OwlFreshMojoSchema {
            public static let module = "\(file.module)"
            public static let sourceChecksum = "\(checksum)"
            public static let declarations: [MojoSchemaDeclaration] = [
        \(declarationRows)
            ]
        }
        """
    }

    private static func swiftMethodSignature(interface: MojoInterface, method: MojoMethod) -> String {
        let methodName = lowerCamel(method.name)
        let response = responseType(method)
        if shouldGenerateRequestStruct(method) {
            let requestName = requestStructName(interface: interface, method: method)
            return "func \(methodName)(_ request: \(requestName))\(response)"
        }
        if let parameter = method.parameters.first {
            return "func \(methodName)(_ \(swiftPropertyName(parameter.name)): \(parameter.type.swiftName))\(response)"
        }
        return "func \(methodName)()\(response)"
    }

    private static func responseType(_ method: MojoMethod) -> String {
        guard !method.responseParameters.isEmpty else {
            return ""
        }
        if method.responseParameters.count == 1, let response = method.responseParameters.first {
            return " async throws -> \(response.type.swiftName)"
        }
        return " async throws -> \(responseStructName(methodName: method.name))"
    }

    private static func shouldGenerateRequestStruct(_ method: MojoMethod) -> Bool {
        method.parameters.count > 1
    }

    private static func requestStructName(interface: MojoInterface, method: MojoMethod) -> String {
        "\(interface.name)\(method.name)Request"
    }

    private static func responseStructName(interface: MojoInterface, method: MojoMethod) -> String {
        "\(interface.name)\(method.name)Response"
    }

    private static func responseStructName(methodName: String) -> String {
        "\(methodName)Response"
    }

    static func swiftEnumCaseName(_ name: String) -> String {
        let trimmed = name.hasPrefix("k") ? String(name.dropFirst()) : name
        return lowerCamel(trimmed)
    }

    static func swiftPropertyName(_ name: String) -> String {
        lowerCamelFromSnake(name)
    }

    static func lowerCamel(_ name: String) -> String {
        guard let first = name.first else {
            return name
        }
        return first.lowercased() + name.dropFirst()
    }

    static func lowerCamelFromSnake(_ name: String) -> String {
        let parts = name.split(separator: "_").map(String.init)
        guard let first = parts.first else {
            return name
        }
        return ([first.lowercased()] + parts.dropFirst().map { part in
            guard let first = part.first else {
                return part
            }
            return first.uppercased() + part.dropFirst()
        }).joined()
    }
}

public enum BindingsReportStatus: Equatable {
    case generated
    case passed
    case failed(String)

    var title: String {
        switch self {
        case .generated:
            return "GENERATED"
        case .passed:
            return "PASS"
        case .failed:
            return "FAIL"
        }
    }

    var cssClass: String {
        switch self {
        case .generated:
            return "generated"
        case .passed:
            return "passed"
        case .failed:
            return "failed"
        }
    }

    var detail: String {
        switch self {
        case .generated:
            return "Generated Swift bindings and report from the Mojo source."
        case .passed:
            return "Generated Swift bindings are up to date with the Mojo source."
        case .failed(let message):
            return message
        }
    }
}

public enum BindingsReportRenderer {
    public static func render(
        file: MojoFile,
        result: SwiftGenerationResult,
        status: BindingsReportStatus,
        mojomPath: String,
        swiftPath: String
    ) -> String {
        let declarations = file.declarations.map { declaration in
            declarationSection(declaration)
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>OWL Mojo Binding Report</title>
          <style>
            html, body { margin: 0; background: #f7f7f7; color: #141414; font: 16px -apple-system, BlinkMacSystemFont, sans-serif; }
            main { width: 1120px; margin: 0 auto; padding: 32px 0 48px; }
            h1 { margin: 0 0 12px; font-size: 34px; letter-spacing: 0; }
            h2 { margin: 28px 0 10px; font-size: 22px; letter-spacing: 0; }
            .status { border: 4px solid #141414; padding: 18px 22px; font-weight: 900; font-size: 30px; }
            .passed { background: rgb(0, 204, 82); }
            .generated { background: rgb(255, 210, 0); }
            .failed { background: rgb(255, 82, 82); }
            .grid { display: grid; grid-template-columns: 180px 1fr; gap: 8px 18px; margin: 18px 0 26px; }
            .label { font-weight: 800; }
            table { width: 100%; border-collapse: collapse; background: white; border: 4px solid #141414; margin-bottom: 18px; }
            th, td { border: 2px solid #141414; padding: 10px 12px; text-align: left; vertical-align: top; }
            th { background: #0059ff; color: white; font-weight: 900; }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 14px; }
            .kind { width: 120px; font-weight: 900; }
          </style>
        </head>
        <body>
        <main>
          <h1>OWL Mojo Binding Report</h1>
          <div class="status \(status.cssClass)">\(escapeHTML(status.title)): \(escapeHTML(status.detail))</div>
          <div class="grid">
            <div class="label">Mojo source</div><div><code>\(escapeHTML(mojomPath))</code></div>
            <div class="label">Swift output</div><div><code>\(escapeHTML(swiftPath))</code></div>
            <div class="label">Module</div><div><code>\(escapeHTML(file.module))</code></div>
            <div class="label">Checksum</div><div><code>\(escapeHTML(result.checksum))</code></div>
          </div>
          <h2>Generated Declarations</h2>
          <table>
            <thead><tr><th class="kind">Mojo</th><th>Name</th><th>Generated Swift surface</th></tr></thead>
            <tbody>
        \(declarations)
            </tbody>
          </table>
        </main>
        </body>
        </html>
        """
    }

    private static func declarationSection(_ declaration: MojoDeclaration) -> String {
        switch declaration {
        case .enumeration(let enumeration):
            let lines = ["enum \(enumeration.name): UInt32"] + enumeration.cases
                .map { enumCase in "\(enumCase.name)=\(enumCase.rawValue) -> .\(MojoSwiftGenerator.swiftEnumCaseName(enumCase.name))" }
            return row(kind: "enum", name: enumeration.name, swiftLines: lines)
        case .structure(let structure):
            let lines = ["struct \(structure.name)"] + structure.fields
                .map { field in "\(field.type.mojoName) \(field.name) -> \(field.type.swiftName) \(MojoSwiftGenerator.swiftPropertyName(field.name))" }
            return row(kind: "struct", name: structure.name, swiftLines: lines)
        case .interface(let interface):
            let lines = ["protocol \(interface.name)MojoInterface"] + interface.methods.map { method in
                let params = method.parameters
                    .map { "\($0.type.mojoName) \($0.name) -> \($0.type.swiftName) \(MojoSwiftGenerator.swiftPropertyName($0.name))" }
                    .joined(separator: ", ")
                let response = method.responseParameters.isEmpty
                    ? ""
                    : " -> " + method.responseParameters.map { $0.type.swiftName }.joined(separator: ", ")
                return "\(MojoSwiftGenerator.lowerCamel(method.name))(\(params))\(response)"
            }
            return row(kind: "interface", name: interface.name, swiftLines: lines)
        }
    }

    private static func row(kind: String, name: String, swiftLines: [String]) -> String {
        let swift = swiftLines.map(escapeHTML).joined(separator: "<br>")
        return """
              <tr><td class="kind">\(escapeHTML(kind))</td><td><code>\(escapeHTML(name))</code></td><td><code>\(swift)</code></td></tr>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
