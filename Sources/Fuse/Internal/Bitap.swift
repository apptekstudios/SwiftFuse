/// Reusable scratch buffers for the Bitap inner loop. One per worker, never shared.
struct BitapScratch {
    var bits: [UInt32] = []
    var lastBits: [UInt32] = []
    var matchMask: [UInt8] = []

    @inline(__always)
    mutating func reserve(bitCapacity: Int, maskCapacity: Int) {
        if bits.count < bitCapacity {
            bits = [UInt32](repeating: 0, count: bitCapacity)
            lastBits = [UInt32](repeating: 0, count: bitCapacity)
        }
        if matchMask.count < maskCapacity {
            matchMask = [UInt8](repeating: 0, count: maskCapacity)
        }
    }
}

/// Fuse.js `createPatternAlphabet`: the bit mask of pattern positions for each character code.
/// ASCII codes use a dense table; everything else goes through a tiny open-addressed hash table.
struct PatternAlphabet: Sendable {
    var ascii: [UInt32]
    private var keys: [UInt32]
    private var values: [UInt32]
    private var occupied: UInt64

    private static let tableSize = 64

    init(_ codes: [UInt32]) {
        ascii = [UInt32](repeating: 0, count: 128)
        keys = [UInt32](repeating: 0, count: Self.tableSize)
        values = [UInt32](repeating: 0, count: Self.tableSize)
        occupied = 0
        let length = codes.count
        for (index, code) in codes.enumerated() {
            let bit = UInt32(1) << UInt32(length - index - 1)
            if code < 128 {
                ascii[Int(code)] |= bit
            } else {
                var slot = Self.slot(for: code)
                while occupied & (1 << UInt64(slot)) != 0, keys[slot] != code {
                    slot = (slot + 1) & (Self.tableSize - 1)
                }
                occupied |= 1 << UInt64(slot)
                keys[slot] = code
                values[slot] |= bit
            }
        }
    }

    @inline(__always)
    private static func slot(for code: UInt32) -> Int {
        Int((code &* 0x9E37_79B1) >> 26)
    }

    @inline(__always)
    func mask(for code: UInt32) -> UInt32 {
        if code < 128 {
            return ascii[Int(code)]
        }
        return slowMask(for: code)
    }

    /// Lookup for non-ASCII codes.
    @inline(never)
    func slowMask(for code: UInt32) -> UInt32 {
        var slot = Self.slot(for: code)
        while occupied & (1 << UInt64(slot)) != 0 {
            if keys[slot] == code {
                return values[slot]
            }
            slot = (slot + 1) & (Self.tableSize - 1)
        }
        return 0
    }
}

/// The fuzzy-matching options the Bitap core needs.
struct BitapOptions: Sendable, Hashable {
    var location: Int
    var distance: Int
    var threshold: Double
    var findAllMatches: Bool
    var minMatchCharLength: Int
    var includeMatches: Bool
    var ignoreLocation: Bool

    init(options: FuseOptions) {
        location = options.location
        distance = options.distance
        threshold = options.threshold
        findAllMatches = options.findAllMatches
        minMatchCharLength = options.minMatchCharLength
        includeMatches = options.includeMatches
        ignoreLocation = options.ignoreLocation
    }

    var computeMatches: Bool { includeMatches || minMatchCharLength > 1 }
}

/// A compiled Bitap pattern: up to 32 characters per chunk, Fuse.js chunking for longer patterns.
struct BitapPattern: Sendable {
    struct Chunk: Sendable {
        let codes: [UInt32]
        let alphabet: PatternAlphabet
        let startIndex: Int
        let finalMask: UInt32
        /// Distinct codes with their multiplicity and bloom bit, for the pre-filter.
        let prefilter: [(bit: UInt64, count: Int)]
        /// Largest error count that can still satisfy `threshold`.
        let maxErrors: Int
    }

    let codes: [UInt32]
    let chunks: [Chunk]
    let options: BitapOptions

    static let maxBits = 32

    init(codes: [UInt32], options: BitapOptions) {
        self.codes = codes
        self.options = options
        var chunks: [Chunk] = []
        let length = codes.count
        if length == 0 {
            // Fuse.js: an empty pattern never matches (except exactly, which blank values never are).
        } else if length > Self.maxBits {
            var index = 0
            let remainder = length % Self.maxBits
            let end = length - remainder
            while index < end {
                chunks.append(Self.makeChunk(Array(codes[index ..< index + Self.maxBits]), startIndex: index, options: options))
                index += Self.maxBits
            }
            if remainder > 0 {
                let start = length - Self.maxBits
                chunks.append(Self.makeChunk(Array(codes[start...]), startIndex: start, options: options))
            }
        } else {
            chunks.append(Self.makeChunk(codes, startIndex: 0, options: options))
        }
        self.chunks = chunks
    }

