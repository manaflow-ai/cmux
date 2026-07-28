import Testing

private func codexTestComment(_ message: @autoclosure () -> String) -> Comment? {
  let value = message()
  return value.isEmpty ? nil : Comment(rawValue: value)
}

func codexSourceLocation(
  fileID: String = #fileID,
  filePath: String = #filePath,
  line: Int = #line,
  column: Int = #column
) -> SourceLocation {
  SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
}

func codexExpectFalse(
  _ condition: Bool,
  _ message: @autoclosure () -> String = "",
  sourceLocation: SourceLocation = codexSourceLocation()
) {
  #expect(!condition, codexTestComment(message()), sourceLocation: sourceLocation)
}

func codexExpectTrue(
  _ condition: Bool,
  _ message: @autoclosure () -> String = "",
  sourceLocation: SourceLocation = codexSourceLocation()
) {
  #expect(condition, codexTestComment(message()), sourceLocation: sourceLocation)
}

func codexExpectEqual<T: Equatable>(
  _ actual: T,
  _ expected: T,
  _ message: @autoclosure () -> String = "",
  sourceLocation: SourceLocation = codexSourceLocation()
) {
  #expect(actual == expected, codexTestComment(message()), sourceLocation: sourceLocation)
}

func codexExpectNil<T>(
  _ value: T?,
  _ message: @autoclosure () -> String = "",
  sourceLocation: SourceLocation = codexSourceLocation()
) {
  #expect(value == nil, codexTestComment(message()), sourceLocation: sourceLocation)
}

func codexRequire<T>(
  _ value: T?,
  _ message: @autoclosure () -> String = "",
  sourceLocation: SourceLocation = codexSourceLocation()
) throws -> T {
  try #require(value, codexTestComment(message()), sourceLocation: sourceLocation)
}
