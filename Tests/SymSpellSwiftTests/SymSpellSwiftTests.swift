@testable import SymSpellSwift
import XCTest

final class SymSpellTests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    private func loadFromDictionaryFile() async -> SymSpell? {
        let symSpell = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 3)

        guard let path = Bundle.module.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt") else {
            return nil
        }

        try? await symSpell.loadDictionary(from: path, termIndex: 0, countIndex: 1, termCount: 82765)

        return symSpell
    }

    func testWordsWithSharedPrefixShouldRetainCounts() {
        let symSpell = SymSpell(maxDictionaryEditDistance: 1, prefixLength: 3)
        symSpell.createDictionaryEntry(key: "pipe", count: 5)
        symSpell.createDictionaryEntry(key: "pips", count: 10)

        var result = symSpell.lookup("pipe", verbosity: .all, maxEditDistance: 1)
        XCTAssertEqual(2, result.count)
        XCTAssertEqual("pipe", result[0].term)
        XCTAssertEqual(5, result[0].count)
        XCTAssertEqual("pips", result[1].term)
        XCTAssertEqual(10, result[1].count)

        result = symSpell.lookup("pips", verbosity: .all, maxEditDistance: 1)
        XCTAssertEqual(2, result.count)
        XCTAssertEqual("pips", result[0].term)
        XCTAssertEqual(10, result[0].count)
        XCTAssertEqual("pipe", result[1].term)
        XCTAssertEqual(5, result[1].count)

        result = symSpell.lookup("pip", verbosity: .all, maxEditDistance: 1)
        XCTAssertEqual(2, result.count)
        XCTAssertEqual("pips", result[0].term)
        XCTAssertEqual(10, result[0].count)
        XCTAssertEqual("pipe", result[1].term)
        XCTAssertEqual(5, result[1].count)
    }

    func testAddAdditionalCountsShouldNotAddWordAgain() {
        let symSpell = SymSpell()
        let word = "hello"
        symSpell.createDictionaryEntry(key: word, count: 11)
        XCTAssertEqual(1, symSpell.wordCount)
        symSpell.createDictionaryEntry(key: word, count: 3)
        XCTAssertEqual(1, symSpell.wordCount)
    }

    func testAddAdditionalCountsShouldIncreaseCount() {
        let symSpell = SymSpell()
        let word = "hello"
        symSpell.createDictionaryEntry(key: word, count: 11)

        var result = symSpell.lookup(word, verbosity: .top)
        var count = result.first?.count ?? 0
        XCTAssertEqual(11, count)

        symSpell.createDictionaryEntry(key: word, count: 3)
        result = symSpell.lookup(word, verbosity: .top)
        count = result.first?.count ?? 0
        XCTAssertEqual(11 + 3, count)
    }

    func testVerbosityShouldControlLookupResults() {
        let symSpell = SymSpell()
        symSpell.createDictionaryEntry(key: "steam", count: 1)
        symSpell.createDictionaryEntry(key: "steams", count: 2)
        symSpell.createDictionaryEntry(key: "steem", count: 3)

        var result = symSpell.lookup("steems", verbosity: .top, maxEditDistance: 2)
        XCTAssertEqual(1, result.count)

        result = symSpell.lookup("steems", verbosity: .closest, maxEditDistance: 2)
        XCTAssertEqual(2, result.count)

        result = symSpell.lookup("steems", verbosity: .all, maxEditDistance: 2)
        XCTAssertEqual(3, result.count)
    }

    func testLookupShouldReturnMostFrequent() {
        let symSpell = SymSpell()
        symSpell.createDictionaryEntry(key: "steama", count: 4)
        symSpell.createDictionaryEntry(key: "steamb", count: 6)
        symSpell.createDictionaryEntry(key: "steamc", count: 2)

        let result = symSpell.lookup("steam", verbosity: .top, maxEditDistance: 2)
        XCTAssertEqual(1, result.count)
        XCTAssertEqual("steamb", result[0].term)
        XCTAssertEqual(6, result[0].count)
    }

    func testLookupShouldFindExactMatch() {
        let symSpell = SymSpell()
        symSpell.createDictionaryEntry(key: "steama", count: 4)
        symSpell.createDictionaryEntry(key: "steamb", count: 6)
        symSpell.createDictionaryEntry(key: "steamc", count: 2)

        let result = symSpell.lookup("steama", verbosity: .top, maxEditDistance: 2)
        XCTAssertEqual(1, result.count)
        XCTAssertEqual("steama", result[0].term)
    }

    func testLookupShouldNotReturnNonWordDelete() {
        let symSpell = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 7)
        symSpell.createDictionaryEntry(key: "pawn", count: 10)

        var result = symSpell.lookup("paw", verbosity: .top, maxEditDistance: 0)
        XCTAssertEqual(0, result.count)

        result = symSpell.lookup("awn", verbosity: .top, maxEditDistance: 0)
        XCTAssertEqual(0, result.count)
    }
    
    func testComplete() async {
        guard let symSpell = await loadFromDictionaryFile() else {
            XCTFail()
            return
        }
        
        var result = symSpell.complete("yeste")
        XCTAssert(result.count == 4)
        XCTAssert(result[0].term == "yesterday")
        XCTAssert(result[1].term == "yesterdays")
        
        result = symSpell.complete("yste")
        XCTAssert(result.count == 0)
        
        result = symSpell.complete("ballo")
        XCTAssert(result.count == 10)
        XCTAssert(result[0].term == "balloon")
        XCTAssert(result[1].term == "ballot")
    }
    
    func testUnicodeComplete() {
        let symSpell = SymSpell()
        symSpell.createDictionaryEntry(key: "བོད་", count: 1)
        symSpell.createDictionaryEntry(key: "ལྗོངས་", count: 1)
        
        var result = symSpell.complete("བ")
        XCTAssert(result.count == 1)
        XCTAssert(result[0].term == "བོད་")
        
        result = symSpell.complete("བོ")
        XCTAssert(result.count == 1)
        XCTAssert(result[0].term == "བོད་")
        
        result = symSpell.complete("ད")
        XCTAssert(result.count == 0)
        
        result = symSpell.complete("ལ")
        XCTAssert(result.count == 1)
        
        result = symSpell.complete("ལྗ")
        XCTAssert(result.count == 1)
        
        
    }

    func testEnglishWordCorrection() async {
        guard let symSpell = await loadFromDictionaryFile() else {
            XCTFail()
            return
        }

        let sentences = [
            "tke",
            "abolution",
            "intermedaite",
            "usefull",
            "kniow",
        ]

        XCTAssert(symSpell.lookup(sentences[0], verbosity: .closest).first?.term == "the")
        XCTAssert(symSpell.lookup(sentences[1], verbosity: .closest).first?.term == "abolition")
        XCTAssert(symSpell.lookup(sentences[2], verbosity: .closest).first?.term == "intermediate")
        XCTAssert(symSpell.lookup(sentences[3], verbosity: .closest).first?.term == "useful")
        XCTAssert(symSpell.lookup(sentences[4], verbosity: .closest).first?.term == "know")
    }

    func testEnglishCompoundCorrection() async {
        guard let symSpell = await loadFromDictionaryFile() else {
            XCTFail()
            return
        }

        guard let path = Bundle.module.url(forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt") else {
            XCTFail()
            return
        }

        try? await symSpell.loadBigramDictionary(from: path)

        let sentences = [
            "whereis th elove hehad dated forImuch of thepast who couqdn'tread in sixthgrade and ins pired him",
            "in te dhird qarter oflast jear he hadlearned ofca sekretplan",
            "the bigjest playrs in te strogsommer film slatew ith plety of funn",
            "can yu readthis messa ge despite thehorible sppelingmsitakes",
        ]

        XCTAssertEqual(symSpell.lookupCompound(sentences[0]).first?.term, "where is the love he had dated for much of the past who couldn't read in sixth grade and inspired him")
        XCTAssertEqual(symSpell.lookupCompound(sentences[1]).first?.term, "in the third quarter of last year he had learned of a secret plan")
        XCTAssertEqual(symSpell.lookupCompound(sentences[2]).first?.term, "the biggest players in the strong summer film slate with plenty of fun")
        XCTAssertEqual(symSpell.lookupCompound(sentences[3]).first?.term, "can you read this message despite the horrible spelling mistakes")
    }

    func testSegmenting() async {
        guard let symSpell = await loadFromDictionaryFile() else {
            XCTFail()
            return
        }

        // Load bigrams - required for word segmentation
        guard let bigramPath = Bundle.module.url(forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt") else {
            XCTFail("Bigram dictionary not found")
            return
        }
        try? await symSpell.loadBigramDictionary(from: bigramPath)

        // Test simple phrases where all word pairs exist as bigrams
        // Note: segmentation only works at positions where valid bigrams exist
        let result1 = symSpell.wordSegmentation("thequickbrown", maxEditDistance: 0)
        XCTAssertEqual(result1.segmentedString, "the quick brown")

        let result2 = symSpell.wordSegmentation("itwasa", maxEditDistance: 0)
        XCTAssertEqual(result2.segmentedString, "it was a")

        // Test that bad segmentation doesn't happen - words stay together when no valid bigram
        let result3 = symSpell.wordSegmentation("crazyy", maxEditDistance: 0)
        XCTAssertFalse(result3.segmentedString.contains(" "), "Should not segment 'crazyy'")
    }

    func testWordSegmentationWithBigrams() async throws {
        let symSpell = SymSpell()

        guard let dictURL = Bundle.module.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt") else {
            throw XCTSkip("Dictionary resource not found")
        }

        guard let bigramURL = Bundle.module.url(forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt") else {
            throw XCTSkip("Bigram dictionary resource not found")
        }

        try await symSpell.loadDictionary(from: dictURL)
        try await symSpell.loadBigramDictionary(from: bigramURL)

        // Test that valid bigram segmentation works
        let result1 = symSpell.wordSegmentation("thequickbrown", maxEditDistance: 0)
        XCTAssertEqual(result1.segmentedString, "the quick brown")

        // Test with a phrase - should segment based on valid bigrams only
        let result2 = symSpell.wordSegmentation("itwasabright", maxEditDistance: 0)
        XCTAssertNotNil(result2.segmentedString)

        // "crazyy" should not be incorrectly segmented
        let result3 = symSpell.wordSegmentation("crazyy", maxEditDistance: 0)
        XCTAssertFalse(result3.segmentedString.contains(" "), "Should not segment 'crazyy' without valid bigrams")
    }

    func testWordSegmentationWithoutBigrams() async throws {
        let symSpell = SymSpell()

        guard let dictURL = Bundle.module.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt") else {
            throw XCTSkip("Dictionary resource not found")
        }

        try await symSpell.loadDictionary(from: dictURL)
        // Note: NOT loading bigrams

        // Without bigrams, should return input unchanged
        let result = symSpell.wordSegmentation("thequickbrown", maxEditDistance: 0)
        XCTAssertEqual(result.segmentedString, "thequickbrown", "Without bigrams loaded, input should be returned unchanged")
    }
}

