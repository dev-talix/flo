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

    func testAutomaticListsUseConsumedSentencePunctuationButDoNotRestoreIt() {
        for punctuation in [".", "!", "?"] {
            let parts = Snippets.parts(in: "First, insert code\(punctuation) Second, get eggs.",
                                       snippets: [("insert code", "code")])
            XCTAssertEqual(VoiceFormatter.apply(parts).map(\.text).joined(), "1. code\n2. Get eggs.")
        }
        for punctuation in ["", ",", ";", ":"] {
            let parts = Snippets.parts(in: "First, insert code\(punctuation) Second, get eggs.",
                                       snippets: [("insert code", "code.")])
            XCTAssertEqual(VoiceFormatter.apply(parts).map(\.text).joined(), "First, code. Second, get eggs.")
        }
    }

    func testAutomaticListsKeepLongUnicodeCodeAndRepeatedExpansionsExact() {
        let code = "  ```swift\n" + String(repeating: "\t// First, new line. Second, next item. 🥚 e\u{301}\n", count: 20) + "```\n\t"
        let parts = Snippets.parts(in: "🥚 Two things. First, insert code. Second, insert code! Third, done.",
                                   snippets: [("insert code", code)])
        let formatted = VoiceFormatter.apply(parts)
        XCTAssertEqual(Array(formatted.map(\.text).joined().utf8),
                       Array(("🥚 Two things.\n1. " + code + "\n2. " + code + "\n3. Done.").utf8))
        let protected = formatted.compactMap { part -> String? in
            if case .verbatim = part { return part.text }
            return nil
        }
        XCTAssertEqual(protected.map { Array($0.utf8) }, [Array(code.utf8), Array(code.utf8)])
    }

    func testLongOriginalTriggerStillSeparatesDistantOrdinals() {
        let trigger = String(repeating: "detail ", count: 80) + "end"
        let parts = Snippets.parts(in: "First, \(trigger). Second, get eggs.", snippets: [(trigger, "code")])
        XCTAssertEqual(VoiceFormatter.apply(parts).map(\.text).joined(), "First, code Second, get eggs.")
    }

    func testProtectedOrdinalsCannotCreateOrInterruptAProseList() {
        let saved = "First, saved. Second, new paragraph."
        let single = Snippets.parts(in: "First, insert code.", snippets: [("insert code", saved)])
        XCTAssertEqual(VoiceFormatter.apply(single).map(\.text).joined(), "First, " + saved)
        let hiddenFirst = Snippets.parts(in: "First, hidden. Second, spoken.", snippets: [("First, hidden", saved)])
        XCTAssertEqual(VoiceFormatter.apply(hiddenFirst).map(\.text).joined(), saved + " Second, spoken.")
        let hiddenThird = Snippets.parts(in: "First, apples. Third, hidden. Second, pears.",
                                         snippets: [("Third, hidden", saved)])
        XCTAssertEqual(VoiceFormatter.apply(hiddenThird).map(\.text).joined(), "1. Apples. " + saved + "\n2. Pears.")
    }

    func testNumberCuesAndTerminatorShareTheWholeStringFormattingRules() {
        let text = "Two things. Number one, insert code! Number two: apples. Finally, done."
        let parts = Snippets.parts(in: text, snippets: [("insert code", "code")])
        XCTAssertEqual(VoiceFormatter.apply(parts).map(\.text).joined(),
                       "Two things.\n1. code\n2. Apples.\n3. Done.")
        let baseline = VoiceFormatter.apply(text)
        XCTAssertEqual(Snippets.expand(baseline, snippets: [("insert code", "code")]),
                       VoiceFormatter.apply(parts).map(\.text).joined())
    }

    func testExplicitBulletAndParagraphCommandsKeepStateAcrossSavedCommands() {
        let parts = Snippets.parts(in: "bullet point insert code next item apples new paragraph next item on the agenda",
                                   snippets: [("insert code", "lowercase new paragraph numbered list")])
        XCTAssertEqual(VoiceFormatter.apply(parts).map(\.text).joined(),
                       "- lowercase new paragraph numbered list\n- Apples\n\nNext item on the agenda")
    }
}
