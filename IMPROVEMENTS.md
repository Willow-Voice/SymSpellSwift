# SymSpellSwift Improvements

Planned enhancements for the SymSpellSwift library.

---

## 1. Word Segmentation: Minimum Word Length

**Problem:**
Word segmentation produces incorrect results with single-letter words:
- `"crazy"` → `"crazy y"` (incorrect)
- `"woahh"` → `"w ahh"` (incorrect)
- `"crazyy"` → `"crazy y"` (incorrect)
- `"highlyyy"` (mistyped "highly") → `"hi gj k y"` (completely wrong)

Single-letter dictionary words like "y", "w", "a" are being used in segmentation when they shouldn't be.

**Solution:**
Add a `minWordLength` parameter to `wordSegmentation()`:

```swift
func wordSegmentation(
    phrase: String,
    maxEditDistance: Int = 2,
    minWordLength: Int = 2  // NEW: minimum length for segmented words
) -> SegmentedEntry
```

**Implementation Notes:**
- Default `minWordLength` to 2
- Allow exceptions for common single-letter words: "I", "a" (and possibly "O" as interjection)
- Filter candidate segmentations that contain words shorter than the minimum
- Consider adding a parameter for custom allowed single-letter words

**Example Behavior After Fix:**
- `"crazyy"` → `"crazy"` (single word correction, not segmentation)
- `"whatsthat"` → `"what's that"` (valid segmentation)
- `"iamhere"` → `"I am here"` (valid, "I" is allowed exception)

---

## 2. Spatial Keyboard Error Weighting

**Problem:**
Standard edit distance treats all character substitutions equally, but keyboard typos often involve adjacent keys:
- Typing "r" instead of "t" (adjacent on QWERTY)
- Typing "n" instead of "m" (adjacent on QWERTY)

A user typing "thr" meaning "the" should rank higher than "thr" → "tar" even though both are 1 substitution.

**Solution:**
Pass keyboard layout during SymSpell initialization. The library handles all layout-specific logic internally.

```swift
// Keyboard layouts handled by SymSpell
public enum KeyboardLayout {
    case qwerty          // Standard US/UK layout
    case qwertyMobile    // Mobile QWERTY (different adjacencies due to key size)
    case azerty          // French layout
    case qwertz          // German layout
    case dvorak          // Dvorak layout
    case colemak         // Colemak layout
    case none            // Disable spatial weighting (default, current behavior)
}

// Initialize with keyboard layout
let symSpell = LowMemorySymSpell(
    maxEditDistance: 2,
    prefixLength: 7,
    keyboardLayout: .qwertyMobile  // NEW parameter
)
```

**Implementation Notes:**

1. **Library owns all adjacency maps internally:**
   ```swift
   // Internal to SymSpell - not exposed to consumers
   internal struct KeyboardAdjacency {
       static let qwerty: [Character: Set<Character>] = [
           "q": ["w", "a"],
           "w": ["q", "e", "a", "s"],
           "e": ["w", "r", "s", "d"],
           "t": ["r", "y", "f", "g"],
           // ... etc
       ]

       static let qwertyMobile: [Character: Set<Character>] = [
           // Slightly different - larger touch targets mean different error patterns
       ]

       static func adjacency(for layout: KeyboardLayout) -> [Character: Set<Character>]
   }
   ```

2. **Modify distance calculation:**
   - Adjacent key substitution: 0.5 cost (instead of 1.0)
   - Non-adjacent substitution: 1.0 cost
   - This allows `maxEditDistance: 2` to catch up to 4 adjacent-key errors

3. **Support fractional distances in lookup:**
   - Internal distance calculations use `Double`
   - Results filtered by `maxEditDistance` still work correctly

4. **Default behavior unchanged:**
   - `keyboardLayout: .none` preserves current behavior (no spatial weighting)
   - Existing code continues to work without modification

**Example Behavior After Fix:**
```
Input: "tje" (meant "the", j is adjacent to h)
Before: "the" distance=1, "tie" distance=1 (equal ranking)
After:  "the" distance=0.5 (adjacent j→h), "tie" distance=1.0 (non-adjacent)
```

---

## 3. Improved Frequency Weighting in Ranking

**Problem:**
Currently, SymSpell ranks suggestions by:
1. Edit distance (primary sort)
2. Frequency (secondary sort - only as tiebreaker within same distance)

This means a rare word with distance 1 always ranks higher than a common word with distance 2, even when the common word is much more likely to be correct.

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

## 4. Future Considerations

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

1. **High**: Word Segmentation Min Length - Causes visible bugs (e.g., "highlyyy" → "hi gj k y")
2. **High**: Spatial Keyboard Weighting - Significant UX improvement for typos
3. **High**: Improved Frequency Weighting - Common words should rank higher
4. **Medium**: Confidence Score API - Cleaner integration
5. **Low**: Custom Dictionary Tiers - Nice to have
6. **Low**: Phonetic Matching - Complex implementation
