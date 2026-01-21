# SymSpellSwift
Swift implementation of SymSpell: Spelling correction &amp; Fuzzy search: 1 million times faster through Symmetric Delete spelling correction algorithm

_Description from https://github.com/wolfgarbe/SymSpell/_

The Symmetric Delete spelling correction algorithm reduces the complexity of edit candidate generation and dictionary lookup for a given Damerau-Levenshtein distance. It is six orders of magnitude faster (than the standard approach with deletes + transposes + replaces + inserts) and language independent.

Opposite to other algorithms only deletes are required, no transposes + replaces + inserts. Transposes + replaces + inserts of the input term are transformed into deletes of the dictionary term. Replaces and inserts are expensive and language dependent: e.g. Chinese has 70,000 Unicode Han characters!

The speed comes from the inexpensive delete-only edit candidate generation and the pre-calculation.
An average 5 letter word has about 3 million possible spelling errors within a maximum edit distance of 3,
but SymSpell needs to generate only 25 deletes to cover them all, both at pre-calculation and at lookup time. Magic!

## Single word spelling correction
Lookup provides a very fast spelling correction of single words.

- A Verbosity parameter allows to control the number of returned results:
Top: Top suggestion with the highest term frequency of the suggestions of smallest edit distance found.
Closest: All suggestions of smallest edit distance found, suggestions ordered by term frequency.
All: All suggestions within maxEditDistance, suggestions ordered by edit distance, then by term frequency.
- The Maximum edit distance parameter controls up to which edit distance words from the dictionary should be treated as suggestions.
- The required Word frequency dictionary can either be directly loaded from text files (LoadDictionary) or generated from a large text corpus (CreateDictionary).

### Applications

- Spelling correction,
- Query correction (10–15% of queries contain misspelled terms),
- Chatbots,
- OCR post-processing,
- Automated proofreading.
- Fuzzy search & approximate string matching

## Compound aware multi-word spelling correction
Supports compound aware automatic spelling correction of multi-word input strings.

### Compound splitting & decompounding
`lookup()` assumes every input string as single term. `lookupCompound()` also supports compound splitting / decompounding with three cases:

1. mistakenly inserted space within a correct word led to two incorrect terms
2. mistakenly omitted space between two correct words led to one incorrect combined term
3. multiple input terms with/without spelling errors

Splitting errors, concatenation errors, substitution errors, transposition errors, deletion errors and insertion errors can by mixed within the same word.

2. Automatic spelling correction

Large document collections make manual correction infeasible and require unsupervised, fully-automatic spelling correction.
In conventional spelling correction of a single token, the user is presented with multiple spelling correction suggestions.
For automatic spelling correction of long multi-word text the algorithm itself has to make an educated choice.

### Examples:
```diff
- whereis th elove hehad dated forImuch of thepast who couqdn'tread in sixthgrade and ins pired him
+ where is the love he had dated for much of the past who couldn't read in sixth grade and inspired him  (9 edits)

- in te dhird qarter oflast jear he hadlearned ofca sekretplan
+ in the third quarter of last year he had learned of a secret plan  (9 edits)

- the bigjest playrs in te strogsommer film slatew ith plety of funn
+ the biggest players in the strong summer film slate with plenty of fun  (9 edits)

- Can yu readthis messa ge despite thehorible sppelingmsitakes
+ can you read this message despite the horrible spelling mistakes  (9 edits)
```

## Word Segmentation of noisy text
WordSegmentation divides a string into words by inserting missing spaces at appropriate positions.

- Misspelled words are corrected and do not prevent segmentation.
- Existing spaces are allowed and considered for optimum segmentation.
- SymSpell.WordSegmentation uses a Triangular Matrix approach instead of the conventional Dynamic Programming: It uses an array instead of a dictionary for memoization, loops instead of recursion and incrementally optimizes prefix strings instead of remainder strings.
- The Triangular Matrix approach is faster than the Dynamic Programming approach. It has a lower memory consumption, better scaling (constant O(1) memory consumption vs. linear O(n)) and is GC friendly.
- While each string of length n can be segmented into 2^n−1 possible compositions,
SymSpell.WordSegmentation has a linear runtime O(n) to find the optimum composition.

### Examples:
```diff
- thequickbrownfoxjumpsoverthelazydog
+ the quick brown fox jumps over the lazy dog

- itwasabrightcolddayinaprilandtheclockswerestrikingthirteen
+ it was a bright cold day in april and the clocks were striking thirteen

- itwasthebestoftimesitwastheworstoftimesitwastheageofwisdomitwastheageoffoolishness
+ it was the best of times it was the worst of times it was the age of wisdom it was the age of foolishness
```

