//
// LowMemorySymSpell.swift
// SymSpellSwift
//
// Memory-efficient SymSpell implementation using memory-mapped binary files.
// Designed for memory-constrained environments like iOS keyboard extensions.
//

import Foundation

// MARK: - SymSpellConfiguration

/// Configuration for tunable parameters in SymSpellSwift.
///
/// Use this to customize ranking weights, confidence thresholds, and other parameters
/// without needing to update the package. All values have sensible defaults.
///
/// Example:
/// ```swift
/// var config = SymSpellConfiguration()
/// config.minConfidence = 0.8  // More conservative auto-correction
/// config.balanced.frequencyWeight = 0.4  // Boost frequency importance
///
/// let symSpell = LowMemorySymSpell(configuration: config)
/// ```
public struct SymSpellConfiguration: Sendable {

    // MARK: - Ranking Mode Weights

    /// Weights for balanced ranking mode
    public struct BalancedWeights: Sendable {
        /// Weight for distance score (0.0-1.0). Higher = distance matters more.
        public var distanceWeight: Double = 0.5
        /// Weight for frequency score (0.0-1.0). Higher = common words rank higher.
        public var frequencyWeight: Double = 0.3
        /// Weight for bigram context bonus (0.0-1.0). Higher = previous word context matters more.
        public var bigramBonusWeight: Double = 0.2

        public init() {}

        public init(distanceWeight: Double, frequencyWeight: Double, bigramBonusWeight: Double) {
            self.distanceWeight = distanceWeight
            self.frequencyWeight = frequencyWeight
            self.bigramBonusWeight = bigramBonusWeight
        }
    }

    /// Weights for frequency-boosted ranking mode
    public struct FrequencyBoostedWeights: Sendable {
        /// Weight for distance score (0.0-1.0). Lower than balanced = more tolerance for edits.
        public var distanceWeight: Double = 0.3
        /// Weight for frequency score (0.0-1.0). Higher = strongly favor common words.
        public var frequencyWeight: Double = 0.4
        /// Weight for bigram context bonus (0.0-1.0). Higher = previous word context matters more.
        public var bigramBonusWeight: Double = 0.3

        public init() {}

        public init(distanceWeight: Double, frequencyWeight: Double, bigramBonusWeight: Double) {
            self.distanceWeight = distanceWeight
            self.frequencyWeight = frequencyWeight
            self.bigramBonusWeight = bigramBonusWeight
        }
    }

    /// Weights for distance-first ranking mode
    public struct DistanceFirstWeights: Sendable {
        /// Multiplier for bigram frequency bonus in distance-first mode.
        /// Higher values give more weight to words that commonly follow the previous word.
        public var bigramBonusMultiplier: Double = 10.0

        public init() {}

        public init(bigramBonusMultiplier: Double) {
            self.bigramBonusMultiplier = bigramBonusMultiplier
        }
    }

    /// Weights for balanced ranking mode
    public var balanced = BalancedWeights()

    /// Weights for frequency-boosted ranking mode
    public var frequencyBoosted = FrequencyBoostedWeights()

    /// Weights for distance-first ranking mode
    public var distanceFirst = DistanceFirstWeights()

    // MARK: - Auto-Correction Confidence

    /// Minimum confidence threshold for auto-correction (0.0-1.0).
    /// Corrections below this threshold won't be applied automatically.
    public var minConfidence: Double = 0.75

    /// Penalty per edit distance unit (0.0-1.0).
    /// Distance 1 = this penalty, Distance 2 = 2x this penalty.
    public var distancePenaltyPerEdit: Double = 0.2

    /// Multiplier for ambiguity penalty when multiple suggestions have similar frequency.
    /// Higher = more penalty when there's no clear winner.
    public var ambiguityPenaltyMultiplier: Double = 0.6

    /// Penalty per character below the short word threshold.
    /// Short words are riskier to auto-correct.
    public var shortWordPenaltyPerChar: Double = 0.07

    /// Words shorter than this are considered "short" and get extra penalty.
    public var shortWordThreshold: Int = 4

    /// Bonus confidence for very high frequency words.
    public var highFrequencyBonus: Double = 0.05

    /// Frequency threshold above which highFrequencyBonus is applied.
    public var highFrequencyThreshold: Int = 100000

    /// Maximum confidence for correcting a valid (in-dictionary) word.
    /// Valid words are usually intentional, so corrections should be conservative.
    public var validWordMaxConfidence: Double = 0.6

    /// Minimum frequency ratio required to suggest correcting a valid word.
    /// Suggestion must be this many times more frequent than the original.
    public var validWordMinFrequencyRatio: Double = 10.0

    // MARK: - Word Segmentation (Beam Search)

    /// Edit distance penalty per edit in beam search segmentation.
    /// Higher = more conservative corrections during segmentation.
    public var beamSearchEditPenalty: Double = 5.0

    // MARK: - Autocapitalization

    /// Settings for automatic capitalization rules.
    public struct AutocapitalizationSettings: Sendable {
        /// Enable autocapitalization (master switch)
        public var enabled: Bool = true

        /// Capitalize standalone "i" to "I"
        public var capitalizeI: Bool = true

        /// Capitalize "i" in contractions: "i'm" → "I'm", "i've" → "I've", etc.
        public var capitalizeIContractions: Bool = true

        /// Capitalize first letter after sentence-ending punctuation (. ! ?)
        public var capitalizeSentenceStart: Bool = true

        /// Custom words that should always be capitalized (e.g., ["api"] → "API")
        public var alwaysCapitalize: [String: String] = [:]

        public init() {}

        public init(
            enabled: Bool = true,
            capitalizeI: Bool = true,
            capitalizeIContractions: Bool = true,
            capitalizeSentenceStart: Bool = true,
            alwaysCapitalize: [String: String] = [:]
        ) {
            self.enabled = enabled
            self.capitalizeI = capitalizeI
            self.capitalizeIContractions = capitalizeIContractions
            self.capitalizeSentenceStart = capitalizeSentenceStart
            self.alwaysCapitalize = alwaysCapitalize
        }
    }

    /// Autocapitalization settings
    public var autocapitalization = AutocapitalizationSettings()

    // MARK: - Suffix Handling

    /// Settings for recognizing valid words with common suffixes.
    /// Helps avoid incorrect corrections for words like "cats" (cat + s) that may not be in the dictionary.
    public struct SuffixSettings: Sendable {
        /// Enable suffix recognition (master switch)
        public var enabled: Bool = true

        /// Common plural suffixes: -s, -es
        public var handlePlurals: Bool = true

        /// Verb suffixes: -ed, -ing, -s, -es
        public var handleVerbForms: Bool = true

        /// Possessive: -'s
        public var handlePossessives: Bool = true

        /// Adverb suffix: -ly
        public var handleAdverbs: Bool = true

        /// Comparative/superlative: -er, -est
        public var handleComparatives: Bool = true

        public init() {}

        public init(
            enabled: Bool = true,
            handlePlurals: Bool = true,
            handleVerbForms: Bool = true,
            handlePossessives: Bool = true,
            handleAdverbs: Bool = true,
            handleComparatives: Bool = true
        ) {
            self.enabled = enabled
            self.handlePlurals = handlePlurals
            self.handleVerbForms = handleVerbForms
            self.handlePossessives = handlePossessives
            self.handleAdverbs = handleAdverbs
            self.handleComparatives = handleComparatives
        }
    }

    /// Suffix handling settings
    public var suffixHandling = SuffixSettings()

    // MARK: - Initialization

    public init() {}

    /// Create configuration with custom confidence threshold
    public init(minConfidence: Double) {
        self.minConfidence = minConfidence
    }

    // MARK: - Presets

    /// Default configuration with balanced settings
    public static let `default` = SymSpellConfiguration()

    /// Conservative configuration that minimizes false corrections
    public static var conservative: SymSpellConfiguration {
        var config = SymSpellConfiguration()
        config.minConfidence = 0.85
        config.distancePenaltyPerEdit = 0.25
        config.ambiguityPenaltyMultiplier = 0.8
        config.validWordMaxConfidence = 0.5
        config.validWordMinFrequencyRatio = 20.0
        config.beamSearchEditPenalty = 7.0
        return config
    }

    /// Aggressive configuration that corrects more liberally
    public static var aggressive: SymSpellConfiguration {
        var config = SymSpellConfiguration()
        config.minConfidence = 0.6
        config.distancePenaltyPerEdit = 0.15
        config.ambiguityPenaltyMultiplier = 0.4
        config.validWordMaxConfidence = 0.7
        config.validWordMinFrequencyRatio = 5.0
        config.beamSearchEditPenalty = 3.0
        return config
    }
}

// MARK: - Composition

/// Result of word segmentation operation
public struct Composition {
    /// Words separated by spaces
    public let segmentedString: String
    /// Spelling-corrected version of segmented string
    public let correctedString: String
    /// Total edit distance applied during correction
    public let distanceSum: Int
    /// Log probability sum (measure of how common the segmentation is)
    public let logProbSum: Double

    public init(segmentedString: String, correctedString: String, distanceSum: Int, logProbSum: Double) {
        self.segmentedString = segmentedString
        self.correctedString = correctedString
        self.distanceSum = distanceSum
        self.logProbSum = logProbSum
    }
}

// MARK: - SegmentationHypothesis

/// A hypothesis in the beam search for word segmentation.
///
/// Tracks the current state of a potential segmentation including:
/// - Words found so far (with spelling corrections applied)
/// - Original segments before correction (for comparison)
/// - Position in the input string
/// - Cumulative edit distance and bigram probability scores
struct SegmentationHypothesis {
    /// Corrected words found so far
    let words: [String]
    /// Original segments before correction
    let originalSegments: [String]
    /// Current position in input string
    let position: Int
    /// Sum of edit distances for all corrections
    let totalEditDistance: Int
    /// Sum of log(bigram_frequency) for scoring
    let bigramLogProbSum: Double

    /// Calculate combined score (higher is better)
    ///
    /// - Parameter editPenalty: Penalty per edit distance unit (from configuration)
    /// - Returns: Score balancing bigram probability and edit distance
    func score(editPenalty: Double) -> Double {
        // Balance: prefer common phrases (positive), penalize corrections (negative)
        let penalty = Double(totalEditDistance) * editPenalty
        return bigramLogProbSum - penalty
    }

    /// Create an initial empty hypothesis
    static func initial() -> SegmentationHypothesis {
        return SegmentationHypothesis(
            words: [],
            originalSegments: [],
            position: 0,
            totalEditDistance: 0,
            bigramLogProbSum: 0.0
        )
    }

    /// Extend this hypothesis with a new word
    func extend(
        withWord word: String,
        originalSegment: String,
        editDistance: Int,
        segmentLength: Int,
        bigramLogProb: Double
    ) -> SegmentationHypothesis {
        return SegmentationHypothesis(
            words: words + [word],
            originalSegments: originalSegments + [originalSegment],
            position: position + segmentLength,
            totalEditDistance: totalEditDistance + editDistance,
            bigramLogProbSum: bigramLogProbSum + bigramLogProb
        )
    }
}

// MARK: - Verbosity (for LowMemorySymSpell)

/// Controls the quantity/closeness of returned suggestions
public enum LowMemoryVerbosity {
    /// Top suggestion with highest term frequency of the suggestions of smallest edit distance found
    case top
    /// All suggestions of smallest edit distance found, ordered by term frequency
    case closest
    /// All suggestions within maxEditDistance, ordered by edit distance, then by term frequency
    case all
}

// MARK: - RankingMode

