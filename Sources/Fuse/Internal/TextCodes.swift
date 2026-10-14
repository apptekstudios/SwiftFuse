import Foundation

/// Converts text into a flat array of `UInt32` codes, one per `Character`.
///
/// Every string in the index and every query pattern is run through the same normaliser,
/// so matching is a plain integer comparison in the hot loop. Normalisation is applied per
/// `Character`, which guarantees that code offsets map 1:1 back onto the original string
/// (Fuse.js normalises the whole string and can misreport highlight ranges for characters
/// whose lowercase form has a different length).
///
/// Code assignment:
/// - a `Character` whose normalised form is a single Unicode scalar becomes that scalar value
///   (`< 0x110000`);
/// - a multi-scalar grapheme (emoji sequences, letters with several combining marks, …) becomes a
///   deterministic 32-bit FNV-1a hash of its scalars with the top bit set, which can never collide
///   with a scalar value.
struct TextNormalizer: Sendable, Hashable, Codable {
    var isCaseSensitive: Bool
    var ignoreDiacritics: Bool

    init(isCaseSensitive: Bool = false, ignoreDiacritics: Bool = false) {
        self.isCaseSensitive = isCaseSensitive
        self.ignoreDiacritics = ignoreDiacritics
    }

    init(options: FuseOptions) {
        self.init(isCaseSensitive: options.isCaseSensitive, ignoreDiacritics: options.ignoreDiacritics)
    }

    // MARK: Encoding

    /// What one pass over a string produces besides the codes themselves.
    struct Encoded {
        var length: Int
        var bloom: UInt64
        var tokenCount: Int
        var isBlank: Bool
    }

    /// Appends the codes for `string` to `out`, computing the per-record statistics in the same pass.
    func encode(_ string: String, into out: inout [UInt32], cache: inout [Character: UInt32]) -> Encoded {
        let start = out.count
        if let encoded = encodeASCII(string, into: &out) {
            return encoded
        }
        out.removeSubrange(start...)
        var bloom: UInt64 = 0
        var tokens = 0
        var inWord = false
        var isBlank = true
        for character in string {
            let code = code(for: character, cache: &cache)
            out.append(code)
            bloom |= TextStats.bloomBit(code)
            if TextStats.isWordSeparator(code) {
                inWord = false
            } else {
                if !inWord { tokens += 1; inWord = true }
                if isBlank, !character.isWhitespace, character != "\u{FEFF}" { isBlank = false }
            }
        }
        return Encoded(length: out.count - start, bloom: bloom, tokenCount: max(1, tokens), isBlank: isBlank)
    }

