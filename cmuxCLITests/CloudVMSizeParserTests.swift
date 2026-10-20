import Testing

@Suite("cmux vm: size parsing")
struct CloudVMSizeParserTests {
    private let parser = CloudVMSizeParser()

    @Test(arguments: [
        ("3g", 3_072), ("20gb", 20_480), ("1GiB", 1_024),
        ("1024mb", 1_024), ("20480", 20_480),
    ])
    func acceptsUnitAliasesWithoutAClientLadder(input: String, expectedMb: Int) {
        #expect(parser.parse(input) == expectedMb)
    }

    @Test(arguments: ["0g", "511", "1.5g", "", "gib", "-2g"])
    func rejectsMalformedOrSubMinimumMemory(input: String) {
        #expect(parser.parse(input) == nil)
    }
}