### Applications:

- Word Segmentation for CJK languages for Indexing Spelling correction, Machine translation, Language understanding, Sentiment analysis
- Normalizing English compound nouns for search & indexing (e.g. ice box = ice-box = icebox; pig sty = pig-sty = pigsty)
- Word segmentation for compounds if both original word and split word parts should be indexed.
- Correction of missing spaces caused by Typing errors.
- Correction of Conversion errors: spaces between word may get lost e.g. when removing line breaks.
- Correction of OCR errors: inferior quality of original documents or handwritten text may prevent that all spaces are recognized.
- Correction of Transmission errors: during the transmission over noisy channels spaces can get lost or spelling errors introduced.
- Keyword extraction from URL addresses, domain names, #hashtags, table column descriptions or programming variables written without spaces.
- For password analysis, the extraction of terms from passwords can be required.
- For Speech recognition, if spaces between words are not properly recognized in spoken language.
- Automatic CamelCasing of programming variables.
- Applications beyond Natural Language processing, e.g. segmenting DNA sequence into words

## Swift implementation
Current implementation builds on the original SymSpell, but uses Swift best practices and modern paradigms to achieve the same results with even better performance.

This package includes two implementations:
- **SymSpell** - Standard in-memory implementation (~150MB RAM for 82k words)
- **LowMemorySymSpell** - Memory-mapped implementation (~15-20MB RAM) ideal for iOS keyboard extensions

## Usage

### Standard SymSpell (In-Memory)

```swift
let symSpell = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 3)
if let path = Bundle.main.url(forResource: "frequency_dictionary_en_82_765", withExtension: "txt") {
  try? await symSpell.loadDictionary(from: path, termIndex: 0, countIndex: 1, termCount: 82765)
}

let results = symSpell.lookup("intermedaite", verbosity: .closest)
print(results.first?.term)  // "intermediate"
```

### LowMemorySymSpell (Memory-Mapped)

For memory-constrained environments like iOS keyboard extensions (50MB limit):

```swift
let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7)

// Load pre-built binary files from app bundle
if let dataDir = Bundle.main.resourceURL?.appendingPathComponent("mmap_data") {
    spellChecker.loadPrebuilt(from: dataDir)
}

// Spell checking
let suggestions = spellChecker.lookup(phrase: "helo", verbosity: .top)
print(suggestions.first?.term)  // "hello"

// Auto-correction with confidence threshold
if let correction = spellChecker.autoCorrection(for: "memebers") {
    print(correction)  // "members"
}

// Word segmentation
let result = spellChecker.wordSegmentation(phrase: "thequickbrown")
print(result.correctedString)  // "the quick brown"
```

## Pre-built Dictionary Data

This repository includes pre-built binary dictionary files in three sizes:

| Directory | Words | Size | Use Case |
|-----------|-------|------|----------|
| `mmap_data_full` | ~83k | 24 MB | Full English dictionary |
| `mmap_data` | ~83k | 24 MB | Default (same as full) |
| `mmap_data_small` | ~30k | 13 MB | Smaller footprint |

## Generating mmap Data Files

To regenerate the binary dictionary files or create custom ones:

### Prerequisites

```bash
# Create a virtual environment (recommended)
cd symspellswift
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install symspellpy editdistpy
```

### Generate Files

```bash
# Full dictionary (default)
python scripts/build_mmap_files.py --output ./mmap_data_full

# Smaller dictionary (top 30k most frequent words)
python scripts/build_mmap_files.py --output ./mmap_data_small --top-n 30000

# Custom dictionary
python scripts/build_mmap_files.py \
    --dictionary /path/to/your/dictionary.txt \
    --bigrams /path/to/your/bigrams.txt \
    --output ./my_mmap_data

# Deactivate venv when done
deactivate
```

### Options

```
--output, -o       Output directory for binary files (default: ./mmap_data)
--dictionary, -d   Path to frequency dictionary file
--bigrams, -b      Path to bigram dictionary file
--max-edit-distance, -e   Max edit distance (default: 2)
--prefix-length, -p       Prefix length (default: 7)
--top-n            Only include top N most frequent words
```

### Dictionary File Format

**Word frequency dictionary** (tab or space separated):
```
the 23135851162
of 13151942776
and 12997637966
```

**Bigram dictionary**:
```
the the 34563
of the 29432
in the 23567
```

## Spatial Keyboard Error Weighting

SymSpellSwift supports keyboard-aware spell correction that gives preference to corrections involving adjacent keys. This improves correction accuracy for common typing errors where users hit a neighboring key.