/// Controls how suggestions are ranked/sorted.
///
/// By default, SymSpell ranks by edit distance first, using frequency only as a tiebreaker.
/// This can cause rare words at distance 1 to rank higher than very common words at distance 2.
///
/// **Example with `.distanceFirst` (default):**
/// ```
/// Input: "teh"
/// 1. "te" (distance 1, freq: 500)      <- rare word ranks first
/// 2. "the" (distance 2, freq: 5000000) <- common word ranks lower
/// ```
///
/// **Example with `.balanced`:**
/// ```
/// Input: "teh"
/// 1. "the" (distance 2, freq: 5000000) <- common word now ranks first
/// 2. "te" (distance 1, freq: 500)
/// ```
public enum RankingMode {
    /// Default SymSpell behavior: distance is primary sort, frequency is tiebreaker only.
    /// Use this for traditional spell checking where closest match is preferred.
    case distanceFirst

    /// Balanced scoring that weighs both distance and frequency.
    /// Common words can outrank rare words even with slightly higher edit distance.
    /// Recommended for keyboard auto-correction where common words are more likely intended.
    case balanced

    /// Aggressive frequency weighting that strongly favors common words.
    /// Use this when the input is likely a common word with multiple typos.
    case frequencyBoosted
}

// MARK: - SuggestionScorer

/// Calculates combined scores for ranking suggestions.
///
/// Supports three ranking modes:
/// - `.distanceFirst`: Traditional SymSpell behavior (distance primary, frequency tiebreaker)
/// - `.balanced`: Weighs both distance and frequency (common words can outrank closer rare words)
/// - `.frequencyBoosted`: Strongly favors common words
///
/// Additionally supports bigram context: if a previous word is provided, suggestions that
/// commonly follow that word get a score boost.
///
/// All weights are configurable via `SymSpellConfiguration`.
struct SuggestionScorer {
    let maxEditDistance: Int
    let maxFrequency: Int
    let maxBigramFrequency: Int
    let mode: RankingMode
    let config: SymSpellConfiguration

    init(maxEditDistance: Int, maxFrequency: Int, maxBigramFrequency: Int = 0, mode: RankingMode, config: SymSpellConfiguration = .default) {
        self.maxEditDistance = maxEditDistance
        self.maxFrequency = maxFrequency
        self.maxBigramFrequency = maxBigramFrequency
        self.mode = mode
        self.config = config
    }

    /// Calculate a combined score for a suggestion (higher is better).
    ///
    /// - Parameters:
    ///   - distance: Edit distance from input
    ///   - frequency: Word frequency from dictionary
    ///   - bigramFrequency: Bigram frequency with previous word (0 if no context)
    /// - Returns: Combined score (higher = better ranking)
    func score(distance: Int, frequency: Int, bigramFrequency: Int = 0) -> Double {
        // Exact match bonus: very small to act as a tiebreaker only.
        // When comparing candidates in bigram context, we want bigram scoring to decide.
        // The lookup logic already returns early for exact matches when there's no previousWord,
        // so we don't need a large bonus here - just a small tiebreaker for equal scores.
        let exactMatchBonus: Double = distance == 0 ? 0.01 : 0.0

        switch mode {
        case .distanceFirst:
            // Traditional: distance primary, frequency secondary (as tiebreaker)
            // Bigram context adds a bonus to the frequency score
            let distanceScore = Double(maxEditDistance + 1 - distance) * 1_000_000_000.0
            var freqScore = Double(frequency)

            // Bigram bonus: if this word commonly follows the previous word, boost it
            if bigramFrequency > 0 {
                freqScore += Double(bigramFrequency) * config.distanceFirst.bigramBonusMultiplier
            }

            return distanceScore + freqScore

        case .balanced:
            // Balanced: combine distance, frequency, and bigram context
            let normalizedFreq = maxFrequency > 0
                ? log10(Double(frequency) + 1) / log10(Double(maxFrequency) + 1)
                : 0.0

            let distancePenalty = Double(distance) / Double(max(1, maxEditDistance))

            // Bigram bonus
            var bigramBonus = 0.0
            if bigramFrequency > 0 && maxBigramFrequency > 0 {
                let normalizedBigram = log10(Double(bigramFrequency) + 1) / log10(Double(maxBigramFrequency) + 1)
                bigramBonus = normalizedBigram * config.balanced.bigramBonusWeight
            }

            // Combined score using configurable weights
            return exactMatchBonus +
                   (1.0 - distancePenalty) * config.balanced.distanceWeight +
                   normalizedFreq * config.balanced.frequencyWeight +
                   bigramBonus

        case .frequencyBoosted:
            // Aggressive frequency boosting with bigram context
            let normalizedFreq = maxFrequency > 0
                ? log10(Double(frequency) + 1) / log10(Double(maxFrequency) + 1)
                : 0.0

            let distancePenalty = Double(distance) / Double(max(1, maxEditDistance))

            // Stronger bigram bonus
            var bigramBonus = 0.0
            if bigramFrequency > 0 && maxBigramFrequency > 0 {
                let normalizedBigram = log10(Double(bigramFrequency) + 1) / log10(Double(maxBigramFrequency) + 1)
                bigramBonus = normalizedBigram * config.frequencyBoosted.bigramBonusWeight
            }

            // Combined score using configurable weights
            return exactMatchBonus +
                   (1.0 - distancePenalty) * config.frequencyBoosted.distanceWeight +
                   normalizedFreq * config.frequencyBoosted.frequencyWeight +
                   bigramBonus
        }
    }
}

// MARK: - MMapDictionary

/// Memory-mapped dictionary for word frequencies.
///
/// Binary format:
/// - Header: [num_words: 4 bytes (UInt32, little-endian)]
/// - Word index: [offset: 4 bytes] * num_words (points into data section)
/// - Data section: [word_len: 1 byte][word: variable UTF-8][count: 8 bytes (UInt64)] * num_words
///
/// Words are stored sorted alphabetically for binary search.
public class MMapDictionary {
    private static let headerSize = 4  // num_words
    private static let indexEntrySize = 4  // offset

    private let filePath: URL
    private var data: Data?
    private(set) var numWords: Int = 0
    private var dataStart: Int = 0

    // Small LRU cache for frequently accessed words
    private var wordCache: [String: Int] = [:]
    var cacheMaxSize: Int = 1000

    public init(filePath: URL) {
        self.filePath = filePath
    }

    /// Build the mmap file from a list of (word, count) pairs
    public func build(words: [(String, Int)]) throws {
        // Sort words alphabetically
        let sortedWords = words.sorted { $0.0 < $1.0 }
        numWords = sortedWords.count

        // Calculate data start position
        dataStart = Self.headerSize + (numWords * Self.indexEntrySize)

        var fileData = Data()

        // Write header (num_words as UInt32 little-endian)
        var numWordsUInt32 = UInt32(numWords).littleEndian
        fileData.append(Data(bytes: &numWordsUInt32, count: 4))

        // First pass: calculate offsets
        var offsets: [UInt32] = []
        var currentOffset = UInt32(dataStart)
        for (word, _) in sortedWords {
            offsets.append(currentOffset)
            let wordBytes = word.utf8
            // word_len (1 byte) + word + count (8 bytes)
            currentOffset += UInt32(1 + wordBytes.count + 8)
        }

        // Write index
        for offset in offsets {
            var offsetLE = offset.littleEndian
            fileData.append(Data(bytes: &offsetLE, count: 4))
        }

        // Write data
        for (word, count) in sortedWords {
            let wordBytes = Array(word.utf8)
            fileData.append(UInt8(wordBytes.count))
            fileData.append(contentsOf: wordBytes)
            var countUInt64 = UInt64(count).littleEndian
            fileData.append(Data(bytes: &countUInt64, count: 8))
        }

        try fileData.write(to: filePath)
    }

    /// Open the mmap file for reading
    @discardableResult
    public func open() -> Bool {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return false
        }

        do {
            // Memory-map the file for efficient access
            data = try Data(contentsOf: filePath, options: .mappedIfSafe)

            // Read header
            guard let data = data, data.count >= Self.headerSize else {
                return false
            }

            numWords = Int(readUInt32(from: data, at: 0))
            dataStart = Self.headerSize + (numWords * Self.indexEntrySize)

            return true
        } catch {
            return false
        }
    }

    // MARK: - Safe Binary Reading Helpers

    /// Safely read a UInt32 from data at the given offset (handles alignment)
    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    /// Safely read a UInt64 from data at the given offset (handles alignment)
    private func readUInt64(from data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 8))
        }
        return UInt64(littleEndian: value)
    }

    /// Close the mmap file
    public func close() {
        data = nil
        wordCache.removeAll()
    }

    /// Get word and count at a specific index
    func getWordAtIndex(_ idx: Int) -> (word: String, count: Int)? {
        guard let data = data, idx >= 0, idx < numWords else {
            return nil
        }

        // Get offset from index
        let indexOffset = Self.headerSize + (idx * Self.indexEntrySize)
        let dataOffset = Int(readUInt32(from: data, at: indexOffset))

        // Read word
        guard dataOffset < data.count else { return nil }
        let wordLen = Int(data[dataOffset])
        let wordStart = dataOffset + 1
        let wordEnd = wordStart + wordLen

        guard wordEnd <= data.count else { return nil }

        guard let word = String(bytes: data[wordStart..<wordEnd], encoding: .utf8) else {
            return nil
        }

        // Read count
        let countOffset = wordEnd
        guard countOffset + 8 <= data.count else { return nil }

        let count = Int(readUInt64(from: data, at: countOffset))

        return (word, count)
    }

    /// Get count for a word using binary search
    public func get(_ word: String) -> Int {
        guard data != nil else { return 0 }

        // Check cache first
        if let cached = wordCache[word] {
            return cached
        }

        // Binary search
        var left = 0
        var right = numWords - 1

        while left <= right {
            let mid = (left + right) / 2
            guard let (midWord, midCount) = getWordAtIndex(mid) else { break }

            if midWord == word {
                // Add to cache
                updateCache(word: word, count: midCount)
                return midCount
            } else if midWord < word {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }

        return 0
    }

    private func updateCache(word: String, count: Int) {
        if wordCache.count >= cacheMaxSize {
            // Simple cache eviction: remove half
            let keysToRemove = Array(wordCache.keys.prefix(cacheMaxSize / 2))
            for key in keysToRemove {
                wordCache.removeValue(forKey: key)
            }
        }
        wordCache[word] = count
    }

    /// Check if word exists in dictionary
    public func contains(_ word: String) -> Bool {
        return get(word) > 0
    }

    /// Estimate the maximum word frequency in the dictionary.
    ///
    /// Samples common English words and returns the highest frequency found.
    /// This is used for normalizing frequency scores in ranking.
    func estimateMaxFrequency() -> Int {
        // Sample common English words that typically have highest frequencies
        let commonWords = ["the", "of", "and", "a", "to", "in", "is", "you", "that", "it"]
        var maxFreq = 0

        for word in commonWords {
            let freq = get(word)
            if freq > maxFreq {
                maxFreq = freq
            }
        }

        // If no common words found, scan first 100 entries
        if maxFreq == 0 {
            for i in 0..<min(100, numWords) {
                if let (_, count) = getWordAtIndex(i) {
                    maxFreq = max(maxFreq, count)
                }
            }
        }

        return maxFreq
    }

    /// Find the range of indices for words starting with the given prefix.
    ///
    /// Uses binary search to find the first word >= prefix, then scans forward.
    ///
    /// - Parameters:
    ///   - prefix: The prefix to search for
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of (word, count) tuples sorted by count descending
    func findWordsWithPrefix(_ prefix: String, limit: Int) -> [(word: String, count: Int)] {
        guard data != nil, numWords > 0, !prefix.isEmpty else { return [] }

        // Binary search to find first word >= prefix
        var left = 0
        var right = numWords - 1
        var firstIndex = numWords

        while left <= right {
            let mid = (left + right) / 2
            guard let (midWord, _) = getWordAtIndex(mid) else { break }

            if midWord < prefix {
                left = mid + 1
            } else {
                firstIndex = mid
                right = mid - 1
            }
        }

        // Collect words starting with prefix
        var results: [(word: String, count: Int)] = []
        var idx = firstIndex

        while idx < numWords {
            guard let (word, count) = getWordAtIndex(idx) else { break }

            // Check if word still starts with prefix
            if !word.hasPrefix(prefix) {
                break
            }

            results.append((word, count))
            idx += 1

            // Collect more than limit to allow sorting by frequency
            if results.count >= limit * 10 {
                break
            }
        }

        // Sort by count descending and return top results
        results.sort { $0.count > $1.count }
        return Array(results.prefix(limit))
    }
}

