//
// KeyboardLayout.swift
// SymSpellSwift
//
// Keyboard layout support for spatial error weighting in spell checking.
// Uses pre-computed distance matrices stored in binary files.
//

import Foundation

// MARK: - KeyboardLayout Enum

/// Supported keyboard layouts for spatial error weighting.
///
/// Spatial error weighting reduces the edit distance penalty for character substitutions
/// that involve adjacent keys on the keyboard. This helps prioritize corrections for
/// common typos caused by hitting a neighboring key.
///
/// Example: Typing "tje" when meaning "the" (j is adjacent to h on QWERTY)
/// - Without spatial weighting: "the" has distance 1 (same as "tie")
/// - With QWERTY weighting: "the" has distance 0.5 (j→h is adjacent), "tie" has distance 1.0
public enum KeyboardLayout: String, CaseIterable {
    /// Standard QWERTY layout (US/UK)
    case qwerty

    /// AZERTY layout (French)
    case azerty

    /// QWERTZ layout (German)
    case qwertz

    /// Dvorak layout
    case dvorak

    /// Colemak layout
    case colemak

    /// No keyboard layout - disable spatial weighting (default behavior)
    case none

    /// Filename for the binary layout file
    var filename: String {
        switch self {
        case .none:
            return ""
        default:
            return "keyboard_\(rawValue).bin"
        }
    }
}

// MARK: - MMapKeyboardLayout

/// Memory-mapped keyboard layout for efficient key distance lookups.
///
/// Binary format:
/// - Header: "KYBD" (4 bytes magic) + version (1 byte)
/// - Distance matrix: 26x26 bytes for lowercase letters a-z
///   - Value at [i][j] = keyboard distance from letter i to letter j
///   - 0 = same key
///   - 1 = directly adjacent (ring 1)
///   - 2 = distance 2 away (ring 2)
///   - 255 = far away / not related
public class MMapKeyboardLayout {
    private static let magic = Data("KYBD".utf8)
    private static let headerSize = 5  // 4 bytes magic + 1 byte version
    private static let matrixSize = 26 * 26  // 676 bytes

    private var data: Data?
    private let layout: KeyboardLayout

    /// Create a keyboard layout handler for the specified layout.
    ///
    /// - Parameter layout: The keyboard layout to use
    public init(layout: KeyboardLayout) {
        self.layout = layout
    }

    /// Load the keyboard layout from a binary file.
    ///
    /// - Parameter path: Path to the .bin file
    /// - Returns: true if loaded successfully
    @discardableResult
    public func load(from path: URL) -> Bool {
        guard layout != .none else { return true }

        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        do {
            let fileData = try Data(contentsOf: path, options: .mappedIfSafe)

            // Validate header
            guard fileData.count >= Self.headerSize + Self.matrixSize else {
                return false
            }

            // Check magic bytes
            guard fileData.prefix(4) == Self.magic else {
                return false
            }

            // Check version
            let version = fileData[4]
            guard version == 1 else {
                return false
            }

            self.data = fileData
            return true
        } catch {
            return false
        }
    }

    /// Load the keyboard layout from a directory containing layout files.
    ///
    /// - Parameter directory: Directory containing keyboard_*.bin files
    /// - Returns: true if loaded successfully
    @discardableResult
    public func loadFromDirectory(_ directory: URL) -> Bool {
        guard layout != .none else { return true }

        let path = directory.appendingPathComponent(layout.filename)
        return load(from: path)
    }

    /// Get the keyboard distance between two characters.
    ///
    /// - Parameters:
    ///   - from: Source character
    ///   - to: Target character
    /// - Returns: Keyboard distance (0=same, 1=adjacent, 2=far, 255=not related)
    public func distance(from: Character, to: Character) -> Int {
        guard layout != .none, let data = data else {
            // No layout loaded - treat all as far (use standard edit distance)
            return from == to ? 0 : 255
        }

        // Convert to lowercase letter indices
        guard let fromIndex = letterIndex(from),
              let toIndex = letterIndex(to) else {
            // Non-letter characters - treat as far
            return from == to ? 0 : 255
        }

        // Read from matrix
        let offset = Self.headerSize + (fromIndex * 26) + toIndex
        guard offset < data.count else {
            return 255
        }

        return Int(data[offset])
    }

