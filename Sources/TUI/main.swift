#!/usr/bin/env swift
//
// main.swift
// SymSpellSwift TUI
//
// Interactive TUI for testing LowMemorySymSpell spell checking.
// Shows suggestions as you type with auto-replace for high-confidence corrections.
//
// Usage:
//     swift run TUI
//     swift run TUI --low-memory
//
// Controls:
//     Ctrl+A  - Toggle auto-replace
//     Ctrl+Z  - Undo last auto-replace
//     Ctrl+V  - Cycle verbosity (TOP / CLOSEST / ALL)
//     Ctrl+E  - Cycle max edit distance (1 / 2)
//     Ctrl+T  - Toggle transfer casing
//     Ctrl+U  - Clear input
//     TAB     - Accept top suggestion
//     Enter   - Accept selected suggestion
//     Up/Down - Navigate suggestions
//     ESC     - Quit
//

import Foundation
import Darwin.ncurses
import SymSpellSwift

// MARK: - ncurses Constants (not available as macros in Swift)

// Attribute constants
let ATTR_BOLD: Int32 = 1 << 21  // ATTR_BOLD
let ATTR_NORMAL: Int32 = 0

// Helper function for getmaxyx macro
func getTerminalSize() -> (height: Int32, width: Int32) {
    return (getmaxy(stdscr), getmaxx(stdscr))
}

// MARK: - Color Pairs

let COLOR_HEADER = Int16(1)
let COLOR_VALID = Int16(2)
let COLOR_INFO = Int16(3)
let COLOR_WARNING = Int16(4)
let COLOR_HIGHLIGHT = Int16(5)
let COLOR_MUTED = Int16(6)
let COLOR_NORMAL = Int16(7)

// MARK: - Verbosity Conversion

extension LowMemoryVerbosity {
    var name: String {
        switch self {
        case .top: return "TOP"
        case .closest: return "CLOSEST"
        case .all: return "ALL"
        }
    }
}

// MARK: - SymSpellTUI

class SymSpellTUI {
    // Auto-replace threshold: suggestions with confidence >= this are auto-applied
    static let autoReplaceThreshold = 0.75  // 75%

    // State
    var textBuffer = ""
    var cursorPos = 0
    var selected = 0
    var verbosity: LowMemoryVerbosity = .all
    var maxEditDistance = 2
    var transferCasing = false
    var statusMessage: String? = nil
    var autoReplaceEnabled = true
    var lastAutoReplacement: (original: String, replacement: String, position: Int)? = nil
    var autoReplaceMessage: String? = nil

    // Spell checker
    var spellChecker: LowMemorySymSpell!
    var dictLoaded = false
    var wordCount = 0
    var dbSizeMB: Double = 0.0
    var datasetName: String = "unknown"

    // Resource monitoring
    let startTime = Date()
    var lastLookupTimeMs: Double = 0.0
    var preDictMemoryMB: Double = 0.0
    var postDictMemoryMB: Double = 0.0

    // Terminal size
    var height: Int32 = 0
    var width: Int32 = 0

    init() {
        preDictMemoryMB = getMemoryMB()
    }

    // MARK: - Memory Monitoring