    private static func makeChunk(_ codes: [UInt32], startIndex: Int, options: BitapOptions) -> Chunk {
        var counts: [UInt32: Int] = [:]
        for code in codes {
            counts[code, default: 0] += 1
        }
        let prefilter = counts.map { (bit: TextStats.bloomBit($0.key), count: $0.value) }
        // score = errors / len (+ proximity) <= threshold  =>  errors <= threshold * len
        let maxErrors = options.threshold >= 1 ? Int.max : Int((options.threshold * Double(codes.count)).rounded(.down))
        return Chunk(
            codes: codes,
            alphabet: PatternAlphabet(codes),
            startIndex: startIndex,
            finalMask: UInt32(1) << UInt32(codes.count - 1),
            prefilter: prefilter,
            maxErrors: maxErrors
        )
    }

    /// `true` when no chunk can possibly match a text with the given character bloom. Sound: a
    /// pattern character that does not occur in the text costs at least one edit.
    @inline(__always)
    func cannotMatch(bloom: UInt64) -> Bool {
        for chunk in chunks {
            if chunk.maxErrors == Int.max { return false }
            var absent = 0
            for entry in chunk.prefilter where bloom & entry.bit == 0 {
                absent += entry.count
                if absent > chunk.maxErrors { break }
            }
            if absent <= chunk.maxErrors { return false }
        }
        return !chunks.isEmpty
    }

    /// Fuse.js `BitapSearch.searchIn`.
    func search(_ text: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch) -> FuseMatchResult {
        if codes.count == text.count, codes.withUnsafeBufferPointer({ $0.elementsEqual(text) }) {
            if text.count < options.minMatchCharLength {
                return .noMatch
            }
            return FuseMatchResult(isMatch: true, score: 0, indices: options.includeMatches ? [0 ..< text.count] : [])
        }
        guard !chunks.isEmpty else { return .noMatch }
        var totalScore = 0.0
        var hasMatches = false
        var indices: [Range<Int>] = []
        for chunk in chunks {
            let result = Bitap.search(text: text, chunk: chunk, location: options.location + chunk.startIndex, options: options, scratch: &scratch)
            if result.isMatch {
                hasMatches = true
                if options.includeMatches {
                    indices.append(contentsOf: result.indices)
                }
            }
            totalScore += result.score
        }
        guard hasMatches else { return .noMatch }
        return FuseMatchResult(
            isMatch: true,
            score: totalScore / Double(chunks.count),
            indices: options.includeMatches ? Bitap.mergeIndices(indices) : []
        )
    }
}

