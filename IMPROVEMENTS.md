# SymSpellSwift Improvements

Planned enhancements for the SymSpellSwift library.

---

## 1. Word Segmentation: Bigram-Based Validation ✅ IMPLEMENTED

**Problem:**
Word segmentation produces incorrect results with single-letter words:
- `"crazy"` → `"crazy y"` (incorrect)
- `"woahh"` → `"w ahh"` (incorrect)
- `"crazyy"` → `"crazy y"` (incorrect)
- `"highlyyy"` (mistyped "highly") → `"hi gj k y"` (completely wrong)

**Solution Implemented:**
Word segmentation now **requires** the bigram dictionary to be loaded. Segmentation only occurs at positions where the resulting word pair exists in the bigram dictionary.

```swift
// Load both dictionaries
spellChecker.loadDictionary(corpus: dictURL)
spellChecker.loadBigramDictionary(corpus: bigramURL)  // Required!

// Segmentation only where valid bigrams exist
spellChecker.wordSegmentation(phrase: "thequickbrown")  // → "the quick brown"
spellChecker.wordSegmentation(phrase: "woahhhh")        // → "woahhhh" (unchanged - no valid bigrams)
spellChecker.wordSegmentation(phrase: "crazyy")         // → "crazyy" (unchanged)
```

**Behavior:**
- Without bigrams loaded: Returns input unchanged
- With bigrams: Only segments where consecutive word pairs exist in bigram dictionary
- Prevents all incorrect single-letter segmentations

---

## 2. Correction-Aware Segmentation (Beam Search) ✅ IMPLEMENTED

**Problem:**
Current segmentation requires input words to be correctly spelled OR uses spelling correction only as a fallback. This fails for concatenated misspelled words:

- `"helloworlf"` → should become `"hello world"`

The old greedy algorithm:
1. Looks for exact dictionary matches first
2. Only spell-corrects when no match found
3. Can't explore multiple segmentation hypotheses

**Solution Implemented:**
Use **beam search** to explore multiple segmentation + correction hypotheses simultaneously:

```swift
func wordSegmentation(
    phrase: String,
    maxEditDistance: Int = 2,
    beamWidth: Int = 10  // Number of hypotheses to track
) -> Composition
```

**Algorithm:**

```
Input: "tahtswhat"

Beam at position 0:
  Try segment lengths 1-10, get spelling corrections for each:
  - "t" → corrections: ["t"(d=0)] - too short, skip
  - "ta" → corrections: ["ta"(d=0), "to"(d=1)...]
  - "tah" → corrections: ["the"(d=2), "tan"(d=2)...]
  - "taht" → corrections: ["that"(d=1), "tart"(d=2)...]
  - "tahts" → corrections: ["that's"(d=1), "thats"(d=1)...]  ← promising!

  Score each by: bigram_probability - edit_distance_penalty
  Keep top-10 hypotheses

Beam after "tahts"→"that's" (position 5):
  Remaining: "what"
  - "what" → corrections: ["what"(d=0)]
  - Bigram "that's what" exists with high frequency

  Final: "that's what" with score = bigram_score - 1 (edit distance)
```

**Scoring Function:**
```swift
struct SegmentationHypothesis {
    let words: [String]           // Corrected words so far
    let position: Int             // Current position in input
    let totalEditDistance: Int    // Sum of edit distances
    let bigramLogProb: Double     // Sum of log(bigram frequencies)

    var score: Double {
        // Balance: prefer common phrases, penalize corrections
        let editPenalty = Double(totalEditDistance) * 2.0
        return bigramLogProb - editPenalty
    }
}
```

**Implementation Notes:**

1. **At each position, generate candidates:**
   ```swift
   for length in 1...min(maxWordLength, remaining.count) {
       let segment = input[position..<position+length]
       let corrections = lookup(segment, verbosity: .closest, maxEditDistance: 2)

       for correction in corrections.prefix(3) {
           // Check bigram with previous word
           if let prev = hypothesis.words.last {
               guard bigrams["\(prev) \(correction.term)"] != nil else { continue }
           }
           // Add new hypothesis
       }
   }
   ```

2. **Prune beam after each position:**
   - Sort hypotheses by score
   - Keep only top `beamWidth` candidates
   - Discard low-scoring paths early

3. **Handle contractions:**
   - Include contractions in dictionary ("that's", "don't", "won't")
   - Include bigrams with contractions ("that's what", "don't know")

4. **Fallback behavior:**
   - If no valid segmentation found, return best partial result
   - Or return input unchanged (current behavior)

