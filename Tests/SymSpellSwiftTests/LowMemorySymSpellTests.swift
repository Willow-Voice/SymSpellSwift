@testable import SymSpellSwift
import XCTest

final class LowMemorySymSpellTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lowmemory_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - MMapDictionary Tests

    func testMMapDictionaryBuildAndOpen() throws {
        let dictPath = tempDir.appendingPathComponent("words.bin")
        let dict = MMapDictionary(filePath: dictPath)

        let words = [
            ("apple", 100),
            ("banana", 200),
            ("cherry", 150),
            ("zebra", 50)
        ]

        try dict.build(words: words)
        XCTAssertTrue(dict.open())
        XCTAssertEqual(dict.numWords, 4)

        dict.close()
    }

    func testMMapDictionaryBinarySearch() throws {
        let dictPath = tempDir.appendingPathComponent("words.bin")
        let dict = MMapDictionary(filePath: dictPath)

        let words = [
            ("apple", 100),
            ("banana", 200),
            ("cherry", 150),
            ("zebra", 50)
        ]

        try dict.build(words: words)
        dict.open()

        XCTAssertEqual(dict.get("apple"), 100)
        XCTAssertEqual(dict.get("banana"), 200)
        XCTAssertEqual(dict.get("cherry"), 150)
        XCTAssertEqual(dict.get("zebra"), 50)
        XCTAssertEqual(dict.get("notfound"), 0)

        XCTAssertTrue(dict.contains("apple"))
        XCTAssertFalse(dict.contains("notfound"))

        dict.close()
    }

    func testMMapDictionaryCache() throws {
        let dictPath = tempDir.appendingPathComponent("words.bin")
        let dict = MMapDictionary(filePath: dictPath)
        dict.cacheMaxSize = 2

        let words = [
            ("apple", 100),
            ("banana", 200),
            ("cherry", 150)
        ]

        try dict.build(words: words)
        dict.open()

        // Access words to populate cache
        _ = dict.get("apple")
        _ = dict.get("banana")
        _ = dict.get("cherry")  // Should trigger cache eviction

        // All should still be accessible
        XCTAssertEqual(dict.get("apple"), 100)
        XCTAssertEqual(dict.get("banana"), 200)
        XCTAssertEqual(dict.get("cherry"), 150)

        dict.close()
    }

    // MARK: - MMapDeletes Tests

    func testMMapDeletesBuildAndOpen() throws {
        let deletesPath = tempDir.appendingPathComponent("deletes.bin")
        let deletesIndex = MMapDeletes(filePath: deletesPath)

        let deletes: [String: [Int]] = [
            "helo": [0, 1],
            "hell": [0],
            "ello": [0, 2]
        ]

        try deletesIndex.build(deletes: deletes)
        XCTAssertTrue(deletesIndex.open())
        XCTAssertEqual(deletesIndex.numEntries, 3)

        deletesIndex.close()
    }

    func testMMapDeletesBinarySearch() throws {
        let deletesPath = tempDir.appendingPathComponent("deletes.bin")
        let deletesIndex = MMapDeletes(filePath: deletesPath)

        let deletes: [String: [Int]] = [
            "helo": [0, 1],
            "hell": [0],
            "ello": [0, 2]
        ]

        try deletesIndex.build(deletes: deletes)
        deletesIndex.open()

        XCTAssertEqual(deletesIndex.get("helo"), [0, 1])
        XCTAssertEqual(deletesIndex.get("hell"), [0])
        XCTAssertEqual(deletesIndex.get("ello"), [0, 2])
        XCTAssertEqual(deletesIndex.get("notfound"), [])

        deletesIndex.close()
    }

    // MARK: - LowMemorySymSpell Tests

    func testLowMemorySymSpellBasicLookup() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        // Create a simple dictionary file
        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        hello 1000
        world 900
        help 800
        held 700
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))
        XCTAssertEqual(spellChecker.wordCount, 4)

        // Exact match
        let exact = spellChecker.lookup(phrase: "hello", verbosity: .top)
        XCTAssertEqual(exact.first?.term, "hello")
        XCTAssertEqual(exact.first?.distance, 0)

        // Spelling correction
        let correction = spellChecker.lookup(phrase: "helo", verbosity: .top, maxEditDistance: 2)
        XCTAssertEqual(correction.first?.term, "hello")
        XCTAssertEqual(correction.first?.distance, 1)

        spellChecker.close()
    }

    func testLowMemorySymSpellVerbosity() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        steam 100
        steams 200
        steem 150
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        // Top verbosity
        let topResult = spellChecker.lookup(phrase: "steems", verbosity: .top, maxEditDistance: 2)
        XCTAssertEqual(topResult.count, 1)

        // Closest verbosity
        let closestResult = spellChecker.lookup(phrase: "steems", verbosity: .closest, maxEditDistance: 2)
        XCTAssertEqual(closestResult.count, 2)

        // All verbosity
        let allResult = spellChecker.lookup(phrase: "steems", verbosity: .all, maxEditDistance: 2)
        XCTAssertEqual(allResult.count, 3)

        spellChecker.close()
    }

    func testLowMemorySymSpellWordSegmentation() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        the 10000
        quick 5000
        brown 4000
        fox 3000
        jumps 2500
        over 2000
        lazy 1500
        dog 1000
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        let result = spellChecker.wordSegmentation(phrase: "thequickbrownfox")
        XCTAssertEqual(result.correctedString, "the quick brown fox")

        spellChecker.close()
    }

    func testLowMemorySymSpellIsValidWord() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        hello 1000
        world 900
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        XCTAssertTrue(spellChecker.isValidWord("hello"))
        XCTAssertTrue(spellChecker.isValidWord("world"))
        XCTAssertFalse(spellChecker.isValidWord("notaword"))

        spellChecker.close()
    }

    func testLowMemorySymSpellTransferCasing() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        hello 1000
        world 900
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        // Test transfer casing
        let result = spellChecker.lookup(phrase: "HELO", verbosity: .top, transferCasing: true)
        XCTAssertEqual(result.first?.term, "HELLO")

        let result2 = spellChecker.lookup(phrase: "Helo", verbosity: .top, transferCasing: true)
        XCTAssertEqual(result2.first?.term, "Hello")

        spellChecker.close()
    }

    func testLowMemorySymSpellCompoundCorrection() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        the 10000
        quick 5000
        brown 4000
        fox 3000
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        let result = spellChecker.lookupCompound(phrase: "teh quik brown fox")
        XCTAssertEqual(result.first?.term, "the quick brown fox")

        spellChecker.close()
    }

    func testLowMemorySymSpellAutoCorrection() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        hello 10000
        world 9000
        help 8000
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        // Should auto-correct with high confidence
        let correction = spellChecker.autoCorrection(for: "helo")
        XCTAssertEqual(correction, "hello")

        // Valid word should return nil
        let noCorrection = spellChecker.autoCorrection(for: "hello")
        XCTAssertNil(noCorrection)

        spellChecker.close()
    }

    func testLowMemorySymSpellSuggestions() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        hello 10000
        help 9000
        held 8000
        helm 7000
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        let suggestions = spellChecker.suggestions(for: "helo", limit: 3)
        XCTAssertTrue(suggestions.count <= 3)
        XCTAssertEqual(suggestions.first?.term, "hello")

        spellChecker.close()
    }

    func testLowMemorySymSpellTopN() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        word1 1000
        word2 2000
        word3 3000
        word4 4000
        word5 5000
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        // Load only top 3 words
        XCTAssertTrue(spellChecker.loadDictionaryTopN(corpus: dictPath, n: 3))
        XCTAssertEqual(spellChecker.wordCount, 3)

        // Top 3 by frequency should be word5, word4, word3
        XCTAssertTrue(spellChecker.isValidWord("word5"))
        XCTAssertTrue(spellChecker.isValidWord("word4"))
        XCTAssertTrue(spellChecker.isValidWord("word3"))
        XCTAssertFalse(spellChecker.isValidWord("word2"))
        XCTAssertFalse(spellChecker.isValidWord("word1"))

        spellChecker.close()
    }

    func testLowMemorySymSpellEmptyInput() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        hello 1000
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        let result = spellChecker.lookup(phrase: "", verbosity: .top)
        XCTAssertTrue(result.isEmpty)

        spellChecker.close()
    }

    func testLowMemorySymSpellGetDbSizeMB() throws {
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        let dictPath = tempDir.appendingPathComponent("dict.txt")
        let dictContent = """
        hello 1000
        world 900
        """
        try dictContent.write(to: dictPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictPath))

        let sizeMB = spellChecker.getDbSizeMB()
        XCTAssertTrue(sizeMB > 0)

        spellChecker.close()
    }

    // MARK: - Integration with Full Dictionary

    func testLowMemorySymSpellWithFullDictionary() async throws {
        guard let dictURL = Bundle.module.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt") else {
            throw XCTSkip("Dictionary file not available")
        }

        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictURL))

        // Test common misspellings
        let correction1 = spellChecker.lookup(phrase: "memebers", verbosity: .top)
        XCTAssertEqual(correction1.first?.term, "members")

        let correction2 = spellChecker.lookup(phrase: "recieve", verbosity: .top)
        XCTAssertEqual(correction2.first?.term, "receive")

        let correction3 = spellChecker.lookup(phrase: "accomodate", verbosity: .top)
        XCTAssertEqual(correction3.first?.term, "accommodate")

        spellChecker.close()
    }

    func testLowMemorySymSpellSegmentationWithFullDictionary() async throws {
        guard let dictURL = Bundle.module.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt") else {
            throw XCTSkip("Dictionary file not available")
        }

        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: tempDir)

        XCTAssertTrue(spellChecker.loadDictionary(corpus: dictURL))

        // Test a simpler segmentation case
        let result = spellChecker.wordSegmentation(phrase: "thequickbrown")
        XCTAssertEqual(result.correctedString, "the quick brown")

        // Another simple case
        let result2 = spellChecker.wordSegmentation(phrase: "helloworld")
        XCTAssertEqual(result2.correctedString, "hello world")

        spellChecker.close()
    }
}