    /// Check if two characters are adjacent on the keyboard.
    ///
    /// - Parameters:
    ///   - char1: First character
    ///   - char2: Second character
    /// - Returns: true if the characters are adjacent (distance 1)
    public func areAdjacent(_ char1: Character, _ char2: Character) -> Bool {
        return distance(from: char1, to: char2) == 1
    }

    /// Get the substitution cost for replacing one character with another.
    ///
    /// - Parameters:
    ///   - from: Original character
    ///   - to: Replacement character
    /// - Returns: Substitution cost (0.5 for adjacent keys, 1.0 otherwise)
    public func substitutionCost(from: Character, to: Character) -> Double {
        guard layout != .none else {
            return from == to ? 0.0 : 1.0
        }

        let keyDistance = distance(from: from, to: to)

        switch keyDistance {
        case 0:
            // Same character
            return 0.0
        case 1:
            // Adjacent keys - reduced penalty
            return 0.5
        case 2:
            // Distance 2 - slightly reduced penalty
            return 0.75
        default:
            // Far or unknown
            return 1.0
        }
    }

    /// Convert a character to its index in the 26-letter alphabet (0-25).
    private func letterIndex(_ char: Character) -> Int? {
        let lower = char.lowercased().first ?? char
        guard let ascii = lower.asciiValue,
              ascii >= 97 && ascii <= 122 else {  // 'a' = 97, 'z' = 122
            return nil
        }
        return Int(ascii - 97)
    }

    /// Close the layout and release resources.
    public func close() {
        data = nil
    }
}

// MARK: - Weighted Edit Distance

/// Calculate Damerau-Levenshtein distance with keyboard-weighted substitution costs.
///
/// This function modifies the standard edit distance to use fractional costs
/// for substitutions between adjacent keyboard keys.
///
/// - Parameters:
///   - s1: First string
///   - s2: Second string
///   - maxDistance: Maximum distance to calculate
///   - keyboard: Keyboard layout for spatial weighting (nil for standard distance)
/// - Returns: Weighted edit distance, or -1 if exceeds maxDistance
public func weightedDamerauLevenshteinDistance(
    _ s1: String,
    _ s2: String,
    maxDistance: Int,
    keyboard: MMapKeyboardLayout?
) -> Double {
    guard let keyboard = keyboard, keyboard.keyboardLayout != .none else {
        // No keyboard layout - use standard distance
        let dist = s1.distanceDamerauLevenshtein(between: s2)
        return dist <= maxDistance ? Double(dist) : -1.0
    }

    let chars1 = Array(s1.lowercased())
    let chars2 = Array(s2.lowercased())

    let len1 = chars1.count
    let len2 = chars2.count

    // Quick length check
    if abs(len1 - len2) > maxDistance {
        return -1.0
    }

    // Handle empty strings
    if len1 == 0 { return len2 <= maxDistance ? Double(len2) : -1.0 }
    if len2 == 0 { return len1 <= maxDistance ? Double(len1) : -1.0 }

    // DP matrix with Double for fractional costs
    var dp = [[Double]](repeating: [Double](repeating: Double(maxDistance + 1), count: len2 + 1), count: len1 + 1)

    // Initialize base cases
    for i in 0...len1 {
        dp[i][0] = Double(i)
    }
    for j in 0...len2 {
        dp[0][j] = Double(j)
    }

    // Fill DP matrix
    for i in 1...len1 {
        var minInRow = Double(maxDistance + 1)

        for j in 1...len2 {
            let char1 = chars1[i - 1]
            let char2 = chars2[j - 1]

            // Substitution cost (keyboard-weighted)
            let substCost = keyboard.substitutionCost(from: char1, to: char2)

            // Standard operations
            let substitution = dp[i - 1][j - 1] + substCost
            let insertion = dp[i][j - 1] + 1.0
            let deletion = dp[i - 1][j] + 1.0

            dp[i][j] = min(substitution, min(insertion, deletion))

            // Transposition (Damerau)
            if i > 1 && j > 1 && char1 == chars2[j - 2] && chars1[i - 2] == char2 {
                dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1.0)
            }

            minInRow = min(minInRow, dp[i][j])
        }

        // Early termination if all values in row exceed maxDistance
        if minInRow > Double(maxDistance) {
            return -1.0
        }
    }

    let result = dp[len1][len2]
    return result <= Double(maxDistance) ? result : -1.0
}

// MARK: - Extension for MMapKeyboardLayout

extension MMapKeyboardLayout {
    /// The keyboard layout type
    public var keyboardLayout: KeyboardLayout {
        return layout
    }
}
