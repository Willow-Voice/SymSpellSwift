# Rejected Auto-Corrections Feature

## Overview

This document describes how to implement a feature where users can "reject" specific auto-corrections by undoing them. When a user:

1. Types a misspelled word (e.g., "teh")
2. Gets it auto-corrected (e.g., → "the")
3. Deletes the correction and re-types the original word ("teh")

The system should **remember this rejection** and not auto-correct "teh" → "the" again, while still allowing other suggestions like "teh" → "tea".

---

## Problem Context

### Current Behavior (Without This Feature)
```
User types: "teh" → Auto-corrected to: "the"
User deletes "the", types "teh" again → Auto-corrected to: "the" (frustrating!)
```

### Desired Behavior (With This Feature)
```
User types: "teh" → Auto-corrected to: "the"
User deletes "the", types "teh" again → NO auto-correction (respects user intent)
Other suggestions like "tea" still available if user wants them
```

---

## Architecture

### Key Distinction: Ignored Words vs Rejected Corrections

KeyboardKit's `AutocompleteService` protocol has `ignoreWord(_:)`, but this is **too aggressive** for our use case:

| Mechanism | Behavior | Use Case |
|-----------|----------|----------|
| `ignoreWord("teh")` | No suggestions at all for "teh" | User explicitly says "never correct this word" |
| `rejectCorrection(input: "teh", correction: "the")` | Blocks only "teh" → "the", other suggestions still work | User undoes a specific auto-correction |

### Data Model

```swift
/// Represents a specific input → correction pair that was rejected
public struct RejectedAutoCorrection: Hashable, Codable {
    /// The word the user typed (e.g., "teh")
    public let input: String
    /// The correction that was rejected (e.g., "the")
    public let correction: String
    
    public init(input: String, correction: String) {
        // Normalize to lowercase for consistent matching
        self.input = input.lowercased()
        self.correction = correction.lowercased()
    }
}
```

---

## Integration with KeyboardKit's AutocompleteService

### Protocol Reference

```swift
protocol AutocompleteService: AnyObject {
    var canIgnoreWords: Bool { get }
    var canLearnWords: Bool { get }
    var ignoredWords: [String] { get }
    var learnedWords: [String] { get }
    var locale: Locale { get }
    
    func autocomplete(_ text: String) async throws -> Autocomplete.Result
    func hasIgnoredWord(_ word: String) -> Bool
    func hasLearnedWord(_ word: String) -> Bool
    func ignoreWord(_ word: String)
    func learnWord(_ word: String)
    func removeIgnoredWord(_ word: String)
    func unlearnWord(_ word: String)
}
```

### Extended Properties for Rejected Corrections

Add these properties to your `AutocompleteService` implementation:

```swift
/// Specific correction pairs the user has rejected
/// Unlike ignoredWords, this allows other suggestions for the same input
public private(set) var rejectedCorrections: Set<RejectedAutoCorrection> = []

/// Tracks the last auto-correction applied (for rejection detection)
private var lastAutoCorrection: (input: String, correction: String)?
```

---

## Implementation

### 1. RejectedCorrectionsManager (Standalone Class)

If you want to keep rejection logic separate from your AutocompleteService:

```swift
import Foundation

/// Manages tracking of rejected auto-corrections with optional persistence
public class RejectedCorrectionsManager {
    
    // MARK: - Storage
    
    /// In-memory set of rejected correction pairs
    private var rejections: Set<RejectedAutoCorrection> = []
    
    /// Maximum rejections to track (prevents unbounded growth)
    public var maxRejections: Int = 500
    
    /// Whether to persist rejections across app launches
    public let persistent: Bool
    
    /// UserDefaults key for persistence
    private let persistenceKey = "symspell_rejected_corrections"
    
    // MARK: - Initialization
    
    public init(persistent: Bool = true) {
        self.persistent = persistent
        if persistent {
            loadFromStorage()
        }
    }
    
    // MARK: - Core API
    
    /// Check if a specific input → correction pair was rejected
    public func isRejected(input: String, correction: String) -> Bool {
        let rejection = RejectedAutoCorrection(input: input, correction: correction)
        return rejections.contains(rejection)
    }
    
    /// Mark a correction as rejected by the user
    public func reject(input: String, correction: String) {
        let rejection = RejectedAutoCorrection(input: input, correction: correction)
        rejections.insert(rejection)
        
        // Prevent unbounded growth - remove oldest entries
        while rejections.count > maxRejections {
            // Note: Set doesn't guarantee order, consider using an ordered structure
            // for true LRU behavior
            rejections.remove(rejections.first!)
        }
        
        if persistent {
            saveToStorage()
        }
    }
    
    /// Remove a rejection (user wants the suggestion back)
    public func removeRejection(input: String, correction: String) {
        let rejection = RejectedAutoCorrection(input: input, correction: correction)
        rejections.remove(rejection)
        
        if persistent {
            saveToStorage()
        }
    }
    
    /// Get all rejections for a specific input word
    public func rejectionsFor(input: String) -> [String] {
        let lowercased = input.lowercased()
        return rejections
            .filter { $0.input == lowercased }
            .map { $0.correction }
    }
    
    /// Clear all rejections
    public func clearAll() {
        rejections.removeAll()
        if persistent {
            saveToStorage()
        }
    }
    
    /// Number of tracked rejections
    public var count: Int {
        rejections.count
    }
    
    // MARK: - Persistence
    
    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode(Set<RejectedAutoCorrection>.self, from: data) else {
            return
        }
        rejections = decoded
    }
    
    private func saveToStorage() {
        guard let data = try? JSONEncoder().encode(rejections) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }
}
```