// MARK: - MMapDeletes

/// Memory-mapped deletes index for spell checking.
///
/// Binary format:
/// - Header: [num_entries: 4 bytes (UInt32, little-endian)]
/// - Offset index: [offset: 4 bytes] * num_entries (for binary search without loading keys)
/// - Entries: sorted by delete_key
///   - [key_len: 1 byte][key: variable UTF-8][num_suggestions: 2 bytes (UInt16)][suggestion_indices: 4 bytes each (UInt32)]
///
/// Keys are read from mmap during binary search - not loaded into memory.
public class MMapDeletes {
    private let filePath: URL
    private var data: Data?
    private(set) var numEntries: Int = 0
    private var dataStart: Int = 0

    public init(filePath: URL) {
        self.filePath = filePath
    }

    /// Build the mmap file from deletes dictionary
    public func build(deletes: [String: [Int]]) throws {
        // Sort keys
        let sortedKeys = deletes.keys.sorted()
        numEntries = sortedKeys.count

        // Calculate data start (after header + index)
        dataStart = 4 + (numEntries * 4)

        var fileData = Data()

        // Write header
        var numEntriesUInt32 = UInt32(numEntries).littleEndian
        fileData.append(Data(bytes: &numEntriesUInt32, count: 4))

        // First pass: calculate offsets
        var offsets: [UInt32] = []
        var currentOffset = UInt32(dataStart)
        for key in sortedKeys {
            offsets.append(currentOffset)
            let keyBytes = key.utf8
            let numSuggestions = deletes[key]?.count ?? 0
            currentOffset += UInt32(1 + keyBytes.count + 2 + (numSuggestions * 4))
        }

        // Write offset index
        for offset in offsets {
            var offsetLE = offset.littleEndian
            fileData.append(Data(bytes: &offsetLE, count: 4))
        }

        // Write entries
        for key in sortedKeys {
            guard let suggestions = deletes[key] else { continue }
            let keyBytes = Array(key.utf8)

            fileData.append(UInt8(keyBytes.count))
            fileData.append(contentsOf: keyBytes)

            var numSuggestions = UInt16(suggestions.count).littleEndian
            fileData.append(Data(bytes: &numSuggestions, count: 2))

            for idx in suggestions {
                var idxUInt32 = UInt32(idx).littleEndian
                fileData.append(Data(bytes: &idxUInt32, count: 4))
            }
        }

        try fileData.write(to: filePath)
    }

    /// Open mmap file
    @discardableResult
    public func open() -> Bool {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return false
        }

        do {
            data = try Data(contentsOf: filePath, options: .mappedIfSafe)

            guard let data = data, data.count >= 4 else {
                return false
            }

            // Read header
            numEntries = Int(readUInt32(from: data, at: 0))
            dataStart = 4 + (numEntries * 4)

            return true
        } catch {
            return false
        }
    }

    /// Close the mmap file
    public func close() {
        data = nil
    }

    // MARK: - Safe Binary Reading Helpers

    /// Safely read a UInt32 from data at the given offset (handles alignment)
    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    /// Safely read a UInt16 from data at the given offset (handles alignment)
    private func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        var value: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 2))
        }
        return UInt16(littleEndian: value)
    }

    /// Read key at index from mmap (no memory allocation for storage)
    private func getKeyAtIndex(_ idx: Int) -> String? {
        guard let data = data, idx >= 0, idx < numEntries else {
            return nil
        }

        // Get offset from index
        let indexPos = 4 + (idx * 4)
        let offset = Int(readUInt32(from: data, at: indexPos))

        // Read key
        guard offset < data.count else { return nil }
        let keyLen = Int(data[offset])
        let keyStart = offset + 1
        let keyEnd = keyStart + keyLen

        guard keyEnd <= data.count else { return nil }

        return String(bytes: data[keyStart..<keyEnd], encoding: .utf8)
    }

    /// Read suggestions at index from mmap
    private func getSuggestionsAtIndex(_ idx: Int) -> [Int] {
        guard let data = data, idx >= 0, idx < numEntries else {
            return []
        }

        // Get offset from index
        let indexPos = 4 + (idx * 4)
        let offset = Int(readUInt32(from: data, at: indexPos))

        // Skip key, read suggestions
        guard offset < data.count else { return [] }
        let keyLen = Int(data[offset])
        let numSuggestionsOffset = offset + 1 + keyLen

        guard numSuggestionsOffset + 2 <= data.count else { return [] }

        let numSuggestions = Int(readUInt16(from: data, at: numSuggestionsOffset))

        var suggestions: [Int] = []
        suggestions.reserveCapacity(numSuggestions)

        let suggestionsStart = numSuggestionsOffset + 2
        for i in 0..<numSuggestions {
            let suggestionOffset = suggestionsStart + (i * 4)
            guard suggestionOffset + 4 <= data.count else { break }

            let suggestionIdx = Int(readUInt32(from: data, at: suggestionOffset))
            suggestions.append(suggestionIdx)
        }

        return suggestions
    }

    /// Get suggestion indices for a delete key using binary search
    public func get(_ key: String) -> [Int] {
        guard data != nil, numEntries > 0 else { return [] }

        // Binary search - read keys from mmap, don't store in memory
        var left = 0
        var right = numEntries - 1

        while left <= right {
            let mid = (left + right) / 2
            guard let midKey = getKeyAtIndex(mid) else { break }

            if midKey == key {
                return getSuggestionsAtIndex(mid)
            } else if midKey < key {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }

        return []
    }
}

// MARK: - LowMemorySymSpell

/// Memory-efficient SymSpell using memory-mapped files.
///
/// This implementation stores dictionaries in memory-mapped binary files instead of RAM,
/// making it suitable for memory-constrained environments like iOS keyboard extensions (~50MB limit).
///
/// Usage:
/// ```swift
/// let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7)
///
/// // Option 1: Load pre-built files (recommended for iOS)
/// let dataDir = Bundle.main.resourceURL!.appendingPathComponent("mmap_data")
/// spellChecker.loadPrebuilt(from: dataDir)
///
/// // Option 2: Build from dictionary file
/// spellChecker.loadDictionary(corpus: dictionaryPath)
///
/// // Lookup suggestions
/// let suggestions = spellChecker.lookup(phrase: "helo", verbosity: .top)
/// ```
///
/// For keyboard-aware spell checking with spatial error weighting:
/// ```swift
/// let spellChecker = LowMemorySymSpell(
///     maxEditDistance: 2,
///     prefixLength: 7,
///     keyboardLayout: .qwerty
/// )
/// // Load keyboard layout from directory containing keyboard_qwerty.bin
/// spellChecker.loadKeyboardLayout(from: keyboardLayoutDir)
/// ```
public class LowMemorySymSpell {
    /// Maximum edit distance for lookups
    public let maxEditDistance: Int
    /// Length of word prefixes for spell checking
    public let prefixLength: Int
    /// Keyboard layout for spatial error weighting
    public let keyboardLayout: KeyboardLayout
    /// Ranking mode for sorting suggestions
    public let rankingMode: RankingMode
    /// Configuration for tunable parameters (thresholds, weights, etc.)
    public var configuration: SymSpellConfiguration

    // Data directory
    private let dataDir: URL
    private let shouldCleanupDataDir: Bool

    // File paths
    private let wordsPath: URL
    private let deletesPath: URL
    private let bigramsPath: URL

    // Memory-mapped structures
    private let words: MMapDictionary
    private let deletes: MMapDeletes
    private let bigrams: MMapDictionary

    // Keyboard layout for spatial weighting
    private var keyboard: MMapKeyboardLayout?

    // Statistics
    public private(set) var wordCount: Int = 0
    public private(set) var bigramCount: Int = 0
    /// Maximum word frequency in dictionary (for ranking normalization)
    public private(set) var maxFrequency: Int = 0
    /// Maximum bigram frequency (for ranking normalization)
    public private(set) var maxBigramFrequency: Int = 0

    /// Create a new LowMemorySymSpell instance.
    ///
    /// - Parameters:
    ///   - maxEditDistance: Maximum edit distance for lookups (default: 2)
    ///   - prefixLength: Length of word prefixes for spell checking (default: 7)
    ///   - keyboardLayout: Keyboard layout for spatial error weighting (default: .none)
    ///   - rankingMode: How to rank suggestions - `.distanceFirst` (default), `.balanced`, or `.frequencyBoosted`
    ///   - configuration: Configuration for tunable parameters (default: .default)
    ///   - dataDir: Directory for mmap files. If nil, uses a temporary directory.
    public init(
        maxEditDistance: Int = 2,
        prefixLength: Int = 7,
        keyboardLayout: KeyboardLayout = .none,
        rankingMode: RankingMode = .distanceFirst,
        configuration: SymSpellConfiguration = .default,
        dataDir: URL? = nil
    ) {
        self.maxEditDistance = maxEditDistance
        self.prefixLength = prefixLength
        self.keyboardLayout = keyboardLayout
        self.rankingMode = rankingMode
        self.configuration = configuration

        if let dataDir = dataDir {
            self.dataDir = dataDir
            self.shouldCleanupDataDir = false
        } else {
            self.dataDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("symspell_mmap_\(UUID().uuidString)")
            self.shouldCleanupDataDir = true
            try? FileManager.default.createDirectory(at: self.dataDir, withIntermediateDirectories: true)
        }

        self.wordsPath = self.dataDir.appendingPathComponent("words.bin")
        self.deletesPath = self.dataDir.appendingPathComponent("deletes.bin")
        self.bigramsPath = self.dataDir.appendingPathComponent("bigrams.bin")

        self.words = MMapDictionary(filePath: wordsPath)
        self.deletes = MMapDeletes(filePath: deletesPath)
        self.bigrams = MMapDictionary(filePath: bigramsPath)

        // Initialize keyboard layout if specified
        if keyboardLayout != .none {
            self.keyboard = MMapKeyboardLayout(layout: keyboardLayout)
        }
    }

    deinit {
        close()
    }

    // MARK: - Loading Methods

