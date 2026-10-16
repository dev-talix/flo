import XCTest
@testable import LocalFlow

final class VerbatimSnippetTests: XCTestCase {
    func testStorageReadsLegacyAndRoundTripsExactWhitespaceCodeAndURLs() {
        let name = "LocalFlow.VerbatimSnippetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["signature\tThanks\\nFlo", "v2:legacy\tliteral", "malformed"], forKey: Settings.Key.snippets)
        let legacy = Settings.loadSnippets(from: defaults)
        XCTAssertEqual(legacy.map(\.trigger), ["signature", "v2:legacy"])
        XCTAssertEqual(legacy.map(\.expansion), ["Thanks\nFlo", "literal"])
        let code = "  ```swift\n\tlet value = \"\\n\"\nhttps://example.com/a?b=1#part\n```\n "
        let snippets = legacy + [(trigger: "code", expansion: code), (trigger: "blank", expansion: " \n\t ")]
        Settings.storeSnippets(snippets, in: defaults)
        let restored = Settings.loadSnippets(from: defaults)
        XCTAssertEqual(restored.map(\.trigger), snippets.map(\.trigger))
        XCTAssertEqual(restored.map { Array($0.expansion.utf8) }, snippets.map { Array($0.expansion.utf8) })
        XCTAssertEqual(defaults.stringArray(forKey: Settings.Key.snippets),
                       snippets.map { "\($0.trigger)\t\($0.expansion.replacingOccurrences(of: "\n", with: "\\n"))" })
        XCTAssertNotNil(defaults.dictionary(forKey: Settings.Key.verbatimSnippets))

        defaults.set(["external\tupdated\\ntext"], forKey: Settings.Key.snippets)
        XCTAssertEqual(Settings.loadSnippets(from: defaults).map(\.expansion), ["updated\ntext"])
        Settings.storeSnippets(legacy, in: defaults)
        XCTAssertNil(defaults.object(forKey: Settings.Key.verbatimSnippets))
    }

    func testOriginalMatchesExpandOnceWithoutExpandingInsertedTriggers() {
        XCTAssertEqual(Snippets.expand("alpha alpha beta", snippets: [
            ("alpha", "beta"), ("beta", "gamma")
        ]), "beta beta gamma")
    }

    func testOverlapUsesEarliestThenLongestThenSavedOrder() {
        let snippets = [("insert", "short"), ("insert code", "long"), ("INSERT CODE", "tie")]
        XCTAssertEqual(Snippets.expand("Insert code. insert", snippets: snippets), "long short")
        XCTAssertEqual(Snippets.expand("one two three", snippets: [
            ("two three", "later"), ("one two", "earlier")
        ]), "earlier three")
    }

    func testRejectedOverlapDoesNotHideALaterOccurrenceOfTheSameTrigger() {
        XCTAssertEqual(Snippets.expand("a b b b", snippets: [
            ("a b", "first"), ("b b", "second")
        ]), "first second")
    }

    func testEmptyTriggersAndExpansionsAreSafeAndCodeIsExact() {
        let code = "  ```swift\n\tlet path = \"https://example.com/a?b=1\"\n// beta new line $1 \\n\n```\n "
        XCTAssertEqual(Snippets.expand("insert code insert code", snippets: [
            ("", "bad"), ("  \n", "bad"), ("insert", ""), ("insert code", code), ("beta", "wrong")
        ]), code + " " + code)
    }
}