### How It Works

- Adjacent key substitutions (e.g., 'h' and 'j' on QWERTY) cost 0.5 instead of 1.0
- Distance-2 key substitutions cost 0.75
- This allows the spell checker to better identify intended words

**Example:** For input "tje" (meaning "the"):
- Without keyboard weighting: "the" and "tie" both have distance 1
- With QWERTY weighting: "the" has distance 0.5 (j→h adjacent), "tie" has distance 1.0

### Usage

```swift
// Initialize with keyboard layout
let spellChecker = LowMemorySymSpell(
    maxEditDistance: 2,
    prefixLength: 7,
    keyboardLayout: .qwerty
)

// Load keyboard layout binary file
if let keyboardDir = Bundle.main.resourceURL?.appendingPathComponent("keyboard_layouts") {
    spellChecker.loadKeyboardLayout(from: keyboardDir)
}

// Load dictionary
spellChecker.loadPrebuilt(from: dataDir)

// "tje" will now prefer "the" over "tie"
let suggestions = spellChecker.lookup(phrase: "tje", verbosity: .closest)
```

### Supported Layouts

| Layout | Enum Value | Description |
|--------|------------|-------------|
| QWERTY | `.qwerty` | Standard US/UK layout |
| AZERTY | `.azerty` | French layout |
| QWERTZ | `.qwertz` | German layout |
| Dvorak | `.dvorak` | Dvorak layout |
| Colemak | `.colemak` | Colemak layout |
| None | `.none` | Disable spatial weighting (default) |

### Generating Keyboard Layout Files

Pre-built keyboard layout files are included in `keyboard_layouts/`. To regenerate or add new layouts:

```bash
# Generate all layouts
python scripts/generate_keyboard_layout.py --output ./keyboard_layouts

# Generate specific layout
python scripts/generate_keyboard_layout.py --layout qwerty --output ./keyboard_layouts

# Show adjacency information (for debugging)
python scripts/generate_keyboard_layout.py --layout qwerty --verbose
```

### Adding Custom Layouts

To add a new keyboard layout:

1. Edit `scripts/generate_keyboard_layout.py`
2. Add your layout rows to the `LAYOUTS` dictionary:
   ```python
   MY_LAYOUT_ROWS = [
       list("qwertyuiop"),  # Top row
       list("asdfghjkl"),   # Middle row
       list("zxcvbnm"),     # Bottom row
   ]

   LAYOUTS["mylayout"] = MY_LAYOUT_ROWS
   ```
3. Run the script to generate the binary file
4. Add the corresponding enum case in `KeyboardLayout.swift`

### Binary Format

Keyboard layout files use a compact binary format (681 bytes):
- Header: 4 bytes magic ("KYBD") + 1 byte version
- Distance matrix: 26x26 bytes for lowercase letters a-z
  - 0 = same key
  - 1 = adjacent (ring 1)
  - 2 = distance 2 (ring 2)
  - 255 = far away

## Interactive TUI

A terminal UI is included for testing the spell checker:

```bash
# Build and run
swift run TUI

# Or with explicit dictionary path
swift run TUI --prebuilt ./mmap_data_full
```

**Controls:**
- `Ctrl+A` - Toggle auto-replace (>=75% confidence)
- `Ctrl+Z` - Undo last auto-replace
- `Ctrl+V` - Cycle verbosity (TOP / CLOSEST / ALL)
- `Ctrl+E` - Cycle max edit distance (1 / 2)
- `TAB` - Accept top suggestion
- `ESC` - Quit

## iOS Keyboard Extension Integration

```swift
class KeyboardViewController: UIInputViewController {
    let spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7)

    override func viewDidLoad() {
        super.viewDidLoad()

        // Load from app bundle
        if let dataDir = Bundle.main.resourceURL?.appendingPathComponent("mmap_data") {
            spellChecker.loadPrebuilt(from: dataDir)
        }
    }

    func checkSpelling(_ word: String) -> [SuggestItem] {
        return spellChecker.suggestions(for: word, limit: 5)
    }

    func shouldAutoCorrect(_ word: String) -> String? {
        return spellChecker.autoCorrection(for: word)
    }
}
```

## Memory Usage Comparison

| Implementation | RAM Usage | Load Time |
|----------------|-----------|-----------|
| SymSpell (in-memory) | ~150 MB | ~500ms |
| LowMemorySymSpell | ~15-20 MB | ~10ms |

The low-memory implementation stays well within the iOS keyboard extension 50MB limit.

