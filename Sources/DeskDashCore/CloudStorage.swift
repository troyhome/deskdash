import Foundation

/// Storage in an online account (iCloud), shown next to the drives even though it isn't attached.
public struct CloudAccount: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    /// True when the plan size is DeskDash's guess, not one the user picked.
    public let totalIsGuess: Bool

    public init(id: String, name: String, totalBytes: Int64, availableBytes: Int64, totalIsGuess: Bool) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.totalIsGuess = totalIsGuess
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

/// iCloud: macOS tells how much space is left (`brctl quota`), but not the plan size, so the plan is the smallest
/// iCloud+ size that fits what's left, unless the user picked one.
public enum ICloudStorage {
    /// iCloud's plan sizes: free, then iCloud+ 50 GB, 200 GB, 2 TB, 6 TB, 12 TB.
    public static let planSizes: [Int64] = [5, 50, 200, 2_000, 6_000, 12_000].map { $0 * Bytes.gigabyte }

    /// "1151605086740 bytes of quota remaining in personal account" -> 1151605086740.
    public static func remainingBytes(fromQuotaOutput text: String) -> Int64? {
        guard let range = text.range(of: " bytes of quota remaining") else { return nil }
        return Int64(text[..<range.lowerBound].split(whereSeparator: { !$0.isNumber }).last ?? "")
    }

    public static func guessPlan(remaining: Int64) -> Int64 {
        planSizes.first { $0 >= remaining } ?? remaining
    }

    public static func account(remaining: Int64, chosenPlan: Int64?) -> CloudAccount {
        let total = max(chosenPlan ?? guessPlan(remaining: remaining), remaining)
        return CloudAccount(id: "icloud", name: "iCloud", totalBytes: total, availableBytes: remaining,
                            totalIsGuess: chosenPlan == nil)
    }

    /// Asks macOS. Slow-ish (a separate program), so call it off the main thread. Nil when not signed in.
    public static func current(chosenPlan: Int64?) -> CloudAccount? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        process.arguments = ["quota"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let remaining = remainingBytes(fromQuotaOutput: String(decoding: data, as: UTF8.self)) else { return nil }
        return account(remaining: remaining, chosenPlan: chosenPlan)
    }
}