**Example Behavior After Implementation:**
```
Input: "tahtswhat"
  Hypotheses explored:
    "that what" (d=2, no bigram for "that what") → rejected
    "that's what" (d=1, bigram exists!) → score: 15.2
    "tarts what" (d=2, no bigram) → rejected

  Result: "that's what"

Input: "thayswhat"
  "thays" → "that's" (d=2, 'ay'→'at' + add apostrophe)
  "what" → "what" (d=0)
  Bigram "that's what" exists

  Result: "that's what"

Input: "helloworlf"
  "hello" → "hello" (d=0)
  "worlf" → "world" (d=1)
  Bigram "hello world" exists

  Result: "hello world"
```

**Performance Considerations:**
- Beam width of 10 keeps search tractable
- Early pruning prevents exponential blowup
- Limit correction candidates to top-3 per segment
- Cache bigram lookups

**Comparison with Apple's Approach:**
Apple's keyboard likely uses:
- Neural language models (we use bigram frequencies)
- Keyboard proximity weighting (see Section 3)
- User history/context (out of scope)
- Device-optimized inference (we use simpler beam search)

This beam search approach provides ~80% of the benefit with much simpler implementation.

**Usage:**
```swift
// Beam search is now the default (beamWidth: 10)
let result = spellChecker.wordSegmentation(phrase: "helloworlf")
print(result.correctedString)  // "hello world"

// Use greedy mode for faster but less accurate results
let result2 = spellChecker.wordSegmentation(phrase: "helloworlf", beamWidth: 0)

// Customize beam width for more thorough search
let result3 = spellChecker.wordSegmentation(phrase: "helloworlf", beamWidth: 20)
```