### 2. Auto-Correction Tracking State

Track the last auto-correction so you can detect when user rejects it:

```swift
/// State for tracking auto-correction for rejection detection
public class AutoCorrectionTracker {
    
    /// The last auto-correction that was applied
    private var lastCorrection: (input: String, correction: String, timestamp: Date)?
    
    /// Time window to consider a re-type as a rejection (seconds)
    public var rejectionTimeWindow: TimeInterval = 10.0
    
    /// Record that an auto-correction was just applied
    public func recordAutoCorrection(input: String, correction: String) {
        lastCorrection = (
            input: input.lowercased(),
            correction: correction.lowercased(),
            timestamp: Date()
        )
    }
    
    /// Check if the current word indicates a rejection of the last correction
    /// Returns the rejected correction if detected, nil otherwise
    public func checkForRejection(currentWord: String) -> (input: String, correction: String)? {
        guard let last = lastCorrection else { return nil }
        
        // Check if within time window
        let elapsed = Date().timeIntervalSince(last.timestamp)
        guard elapsed <= rejectionTimeWindow else {
            lastCorrection = nil
            return nil
        }
        
        // User typed the original word again = rejection
        if currentWord.lowercased() == last.input {
            let rejection = (input: last.input, correction: last.correction)
            lastCorrection = nil
            return rejection
        }
        
        return nil
    }
    
    /// Clear tracking (e.g., when moving to a new text field)
    public func reset() {
        lastCorrection = nil
    }
}
```

### 3. Integration in AutocompleteService

Here's how to integrate everything into your `AutocompleteService` implementation:

```swift
public class SymSpellAutocompleteService: AutocompleteService {
    
    // MARK: - Dependencies
    
    private let spellChecker: LowMemorySymSpell
    private let rejectionManager: RejectedCorrectionsManager
    private let correctionTracker: AutoCorrectionTracker
    
    // MARK: - AutocompleteService Protocol Properties
    
    public var locale: Locale
    public var canLearnWords: Bool { true }
    public var canIgnoreWords: Bool { true }
    public private(set) var learnedWords: [String] = []
    public private(set) var ignoredWords: [String] = []
    
    // MARK: - Initialization
    
    public init(
        spellChecker: LowMemorySymSpell,
        locale: Locale = .current,
        persistRejections: Bool = true
    ) {
        self.spellChecker = spellChecker
        self.locale = locale
        self.rejectionManager = RejectedCorrectionsManager(persistent: persistRejections)
        self.correctionTracker = AutoCorrectionTracker()
        
        loadPersistedWords()
    }
    
    // MARK: - Main Autocomplete Method
    
    public func autocomplete(_ text: String) async throws -> Autocomplete.Result {
        let currentWord = extractCurrentWord(from: text)
        
        guard !currentWord.isEmpty else {
            return Autocomplete.Result(inputText: text, suggestions: [])
        }
        
        // 1. Check if word is completely ignored
        if hasIgnoredWord(currentWord) {
            return Autocomplete.Result(inputText: text, suggestions: [])
        }
        
        // 2. Check for rejection of last auto-correction
        if let rejection = correctionTracker.checkForRejection(currentWord: currentWord) {
            rejectionManager.reject(input: rejection.input, correction: rejection.correction)
            // Log for debugging
            print("Rejected correction: '\(rejection.input)' → '\(rejection.correction)'")
        }
        
        // 3. Get suggestions from SymSpell
        let spellSuggestions = spellChecker.lookup(
            phrase: currentWord,
            verbosity: .closest,
            maxEditDistance: 2,
            transferCasing: true
        )
        
        // 4. Filter out rejected corrections
        let filteredSuggestions = spellSuggestions.filter { suggestion in
            !rejectionManager.isRejected(input: currentWord, correction: suggestion.term)
        }
        
        // 5. Convert to Autocomplete.Suggestion
        let suggestions = filteredSuggestions
            .prefix(3)
            .enumerated()
            .map { index, item -> Autocomplete.Suggestion in
                let isAutoCorrect = index == 0 
                    && item.distance == 1 
                    && shouldAutoCorrect(item, for: currentWord)
                
                return Autocomplete.Suggestion(
                    text: item.term,
                    title: nil,
                    isAutocorrect: isAutoCorrect,
                    isUnknown: item.count == 0,
                    subtitle: nil,
                    additionalInfo: [:]
                )
            }
        
        // 6. Track if we're about to auto-correct
        if let first = suggestions.first, first.isAutocorrect {
            correctionTracker.recordAutoCorrection(
                input: currentWord,
                correction: first.text
            )
        }
        
        return Autocomplete.Result(inputText: text, suggestions: Array(suggestions))
    }
    
    // MARK: - Auto-Correct Decision Logic
    
    private func shouldAutoCorrect(_ suggestion: SuggestItem, for input: String) -> Bool {
        // Never auto-correct to a rejected correction
        if rejectionManager.isRejected(input: input, correction: suggestion.term) {
            return false
        }
        
        // Must have some edit distance (not exact match)
        guard suggestion.distance > 0 else { return false }
        
        // Confidence calculation
        let distanceScore = max(0, 1.0 - Double(suggestion.distance) * 0.4)
        let frequencyScore = suggestion.count > 1000 ? 0.3 : 0.1
        let confidence = min(1.0, distanceScore + frequencyScore)
        
        // Only auto-correct with high confidence
        return confidence >= 0.75
    }
    
    // MARK: - Helper Methods
    
    private func extractCurrentWord(from text: String) -> String {
        text.components(separatedBy: .whitespaces).last ?? ""
    }
    
    // ... implement other AutocompleteService methods ...
}
```

---

## Detection Scenarios

### Scenario 1: Simple Rejection

```
1. User types: "teh"
2. autocomplete() returns: [Suggestion(text: "the", isAutocorrect: true), ...]
3. KeyboardKit applies auto-correction: "teh" → "the"
4. correctionTracker records: (input: "teh", correction: "the", timestamp: now)

5. User presses backspace 3 times (deletes "the")
6. User types: "teh"
7. autocomplete() called with "teh"
8. checkForRejection() detects: currentWord "teh" == lastCorrection.input "teh"
9. rejectionManager.reject(input: "teh", correction: "the") is called

10. Next lookup filters out "the" from suggestions
11. User sees "tea" and other suggestions, but NOT "the"
```

### Scenario 2: User Accepts Correction

```
1. User types: "teh"
2. Auto-corrected to: "the"
3. correctionTracker records: (input: "teh", correction: "the")
4. User continues typing: "the quick..."
5. No rejection detected (currentWord "quick" != "teh")
6. correctionTracker times out after 10 seconds
```

### Scenario 3: User Wants Correction Back Later

```
1. User previously rejected "teh" → "the"
2. Later, user wants the correction back
3. Call: rejectionManager.removeRejection(input: "teh", correction: "the")
4. Or: clear all with rejectionManager.clearAll()
```

---

## Edge Cases to Handle

### 1. Casing Variations

```swift
// These should all be treated as the same rejection:
rejectionManager.reject(input: "Teh", correction: "The")
rejectionManager.isRejected(input: "teh", correction: "the")  // true
rejectionManager.isRejected(input: "TEH", correction: "THE")  // true
```

**Solution:** Normalize to lowercase in `RejectedAutoCorrection.init()`

### 2. Time-Based Expiry

Consider whether rejections should expire:

```swift
public struct RejectedAutoCorrection: Hashable, Codable {
    public let input: String
    public let correction: String
    public let timestamp: Date  // Optional: for expiry logic
    
    // Expire rejections older than 30 days?
    public var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 30 * 24 * 60 * 60
    }
}
```

### 3. Partial Matches During Typing