    /// Load pre-built mmap files without building.
    ///
    /// Use this for iOS/low-memory devices where files are pre-built and shipped with the app.
    ///
    /// - Parameter directory: Directory containing words.bin, deletes.bin, and optionally bigrams.bin
    /// - Returns: True if pre-built files were loaded successfully
    @discardableResult
    public func loadPrebuilt(from directory: URL) -> Bool {
        let wordsFile = directory.appendingPathComponent("words.bin")
        let deletesFile = directory.appendingPathComponent("deletes.bin")
        let bigramsFile = directory.appendingPathComponent("bigrams.bin")

        // Check if required files exist
        guard FileManager.default.fileExists(atPath: wordsFile.path),
              FileManager.default.fileExists(atPath: deletesFile.path) else {
            return false
        }

        // Create new MMapDictionary/MMapDeletes with the correct paths
        let wordsDict = MMapDictionary(filePath: wordsFile)
        let deletesIdx = MMapDeletes(filePath: deletesFile)

        guard wordsDict.open() else { return false }
        wordCount = wordsDict.numWords

        guard deletesIdx.open() else { return false }

        // Copy the opened instances
        // Note: We need to use the directory-based files directly
        // Update our internal references to point to the prebuilt files

        // Close our default instances and reopen with prebuilt paths
        words.close()
        deletes.close()

        // Reload from prebuilt directory
        let prebuiltWords = MMapDictionary(filePath: wordsFile)
        let prebuiltDeletes = MMapDeletes(filePath: deletesFile)

        guard prebuiltWords.open() else { return false }
        guard prebuiltDeletes.open() else { return false }

        // Store references (we'll use a different approach - store the paths and reload)
        _prebuiltWordsPath = wordsFile
        _prebuiltDeletesPath = deletesFile
        _prebuiltWords = prebuiltWords
        _prebuiltDeletes = prebuiltDeletes

        wordCount = prebuiltWords.numWords

        // Estimate max frequency for ranking normalization
        maxFrequency = prebuiltWords.estimateMaxFrequency()

        // Bigrams are optional
        if FileManager.default.fileExists(atPath: bigramsFile.path) {
            let bigramsDict = MMapDictionary(filePath: bigramsFile)
            if bigramsDict.open() {
                _prebuiltBigramsPath = bigramsFile
                _prebuiltBigrams = bigramsDict
                bigramCount = bigramsDict.numWords
                maxBigramFrequency = bigramsDict.estimateMaxFrequency()
            }
        }

        return true
    }

    // Prebuilt file references (used when loading from external directory)
    private var _prebuiltWordsPath: URL?
    private var _prebuiltDeletesPath: URL?
    private var _prebuiltBigramsPath: URL?
    private var _prebuiltWords: MMapDictionary?
    private var _prebuiltDeletes: MMapDeletes?
    private var _prebuiltBigrams: MMapDictionary?

    // Accessor properties for the active dictionaries
    private var activeWords: MMapDictionary {
        return _prebuiltWords ?? words
    }

    private var activeDeletes: MMapDeletes {
        return _prebuiltDeletes ?? deletes
    }

    private var activeBigrams: MMapDictionary {
        return _prebuiltBigrams ?? bigrams
    }

    /// Load dictionary from a text file into mmap structures.
    ///
    /// - Parameters:
    ///   - corpus: Path to the dictionary file
    ///   - termIndex: Column position of the word (default: 0)
    ///   - countIndex: Column position of the frequency count (default: 1)
    ///   - separator: Column separator (default: " ")
    /// - Returns: True if dictionary was loaded successfully
    @discardableResult
    public func loadDictionary(
        corpus: URL,
        termIndex: Int = 0,
        countIndex: Int = 1,
        separator: String = " "
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: corpus.path) else {
            return false
        }

        guard let content = try? String(contentsOf: corpus, encoding: .utf8) else {
            return false
        }

        var wordsList: [(String, Int)] = []

