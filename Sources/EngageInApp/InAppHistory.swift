import Foundation

struct ImpressionHistory: Codable, Sendable {
    var total = 0
    var sessionId: Int64 = -1
    var sessionCount = 0
    var day: String?
    var dayCount = 0
    var lastImpressionAt: Date?
    var lastDismissedAt: Date?
}

private struct GenerationHistory: Codable {
    var sessionId: Int64 = 0
    var sessionCount = 0
    var records: [String: ImpressionHistory] = [:]
}

private struct PersistedInAppHistory: Codable { var generations: [String: GenerationHistory] = [:] }

final class InAppHistory: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: @Sendable () -> Int64
    private let url: URL
    private var stored: PersistedInAppHistory

    init(generation: @escaping @Sendable () -> Int64, directory: URL = inAppStorageDirectory()) {
        self.generation = generation
        url = directory.appendingPathComponent("in-app-history.json")
        stored = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(PersistedInAppHistory.self, from: $0)
        } ?? PersistedInAppHistory()
    }

    var sessionId: Int64 { locked { active.sessionId } }
    var sessionCount: Int { locked { active.sessionCount } }

    @discardableResult
    func beginSession() -> Int64 {
        mutate { value in value.sessionId += 1; value.sessionCount += 1 }
        return sessionId
    }

    func history(_ campaignKey: String) -> ImpressionHistory {
        locked { active.records[campaignKey] ?? ImpressionHistory() }
    }

    func recordImpression(_ campaignKey: String, at timestamp: Date) {
        mutate { value in
            var record = value.records[campaignKey] ?? ImpressionHistory()
            let day = utcHistoryDay(timestamp)
            record.total += 1
            record.sessionCount = record.sessionId == value.sessionId ? record.sessionCount + 1 : 1
            record.sessionId = value.sessionId
            record.dayCount = record.day == day ? record.dayCount + 1 : 1
            record.day = day
            record.lastImpressionAt = timestamp
            value.records[campaignKey] = record
        }
    }

    func recordDismiss(_ campaignKey: String, at timestamp: Date) {
        mutate { value in
            var record = value.records[campaignKey] ?? ImpressionHistory()
            record.lastDismissedAt = timestamp
            value.records[campaignKey] = record
        }
    }

    func clearAll() {
        lock.lock()
        stored = PersistedInAppHistory()
        try? FileManager.default.removeItem(at: url)
        lock.unlock()
    }

    private var active: GenerationHistory {
        stored.generations[String(generation())] ?? GenerationHistory()
    }

    private func mutate(_ operation: (inout GenerationHistory) -> Void) {
        lock.lock()
        let key = String(generation())
        var value = stored.generations[key] ?? GenerationHistory()
        operation(&value)
        stored.generations[key] = value
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        lock.unlock()
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return operation()
    }
}

private func utcHistoryDay(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: value)
}

func inAppStorageDirectory() -> URL {
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? manager.temporaryDirectory
    let directory = base.appendingPathComponent("io.engage.sdk", isDirectory: true)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