**Key Implementation Details:**
- Valid single words are preserved (e.g., "together" won't become "to get her")
- Corrections only applied to segments of 3+ characters (prevents "c" → "i" false positives)
- Edit distance penalty of 5.0 per edit ensures corrections are used sparingly
- Requires bigrams loaded; without bigrams, returns input unchanged

---

## 3. Spatial Keyboard Error Weighting ✅ IMPLEMENTED

**Problem:**
Standard edit distance treats all character substitutions equally, but keyboard typos often involve adjacent keys:
- Typing "r" instead of "t" (adjacent on QWERTY)
- Typing "n" instead of "m" (adjacent on QWERTY)

A user typing "thr" meaning "the" should rank higher than "thr" → "tar" even though both are 1 substitution.

**Solution Implemented:**
Pass keyboard layout during SymSpell initialization. The library handles all layout-specific logic internally using pre-computed binary distance matrices.

```swift
// Initialize with keyboard layout
let symSpell = LowMemorySymSpell(
    maxEditDistance: 2,
    prefixLength: 7,
    keyboardLayout: .qwerty
)

// Load keyboard layout binary file
symSpell.loadKeyboardLayout(from: keyboardLayoutDirectory)

// Load dictionary
symSpell.loadPrebuilt(from: dataDirectory)

// "tje" will now prefer "the" (j→h adjacent) over "tie"
let suggestions = symSpell.lookup(phrase: "tje", verbosity: .closest)
```

**Supported Layouts:**
- `.qwerty` - Standard US/UK layout
- `.azerty` - French layout
- `.qwertz` - German layout
- `.dvorak` - Dvorak layout
- `.colemak` - Colemak layout
- `.none` - Disable spatial weighting (default)

**Implementation Details:**

1. **Pre-computed distance matrices:**
   - Keyboard layouts stored as compact binary files (681 bytes each)
   - 26x26 distance matrix for lowercase letters
   - Generated via `scripts/generate_keyboard_layout.py`

2. **Weighted edit distance:**
   - Adjacent key substitution: 0.5 cost (instead of 1.0)
   - Distance-2 substitution: 0.75 cost
   - Non-adjacent substitution: 1.0 cost
   - Allows `maxEditDistance: 2` to catch up to 4 adjacent-key errors

3. **Default behavior unchanged:**
   - `keyboardLayout: .none` preserves current behavior
   - Existing code continues to work without modification

**Example Behavior:**
```
Input: "tje" (meant "the", j is adjacent to h)
Before: "the" distance=1, "tie" distance=1 (equal ranking)
After:  "the" distance=0.5 (adjacent j→h), "tie" distance=1.0 (non-adjacent)

Input: "thr" (meant "the", r is adjacent to e)
Result: "the" with weighted distance 0.5 (r→e adjacent)
```

---

## 4. Improved Frequency Weighting in Ranking ✅ IMPLEMENTED

**Problem:**
Originally, SymSpell ranked suggestions by:
1. Edit distance (primary sort)
2. Frequency (secondary sort - only as tiebreaker within same distance)

This meant a rare word with distance 1 always ranked higher than a common word with distance 2, even when the common word was much more likely to be correct.

**Example:**
```
Input: "teh"
Current ranking:
  1. "te" (distance 1, freq: 500)      <- rare word ranks first
  2. "th" (distance 1, freq: 200)
  3. "the" (distance 2, freq: 5000000) <- extremely common, but ranked lower

Desired ranking:
  1. "the" (distance 2, freq: 5000000) <- should rank first due to high frequency
  2. "te" (distance 1, freq: 500)
  3. "th" (distance 1, freq: 200)
```

**Solution:**
Implement a combined scoring function that balances distance and frequency:

```swift
public enum RankingMode {
    case distanceFirst      // Current behavior: distance primary, frequency secondary
    case balanced           // Combined score: weights both distance and frequency
    case frequencyBoosted   // Aggressive frequency weighting for common words
}

let symSpell = LowMemorySymSpell(
    maxEditDistance: 2,
    prefixLength: 7,
    rankingMode: .balanced  // NEW parameter
)
```

**Implementation Notes:**

1. **Balanced scoring formula:**
   ```swift
   // Normalize frequency to 0-1 range using log scale
   let normalizedFreq = log10(Double(frequency) + 1) / log10(Double(maxFrequency) + 1)

   // Distance penalty (0 = perfect, 1 = max distance)
   let distancePenalty = Double(distance) / Double(maxEditDistance)

   // Combined score (higher is better)
   let score = (1.0 - distancePenalty * 0.6) + (normalizedFreq * 0.4)
   ```

2. **Configurable weights:**
   ```swift
   // Allow tuning the balance
   func lookup(
       phrase: String,
       verbosity: Verbosity,
       maxEditDistance: Int,
       distanceWeight: Double = 0.6,  // NEW
       frequencyWeight: Double = 0.4  // NEW
   ) -> [SuggestItem]
   ```

3. **Preserve backwards compatibility:**
   - Default `rankingMode: .distanceFirst` matches current behavior
   - Existing code works unchanged

**Example Behavior After Fix (balanced mode):**
```
Input: "teh"
  1. "the" (d:2, freq:5M, score:0.92)  <- common word ranks first
  2. "te" (d:1, freq:500, score:0.65)
  3. "th" (d:1, freq:200, score:0.58)

Input: "speling"
  1. "spelling" (d:1, freq:100K, score:0.88)
  2. "spieling" (d:1, freq:50, score:0.45)
```

---

## 5. Auto-Apply Correction on Send (Investigation)

**Problem:**
When a user finishes typing and presses "Send" (or Return/Enter), the last word may still be misspelled with a pending autocorrection suggestion visible. Currently, the user must manually accept the correction before sending, which adds friction to the messaging experience.

**Desired Behavior:**
Automatically apply the top autocorrection suggestion to the last word when the user presses Send, similar to iOS keyboard behavior:

```
User types: "See you tomorow"
                      ↑ suggestion: "tomorrow"
User presses Send → Message sent: "See you tomorrow"
```

**Investigation Areas:**

1. **When to auto-apply:**
   - Only when there's a high-confidence suggestion (confidence > threshold)?
   - Only for distance-1 corrections to avoid aggressive changes?
   - Never for proper nouns or capitalized words?
   - What if the "misspelled" word is actually intentional (slang, names)?

2. **API Design Options:**

   ```swift
   // Option A: Explicit method for send-time correction
   func finalizeText(_ text: String) -> String {
       // Returns text with last word auto-corrected if appropriate
   }
   
   // Option B: Include in lookup response
   struct SuggestItem {
       let term: String
       let distance: Int
       let frequency: Int
       let shouldAutoApply: Bool  // NEW: Recommendation for auto-apply
   }
   
   // Option C: Separate confidence check
   func shouldAutoCorrect(
       original: String,
       suggestion: SuggestItem,
       context: AutoCorrectContext
   ) -> Bool
   ```

3. **Confidence Thresholds:**
   - What confidence level justifies auto-applying?
   - Should frequency ratio matter? (suggestion freq / original freq)
   - How does edit distance factor in?
   
   ```swift
   struct AutoCorrectPolicy {
       let minConfidence: Double        // e.g., 0.85
       let maxEditDistance: Int         // e.g., 1
       let minFrequencyRatio: Double    // e.g., 10.0 (suggestion 10x more common)
       let excludeCapitalized: Bool     // Don't correct "iPhone" → "iphone"
   }
   ```

4. **User override/undo:**
   - Should there be a way to undo auto-corrections?
   - Learn from rejected corrections?
   - This is likely UI-layer responsibility, not library

5. **Edge Cases to Handle:**
   - Empty correction (word not in dictionary but no good suggestion)
   - Multiple equally-good suggestions
   - Word is correct but rare (don't "correct" valid words)
   - Partial words / abbreviations ("omw", "brb")
   - URLs, email addresses, @mentions

**Potential Implementation:**

```swift
public struct AutoCorrectResult {
    let originalWord: String
    let correctedWord: String?      // nil if no correction applied
    let confidence: Double
    let wasApplied: Bool
    let reason: AutoCorrectReason   // .applied, .lowConfidence, .excluded, etc.
}

extension LowMemorySymSpell {
    /// Processes text for sending, auto-correcting the last word if appropriate
    func prepareForSend(
        _ text: String,
        policy: AutoCorrectPolicy = .default
    ) -> (text: String, correction: AutoCorrectResult?) {
        guard let lastWord = extractLastWord(text) else {
            return (text, nil)
        }
        
        let suggestions = lookup(phrase: lastWord, verbosity: .closest)
        guard let top = suggestions.first else {
            return (text, nil)
        }
        
        // Check if auto-correction is appropriate
        let shouldCorrect = evaluateAutoCorrect(
            original: lastWord,
            suggestion: top,
            policy: policy
        )
        
        if shouldCorrect {
            let correctedText = replaceLastWord(text, with: top.term)
            return (correctedText, AutoCorrectResult(...))
        }
        
        return (text, nil)
    }
}
```

**Questions to Resolve:**
- Is this in scope for the library, or should it be UI/app responsibility?
- How aggressive should default policy be?
- Should we provide "undo" data to help apps implement undo?
- How does this interact with word segmentation?

**Reference:**
- iOS auto-correction applies on space/punctuation/send
- Android Gboard has similar behavior with configurable aggressiveness
- Both allow words to be "learned" to prevent future corrections

---

## 6. Grammar-Aware Contraction Handling (Future)

**Problem:**
Simple contraction mapping incorrectly converts valid words to contractions:
- "well" → "we'll" (but "well" is a common word: "I'm doing well")
- "were" → "we're" (but "were" is past tense: "they were here")
- "ill" → "I'll" (but "ill" means sick: "feeling ill")
- "its" → "it's" (but "its" is possessive: "the dog wagged its tail")

**Current Workaround:**
These ambiguous words are excluded from the contraction map entirely, meaning:
- "well" stays as "well" (correct for "doing well", but user must manually type "we'll")
- "were" stays as "were" (correct for past tense, but "we're" requires manual entry)

**Ideal Solution:**
Use grammatical context to determine the correct interpretation:

```
"we well go" → "we'll go" (verb context: "we" + verb suggests contraction)
"doing well" → "doing well" (adverb context: "doing" + adverb keeps "well")

"we were there" → "we were there" (past tense context preserved)
"we were going" → "we're going" (present progressive suggests contraction)

"its tail" → "its tail" (possessive: followed by noun)
"its raining" → "it's raining" (contraction: followed by verb)
```

**Implementation Approaches:**

1. **Part-of-speech tagging (complex):**
   - Requires POS tagger or simple grammar rules
   - Look at surrounding words to determine context
   - High accuracy but significant complexity

2. **Bigram-based heuristics (simpler):**
   - Use bigram frequencies to decide
   - "its tail" vs "it's raining" - check which bigram is more common
   - Less accurate but leverages existing bigram infrastructure

3. **Pattern matching (simplest):**
   - "its" + noun → keep "its"
   - "its" + verb/adjective → suggest "it's"
   - Requires basic word classification

**Current Status:** Not implemented. Ambiguous words excluded from contraction map as a safe default.

**Priority:** Medium - improves UX but requires grammar awareness beyond current spell-check scope.

---

## 7. Future Considerations

### Confidence Score API
Expose confidence calculations directly from the library:
```swift
struct SuggestionWithConfidence {
    let term: String
    let distance: Int
    let frequency: Int
    let confidence: Double  // 0.0 - 1.0
}

func lookupWithConfidence(phrase: String, ...) -> [SuggestionWithConfidence]
```

### Custom Dictionary Tiers
Support for loading multiple dictionaries with different weights:
- Primary dictionary (common words, high weight)
- Secondary dictionary (less common, lower weight)
- User dictionary (learned words, configurable weight)

### Phonetic Matching
Optional phonetic similarity for suggestions:
- "definately" → "definitely" (sounds similar)
- Useful for words with silent letters or unusual spellings

---

## Priority

1. ✅ **DONE**: Word Segmentation Bigram Validation - Prevents incorrect segmentations
2. ✅ **DONE**: Spatial Keyboard Weighting - Significant UX improvement for typos
3. ✅ **DONE**: Correction-Aware Segmentation (Beam Search) - Handle misspelled concatenated words
4. ✅ **DONE**: Improved Frequency Weighting - Common words rank higher, bigram context support
5. **Medium**: Grammar-Aware Contraction Handling - Distinguish "well"/"we'll", "its"/"it's" by context
6. **Medium**: Auto-Apply Correction on Send - Better UX for messaging apps
7. **Medium**: Confidence Score API - Cleaner integration
8. **Low**: Custom Dictionary Tiers - Nice to have
9. **Low**: Phonetic Matching - Complex implementation