        for line in content.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: separator)
            guard parts.count >= max(termIndex, countIndex) + 1 else { continue }

            let term = parts[termIndex]
            guard let count = Int(parts[countIndex]) else { continue }

            wordsList.append((term, count))
        }

        return buildFromWordsList(wordsList)
    }

    /// Load only the top N most frequent words from dictionary.
    ///
    /// This significantly reduces memory usage and file sizes.
    /// Recommended for iOS: n=10000-30000 for good spell checking.
    ///
    /// - Parameters:
    ///   - corpus: Path to the dictionary file
    ///   - n: Number of top words to load
    ///   - termIndex: Column position of the word (default: 0)
    ///   - countIndex: Column position of the frequency count (default: 1)
    ///   - separator: Column separator (default: " ")
    /// - Returns: True if dictionary was loaded successfully
    @discardableResult
    public func loadDictionaryTopN(
        corpus: URL,
        n: Int,
        termIndex: Int = 0,
        countIndex: Int = 1,
        separator: String = " "
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: corpus.path) else {
            return false
        }

        guard let content = try? String(contentsOf: corpus, encoding: .utf8) else {
            return false
        }

        var wordsList: [(String, Int)] = []

        for line in content.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: separator)
            guard parts.count >= max(termIndex, countIndex) + 1 else { continue }

            let term = parts[termIndex]
            guard let count = Int(parts[countIndex]) else { continue }

            wordsList.append((term, count))
        }

        // Sort by count descending and take top N
        wordsList.sort { $0.1 > $1.1 }
        wordsList = Array(wordsList.prefix(n))

        return buildFromWordsList(wordsList)
    }

    /// Load bigram dictionary into mmap.
    ///
    /// - Parameters:
    ///   - corpus: Path to the bigram dictionary file
    ///   - termIndex: Column position of the first word (default: 0)
    ///   - countIndex: Column position of the frequency count (default: 2)
    ///   - separator: Column separator. If nil, uses whitespace and treats termIndex as word1, termIndex+1 as word2
    /// - Returns: True if bigram dictionary was loaded successfully
    @discardableResult
    public func loadBigramDictionary(
        corpus: URL,
        termIndex: Int = 0,
        countIndex: Int = 2,
        separator: String? = nil
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: corpus.path) else {
            return false
        }

        guard let content = try? String(contentsOf: corpus, encoding: .utf8) else {
            return false
        }

        var bigramsList: [(String, Int)] = []
        let sep = separator ?? " "
        let minParts = separator == nil ? 3 : 2

        for line in content.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: sep)
            guard parts.count >= minParts else { continue }

            guard let count = Int(parts[countIndex]) else { continue }

            let key: String
            if separator == nil {
                key = "\(parts[termIndex]) \(parts[termIndex + 1])"
            } else {
                key = parts[termIndex]
            }

            bigramsList.append((key, count))
        }

        // Track max bigram frequency for ranking normalization
        maxBigramFrequency = bigramsList.map { $0.1 }.max() ?? 0

        do {
            try bigrams.build(words: bigramsList)
            bigrams.open()
            bigramCount = bigrams.numWords
            return true
        } catch {
            return false
        }
    }

    /// Load keyboard layout from a directory containing layout files.
    ///
    /// The directory should contain files like `keyboard_qwerty.bin`, `keyboard_azerty.bin`, etc.
    /// The appropriate file is selected based on the `keyboardLayout` set during initialization.
    ///
    /// - Parameter directory: Directory containing keyboard layout .bin files
    /// - Returns: true if keyboard layout was loaded successfully
    @discardableResult
    public func loadKeyboardLayout(from directory: URL) -> Bool {
        guard keyboardLayout != .none else { return true }

        if keyboard == nil {
            keyboard = MMapKeyboardLayout(layout: keyboardLayout)
        }

        return keyboard?.loadFromDirectory(directory) ?? false
    }

    /// Load keyboard layout from a specific file.
    ///
    /// - Parameter path: Path to the keyboard layout .bin file
    /// - Returns: true if keyboard layout was loaded successfully
    @discardableResult
    public func loadKeyboardLayoutFile(from path: URL) -> Bool {
        guard keyboardLayout != .none else { return true }

        if keyboard == nil {
            keyboard = MMapKeyboardLayout(layout: keyboardLayout)
        }

        return keyboard?.load(from: path) ?? false
    }

    /// Check if keyboard layout is loaded and active.
    public var isKeyboardLayoutLoaded: Bool {
        guard keyboardLayout != .none else { return false }
        return keyboard != nil
    }

    // MARK: - Private Building Methods

    private func buildFromWordsList(_ wordsList: [(String, Int)]) -> Bool {
        // Sort alphabetically for binary search
        let sortedWords = wordsList.sorted { $0.0 < $1.0 }

        // Track max frequency for ranking normalization
        maxFrequency = sortedWords.map { $0.1 }.max() ?? 0

        // Build words mmap
        do {
            try words.build(words: sortedWords)
            words.open()
            wordCount = words.numWords
        } catch {
            return false
        }

        // Build deletes index
        var deletesDict: [String: [Int]] = [:]

        for (idx, (term, _)) in sortedWords.enumerated() {
            // Add empty string for short words
            if term.count <= maxEditDistance {
                deletesDict["", default: []].append(idx)
            }

            // Generate deletes from prefix
            let prefix = term.count > prefixLength ? String(term.prefix(prefixLength)) : term
            var deleteSet = Set<String>()
            generateDeletes(word: prefix, editDistance: 0, deletes: &deleteSet)
            deleteSet.insert(prefix)

            for delete in deleteSet {
                deletesDict[delete, default: []].append(idx)
            }
        }

        // Build deletes mmap
        do {
            try deletes.build(deletes: deletesDict)
            deletes.open()
        } catch {
            return false
        }

        return true
    }

    /// Generate all deletion variants of a word within edit distance
    private func generateDeletes(word: String, editDistance: Int, deletes: inout Set<String>) {
        let nextDistance = editDistance + 1
        guard !word.isEmpty else { return }

        for i in word.indices {
            var delete = word
            delete.remove(at: i)

            if !deletes.contains(delete) {
                deletes.insert(delete)

                if nextDistance < maxEditDistance {
                    generateDeletes(word: delete, editDistance: nextDistance, deletes: &deletes)
                }
            }
        }
    }

    // MARK: - Spell Checking

    /// Find suggested spellings for a word.
    ///
    /// - Parameters:
    ///   - phrase: The word being spell checked
    ///   - verbosity: Controls quantity/closeness of returned suggestions
    ///   - maxEditDistance: Maximum edit distance (defaults to instance maxEditDistance)
    ///   - includeUnknown: If true, include the input term in results even if not found
    ///   - transferCasing: If true, preserve the user's original casing in suggestions
    ///   - previousWord: Previous word for bigram context (boosts words that commonly follow it)
    /// - Returns: Array of SuggestItem representing suggested corrections
    ///
    /// **Ranking Modes:**
    /// - `.distanceFirst` (default): Traditional SymSpell - closest edit distance wins
    /// - `.balanced`: Weighs distance + frequency + bigram context together
    /// - `.frequencyBoosted`: Strongly favors common words and bigram matches
    ///
    /// **Example with context:**
    /// ```swift
    /// // "th" after "the" is likely "the" (bigram "the the" is rare but "the quick" is common)
    /// let suggestions = spellChecker.lookup(phrase: "qick", verbosity: .closest, previousWord: "the")
    /// // Returns "quick" ranked higher due to "the quick" bigram
    /// ```
    public func lookup(
        phrase: String,
        verbosity: LowMemoryVerbosity,
        maxEditDistance: Int? = nil,
        includeUnknown: Bool = false,
        transferCasing: Bool = false,
        previousWord: String? = nil
    ) -> [SuggestItem] {
        let maxDist = min(maxEditDistance ?? self.maxEditDistance, self.maxEditDistance)
        var suggestions: [SuggestItem] = []

        let originalPhrase = phrase
        let phrase = transferCasing ? phrase.lowercased() : phrase
        let phraseLen = phrase.count

        // Check for exact match
        let count = activeWords.get(phrase)
        var hasExactMatch = false
        if count > 0 {
            let term = transferCasing ? originalPhrase : phrase
            suggestions.append(SuggestItem(term: term, distance: 0, count: count))
            hasExactMatch = true
            // When previousWord is provided, continue searching for alternatives
            // so bigram context can potentially rank a different word higher.
            // e.g., "wonder bow" should find "how" because "wonder how" is a common bigram.
            if verbosity != .all && previousWord == nil {
                return suggestions
            }
        }

        if maxDist == 0 {
            if includeUnknown && suggestions.isEmpty {
                suggestions.append(SuggestItem(term: phrase, distance: maxDist + 1, count: 0))
            }
            return suggestions
        }

        // Generate candidates
        var consideredSuggestions = Set<String>([phrase])
        // When we have an exact match and bigram context, limit search to distance 1
        // alternatives. We don't need distance 2+ since we already have the exact word.
        var maxEditDistance2 = (hasExactMatch && previousWord != nil) ? min(1, maxDist) : maxDist
        var candidates: [String] = []

        let phrasePrefixLen = min(phraseLen, prefixLength)
        candidates.append(String(phrase.prefix(phrasePrefixLen)))

        var candidatePointer = 0
        while candidatePointer < candidates.count {
            let candidate = candidates[candidatePointer]
            candidatePointer += 1
            let candidateLen = candidate.count
            let lenDiff = phrasePrefixLen - candidateLen

            if lenDiff > maxEditDistance2 {
                if verbosity == .all {
                    continue
                }
                break
            }

            // Get suggestions from deletes index
            let suggestionIndices = activeDeletes.get(candidate)

            for idx in suggestionIndices {
                guard let (suggestion, suggestionCount) = activeWords.getWordAtIndex(idx) else { continue }

                if suggestion.isEmpty || suggestion == phrase {
                    continue
                }

                let suggestionLen = suggestion.count

                // Quick rejection tests
                if abs(suggestionLen - phraseLen) > maxEditDistance2 ||
                   suggestionLen < candidateLen ||
                   (suggestionLen == candidateLen && suggestion != candidate) {
                    continue
                }

                if consideredSuggestions.contains(suggestion) {
                    continue
                }
                consideredSuggestions.insert(suggestion)

                // Calculate edit distance
                let distance = damerauLevenshteinDistance(phrase, suggestion, maxEditDistance2)

                if distance < 0 {
                    continue
                }

                if distance <= maxEditDistance2 {
                    var item = SuggestItem(term: suggestion, distance: distance, count: suggestionCount)

                    if transferCasing {
                        item.term = transferCase(from: originalPhrase, to: suggestion)
                    }

                    if !suggestions.isEmpty {
                        // When we have an exact match and bigram context, use .all behavior
                        // to keep the exact match AND add alternatives for ranking comparison.
                        // e.g., "wonder bow" keeps "bow" (exact) and adds "how" (distance 1),
                        // then ranking uses bigram "wonder how" to decide final order.
                        let useAllBehavior = hasExactMatch && previousWord != nil

                        switch verbosity {
                        case .closest:
                            if useAllBehavior {
                                // Keep exact match, add this suggestion for ranking
                                suggestions.append(item)
                            } else {
                                if distance < maxEditDistance2 {
                                    suggestions.removeAll()
                                }
                                maxEditDistance2 = distance
                                suggestions.append(item)
                            }

                        case .top:
                            if useAllBehavior {
                                // Keep exact match, add this suggestion for ranking
                                suggestions.append(item)
                            } else {
                                if distance < maxEditDistance2 || suggestionCount > suggestions[0].count {
                                    maxEditDistance2 = distance
                                    suggestions[0] = item
                                }
                                continue
                            }

                        case .all:
                            suggestions.append(item)
                        }
                    } else {
                        if verbosity != .all {
                            maxEditDistance2 = distance
                        }
                        suggestions.append(item)
                    }
                }
            }

            // Generate more delete candidates
            if lenDiff < maxDist && candidateLen <= prefixLength {
                if verbosity != .all && lenDiff >= maxEditDistance2 {
                    continue
                }

                for i in candidate.indices {
                    var delete = candidate
                    delete.remove(at: i)
                    if !consideredSuggestions.contains(delete) {
                        candidates.append(delete)
                    }
                }
            }
        }

        if suggestions.count > 1 {
            // Apply custom ranking based on rankingMode
            if rankingMode == .distanceFirst && previousWord == nil {
                // Traditional SymSpell sorting
                suggestions.sort()
            } else {
                // Use scorer for balanced/frequencyBoosted modes or when context is provided
                let scorer = SuggestionScorer(
                    maxEditDistance: maxDist,
                    maxFrequency: maxFrequency,
                    maxBigramFrequency: maxBigramFrequency,
                    mode: rankingMode,
                    config: configuration
                )

                // Calculate scores with bigram context
                let prevWord = previousWord?.lowercased()
                var scoredSuggestions: [(item: SuggestItem, score: Double)] = suggestions.map { item in
                    var bigramFreq = 0
                    if let prev = prevWord {
                        let bigram = "\(prev) \(item.term.lowercased())"
                        bigramFreq = activeBigrams.get(bigram)
                    }
                    let score = scorer.score(distance: item.distance, frequency: item.count, bigramFrequency: bigramFreq)
                    return (item, score)
                }

                // Sort by score (descending)
                scoredSuggestions.sort { $0.score > $1.score }
                suggestions = scoredSuggestions.map { $0.item }
            }
        }

        if includeUnknown && suggestions.isEmpty {
            suggestions.append(SuggestItem(term: phrase, distance: maxDist + 1, count: 0))
        }

        return suggestions
    }

    // MARK: - Prefix Completion

    /// Find words that start with the given prefix, sorted by frequency.
    ///
    /// Use this as a fallback when `lookup()` returns no spelling corrections.
    ///
    /// - Parameters:
    ///   - prefix: The prefix to search for
    ///   - limit: Maximum number of results to return (default: 5)
    ///   - minFrequency: Minimum word frequency to include. If nil, uses adaptive threshold
    ///                   based on prefix length (shorter prefix = higher threshold to avoid rare words).
    /// - Returns: Array of SuggestItem with distance 0, sorted by frequency (highest first)
    ///
    /// Example:
    /// ```swift
    /// let completions = symSpell.prefixLookup(prefix: "hel", limit: 3)
    /// // Returns: ["hello", "help", "helmet", ...] sorted by frequency
    /// ```
    ///
    /// **Frequency Filtering:**
    /// For short prefixes (1-3 chars), rare words are filtered out to avoid suggesting
    /// obscure words like "Thackeray" for prefix "Tha". The threshold scales with prefix length:
    /// - 1-2 chars: min frequency 10000 (only very common words)
    /// - 3 chars: min frequency 1000
    /// - 4+ chars: min frequency 100
    public func prefixLookup(prefix: String, limit: Int = 5, minFrequency: Int? = nil) -> [SuggestItem] {
        let lowercasePrefix = prefix.lowercased()

        guard !lowercasePrefix.isEmpty else { return [] }

        // Calculate adaptive minimum frequency based on prefix length
        // Short prefixes require higher frequency to avoid rare word suggestions
        let adaptiveMinFreq: Int
        if let minFreq = minFrequency {
            adaptiveMinFreq = minFreq
        } else {
            switch lowercasePrefix.count {
            case 1...2:
                adaptiveMinFreq = 10000  // Only very common words for 1-2 char prefixes
            case 3:
                adaptiveMinFreq = 1000   // Common words for 3 char prefixes
            case 4:
                adaptiveMinFreq = 100    // Most words for 4 char prefixes
            default:
                adaptiveMinFreq = 10     // Nearly all words for 5+ char prefixes
            }
        }

        // Get more matches than needed, then filter by frequency
        let matches = activeWords.findWordsWithPrefix(lowercasePrefix, limit: limit * 3)

        // Filter by minimum frequency and take top results
        let filtered = matches
            .filter { $0.count >= adaptiveMinFreq }
            .prefix(limit)

        return filtered.map { word, count in
            SuggestItem(term: word, distance: 0, count: count)
        }
    }

    // MARK: - Confidence-Based Auto-Correction

    /// Get a spelling correction with confidence score for auto-replacement decisions.
    ///
    /// Confidence factors in:
    /// - **Edit distance**: Lower distance = higher confidence
    /// - **Frequency ratio**: Clear winner among suggestions = higher confidence
    /// - **Word length**: Short words (< threshold chars) are penalized as they're riskier
    /// - **Ambiguity**: Similar frequencies among top suggestions = lower confidence
    ///
    /// All thresholds and penalties are configurable via `SymSpellConfiguration`.
    ///
    /// - Parameters:
    ///   - word: The word to check for correction
    ///   - minConfidence: Minimum confidence threshold. If nil, uses `configuration.minConfidence`.
    /// - Returns: Tuple of (corrected term, confidence score), or nil if no confident correction
    ///
    /// Returns nil if:
    /// - Input is already a valid dictionary word
    /// - No suggestions found
    /// - Confidence is below minConfidence
    ///
    /// Example:
    /// ```swift
    /// if let (correction, confidence) = symSpell.autoCorrection(for: "teh", minConfidence: 0.8) {
    ///     // Replace "teh" with correction (likely "the")
    /// }
    /// ```
    public func autoCorrection(for word: String, minConfidence: Double? = nil) -> (term: String, confidence: Double)? {
        let threshold = minConfidence ?? configuration.minConfidence
        let lowercaseWord = word.lowercased()
        let wordFrequency = activeWords.get(lowercaseWord)
        let isValid = wordFrequency > 0

        // Get suggestions with all verbosity to assess ambiguity
        let suggestions = lookup(phrase: lowercaseWord, verbosity: .all, maxEditDistance: maxEditDistance)

        guard let top = suggestions.first else {
            return nil  // No suggestions found
        }

        // If word is valid, only suggest correction if there's a MUCH more popular alternative
        if isValid {
            // Find best suggestion that isn't the word itself
            guard let bestAlt = suggestions.first(where: { $0.term != lowercaseWord && $0.distance > 0 }) else {
                return nil  // No alternatives
            }

            // Only consider correction if:
            // 1. Alternative is distance 1 (close typo)
            // 2. Alternative is significantly more popular (configurable ratio)
            let frequencyRatio = Double(bestAlt.count) / Double(max(1, wordFrequency))
            if bestAlt.distance == 1 && frequencyRatio >= configuration.validWordMinFrequencyRatio {
                // Apply heavy penalty - valid words are usually intentional
                let confidence = min(
                    configuration.validWordMaxConfidence,
                    0.3 + (frequencyRatio / 100.0) * 0.3
                )
                if confidence >= threshold {
                    return (bestAlt.term, confidence)
                }
            }

            return nil  // Valid word, keep it
        }

        // Word is not valid - normal correction logic
        guard top.distance > 0 else {
            return nil  // Shouldn't happen, but safety check
        }

        // Calculate confidence score
        var confidence = 1.0

        // Factor 1: Edit distance penalty
        let distancePenalty = Double(top.distance) * configuration.distancePenaltyPerEdit
        confidence -= distancePenalty

        // Factor 2: Frequency ratio / ambiguity
        // If second-best suggestion has similar frequency, reduce confidence
        let sameDistanceSuggestions = suggestions.filter { $0.distance == top.distance }
        if sameDistanceSuggestions.count > 1, let second = sameDistanceSuggestions.dropFirst().first {
            let totalCount = Double(top.count + second.count)
            if totalCount > 0 {
                let ratio = Double(top.count) / totalCount
                // ratio of 0.5 (equal) = full penalty, ratio of 1.0 (clear winner) = 0 penalty
                let ambiguityPenalty = (1.0 - ratio) * configuration.ambiguityPenaltyMultiplier
                confidence -= ambiguityPenalty
            }
        }

        // Factor 3: Short word penalty
        // Words below threshold chars are riskier to auto-correct
        if lowercaseWord.count < configuration.shortWordThreshold {
            let shortWordPenalty = Double(configuration.shortWordThreshold - lowercaseWord.count) * configuration.shortWordPenaltyPerChar
            confidence -= shortWordPenalty
        }

        // Factor 4: Bonus for very high frequency words
        if top.count > configuration.highFrequencyThreshold {
            confidence += configuration.highFrequencyBonus
        }

        // Clamp confidence to [0, 1]
        confidence = max(0.0, min(1.0, confidence))

        // Return nil if below threshold
        guard confidence >= threshold else {
            return nil
        }

        return (top.term, confidence)
    }

    /// Compound word correction for multi-word phrases.
    ///
    /// - Parameters:
    ///   - phrase: The phrase being spell checked
    ///   - maxEditDistance: Maximum edit distance (defaults to instance maxEditDistance)
    ///   - transferCasing: If true, preserve the user's original casing
    /// - Returns: Array with a single SuggestItem containing the corrected phrase
    public func lookupCompound(
        phrase: String,
        maxEditDistance: Int? = nil,
        transferCasing: Bool = false
    ) -> [SuggestItem] {
        let maxDist = maxEditDistance ?? self.maxEditDistance
        let words = phrase.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var correctedWords: [String] = []
        var totalDistance = 0

        for word in words {
            let suggestions = lookup(
                phrase: word,
                verbosity: .top,
                maxEditDistance: maxDist,
                transferCasing: transferCasing
            )

            if let first = suggestions.first {
                correctedWords.append(first.term)
                totalDistance += first.distance
            } else {
                correctedWords.append(word)
                totalDistance += maxDist + 1
            }
        }

        let resultTerm = correctedWords.joined(separator: " ")
        return [SuggestItem(term: resultTerm, distance: totalDistance, count: 1)]
    }

    /// Word segmentation - splits concatenated words with optional spelling correction.
    ///
    /// Uses beam search to explore multiple segmentation + correction hypotheses.
    /// Can handle misspelled concatenated words like "tahtswhat" → "that's what".
    ///
    /// **Examples:**
    /// - `"thequickbrown"` → `"the quick brown"` (pure segmentation)
    /// - `"tahtswhat"` → `"that's what"` (correction + segmentation)
    /// - `"helloworlf"` → `"hello world"` (segmentation + correction)
    ///
    /// **Note:** Best results require bigram dictionary via `loadBigramDictionary()`.
    /// Without bigrams, segmentation still works but may produce less optimal results.
    ///
    /// - Parameters:
    ///   - phrase: The concatenated text to segment
    ///   - maxEditDistance: Maximum edit distance for spelling correction (default: instance maxEditDistance)
    ///   - beamWidth: Number of hypotheses to track. Use 0 for greedy (faster), 10+ for beam search (more accurate)
    /// - Returns: Composition containing the segmented and corrected string
    public func wordSegmentation(phrase: String, maxEditDistance: Int? = nil, beamWidth: Int = 10) -> Composition {
        // Use beam search for correction-aware segmentation
        if beamWidth > 0 {
            return wordSegmentationBeam(
                phrase: phrase,
                maxEditDistance: maxEditDistance,
                beamWidth: beamWidth
            )
        }

        // Fall back to greedy for beamWidth == 0
        return wordSegmentationGreedy(phrase: phrase, maxEditDistance: maxEditDistance)
    }

    /// Greedy word segmentation - faster but cannot correct misspellings mid-segment.
    ///
    /// Splits text like "thequickbrown" into "the quick brown".
    /// Only segments at positions where the resulting word pair exists in the bigram dictionary.
    /// This prevents incorrect segmentations like "woahh" → "w oahh".
    ///
    /// **Important:** Requires bigram dictionary to be loaded via `loadBigramDictionary()`.
    /// Without bigrams loaded, returns the input unchanged.
    ///
    /// - Parameters:
    ///   - phrase: The concatenated text to segment
    ///   - maxEditDistance: Maximum edit distance for spelling correction (default: instance maxEditDistance)
    /// - Returns: Composition containing the segmented and corrected string
    public func wordSegmentationGreedy(phrase: String, maxEditDistance: Int? = nil) -> Composition {
        let maxDist = maxEditDistance ?? self.maxEditDistance
        let input = phrase.lowercased().replacingOccurrences(of: " ", with: "")

        // Without bigrams, we can't safely segment - return input as-is
        guard bigramCount > 0 else {
            return Composition(
                segmentedString: input,
                correctedString: input,
                distanceSum: 0,
                logProbSum: -50.0
            )
        }

        var resultParts: [String] = []
        var i = 0
        var totalDistance = 0

        while i < input.count {
            var bestWord: String? = nil
            var bestLen = 0
            var bestBigramScore = 0

            // Try different lengths (longest first - greedy)
            for length in stride(from: min(20, input.count - i), through: 1, by: -1) {
                let startIdx = input.index(input.startIndex, offsetBy: i)
                let endIdx = input.index(startIdx, offsetBy: length)
                let word = String(input[startIdx..<endIdx])

                let count = activeWords.get(word)
                if count > 0 {
                    // For first word, no bigram check needed
                    // For subsequent words, must have valid bigram with previous word
                    var bigramScore = 1  // Default score for first word
                    if !resultParts.isEmpty {
                        let bigram = "\(resultParts.last!) \(word)"
                        bigramScore = activeBigrams.get(bigram)

                        // If bigram doesn't exist, skip this candidate
                        if bigramScore == 0 {
                            continue
                        }
                    }

                    // Prefer higher bigram score, then longer words
                    let isBetter = bigramScore > bestBigramScore ||
                        (bigramScore == bestBigramScore && length > bestLen)

                    if isBetter {
                        bestWord = word
                        bestLen = length
                        bestBigramScore = bigramScore
                    }
                }
            }

            if let word = bestWord {
                resultParts.append(word)
                i += bestLen
            } else if !resultParts.isEmpty {
                // No valid bigram continuation found - append char to previous word
                let startIdx = input.index(input.startIndex, offsetBy: i)
                let char = String(input[startIdx])
                resultParts[resultParts.count - 1] += char
                totalDistance += 1
                i += 1
            } else {
                // No first word found - try spelling correction
                let maxLen = min(10, input.count - i)
                let startIdx = input.index(input.startIndex, offsetBy: i)
                let endIdx = input.index(startIdx, offsetBy: maxLen)
                let testWord = String(input[startIdx..<endIdx])

                let suggestions = lookup(phrase: testWord, verbosity: .top, maxEditDistance: maxDist)

                if let first = suggestions.first, first.distance <= maxDist {
                    resultParts.append(first.term)
                    totalDistance += first.distance
                    i += testWord.count
                } else {
                    // No match - take single character
                    let charIdx = input.index(input.startIndex, offsetBy: i)
                    resultParts.append(String(input[charIdx]))
                    totalDistance += 1
                    i += 1
                }
            }
        }

        let corrected = resultParts.joined(separator: " ")
        return Composition(
            segmentedString: corrected,
            correctedString: corrected,
            distanceSum: totalDistance,
            logProbSum: -50.0
        )
    }

    /// Correction-aware word segmentation using beam search.
    ///
    /// This advanced segmentation method can handle misspelled concatenated words
    /// by exploring multiple segmentation + correction hypotheses simultaneously.
    ///
    /// **Examples:**
    /// - `"tahtswhat"` → `"that's what"` (correction + segmentation)
    /// - `"helloworlf"` → `"hello world"` (segmentation + correction)
    /// - `"thequickbrown"` → `"the quick brown"` (pure segmentation)
    ///
    /// **Important:** Requires bigram dictionary to be loaded. Without bigrams,
    /// returns input unchanged (same as greedy segmentation).
    ///
    /// - Parameters:
    ///   - phrase: The concatenated text to segment
    ///   - maxEditDistance: Maximum edit distance for spelling correction (default: instance maxEditDistance)
    ///   - beamWidth: Number of hypotheses to track (default: 10)
    ///   - maxWordLength: Maximum segment length to try (default: 20)
    /// - Returns: Composition containing the segmented and corrected string
    public func wordSegmentationBeam(
        phrase: String,
        maxEditDistance: Int? = nil,
        beamWidth: Int = 10,
        maxWordLength: Int = 20
    ) -> Composition {
        let maxDist = maxEditDistance ?? self.maxEditDistance
        let input = phrase.lowercased().replacingOccurrences(of: " ", with: "")
        let inputLen = input.count

        // Empty input
        guard !input.isEmpty else {
            return Composition(
                segmentedString: "",
                correctedString: "",
                distanceSum: 0,
                logProbSum: 0.0
            )
        }

        // Without bigrams, we can't safely segment - return input as-is
        guard bigramCount > 0 else {
            return Composition(
                segmentedString: input,
                correctedString: input,
                distanceSum: 0,
                logProbSum: -50.0
            )
        }

        // Initialize beam with empty hypothesis
        var beam: [SegmentationHypothesis] = [.initial()]

        // Process input character by character position
        while let minPos = beam.map({ $0.position }).min(), minPos < inputLen {
            var nextBeam: [SegmentationHypothesis] = []

            for hypothesis in beam {
                // Skip completed hypotheses
                guard hypothesis.position < inputLen else {
                    nextBeam.append(hypothesis)
                    continue
                }

                let remaining = inputLen - hypothesis.position
                let maxLen = min(maxWordLength, remaining)

                // Try different segment lengths
                for length in 1...maxLen {
                    let startIdx = input.index(input.startIndex, offsetBy: hypothesis.position)
                    let endIdx = input.index(startIdx, offsetBy: length)
                    let segment = String(input[startIdx..<endIdx])

                    // Get candidate corrections for this segment
                    let candidates = getCandidatesForSegment(
                        segment: segment,
                        maxEditDistance: maxDist,
                        limit: 3  // Top 3 corrections per segment
                    )

                    for candidate in candidates {
                        // Check bigram validity
                        var bigramLogProb = 0.0
                        var bigramValid = true

                        if let prevWord = hypothesis.words.last {
                            let bigram = "\(prevWord) \(candidate.word)"
                            let bigramFreq = activeBigrams.get(bigram)

                            // Require valid bigrams for segmentation
                            if bigramFreq == 0 {
                                // No valid bigram - skip this path unless it's a high-quality correction
                                // Only allow if we're taking the entire remaining input as one word (no more segmentation)
                                let isFullRemaining = length == remaining
                                let isExactMatch = candidate.distance == 0

                                if isFullRemaining && isExactMatch {
                                    // Allow as fallback: take rest as one word with penalty
                                    bigramLogProb = -5.0
                                } else {
                                    // Skip - no bigram and not a good fallback
                                    bigramValid = false
                                }
                            } else {
                                bigramLogProb = log(Double(bigramFreq) + 1)
                            }
                        } else {
                            // First word - use word frequency, prefer longer valid words
                            bigramLogProb = log(Double(candidate.frequency) + 1)
                            // Bonus for longer exact matches
                            if candidate.distance == 0 && length > 3 {
                                bigramLogProb += Double(length) * 0.5
                            }
                        }

                        if !bigramValid {
                            continue
                        }

                        // Create extended hypothesis
                        let newHypothesis = hypothesis.extend(
                            withWord: candidate.word,
                            originalSegment: segment,
                            editDistance: candidate.distance,
                            segmentLength: length,
                            bigramLogProb: bigramLogProb
                        )

                        nextBeam.append(newHypothesis)
                    }
                }
            }

            // Prune beam to top beamWidth hypotheses
            let editPenalty = configuration.beamSearchEditPenalty
            nextBeam.sort { $0.score(editPenalty: editPenalty) > $1.score(editPenalty: editPenalty) }
            beam = Array(nextBeam.prefix(beamWidth))

            // Early exit if beam is empty
            if beam.isEmpty {
                break
            }
        }

        // Find best completed hypothesis
        let completedHypotheses = beam.filter { $0.position >= inputLen }
        let editPenaltyForComparison = configuration.beamSearchEditPenalty

        // If we found valid segmentations, use the best one
        if let best = completedHypotheses.max(by: { $0.score(editPenalty: editPenaltyForComparison) < $1.score(editPenalty: editPenaltyForComparison) }) {
            // Compare against keeping input as single word
            let singleWordFreq = activeWords.get(input)

            // If input is a valid single word, prefer it unless segmentation is clearly better
            if singleWordFreq > 0 {
                // Calculate normalized scores for fair comparison
                // Single word: just the word frequency (no bigrams needed)
                let singleWordScore = log(Double(singleWordFreq) + 1)

                // For multi-word segmentation, use average score per word
                // This prevents artificially high scores from just having more words
                let segmentedAvgScore = best.words.count > 0 ? best.bigramLogProbSum / Double(best.words.count) : 0

                // Prefer single word if:
                // 1. It's a single word in best hypothesis anyway, OR
                // 2. Single word score is comparable to or better than average segmented score, OR
                // 3. Segmentation required corrections (edit distance > 0)
                let preferSingleWord = best.words.count == 1 ||
                                       singleWordScore >= segmentedAvgScore * 0.8 ||
                                       best.totalEditDistance > 0

                if preferSingleWord {
                    return Composition(
                        segmentedString: input,
                        correctedString: input,
                        distanceSum: 0,
                        logProbSum: singleWordScore
                    )
                }
            }

            let segmented = best.originalSegments.joined(separator: " ")
            let corrected = best.words.joined(separator: " ")

            return Composition(
                segmentedString: segmented,
                correctedString: corrected,
                distanceSum: best.totalEditDistance,
                logProbSum: best.bigramLogProbSum
            )
        }

        // Fallback: return input as-is
        return Composition(
            segmentedString: input,
            correctedString: input,
            distanceSum: 0,
            logProbSum: -50.0
        )
    }

    /// Get candidate words for a segment (with spelling corrections).
    ///
    /// Returns candidates sorted by quality (exact match first, then by distance and frequency).
    private func getCandidatesForSegment(
        segment: String,
        maxEditDistance: Int,
        limit: Int
    ) -> [(word: String, distance: Int, frequency: Int)] {
        var candidates: [(word: String, distance: Int, frequency: Int)] = []

        // Check for exact match first
        let exactFreq = activeWords.get(segment)
        if exactFreq > 0 {
            candidates.append((segment, 0, exactFreq))
        }

        // Only get spelling corrections for segments of reasonable length
        // Short segments (1-2 chars) shouldn't be corrected to different words
        // as this leads to false positives like "c" → "i", "w" → "a"
        let minLengthForCorrection = 3

        if segment.count >= minLengthForCorrection {
            // Get spelling corrections
            let suggestions = lookup(
                phrase: segment,
                verbosity: .closest,
                maxEditDistance: maxEditDistance
            )

            for suggestion in suggestions {
                // Skip if it's the same as exact match
                if suggestion.term == segment && suggestion.distance == 0 {
                    continue
                }
                // Skip corrections that change the word too drastically
                // (e.g., "razy" → "am" is too different)
                let lengthDiff = abs(suggestion.term.count - segment.count)
                if lengthDiff > maxEditDistance {
                    continue
                }
                candidates.append((suggestion.term, suggestion.distance, suggestion.count))
            }
        }

        // Sort by distance first, then by frequency (descending)
        candidates.sort { a, b in
            if a.distance != b.distance {
                return a.distance < b.distance
            }
            return a.frequency > b.frequency
        }

        // If no candidates found, return the segment itself with high distance
        if candidates.isEmpty {
            candidates.append((segment, maxEditDistance + 1, 0))
        }

        return Array(candidates.prefix(limit))
    }

    // MARK: - Utility Methods

    /// Check if a word is valid (exists in dictionary)
    public func isValidWord(_ word: String) -> Bool {
        return activeWords.get(word.lowercased()) > 0
    }

    /// Get word frequency from dictionary
    public func getWordFrequency(_ word: String) -> Int {
        return activeWords.get(word)
    }

    /// Get total size of mmap files in MB
    public func getDbSizeMB() -> Double {
        var total: UInt64 = 0

        for path in [wordsPath, deletesPath, bigramsPath] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }

        // Also check prebuilt paths
        if let path = _prebuiltWordsPath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? UInt64 {
            total += size
        }
        if let path = _prebuiltDeletesPath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? UInt64 {
            total += size
        }
        if let path = _prebuiltBigramsPath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? UInt64 {
            total += size
        }

        return Double(total) / (1024.0 * 1024.0)
    }

    /// Close all mmap files and cleanup
    public func close() {
        words.close()
        deletes.close()
        bigrams.close()

        _prebuiltWords?.close()
        _prebuiltDeletes?.close()
        _prebuiltBigrams?.close()

        keyboard?.close()

        // Cleanup temp directory if we created it
        if shouldCleanupDataDir {
            try? FileManager.default.removeItem(at: dataDir)
        }
    }

    // MARK: - Edit Distance

    /// Calculate Damerau-Levenshtein distance with early termination.
    ///
    /// When a keyboard layout is loaded, uses weighted substitution costs where
    /// adjacent key substitutions cost 0.5 instead of 1.0.
    ///
    /// - Parameters:
    ///   - s1: First string
    ///   - s2: Second string
    ///   - maxDistance: Maximum distance to calculate
    /// - Returns: Edit distance (ceiling of weighted distance), or -1 if distance exceeds maxDistance
    private func damerauLevenshteinDistance(_ s1: String, _ s2: String, _ maxDistance: Int) -> Int {
        // Handle empty strings
        guard !s1.isEmpty else {
            return s2.count <= maxDistance ? s2.count : -1
        }
        guard !s2.isEmpty else {
            return s1.count <= maxDistance ? s1.count : -1
        }

        let len1 = s1.count
        let len2 = s2.count

        // Quick length check
        if abs(len1 - len2) > maxDistance {
            return -1
        }

        // Use keyboard-weighted distance if available
        if let keyboard = keyboard, keyboard.keyboardLayout != .none {
            // For keyboard-weighted distance, allow exploring more candidates
            // by using a higher internal maxDistance
            let internalMaxDist = maxDistance * 2
            let weightedDist = weightedDamerauLevenshteinDistance(s1, s2, maxDistance: internalMaxDist, keyboard: keyboard)
            if weightedDist < 0 {
                return -1
            }
            // Use ceiling so that 0.5 becomes 1 (not same as exact match)
            // But cap at maxDistance for the returned value
            let ceiledDist = Int(ceil(weightedDist))
            return ceiledDist <= maxDistance ? ceiledDist : -1
        }

        // Use the existing String extension for edit distance
        let distance = s1.distanceDamerauLevenshtein(between: s2)
        return distance <= maxDistance ? distance : -1
    }

    /// Calculate weighted edit distance as a Double for more precise comparisons.
    ///
    /// - Parameters:
    ///   - s1: First string
    ///   - s2: Second string
    ///   - maxDistance: Maximum distance to calculate
    /// - Returns: Weighted edit distance, or -1 if exceeds maxDistance
    private func weightedEditDistance(_ s1: String, _ s2: String, _ maxDistance: Int) -> Double {
        if let keyboard = keyboard, keyboard.keyboardLayout != .none {
            let internalMaxDist = maxDistance * 2
            return weightedDamerauLevenshteinDistance(s1, s2, maxDistance: internalMaxDist, keyboard: keyboard)
        }
        let dist = s1.distanceDamerauLevenshtein(between: s2)
        return dist <= maxDistance ? Double(dist) : -1.0
    }

    /// Transfer casing from source to target word
    private func transferCase(from source: String, to target: String) -> String {
        guard !source.isEmpty, !target.isEmpty else { return target }

        let sourceChars = Array(source)
        let targetChars = Array(target)

        // Check if source is all uppercase
        let isAllUppercase = sourceChars.allSatisfy { !$0.isLetter || $0.isUppercase }

        // Check if source is all lowercase
        let isAllLowercase = sourceChars.allSatisfy { !$0.isLetter || $0.isLowercase }

        // Check if source is title case (first letter uppercase, rest lowercase)
        let isTitleCase = sourceChars.first?.isUppercase == true &&
            sourceChars.dropFirst().allSatisfy { !$0.isLetter || $0.isLowercase }

        if isAllUppercase {
            return target.uppercased()
        } else if isAllLowercase {
            return target.lowercased()
        } else if isTitleCase {
            return target.prefix(1).uppercased() + target.dropFirst().lowercased()
        } else {
            // Character-by-character transfer
            var result = ""
            for (i, char) in targetChars.enumerated() {
                if i < sourceChars.count && sourceChars[i].isUppercase {
                    result.append(char.uppercased())
                } else {
                    result.append(char.lowercased())
                }
            }
            return result
        }
    }
}

