import Foundation
import Fuse

// A dependency-free micro benchmark. Run with:
//     swift run -c release fuse-benchmark [itemCount ...]

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let words = ["anesthesia", "general", "regional", "spinal", "epidural", "block", "femoral", "nerve", "laparoscopic", "cholecystectomy", "appendicectomy", "hernia", "repair", "knee", "arthroscopy", "hip", "replacement", "caesarean", "section", "tonsillectomy", "cataract", "dental", "extraction", "fracture", "fixation", "cystoscopy", "colonoscopy", "endoscopy", "thyroidectomy", "mastectomy", "bypass", "stent", "biopsy", "excision", "lesion", "shoulder", "wrist", "ankle", "cardiac", "vascular", "paediatric", "emergency", "elective", "sedation", "airway", "intubation", "laryngeal", "mask", "patient", "supervisor"]

func makeItems(_ count: Int) -> [String] {
    var rng = SplitMix64(state: 42)
    return (0 ..< count).map { _ in
        let n = Int.random(in: 2 ... 5, using: &rng)
        return (0 ..< n).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ").capitalized
    }
}

struct Book: FuseSearchable {
    var title: String
    var author: String
    var tags: [String]
    static let fuseKeys: [FuseKey<Book>] = [
        FuseKey("title", weight: 2, \.title),
        FuseKey("author", \.author),
        FuseKey("tags", \.tags),
    ]
}

func measure(_ iterations: Int = 1, _ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0 ..< iterations { try body() }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
}

func fmt(_ ms: Double) -> String {
    ms < 1 ? String(format: "%7.3f ms", ms) : String(format: "%7.2f ms", ms)
}

let counts = CommandLine.arguments.dropFirst().compactMap { Int($0) }
let sizes = counts.isEmpty ? [1_000, 10_000, 100_000] : counts
let queries = ["spinal", "lap chole", "knee replacment", "caesarian", "tonsil", "general anesthesia airway"]

print("SwiftFuse benchmark — \(ProcessInfo.processInfo.activeProcessorCount) cores")
print(String(repeating: "-", count: 78))
print(String(format: "%-10@ %-12@ %-12@ %-12@ %-12@ %-12@", "items", "init", "index", "search", "async", "+matches"))

for size in sizes {
    let items = makeItems(size)
    var fuse: Fuse<String>!
    let initTime = measure { fuse = Fuse(items) }
    let indexTime = measure { fuse.prepare() }
    let searchTime = measure(queries.count * 3) {
        for query in queries { _ = fuse.search(query) }
    } / Double(queries.count)
    let semaphore = DispatchSemaphore(value: 0)
    let box = Locked(0.0)
    Task.detached {
        let time = try! await measureAsync(3) {
            for query in queries { _ = try await fuse.search(query) }
        }
        box.withLock { $0 = time / Double(queries.count) }
        semaphore.signal()
    }
    semaphore.wait()
    let asyncTime = box.withLock { $0 }
    let withMatches = Fuse(items, options: FuseOptions(includeMatches: true), indexing: .immediate)
    let matchesTime = measure(queries.count) {
        for query in queries { _ = withMatches.search(query) }
    } / Double(queries.count)
    print(String(format: "%-10d %@ %@ %@ %@ %@", size, fmt(initTime), fmt(indexTime), fmt(searchTime), fmt(asyncTime), fmt(matchesTime)))
}

func measureAsync(_ iterations: Int, _ body: () async throws -> Void) async rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0 ..< iterations { try await body() }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

print()
print("Weighted keys (title×2, author, tags), 10k books:")
let books = makeItems(10_000).enumerated().map { Book(title: $1, author: "Author \($0 % 500)", tags: [words[$0 % words.count], words[($0 * 7) % words.count]]) }
let bookFuse = Fuse(books, indexing: .immediate)
let bookTime = measure(queries.count * 3) { for q in queries { _ = bookFuse.search(q) } } / Double(queries.count)
print("  search: \(fmt(bookTime))")
let extended = Fuse(books, options: FuseOptions(useExtendedSearch: true), indexing: .immediate)
let extendedTime = measure(3) { _ = extended.search("^spinal 'block | =knee") }
print("  extended search: \(fmt(extendedTime))")
let token = Fuse(books, options: FuseOptions(useTokenSearch: true), indexing: .immediate)
let tokenTime = measure(3) { _ = token.search("knee replacment anesthesia") }
print("  token search: \(fmt(tokenTime))")