User might partially re-type before completing:

```
"teh" → "the" (corrected)
User deletes, types "te" (partial)
User types "h" → "teh" (complete)
```

**Solution:** Only check for rejection when word appears complete (space pressed, or matches known pattern)

### 4. Context Sensitivity

Same word might need different corrections in different contexts:

```
"var" in programming context → don't correct
"var" in general writing → correct to "car"
```

**Advanced Solution:** Store context with rejections (app bundle ID, text field type, etc.)

---

## Persistence Strategy

### Option 1: UserDefaults (Simple)

```swift
// Good for: Small number of rejections, simple apps
private let key = "symspell_rejected_corrections"

func save(_ rejections: Set<RejectedAutoCorrection>) {
    let data = try? JSONEncoder().encode(rejections)
    UserDefaults.standard.set(data, forKey: key)
}

func load() -> Set<RejectedAutoCorrection> {
    guard let data = UserDefaults.standard.data(forKey: key),
          let decoded = try? JSONDecoder().decode(Set<RejectedAutoCorrection>.self, from: data) else {
        return []
    }
    return decoded
}
```

### Option 2: App Group UserDefaults (Keyboard Extension)

```swift
// Required for keyboard extensions to share data with main app
let appGroupID = "group.com.yourcompany.yourkeyboard"
let defaults = UserDefaults(suiteName: appGroupID)!

func save(_ rejections: Set<RejectedAutoCorrection>) {
    let data = try? JSONEncoder().encode(rejections)
    defaults.set(data, forKey: "rejected_corrections")
}
```

### Option 3: Core Data / SQLite (Heavy Usage)

For large-scale persistence with querying:

```swift
// Schema
// CREATE TABLE rejected_corrections (
//     id INTEGER PRIMARY KEY,
//     input TEXT NOT NULL,
//     correction TEXT NOT NULL,
//     timestamp REAL NOT NULL,
//     UNIQUE(input, correction)
// );
```

---

## Testing Checklist

- [ ] Auto-correction is blocked after rejection
- [ ] Other suggestions for same input still work
- [ ] Rejection persists across app launches
- [ ] Rejection can be removed/cleared
- [ ] Casing variations are handled
- [ ] Time window for rejection detection works
- [ ] Memory bounded (maxRejections limit)
- [ ] Keyboard extension can access persisted rejections
- [ ] Performance acceptable with many rejections

---

## Usage Example

```swift
// In your keyboard's view controller or coordinator

class KeyboardViewController: UIInputViewController {
    
    var autocompleteService: SymSpellAutocompleteService!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7)
        spellChecker.loadPrebuilt(from: bundledDictionaryURL)
        
        autocompleteService = SymSpellAutocompleteService(
            spellChecker: spellChecker,
            locale: .current,
            persistRejections: true
        )
    }
    
    // Called when user finishes typing a word
    func handleWordCompleted(_ text: String) async {
        do {
            let result = try await autocompleteService.autocomplete(text)
            updateSuggestionBar(with: result.suggestions)
        } catch {
            // Handle error
        }
    }
    
    // Optional: Manual rejection (e.g., long-press on suggestion)
    func handleSuggestionRejected(input: String, suggestion: Autocomplete.Suggestion) {
        autocompleteService.rejectionManager.reject(
            input: input,
            correction: suggestion.text
        )
    }
}
```

---

## Files to Create/Modify

1. **New File:** `Sources/SymSpellSwift/RejectedAutoCorrection.swift`
   - `RejectedAutoCorrection` struct
   - `RejectedCorrectionsManager` class
   - `AutoCorrectionTracker` class

2. **New File:** `Sources/SymSpellSwift/SymSpellAutocompleteService.swift`
   - Full `AutocompleteService` implementation
   - Integration with `LowMemorySymSpell`

3. **Modify:** `Sources/SymSpellSwift/LowMemorySymSpell.swift`
   - Optional: Add convenience methods for rejection-aware lookups

---

## Summary

This feature respects user intent by tracking specific auto-correction pairs they've rejected, rather than completely blocking suggestions for a word. The key components are:

1. **`RejectedAutoCorrection`** - Data model for input/correction pairs
2. **`RejectedCorrectionsManager`** - Manages the set of rejections with persistence
3. **`AutoCorrectionTracker`** - Detects when user rejects by re-typing original
4. **Filtering in `autocomplete()`** - Excludes rejected corrections from suggestions

This approach provides a better user experience than the blunt `ignoreWord()` while still being simple to implement and maintain.