// MARK: - Keyboard Integration Protocol

/// Protocol for keyboard spell checker integration
public protocol KeyboardSpellChecker {
    /// Get spelling suggestions for a word
    func suggestions(for word: String, limit: Int) -> [SuggestItem]

    /// Get spelling suggestions with context (previous word for bigram ranking)
    func suggestions(for word: String, limit: Int, previousWord: String?) -> [SuggestItem]

    /// Get auto-correction for a word (returns nil if word is correct)
    func autoCorrection(for word: String) -> String?

    /// Get auto-correction with context (previous word for bigram ranking)
    func autoCorrection(for word: String, previousWord: String?) -> String?

    /// Check if word is valid
    func isValidWord(_ word: String) -> Bool
}

extension LowMemorySymSpell: KeyboardSpellChecker {
    /// Get spelling suggestions for a word
    public func suggestions(for word: String, limit: Int = 5) -> [SuggestItem] {
        return suggestions(for: word, limit: limit, previousWord: nil)
    }

    /// Get spelling suggestions with context (previous word for bigram ranking)
    ///
    /// When `previousWord` is provided and bigrams are loaded, suggestions that commonly
    /// follow the previous word are ranked higher.
    ///
    /// **Example:**
    /// ```swift
    /// // After "the", "quick" is more likely than "quack"
    /// let suggestions = spellChecker.suggestions(for: "qick", limit: 5, previousWord: "the")
    /// ```
    public func suggestions(for word: String, limit: Int = 5, previousWord: String?) -> [SuggestItem] {
        return Array(lookup(
            phrase: word,
            verbosity: .closest,
            maxEditDistance: maxEditDistance,
            previousWord: previousWord
        ).prefix(limit))
    }