    func encode(_ string: String) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(string.utf8.count)
        var cache: [Character: UInt32] = [:]
        _ = encode(string, into: &out, cache: &cache)
        return out
    }

    /// Fast path for pure-ASCII strings. Returns `nil` (leaving `out` partially appended) when a
    /// non-ASCII byte is encountered or the storage is not contiguous.
    private func encodeASCII(_ string: String, into out: inout [UInt32]) -> Encoded? {
        let lowercase = !isCaseSensitive
        let start = out.count
        return string.utf8.withContiguousStorageIfAvailable { bytes -> Encoded? in
            var previous: UInt8 = 0
            var bloom: UInt64 = 0
            var tokens = 0
            var inWord = false
            for byte in bytes {
                if byte >= 0x80 { return nil }
                var code = UInt32(byte)
                if byte == 0x0A && previous == 0x0D {
                    // "\r\n" is a single Character; Character.asciiValue reports it as "\n".
                    out[out.count - 1] = 0x0A
                    previous = byte
                    continue
                }
                if lowercase, byte >= 0x41, byte <= 0x5A {
                    code |= 0x20
                }
                out.append(code)
                bloom |= TextStats.bloomBit(code)
                if TextStats.isWordSeparator(code) {
                    inWord = false
                } else if !inWord {
                    tokens += 1
                    inWord = true
                }
                previous = byte
            }
            return Encoded(length: out.count - start, bloom: bloom, tokenCount: max(1, tokens), isBlank: tokens == 0)
        } ?? nil
    }

    @inline(__always)
    func code(for character: Character, cache: inout [Character: UInt32]) -> UInt32 {
        if let ascii = character.asciiValue {
            if !isCaseSensitive, ascii >= 0x41, ascii <= 0x5A {
                return UInt32(ascii | 0x20)
            }
            return UInt32(ascii)
        }
        if let cached = cache[character] {
            return cached
        }
        let code = slowCode(for: character)
        cache[character] = code
        return code
    }

    private func slowCode(for character: Character) -> UInt32 {
        var text = String(character)
        if !isCaseSensitive {
            text = text.lowercased()
        }
        if ignoreDiacritics {
            text = TextNormalizer.stripDiacritics(text)
        }
        let scalars = text.unicodeScalars
        guard let first = scalars.first else {
            return TextNormalizer.hash(character.unicodeScalars)
        }
        if scalars.index(after: scalars.startIndex) == scalars.endIndex {
            return first.value
        }
        return TextNormalizer.hash(scalars)
    }

    private static func hash(_ scalars: String.UnicodeScalarView) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for scalar in scalars {
            var value = scalar.value
            for _ in 0..<4 {
                hash ^= value & 0xFF
                hash = hash &* 0x0100_0193
                value >>= 8
            }
        }
        return hash | 0x8000_0000
    }

    // MARK: Diacritics

    /// Mirrors Fuse.js `stripDiacritics`: NFD decomposition with combining marks removed, plus a
    /// small table of letters that have no canonical decomposition.
    static func stripDiacritics(_ string: String) -> String {
        var result = string.folding(options: .diacriticInsensitive, locale: nil)
        if result.contains(where: { nonDecomposable[$0] != nil }) {
            result = String(result.flatMap { nonDecomposable[$0] ?? String($0) })
        }
        return result
    }

    private static let nonDecomposable: [Character: String] = [
        "ł": "l", "Ł": "L",
        "đ": "d", "Đ": "D",
        "ø": "o", "Ø": "O",
        "ħ": "h", "Ħ": "H",
        "ŧ": "t", "Ŧ": "T",
        "ı": "i",
        "ß": "ss",
    ]

    /// Whole-string normalisation used by the token analyser (where exact offsets don't matter).
    func normalizeString(_ string: String) -> String {
        var text = isCaseSensitive ? string : string.lowercased()
        if ignoreDiacritics {
            text = TextNormalizer.stripDiacritics(text)
        }
        return text
    }
}

// MARK: - Per-record helpers

enum TextStats {
    /// Mirrors Fuse.js `isWordSeparator`: U+0009–U+000D, U+0020 and U+00A0.
    @inline(__always)
    static func isWordSeparator(_ code: UInt32) -> Bool {
        (code >= 9 && code <= 13) || code == 32 || code == 160
    }

    /// Number of whitespace-separated tokens, never less than 1 (Fuse.js field-norm input).
    static func tokenCount(_ codes: UnsafeBufferPointer<UInt32>) -> Int {
        var count = 0
        var inWord = false
        for code in codes {
            if isWordSeparator(code) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return max(1, count)
    }

    /// A 64-bit "which characters occur" summary used to skip hopeless candidates.
    @inline(__always)
    static func bloomBit(_ code: UInt32) -> UInt64 {
        1 &<< ((code &* 0x9E37_79B1) >> 26)
    }

    static func bloom(_ codes: UnsafeBufferPointer<UInt32>) -> UInt64 {
        var bloom: UInt64 = 0
        for code in codes {
            bloom |= bloomBit(code)
        }
        return bloom
    }

    /// Fuse.js `isBlank`: the string trims to nothing.
    static func isBlank(_ string: String) -> Bool {
        string.allSatisfy { $0.isWhitespace || $0 == "\u{FEFF}" }
    }
}

/// Fuse.js `norm()`: `round(1000 / numTokens^(0.5 * weight)) / 1000`.
struct FieldNorm: Sendable {
    let weight: Double
    private var cache: [Int: Double] = [:]

    init(weight: Double) {
        self.weight = weight
    }

    mutating func value(forTokenCount tokens: Int) -> Double {
        if let cached = cache[tokens] {
            return cached
        }
        let norm = (1000.0 / pow(Double(tokens), 0.5 * weight)).rounded() / 1000.0
        cache[tokens] = norm
        return norm
    }
}