enum Bitap {
    /// A direct port of Fuse.js `search()` (`src/search/bitap/search.ts`).
    static func search(
        text: UnsafeBufferPointer<UInt32>,
        chunk: BitapPattern.Chunk,
        location: Int,
        options: BitapOptions,
        scratch: inout BitapScratch
    ) -> FuseMatchResult {
        let patternLength = chunk.codes.count
        let textLength = text.count
        let expectedLocation = max(0, min(location, textLength))
        var currentThreshold = options.threshold
        let distance = options.distance
        let ignoreLocation = options.ignoreLocation
        let patternLengthDouble = Double(patternLength)
        let computeMatches = options.computeMatches

        scratch.reserve(bitCapacity: textLength + patternLength + 2, maskCapacity: computeMatches ? textLength : 0)
        if computeMatches {
            scratch.matchMask.withUnsafeMutableBufferPointer { mask in
                mask.baseAddress?.update(repeating: 0, count: textLength)
            }
        }

        // Exact-substring pre-pass: seeds the threshold and the match mask.
        var searchFrom = expectedLocation
        while let index = indexOf(chunk.codes, in: text, from: searchFrom) {
            currentThreshold = min(calculateScore(errors: 0, currentLocation: index, expectedLocation: expectedLocation, patternLength: patternLengthDouble, distance: distance, ignoreLocation: ignoreLocation), currentThreshold)
            searchFrom = index + patternLength
            if computeMatches {
                scratch.matchMask.withUnsafeMutableBufferPointer { mask in
                    for offset in 0 ..< patternLength { mask[index + offset] = 1 }
                }
            }
        }

        var bestLocation = -1
        var finalScore = 1.0
        var bestErrors = 0
        var binMax = patternLength + textLength
        let finalMask = chunk.finalMask
        let alphabet = chunk.alphabet

        alphabet.ascii.withUnsafeBufferPointer { asciiTable in
            scratch.bits.withUnsafeMutableBufferPointer { bitsBuffer in
                scratch.lastBits.withUnsafeMutableBufferPointer { lastBuffer in
                    var bits = bitsBuffer.baseAddress!
                    var lastBits = lastBuffer.baseAddress!
                    let textBase = text.baseAddress
                    var errors = 0
                    while errors < patternLength {
                        var binMin = 0
                        var binMid = binMax
                        while binMin < binMid {
                            if calculateScore(errors: errors, currentLocation: expectedLocation + binMid, expectedLocation: expectedLocation, patternLength: patternLengthDouble, distance: distance, ignoreLocation: ignoreLocation) <= currentThreshold {
                                binMin = binMid
                            } else {
                                binMax = binMid
                            }
                            binMid = (binMax - binMin) / 2 + binMin
                        }
                        binMax = binMid
                        var start = max(1, expectedLocation - binMid + 1)
                        let finish = options.findAllMatches ? textLength : min(expectedLocation + binMid, textLength) + patternLength

                        bits.update(repeating: 0, count: finish + 2)
                        bits[finish + 1] = (UInt32(1) << UInt32(errors)) &- 1

                        var j = finish
                        while j >= start {
                            let currentLocation = j - 1
                            var charMatch: UInt32 = 0
                            if currentLocation < textLength {
                                let code = textBase.unsafelyUnwrapped[currentLocation]
                                charMatch = code < 128 ? asciiTable[Int(code)] : alphabet.slowMask(for: code)
                            }
                            var value = ((bits[j + 1] << 1) | 1) & charMatch
                            if errors > 0 {
                                value |= (((lastBits[j + 1] | lastBits[j]) << 1) | 1) | lastBits[j + 1]
                            }
                            bits[j] = value
                            if value & finalMask != 0 {
                                finalScore = calculateScore(errors: errors, currentLocation: currentLocation, expectedLocation: expectedLocation, patternLength: patternLengthDouble, distance: distance, ignoreLocation: ignoreLocation)
                                if finalScore <= currentThreshold {
                                    currentThreshold = finalScore
                                    bestLocation = currentLocation
                                    bestErrors = errors
                                    if bestLocation <= expectedLocation { break }
                                    start = max(1, 2 * expectedLocation - bestLocation)
                                }
                            }
                            j -= 1
                        }

                        if calculateScore(errors: errors + 1, currentLocation: expectedLocation, expectedLocation: expectedLocation, patternLength: patternLengthDouble, distance: distance, ignoreLocation: ignoreLocation) > currentThreshold {
                            break
                        }
                        swap(&bits, &lastBits)
                        errors += 1
                    }
                }
            }
        }

        if computeMatches, bestLocation >= 0 {
            let matchEnd = min(textLength - 1, bestLocation + patternLength - 1 + bestErrors)
            if bestLocation <= matchEnd {
                scratch.matchMask.withUnsafeMutableBufferPointer { mask in
                    for k in bestLocation ... matchEnd where alphabet.mask(for: text[k]) != 0 {
                        mask[k] = 1
                    }
                }
            }
        }

        var isMatch = bestLocation >= 0
        var indices: [Range<Int>] = []
        if computeMatches {
            indices = convertMaskToIndices(scratch.matchMask, length: textLength, minMatchCharLength: options.minMatchCharLength)
            if indices.isEmpty {
                isMatch = false
            } else if !options.includeMatches {
                indices = []
            }
        }
        return FuseMatchResult(isMatch: isMatch, score: max(0.001, finalScore), indices: indices)
    }

    /// Fuse.js `computeScore` for the Bitap core.
    @inline(__always)
    static func calculateScore(errors: Int, currentLocation: Int, expectedLocation: Int, patternLength: Double, distance: Int, ignoreLocation: Bool) -> Double {
        let accuracy = Double(errors) / patternLength
        if ignoreLocation { return accuracy }
        let proximity = abs(expectedLocation - currentLocation)
        if distance == 0 { return proximity != 0 ? 1 : accuracy }
        return accuracy + Double(proximity) / Double(distance)
    }

    /// `text.indexOf(pattern, from)` on code arrays.
    @inline(__always)
    static func indexOf(_ pattern: [UInt32], in text: UnsafeBufferPointer<UInt32>, from: Int) -> Int? {
        let patternLength = pattern.count
        guard patternLength > 0, from >= 0 else { return nil }
        let last = text.count - patternLength
        guard from <= last else { return nil }
        return pattern.withUnsafeBufferPointer { pattern in
            let first = pattern[0]
            var index = from
            while index <= last {
                if text[index] == first {
                    var k = 1
                    while k < patternLength, text[index + k] == pattern[k] { k += 1 }
                    if k == patternLength { return index }
                }
                index += 1
            }
            return nil
        }
    }

    /// Fuse.js `convertMaskToIndices`, producing half-open ranges.
    static func convertMaskToIndices(_ mask: [UInt8], length: Int, minMatchCharLength: Int) -> [Range<Int>] {
        var indices: [Range<Int>] = []
        var start = -1
        var i = 0
        while i < length {
            let match = mask[i] != 0
            if match && start == -1 {
                start = i
            } else if !match && start != -1 {
                if i - start >= minMatchCharLength {
                    indices.append(start ..< i)
                }
                start = -1
            }
            i += 1
        }
        if start != -1, length > 0, mask[length - 1] != 0, length - start >= minMatchCharLength {
            indices.append(start ..< length)
        }
        return indices
    }

    /// Fuse.js `mergeIndices`: sort and merge overlapping or adjacent ranges.
    static func mergeIndices(_ indices: [Range<Int>]) -> [Range<Int>] {
        guard indices.count > 1 else { return indices }
        let sorted = indices.sorted { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound < $1.upperBound }
        var merged: [Range<Int>] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