    /// Get auto-correction for a word.
    ///
    /// Returns a correction only if confidence is >= 75%.
    ///
    /// For valid words that might be typos of more common words:
    /// - Only suggests if the correction is significantly more popular (10x+)
    /// - Applies heavy confidence penalty since valid words are usually intentional
    ///
    /// - Parameter word: The word to check
    /// - Returns: The correction if confident, nil otherwise
    public func autoCorrection(for word: String) -> String? {
        return autoCorrection(for: word, previousWord: nil)
    }

    /// Get auto-correction with context (previous word for bigram ranking).
    ///
    /// When `previousWord` is provided and bigrams are loaded, corrections that commonly
    /// follow the previous word get a confidence boost.
    ///
    /// - Parameters:
    ///   - word: The word to check
    ///   - previousWord: Previous word for bigram context
    /// - Returns: The correction if confident, nil otherwise
    public func autoCorrection(for word: String, previousWord: String?) -> String? {
        let lowercaseWord = word.lowercased()
        let wordFrequency = getWordFrequency(lowercaseWord)
        let isValid = wordFrequency > 0

        let suggestions = lookup(phrase: lowercaseWord, verbosity: .all, maxEditDistance: maxEditDistance, previousWord: previousWord)

        guard let top = suggestions.first else {
            return nil  // No suggestions found
        }

        // If word is valid (exact match), it will be in suggestions with distance 0
        // We want to consider if there's a MUCH more popular word at distance 1
        if isValid {
            // Find best suggestion that isn't the word itself
            guard let bestAlt = suggestions.first(where: { $0.term != lowercaseWord && $0.distance > 0 }) else {
                return nil  // No alternatives
            }

            // Only consider correction if:
            // 1. Alternative is distance 1 (close typo)
            // 2. Alternative is significantly more popular (10x or more)
            let frequencyRatio = Double(bestAlt.count) / Double(max(1, wordFrequency))
            if bestAlt.distance == 1 && frequencyRatio >= 10.0 {
                // Apply heavy penalty - valid words are usually intentional
                // Base confidence from frequency ratio, but capped low
                let confidence = min(0.6, 0.3 + (frequencyRatio / 100.0) * 0.3)
                if confidence >= 0.5 {
                    return bestAlt.term
                }
            }

            return nil  // Valid word, keep it
        }

        // Word is not valid - normal correction logic
        guard top.distance > 0 else {
            return nil  // Shouldn't happen, but safety check
        }

        // Calculate confidence
        let distanceScore = max(0, 1.0 - Double(top.distance) * 0.4)
        let sameDistance = suggestions.filter { $0.distance == top.distance }
        let maxCount = sameDistance.map { $0.count }.max() ?? top.count
        let freqScore = maxCount > 0 ? 0.3 * Double(top.count) / Double(maxCount) : 0.0
        let confidence = min(1.0, distanceScore + freqScore)

        // 75% threshold for auto-correct
        if confidence >= 0.75 {
            return top.term
        }

        return nil
    }
}