    func getMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.resident_size) / (1024 * 1024)
        }
        return 0.0
    }

    // MARK: - Dictionary Loading

    func loadDictionary(dictionaryPath: String, lowMemory: Bool) -> Bool {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("symspell_tui_\(UUID().uuidString)")

        spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7, dataDir: dataDir)

        let dictURL = URL(fileURLWithPath: dictionaryPath)
        guard FileManager.default.fileExists(atPath: dictionaryPath) else {
            return false
        }

        dictLoaded = spellChecker.loadDictionary(corpus: dictURL)
        if dictLoaded {
            wordCount = spellChecker.wordCount
            dbSizeMB = spellChecker.getDbSizeMB()
        }

        postDictMemoryMB = getMemoryMB()
        return dictLoaded
    }

    func loadPrebuilt(from directory: URL, name: String = "prebuilt") -> Bool {
        spellChecker = LowMemorySymSpell(maxEditDistance: 2, prefixLength: 7)

        dictLoaded = spellChecker.loadPrebuilt(from: directory)
        if dictLoaded {
            wordCount = spellChecker.wordCount
            dbSizeMB = spellChecker.getDbSizeMB()
            datasetName = name
        }

        postDictMemoryMB = getMemoryMB()
        return dictLoaded
    }

    // MARK: - Curses Setup

    func setupCurses() {
        initscr()
        cbreak()
        noecho()
        keypad(stdscr, true)
        curs_set(1)

        if has_colors() {
            start_color()
            use_default_colors()

            init_pair(COLOR_HEADER, Int16(COLOR_CYAN), -1)
            init_pair(COLOR_VALID, Int16(COLOR_GREEN), -1)
            init_pair(COLOR_INFO, Int16(COLOR_YELLOW), -1)
            init_pair(COLOR_WARNING, Int16(COLOR_RED), -1)
            init_pair(COLOR_HIGHLIGHT, Int16(COLOR_MAGENTA), -1)
            init_pair(COLOR_MUTED, Int16(COLOR_BLUE), -1)
            init_pair(COLOR_NORMAL, Int16(COLOR_WHITE), -1)
        }
    }

    func cleanupCurses() {
        endwin()
    }

    // MARK: - Main Loop

    func run() {
        setupCurses()
        defer { cleanupCurses() }

        while true {
            (height, width) = getTerminalSize()
            drawUI()

            let key = getch()

            // Clear messages on keypress (except undo)
            if key != 26 {  // Not Ctrl+Z
                autoReplaceMessage = nil
            }
            if key != KEY_UP && key != KEY_DOWN {
                statusMessage = nil
            }

            switch key {
            case 27:  // ESC
                return

            case 1:  // Ctrl+A - toggle auto-replace
                autoReplaceEnabled.toggle()
                statusMessage = "Auto-replace: \(autoReplaceEnabled ? "ON" : "OFF")"

            case 26:  // Ctrl+Z - undo last auto-replacement
                undoAutoReplace()
                autoReplaceMessage = nil

            case 21:  // Ctrl+U - clear input
                textBuffer = ""
                cursorPos = 0
                selected = 0
                lastAutoReplacement = nil

            case 22:  // Ctrl+V - cycle verbosity
                cycleVerbosity()

            case 20:  // Ctrl+T - toggle transfer casing
                transferCasing.toggle()
                statusMessage = "Transfer casing: \(transferCasing ? "ON" : "OFF")"

            case 5:  // Ctrl+E - cycle edit distance
                maxEditDistance = (maxEditDistance % 2) + 1
                statusMessage = "Max edit distance: \(maxEditDistance)"

            case 127, KEY_BACKSPACE, 8:  // Backspace
                handleBackspace()
                selected = 0

            case KEY_LEFT:
                cursorPos = max(0, cursorPos - 1)

            case KEY_RIGHT:
                cursorPos = min(textBuffer.count, cursorPos + 1)

            case KEY_HOME:
                cursorPos = 0

            case KEY_END:
                cursorPos = textBuffer.count

            case KEY_UP:
                selected = max(0, selected - 1)

            case KEY_DOWN:
                selected += 1

            case 9:  // TAB - accept top suggestion
                acceptSuggestion(index: 0)

            case 10, KEY_ENTER:  // ENTER - accept selected suggestion
                acceptSuggestion(index: selected)

            default:
                if key >= 32 && key <= 126 {  // Printable characters
                    handleChar(Character(UnicodeScalar(Int(key))!))
                    selected = 0
                }
            }
        }
    }

    func cycleVerbosity() {
        switch verbosity {
        case .top:
            verbosity = .closest
        case .closest:
            verbosity = .all
        case .all:
            verbosity = .top
        }
        statusMessage = "Verbosity: \(verbosity.name)"
    }

    // MARK: - Input Handling

    func handleChar(_ char: Character) {
        // Check for auto-replacement when space is typed
        if char == " " {
            tryAutoReplace()
        }

        let index = textBuffer.index(textBuffer.startIndex, offsetBy: cursorPos)
        textBuffer.insert(char, at: index)
        cursorPos += 1
    }

    func handleBackspace() {
        if cursorPos > 0 {
            let index = textBuffer.index(textBuffer.startIndex, offsetBy: cursorPos - 1)
            textBuffer.remove(at: index)
            cursorPos -= 1
        }
    }

    // MARK: - Word Extraction

    func getCurrentWord() -> String {
        guard !textBuffer.isEmpty else { return "" }

        var start = cursorPos
        while start > 0 {
            let idx = textBuffer.index(textBuffer.startIndex, offsetBy: start - 1)
            if textBuffer[idx].isWhitespace { break }
            start -= 1
        }

        var end = cursorPos
        while end < textBuffer.count {
            let idx = textBuffer.index(textBuffer.startIndex, offsetBy: end)
            if textBuffer[idx].isWhitespace { break }
            end += 1
        }

        let startIdx = textBuffer.index(textBuffer.startIndex, offsetBy: start)
        let endIdx = textBuffer.index(textBuffer.startIndex, offsetBy: end)
        return String(textBuffer[startIdx..<endIdx])
    }

    func getWordBoundaries() -> (start: Int, end: Int) {
        guard !textBuffer.isEmpty, cursorPos > 0 else { return (0, 0) }

        var start = cursorPos
        while start > 0 {
            let idx = textBuffer.index(textBuffer.startIndex, offsetBy: start - 1)
            if textBuffer[idx].isWhitespace { break }
            start -= 1
        }

        var end = cursorPos
        while end < textBuffer.count {
            let idx = textBuffer.index(textBuffer.startIndex, offsetBy: end)
            if textBuffer[idx].isWhitespace { break }
            end += 1
        }

        return (start, end)
    }

    // MARK: - Confidence Calculation

    func calculateConfidence(suggestion: SuggestItem, allSuggestions: [SuggestItem]) -> Double {
        let distance = suggestion.distance
        let count = suggestion.count

        // Exact match = 100% confident
        if distance == 0 {
            return 1.0
        }

        // Base score from edit distance
        let distanceScore = max(0, 1.0 - Double(distance) * 0.4)

        // Get max frequency at this distance
        let sameDistance = allSuggestions.filter { $0.distance == distance }
        let maxCount = sameDistance.map { $0.count }.max() ?? count

        // Frequency boost (0.0 to 0.3)
        let freqScore = maxCount > 0 ? 0.3 * Double(count) / Double(maxCount) : 0.0

        return min(1.0, distanceScore + freqScore)
    }

    // MARK: - Auto-Replace

    func tryAutoReplace() {
        guard autoReplaceEnabled, !textBuffer.isEmpty else { return }

        let word = getCurrentWord()
        guard !word.isEmpty else { return }

        var bestReplacement: String? = nil
        var bestConfidence = 0.0
        var replacementType = ""

        // Check lookup suggestions
        let suggestions = spellChecker.lookup(
            phrase: word,
            verbosity: verbosity,
            maxEditDistance: maxEditDistance,
            transferCasing: transferCasing
        )

        if let top = suggestions.first, top.distance > 0 {
            let confidence = calculateConfidence(suggestion: top, allSuggestions: suggestions)
            if confidence > bestConfidence {
                bestReplacement = top.term
                bestConfidence = confidence
                replacementType = "fix"
            }
        }

        // Check word splitting
        if word.count >= 4 {
            let segmentResult = spellChecker.wordSegmentation(phrase: word.lowercased(), maxEditDistance: maxEditDistance)
            let corrected = segmentResult.correctedString.trimmingCharacters(in: .whitespaces)

            if corrected.contains(" ") {
                let splitConfidence = segmentResult.distanceSum == 0 ? 0.85 : 0.7
                if splitConfidence > bestConfidence {
                    bestReplacement = corrected
                    bestConfidence = splitConfidence
                    replacementType = "split"
                }
            }
        }

        // Apply if above threshold
        if let replacement = bestReplacement, bestConfidence >= Self.autoReplaceThreshold {
            let (start, end) = getWordBoundaries()

            // Store for undo
            lastAutoReplacement = (word, replacement, start)

            // Replace
            let startIdx = textBuffer.index(textBuffer.startIndex, offsetBy: start)
            let endIdx = textBuffer.index(textBuffer.startIndex, offsetBy: end)
            textBuffer.replaceSubrange(startIdx..<endIdx, with: replacement)
            cursorPos = start + replacement.count

            // Show message
            let pct = Int(bestConfidence * 100)
            autoReplaceMessage = "Auto (\(replacementType)): \"\(word)\" -> \"\(replacement)\" (\(pct)%)"
        }
    }

    func undoAutoReplace() {
        guard let (original, replacement, position) = lastAutoReplacement else { return }

        let expected = replacement + " "
        let checkStart = textBuffer.index(textBuffer.startIndex, offsetBy: position)

        if position + expected.count <= textBuffer.count {
            let checkEnd = textBuffer.index(checkStart, offsetBy: expected.count)
            let checkRange = checkStart..<checkEnd

            if textBuffer[checkRange] == expected {
                textBuffer.replaceSubrange(checkRange, with: original + " ")
                cursorPos = position + original.count + 1
                statusMessage = "Undid: \"\(replacement)\" -> \"\(original)\""
            }
        }

        lastAutoReplacement = nil
    }

    // MARK: - Suggestion Acceptance

    func acceptSuggestion(index: Int) {
        let word = getCurrentWord()
        guard !word.isEmpty else { return }

        // Get all suggestions
        let (suggestions, splitSuggestion) = getAllSuggestions()

        var allItems: [(term: String, confidence: Double, distance: Int, type: String)] = []

        // Add split suggestion
        if let (splitText, splitConf) = splitSuggestion {
            allItems.append((splitText, splitConf, 0, "split"))
        }

        // Add lookup suggestions
        for suggestion in suggestions {
            let conf = calculateConfidence(suggestion: suggestion, allSuggestions: suggestions)
            allItems.append((suggestion.term, conf, suggestion.distance, "lookup"))
        }

        // Sort
        allItems.sort { lhs, rhs in
            if lhs.distance == 0 && lhs.type == "lookup" && !(rhs.distance == 0 && rhs.type == "lookup") {
                return true
            }
            if rhs.distance == 0 && rhs.type == "lookup" && !(lhs.distance == 0 && lhs.type == "lookup") {
                return false
            }
            return lhs.confidence > rhs.confidence
        }

        guard !allItems.isEmpty else { return }

        let safeIndex = min(index, allItems.count - 1)
        let replacement = allItems[safeIndex].term

        let (start, end) = getWordBoundaries()

        let startIdx = textBuffer.index(textBuffer.startIndex, offsetBy: start)
        let endIdx = textBuffer.index(textBuffer.startIndex, offsetBy: end)
        textBuffer.replaceSubrange(startIdx..<endIdx, with: replacement + " ")
        cursorPos = start + replacement.count + 1
        selected = 0
    }

    func getAllSuggestions() -> (suggestions: [SuggestItem], split: (String, Double)?) {
        let word = getCurrentWord()
        guard !word.isEmpty else { return ([], nil) }

        let lookupStart = Date()
        let suggestions = spellChecker.lookup(
            phrase: word,
            verbosity: verbosity,
            maxEditDistance: maxEditDistance,
            transferCasing: transferCasing
        )
        lastLookupTimeMs = Date().timeIntervalSince(lookupStart) * 1000

        var splitSuggestion: (String, Double)? = nil

        if word.count >= 4 {
            let segmentResult = spellChecker.wordSegmentation(phrase: word.lowercased(), maxEditDistance: maxEditDistance)
            let corrected = segmentResult.correctedString.trimmingCharacters(in: .whitespaces)

            if corrected.contains(" ") {
                let splitConfidence = segmentResult.distanceSum == 0 ? 0.85 : 0.7
                splitSuggestion = (corrected, splitConfidence)
            }
        }

        return (suggestions, splitSuggestion)
    }

    // MARK: - Drawing

    func drawUI() {
        clear()

        if height < 20 || width < 65 {
            mvaddstr(0, 0, "Terminal too small!")
            mvaddstr(1, 0, "Need 65x20, got \(width)x\(height)")
            refresh()
            return
        }

        // Header
        let title = String(repeating: "=", count: min(Int(width) - 1, 75))
        attron(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)))
        mvaddstr(0, 0, title)
        attroff(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)))

        attron(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)) | ATTR_BOLD)
        mvaddstr(1, 0, " SymSpellSwift Interactive Tester ")
        attroff(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)) | ATTR_BOLD)

        // Resource stats
        let memMB = getMemoryMB()
        let uptime = Date().timeIntervalSince(startTime)
        let uptimeMin = Int(uptime / 60)
        let uptimeSec = Int(uptime.truncatingRemainder(dividingBy: 60))

        let resourceInfo = "| RAM: \(String(format: "%.1f", memMB))MB | Lookup: \(String(format: "%.1f", lastLookupTimeMs))ms | \(uptimeMin):\(String(format: "%02d", uptimeSec))"
        let resourceStart = max(38, Int(width) - resourceInfo.count - 1)

        attron(COLOR_PAIR(Int32(COLOR_MUTED)))
        mvaddstr(1, Int32(resourceStart), resourceInfo)
        attroff(COLOR_PAIR(Int32(COLOR_MUTED)))

        attron(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)))
        mvaddstr(2, 0, title)
        attroff(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)))

        // Dictionary info
        let dictStatus = dictLoaded ? "Y" : "X"
        let dictInfo = "[LOW-MEM:\(datasetName)] Dict:\(dictStatus) | Words: \(wordCount) | DB: \(String(format: "%.1f", dbSizeMB))MB"
        attron(COLOR_PAIR(Int32(COLOR_MUTED)))
        mvaddstr(3, 0, dictInfo)
        attroff(COLOR_PAIR(Int32(COLOR_MUTED)))

        // Controls
        attron(COLOR_PAIR(Int32(COLOR_MUTED)))
        mvaddstr(5, 0, "TAB=accept | Up/Down=select | ^Z=undo | ^A=auto | ESC=quit")
        attroff(COLOR_PAIR(Int32(COLOR_MUTED)))

        // Auto-replace status
        let thresholdPct = Int(Self.autoReplaceThreshold * 100)
        attron(COLOR_PAIR(Int32(COLOR_MUTED)))
        mvaddstr(6, 0, "Auto-replace (>=\(thresholdPct)%): ")
        attroff(COLOR_PAIR(Int32(COLOR_MUTED)))

        let autoStatus = autoReplaceEnabled ? "ON" : "OFF"
        let autoColor = autoReplaceEnabled ? COLOR_VALID : COLOR_WARNING
        attron(COLOR_PAIR(Int32(autoColor)) | ATTR_BOLD)
        addstr(autoStatus)
        attroff(COLOR_PAIR(Int32(autoColor)) | ATTR_BOLD)

        attron(COLOR_PAIR(Int32(COLOR_MUTED)))
        addstr(" | Verbosity: ")
        attroff(COLOR_PAIR(Int32(COLOR_MUTED)))
        attron(COLOR_PAIR(Int32(COLOR_INFO)))
        addstr(verbosity.name)
        attroff(COLOR_PAIR(Int32(COLOR_INFO)))

        attron(COLOR_PAIR(Int32(COLOR_MUTED)))
        addstr(" | Edit: ")
        attroff(COLOR_PAIR(Int32(COLOR_MUTED)))
        attron(COLOR_PAIR(Int32(COLOR_INFO)))
        addstr("\(maxEditDistance)")
        attroff(COLOR_PAIR(Int32(COLOR_INFO)))

        // Input area
        attron(COLOR_PAIR(Int32(COLOR_VALID)) | ATTR_BOLD)
        mvaddstr(8, 0, ">>> ")
        attroff(COLOR_PAIR(Int32(COLOR_VALID)) | ATTR_BOLD)

        let displayText = String(textBuffer.prefix(Int(width) - 5))
        attron(COLOR_PAIR(Int32(COLOR_VALID)))
        addstr(displayText)
        attroff(COLOR_PAIR(Int32(COLOR_VALID)))

        // Auto-replace message
        if let msg = autoReplaceMessage {
            attron(COLOR_PAIR(Int32(COLOR_VALID)) | ATTR_BOLD)
            mvaddstr(9, 0, String(msg.prefix(Int(width) - 1)))
            attroff(COLOR_PAIR(Int32(COLOR_VALID)) | ATTR_BOLD)
        }

        // Status message
        if let msg = statusMessage {
            let msgRow: Int32 = autoReplaceMessage != nil ? 10 : 9
            attron(COLOR_PAIR(Int32(COLOR_INFO)))
            mvaddstr(msgRow, 0, String(msg.prefix(Int(width) - 1)))
            attroff(COLOR_PAIR(Int32(COLOR_INFO)))
        }

        // Suggestions
        drawSuggestionsList(startRow: 11)

        // Position cursor
        let cursorX = min(4 + cursorPos, Int(width) - 1)
        move(8, Int32(cursorX))

        refresh()
    }

    func drawSuggestionsList(startRow: Int32) {
        let word = getCurrentWord()

        if word.isEmpty {
            attron(COLOR_PAIR(Int32(COLOR_MUTED)))
            mvaddstr(startRow, 0, "(type to see suggestions)")
            attroff(COLOR_PAIR(Int32(COLOR_MUTED)))
            return
        }

        var row = startRow

        // Get suggestions
        let (suggestions, splitSuggestion) = getAllSuggestions()

        // Determine status
        let isValid = suggestions.contains { $0.distance == 0 }
        let (wordStatus, statusMarker, statusColor): (String, String, Int16)

        if isValid {
            (wordStatus, statusMarker, statusColor) = ("VALID", "Y", COLOR_VALID)
        } else if splitSuggestion != nil {
            (wordStatus, statusMarker, statusColor) = ("JOINED WORDS?", "+", COLOR_INFO)
        } else {
            (wordStatus, statusMarker, statusColor) = ("MISSPELLED", "X", COLOR_WARNING)
        }

        attron(COLOR_PAIR(Int32(COLOR_HEADER)))
        mvaddstr(row, 0, "Current: ")
        attroff(COLOR_PAIR(Int32(COLOR_HEADER)))

        attron(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)) | ATTR_BOLD)
        addstr("\"\(word)\"")
        attroff(COLOR_PAIR(Int32(COLOR_HIGHLIGHT)) | ATTR_BOLD)

        addstr(" ")

        attron(COLOR_PAIR(Int32(statusColor)))
        addstr("\(statusMarker) \(wordStatus)")
        attroff(COLOR_PAIR(Int32(statusColor)))

        row += 2

        // Build combined list
        var allItems: [(term: String, confidence: Double, distance: Int, type: String)] = []

        if let (splitText, splitConf) = splitSuggestion {
            allItems.append((splitText, splitConf, 0, "split"))
        }

        for suggestion in suggestions {
            let conf = calculateConfidence(suggestion: suggestion, allSuggestions: suggestions)
            allItems.append((suggestion.term, conf, suggestion.distance, "lookup"))
        }

        // Sort
        allItems.sort { lhs, rhs in
            if lhs.distance == 0 && lhs.type == "lookup" && !(rhs.distance == 0 && rhs.type == "lookup") {
                return true
            }
            if rhs.distance == 0 && rhs.type == "lookup" && !(lhs.distance == 0 && lhs.type == "lookup") {
                return false
            }
            return lhs.confidence > rhs.confidence
        }

        if !allItems.isEmpty {
            selected = min(selected, allItems.count - 1)

            attron(COLOR_PAIR(Int32(COLOR_HEADER)))
            mvaddstr(row, 0, "Suggestions:")
            attroff(COLOR_PAIR(Int32(COLOR_HEADER)))
            row += 1

            for (i, item) in allItems.prefix(10).enumerated() {
                if row >= height - 2 { break }

                let arrow = i == selected ? "> " : "  "
                let (color, tag): (Int16, String)

                if item.type == "split" {
                    (color, tag) = (COLOR_HIGHLIGHT, "split")
                } else if item.distance == 0 {
                    (color, tag) = (COLOR_VALID, "exact")
                } else if item.confidence >= 0.75 {
                    (color, tag) = (COLOR_VALID, "high")
                } else if item.confidence >= 0.5 {
                    (color, tag) = (COLOR_INFO, "med")
                } else {
                    (color, tag) = (COLOR_WARNING, "low")
                }

                let attr = i == selected ? ATTR_BOLD : 0

                attron(COLOR_PAIR(Int32(color)) | Int32(ATTR_BOLD))
                mvaddstr(row, 0, arrow)
                attroff(COLOR_PAIR(Int32(color)) | Int32(ATTR_BOLD))

                attron(COLOR_PAIR(Int32(color)) | Int32(attr))
                addstr(item.term)
                attroff(COLOR_PAIR(Int32(color)) | Int32(attr))

                // Confidence info
                let confPct = Int(item.confidence * 100)
                let info: String
                if item.type == "split" {
                    info = " (\(confPct)%) [\(tag)]"
                } else {
                    info = " (\(confPct)%) [d:\(item.distance)] [\(tag)]"
                }

                attron(COLOR_PAIR(Int32(COLOR_INFO)))
                addstr(info)
                attroff(COLOR_PAIR(Int32(COLOR_INFO)))

                row += 1
            }

            if allItems.count > 10 {
                attron(COLOR_PAIR(Int32(COLOR_MUTED)))
                mvaddstr(row, 0, "  ... and \(allItems.count - 10) more")
                attroff(COLOR_PAIR(Int32(COLOR_MUTED)))
            }
        } else {
            attron(COLOR_PAIR(Int32(COLOR_MUTED)))
            mvaddstr(row, 0, "  (no suggestions)")
            attroff(COLOR_PAIR(Int32(COLOR_MUTED)))
        }
    }
}