// MARK: - Autocapitalization Utilities

/// Utility for applying autocapitalization rules.
///
/// Example usage:
/// ```swift
/// let settings = SymSpellConfiguration.AutocapitalizationSettings()
/// let capitalizer = Autocapitalizer(settings: settings)
///
/// capitalizer.capitalize("i")           // → "I"
/// capitalizer.capitalize("i'm")         // → "I'm"
/// capitalizer.capitalize("hello", afterSentenceEnd: true)  // → "Hello"
/// ```
public struct Autocapitalizer: Sendable {
    public let settings: SymSpellConfiguration.AutocapitalizationSettings

    /// I-contractions that should be capitalized
    private static let iContractions: Set<String> = [
        "i'm", "i've", "i'll", "i'd"
    ]

    public init(settings: SymSpellConfiguration.AutocapitalizationSettings = .init()) {
        self.settings = settings
    }

    /// Apply autocapitalization rules to a word.
    ///
    /// - Parameters:
    ///   - word: The word to potentially capitalize
    ///   - afterSentenceEnd: Whether this word follows sentence-ending punctuation
    /// - Returns: The word with appropriate capitalization applied
    public func capitalize(_ word: String, afterSentenceEnd: Bool = false) -> String {
        guard settings.enabled else { return word }

        let lowercased = word.lowercased()

        // Check custom always-capitalize words first
        if let customCapitalization = settings.alwaysCapitalize[lowercased] {
            return customCapitalization
        }

        // Capitalize standalone "i"
        if settings.capitalizeI && lowercased == "i" {
            return "I"
        }

        // Capitalize I-contractions: "i'm" → "I'm", etc.
        if settings.capitalizeIContractions && Self.iContractions.contains(lowercased) {
            return "I" + word.dropFirst()
        }

        // Capitalize sentence start
        if settings.capitalizeSentenceStart && afterSentenceEnd && !word.isEmpty {
            return word.prefix(1).uppercased() + word.dropFirst()
        }

        return word
    }

    /// Check if a word needs autocapitalization.
    ///
    /// - Parameters:
    ///   - word: The word to check
    ///   - afterSentenceEnd: Whether this word follows sentence-ending punctuation
    /// - Returns: true if the word would be modified by capitalize()
    public func needsCapitalization(_ word: String, afterSentenceEnd: Bool = false) -> Bool {
        guard settings.enabled else { return false }

        let lowercased = word.lowercased()

        // Check custom words
        if settings.alwaysCapitalize[lowercased] != nil {
            return word != settings.alwaysCapitalize[lowercased]
        }

        // Check standalone "i"
        if settings.capitalizeI && lowercased == "i" && word != "I" {
            return true
        }

        // Check I-contractions
        if settings.capitalizeIContractions && Self.iContractions.contains(lowercased) {
            return !word.hasPrefix("I")
        }

        // Check sentence start
        if settings.capitalizeSentenceStart && afterSentenceEnd && !word.isEmpty {
            return word.first?.isLowercase == true
        }

        return false
    }

    /// Detect if the previous text ends with sentence-ending punctuation.
    ///
    /// - Parameter text: The text before the current word
    /// - Returns: true if text ends with . ! ? followed by optional whitespace
    public static func endsWithSentenceEnd(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let lastChar = trimmed.last else { return true } // Empty = start of text
        return lastChar == "." || lastChar == "!" || lastChar == "?"
    }
}

// MARK: - Suffix Handler

/// Utility for recognizing words that are valid base words with common suffixes.
///
/// This helps avoid incorrect autocorrections for words like "cats" (cat + s),
/// "boxes" (box + es), "running" (run + ning), etc. that may not be in the dictionary
/// but are clearly valid derived forms.
///
/// Example usage:
/// ```swift
/// let settings = SymSpellConfiguration.SuffixSettings()
/// let handler = SuffixHandler(settings: settings, isValidWord: symSpell.isValidWord)
///
/// handler.isValidWithSuffix("cats")     // → true (if "cat" is valid)
/// handler.isValidWithSuffix("boxes")    // → true (if "box" is valid)
/// handler.isValidWithSuffix("running")  // → true (if "run" is valid)
/// handler.getBaseWord("cats")           // → "cat"
/// ```
public struct SuffixHandler {
    public let settings: SymSpellConfiguration.SuffixSettings

    /// Function to check if a word is valid in the dictionary
    private let isValidWord: (String) -> Bool

    /// Suffix patterns with their removal rules
    /// Format: (suffix, baseTransformations) where baseTransformations are ways to get the base word
    private static let suffixRules: [(suffix: String, categories: Set<SuffixCategory>, transforms: [SuffixTransform])] = [
        // Possessive
        ("'s", [.possessive], [.dropSuffix]),

        // -ing forms (verb present participle)
        ("ing", [.verb], [
            .dropSuffix,                    // "going" → "go"
            .dropSuffixAdd("e"),            // "making" → "make"
            .dropSuffixDropDouble           // "running" → "run" (drop doubled consonant)
        ]),

        // -ed forms (verb past tense)
        ("ed", [.verb], [
            .dropSuffix,                    // "walked" → "walk"
            .dropSuffixAdd("e"),            // "baked" → "bake"
            .dropSuffixDropDouble           // "stopped" → "stop"
        ]),

        // -ies → -y (plural of words ending in consonant + y)
        ("ies", [.plural], [.replaceSuffix("y")]),  // "babies" → "baby"

        // -es forms (plural/verb for words ending in s, x, z, ch, sh)
        ("es", [.plural, .verb], [
            .dropSuffix,                    // "boxes" → "box", "watches" → "watch"
        ]),

        // -s forms (basic plural/verb third person)
        ("s", [.plural, .verb], [.dropSuffix]),  // "cats" → "cat", "runs" → "run"

        // -ly (adverbs)
        ("ly", [.adverb], [
            .dropSuffix,                    // "quickly" → "quick"
            .replaceSuffix("le"),           // "simply" → "simple"
            .replaceSuffix("y"),            // "happily" → "happy" (actually ily→y)
        ]),

        // -ily → -y (adverbs from adjectives ending in -y)
        ("ily", [.adverb], [.replaceSuffix("y")]),  // "happily" → "happy"

        // -er (comparative)
        ("er", [.comparative], [
            .dropSuffix,                    // "faster" → "fast"
            .dropSuffixDropDouble,          // "bigger" → "big"
            .dropSuffixAdd("e"),            // "nicer" → "nice"
        ]),

        // -est (superlative)
        ("est", [.comparative], [
            .dropSuffix,                    // "fastest" → "fast"
            .dropSuffixDropDouble,          // "biggest" → "big"
            .dropSuffixAdd("e"),            // "nicest" → "nice"
        ]),

        // -ier → -y (comparative of adjectives ending in -y)
        ("ier", [.comparative], [.replaceSuffix("y")]),  // "happier" → "happy"

        // -iest → -y (superlative of adjectives ending in -y)
        ("iest", [.comparative], [.replaceSuffix("y")]),  // "happiest" → "happy"
    ]

    /// Categories of suffixes for filtering
    public enum SuffixCategory {
        case plural
        case verb
        case possessive
        case adverb
        case comparative
    }

    /// Transformation to apply to get base word
    private enum SuffixTransform {
        case dropSuffix                     // Just remove the suffix
        case dropSuffixAdd(String)          // Remove suffix, add string (e.g., -ing → -e)
        case dropSuffixDropDouble           // Remove suffix and doubled consonant
        case replaceSuffix(String)          // Replace suffix with string
    }

    public init(settings: SymSpellConfiguration.SuffixSettings, isValidWord: @escaping (String) -> Bool) {
        self.settings = settings
        self.isValidWord = isValidWord
    }

    /// Check if a word is a valid base word with a recognized suffix.
    ///
    /// - Parameter word: The word to check
    /// - Returns: true if the word appears to be baseWord + suffix where baseWord is valid
    public func isValidWithSuffix(_ word: String) -> Bool {
        guard settings.enabled else { return false }
        return getBaseWord(word) != nil
    }

    /// Get the base word if this word is baseWord + suffix.
    ///
    /// - Parameter word: The word to analyze
    /// - Returns: The base word if found, nil otherwise
    public func getBaseWord(_ word: String) -> String? {
        guard settings.enabled else { return nil }

        let lowercased = word.lowercased()
        guard lowercased.count >= 3 else { return nil }  // Too short for suffix analysis

        for (suffix, categories, transforms) in Self.suffixRules {
            // Check if this suffix category is enabled
            if !isCategoryEnabled(categories) { continue }

            // Check if word ends with this suffix
            guard lowercased.hasSuffix(suffix) else { continue }

            // Try each transformation to find a valid base
            for transform in transforms {
                if let base = applyTransform(to: lowercased, suffix: suffix, transform: transform) {
                    if isValidWord(base) {
                        return base
                    }
                }
            }
        }

        return nil
    }

    /// Get suffix information for a word if it has a recognized suffix.
    ///
    /// - Parameter word: The word to analyze
    /// - Returns: Tuple of (baseWord, suffix) if found, nil otherwise
    public func analyzeSuffix(_ word: String) -> (base: String, suffix: String)? {
        guard settings.enabled else { return nil }

        let lowercased = word.lowercased()
        guard lowercased.count >= 3 else { return nil }

        for (suffix, categories, transforms) in Self.suffixRules {
            if !isCategoryEnabled(categories) { continue }
            guard lowercased.hasSuffix(suffix) else { continue }

            for transform in transforms {
                if let base = applyTransform(to: lowercased, suffix: suffix, transform: transform) {
                    if isValidWord(base) {
                        return (base, suffix)
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Private Helpers

    private func isCategoryEnabled(_ categories: Set<SuffixCategory>) -> Bool {
        for category in categories {
            switch category {
            case .plural:
                if settings.handlePlurals { return true }
            case .verb:
                if settings.handleVerbForms { return true }
            case .possessive:
                if settings.handlePossessives { return true }
            case .adverb:
                if settings.handleAdverbs { return true }
            case .comparative:
                if settings.handleComparatives { return true }
            }
        }
        return false
    }

    private func applyTransform(to word: String, suffix: String, transform: SuffixTransform) -> String? {
        let withoutSuffix = String(word.dropLast(suffix.count))
        guard !withoutSuffix.isEmpty else { return nil }

        switch transform {
        case .dropSuffix:
            return withoutSuffix

        case .dropSuffixAdd(let addition):
            return withoutSuffix + addition

        case .dropSuffixDropDouble:
            // Check if last two chars are doubled consonant
            guard withoutSuffix.count >= 2 else { return nil }
            let chars = Array(withoutSuffix)
            let last = chars[chars.count - 1]
            let secondLast = chars[chars.count - 2]
            if last == secondLast && isConsonant(last) {
                return String(withoutSuffix.dropLast())
            }
            return nil

        case .replaceSuffix(let replacement):
            return withoutSuffix + replacement
        }
    }

    private func isConsonant(_ char: Character) -> Bool {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        return char.isLetter && !vowels.contains(char.lowercased().first ?? " ")
    }
}