// MARK: - Main

func printUsage() {
    print("""
    ═══════════════════════════════════════════════════════════════════
     SymSpellSwift Interactive Tester
     with Auto-Replace & Resource Monitor
    ═══════════════════════════════════════════════════════════════════

    Usage: TUI [OPTIONS]

    Options:
      --dictionary PATH    Path to frequency dictionary file
      --prebuilt PATH      Path to directory with prebuilt .bin files
      --help               Show this help message

    If no dictionary is specified, looks for the test dictionary in the package.

    Features:
      - Auto-replace misspellings (>=75% confidence)
      - Auto-split joined words ('thequick' -> 'the quick')
      - Real-time memory monitoring
      - Ctrl+Z to undo auto-replacements

    Controls:
      Ctrl+A   Toggle auto-replace
      Ctrl+Z   Undo last auto-replace
      Ctrl+V   Cycle verbosity (TOP / CLOSEST / ALL)
      Ctrl+E   Cycle max edit distance (1 / 2)
      Ctrl+T   Toggle transfer casing
      Ctrl+U   Clear input
      TAB      Accept top suggestion
      Enter    Accept selected suggestion
      Up/Down  Navigate suggestions
      ESC      Quit

    Try typing:
      - 'memebers '     -> auto-corrects to 'members'
      - 'thequick '     -> auto-splits to 'the quick'
    """)
}

func main() {
    var dictionaryPath: String? = nil
    var prebuiltPath: String? = nil

    // Parse arguments
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.popFirst() {
        switch arg {
        case "--help", "-h":
            printUsage()
            return
        case "--dictionary", "-d":
            dictionaryPath = args.popFirst()
        case "--prebuilt", "-p":
            prebuiltPath = args.popFirst()
        default:
            if arg.hasPrefix("-") {
                print("Unknown option: \(arg)")
                printUsage()
                return
            }
        }
    }

    // Check if terminal is interactive
    guard isatty(STDIN_FILENO) != 0 else {
        print("Error: This TUI requires an interactive terminal.")
        print("Please run directly in a terminal, not as a background process.")
        return
    }

    let tui = SymSpellTUI()

    print("═══════════════════════════════════════════════════════════════════")
    print(" SymSpellSwift Interactive Tester")
    print(" with Auto-Replace & Resource Monitor")
    print("═══════════════════════════════════════════════════════════════════")
    print()

    // Load dictionary
    var loaded = false

    if let prebuilt = prebuiltPath {
        print("Loading prebuilt dictionary from: \(prebuilt)")
        let name = URL(fileURLWithPath: prebuilt).lastPathComponent
        loaded = tui.loadPrebuilt(from: URL(fileURLWithPath: prebuilt), name: name)
    } else if let dict = dictionaryPath {
        print("Loading dictionary from: \(dict)")
        tui.datasetName = "text-file"
        loaded = tui.loadDictionary(dictionaryPath: dict, lowMemory: true)
    } else {
        // Try to find prebuilt mmap_data folders first (fastest loading)
        let prebuiltPaths: [(path: String, name: String)] = [
            ("./mmap_data_full", "full"),
            ("./mmap_data", "default"),
            ("./mmap_data_small", "small"),
            ("../mmap_data_full", "full"),
            ("../mmap_data", "default"),
            ("../mmap_data_small", "small"),
        ]

        for (path, name) in prebuiltPaths {
            let fullPath = FileManager.default.currentDirectoryPath + "/" + path
            let wordsFile = fullPath + "/words.bin"
            if FileManager.default.fileExists(atPath: wordsFile) {
                print("Found prebuilt data at: \(fullPath)")
                loaded = tui.loadPrebuilt(from: URL(fileURLWithPath: fullPath), name: name)
                if loaded { break }
            }
        }

        // Fall back to text dictionary files
        if !loaded {
            let possiblePaths = [
                "./frequency_dictionary_en_82_765.txt",
                "../symspellpy/symspellpy/frequency_dictionary_en_82_765.txt",
                "Tests/SymSpellSwiftTests/Resources/frequency_dictionary_en_82_765.txt"
            ]

            for path in possiblePaths {
                let fullPath = FileManager.default.currentDirectoryPath + "/" + path
                if FileManager.default.fileExists(atPath: fullPath) {
                    print("Found dictionary at: \(fullPath)")
                    loaded = tui.loadDictionary(dictionaryPath: fullPath, lowMemory: true)
                    if loaded { break }
                }
            }
        }

        if !loaded {
            // Also check in the bundle
            if let bundlePath = Bundle.main.path(forResource: "frequency_dictionary_en_82_765", ofType: "txt") {
                print("Found dictionary in bundle: \(bundlePath)")
                loaded = tui.loadDictionary(dictionaryPath: bundlePath, lowMemory: true)
            }
        }
    }

    if !loaded {
        print()
        print("ERROR: Could not load dictionary!")
        print()
        print("Please specify a dictionary with --dictionary PATH")
        print("or prebuilt files with --prebuilt PATH")
        print()
        print("Example:")
        print("  swift run TUI --dictionary /path/to/frequency_dictionary_en_82_765.txt")
        return
    }

    print()
    print("Dictionary loaded: \(tui.wordCount) words")
    print("Memory usage: \(String(format: "%.1f", tui.getMemoryMB())) MB")
    print()
    print("Press any key to start...")

    // Wait for keypress
    var buffer = [UInt8](repeating: 0, count: 1)
    _ = read(STDIN_FILENO, &buffer, 1)

    // Run TUI
    tui.run()

    // Cleanup
    tui.spellChecker?.close()

    print()
    print("Goodbye!")
}

main()
