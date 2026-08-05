import Foundation
import EngageCore

enum InAppTriggerType: String, Sendable { case appOpen = "APP_OPEN", screenView = "SCREEN_VIEW", event = "EVENT", sessionCount = "SESSION_COUNT", appUpdate = "APP_UPDATE" }
enum InAppConflictPolicy: String, Sendable { case replaceLowerPriority = "REPLACE_LOWER_PRIORITY", queue = "QUEUE", skip = "SKIP" }

struct InAppTrigger: Sendable {
    let id: String
    let type: InAppTriggerType
    let delaySeconds: Int
    let screenName: String?
    let eventName: String?
    let minimumSessions: Int?
    let versionConstraint: String?
}

struct InAppDisplayPolicy: Sendable {
    let maxTotalImpressions: Int?
    let maxImpressionsPerSession: Int?
    let maxImpressionsPerDay: Int?
    let cooldownMinutes: Int?
    let redisplayAfterDismissal: Bool
}

struct InAppContentVariant: Sendable {
    let id: String?
    let key: String?
    let locale: String
    let allocationPercentage: Int
    let type: InAppContentType
    let payload: EngagePayload
    let presentation: PresentationSpec
}

struct InAppCampaign: Sendable {
    let key: String
    let revision: Int64
    let experienceId: String
    let messageId: String
    let publishedAt: Date
    let availableAt: Date?
    let expiresAt: Date?
    let triggers: [InAppTrigger]
    let startAt: Date?
    let endAt: Date?
    let priority: Int
    let conflictPolicy: InAppConflictPolicy
    let displayPolicy: InAppDisplayPolicy
    let defaultLocale: String
    let fallbackLocale: String?
    let variants: [InAppContentVariant]
    let oneShot: Bool
}

struct ResolvedInAppContent: Sendable {
    let campaign: InAppCampaign
    let variant: InAppContentVariant

    var instanceKey: String {
        "\(campaign.key):\(campaign.revision):\(variant.id ?? variant.key ?? "")"
    }

    var publicContent: InAppContent {
        InAppContent(
            experienceId: campaign.experienceId,
            messageId: campaign.messageId,
            variantId: variant.id ?? variant.key,
            type: variant.type,
            payload: variant.payload,
            presentation: variant.presentation
        )
    }
}

enum InAppRuntimeSignal: Sendable {
    case appOpened
    case appBackgrounded
    case screenViewed(String)
    case screenCleared
    case event(String)
    case localDataWiped
}

final class InAppEvaluator {
    private let history: InAppHistory
    private let installationSeed: @Sendable () -> String
    private let appVersion: String
    private let locales: @Sendable () -> [Locale]
    private let now: @Sendable () -> Date

    private var campaigns: [InAppCampaign] = []
    private var eligibleAt: [String: Date] = [:]
    private var currentScreen: String?
    private(set) var isForeground = false

    init(
        history: InAppHistory,
        installationSeed: @escaping @Sendable () -> String,
        appVersion: String,
        locales: @escaping @Sendable () -> [Locale] = {
            Locale.preferredLanguages.map { Locale(identifier: $0) }
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.history = history
        self.installationSeed = installationSeed
        self.appVersion = appVersion
        self.locales = locales
        self.now = now
        EngageLogger.debug("InApp.Evaluator", "initialized appVersion=\(appVersion)")
    }

    func replaceCampaigns(_ values: [InAppCampaign]) {
        EngageLogger.debug("InApp.Evaluator", "campaigns replacing previous=\(campaigns.count) next=\(values.count)")
        campaigns = values
        let keys = Set(values.map(\.key))
        eligibleAt = eligibleAt.filter { keys.contains($0.key) }
        for campaign in values where campaign.triggers.isEmpty {
            if eligibleAt[campaign.key] == nil {
                eligibleAt[campaign.key] = campaign.availableAt ?? campaign.publishedAt
            }
        }
        guard isForeground else { return }
        let timestamp = now()
        for campaign in values {
            for trigger in campaign.triggers where isInitiallyEligible(trigger) {
                markEligible(campaign, trigger: trigger, at: timestamp, onlyIfAbsent: true)
            }
        }
        EngageLogger.info("InApp.Evaluator", "campaigns active count=\(campaigns.count) eligible=\(eligibleAt.count)")
    }

    func resetContext() {
        EngageLogger.info("InApp.Evaluator", "context resetting campaigns=\(campaigns.count) eligible=\(eligibleAt.count)")
        campaigns = []
        eligibleAt = [:]
        currentScreen = nil
        isForeground = false
    }

    func onSignal(_ signal: InAppRuntimeSignal) {
        let timestamp = now()
        let type: String
        switch signal {
        case .appOpened:
            type = "appOpened"
            guard !isForeground else { return }
            isForeground = true
            history.beginSession()
            for campaign in campaigns {
                for trigger in campaign.triggers where
                    trigger.type == .appOpen
                    || trigger.type == .sessionCount && history.sessionCount >= (trigger.minimumSessions ?? 1)
                    || trigger.type == .appUpdate && versionMatches(appVersion, trigger.versionConstraint) {
                    markEligible(campaign, trigger: trigger, at: timestamp)
                }
            }
        case .appBackgrounded:
            type = "appBackgrounded"
            isForeground = false
        case let .screenViewed(key):
            type = "screen:\(key)"
            currentScreen = key
            for campaign in campaigns {
                for trigger in campaign.triggers where trigger.type == .screenView && trigger.screenName == key {
                    markEligible(campaign, trigger: trigger, at: timestamp)
                }
            }
        case .screenCleared:
            type = "screenCleared"
            currentScreen = nil
            for campaign in campaigns where campaign.triggers.contains(where: { $0.type == .screenView }) {
                eligibleAt[campaign.key] = nil
            }
        case let .event(name):
            type = "event:\(name)"
            for campaign in campaigns {
                for trigger in campaign.triggers where trigger.type == .event && trigger.eventName == name {
                    markEligible(campaign, trigger: trigger, at: timestamp)
                }
            }
        case .localDataWiped:
            type = "localDataWiped"
            resetContext()
        }
        EngageLogger.debug(
            "InApp.Evaluator",
            "signal applied type=\(type) foreground=\(isForeground) eligible=\(eligibleAt.count)"
        )
    }

    func candidates() -> [ResolvedInAppContent] {
        let timestamp = now()
        let values: [ResolvedInAppContent] = campaigns.compactMap { campaign -> ResolvedInAppContent? in
            guard let eligible = eligibleAt[campaign.key],
                  eligible <= timestamp,
                  isScheduled(campaign, at: timestamp),
                  withinLimits(campaign, at: timestamp) else { return nil }
            let screenTriggers = campaign.triggers.filter { $0.type == .screenView }
            if !screenTriggers.isEmpty && !screenTriggers.contains(where: { $0.screenName == currentScreen }) {
                return nil
            }
            return selectVariant(campaign).map { ResolvedInAppContent(campaign: campaign, variant: $0) }
        }.sorted {
            if $0.campaign.priority != $1.campaign.priority {
                return $0.campaign.priority > $1.campaign.priority
            }
            if $0.campaign.publishedAt != $1.campaign.publishedAt {
                return $0.campaign.publishedAt < $1.campaign.publishedAt
            }
            return $0.campaign.key < $1.campaign.key
        }
        EngageLogger.debug(
            "InApp.Evaluator",
            "candidates resolved count=\(values.count) messages=\(values.map { $0.campaign.messageId })"
        )
        return values
    }

    func nextEvaluationDelayNanoseconds() -> UInt64? {
        let timestamp = now()
        var boundaries = Array(eligibleAt.values)
        for campaign in campaigns {
            boundaries += [campaign.startAt, campaign.endAt, campaign.availableAt, campaign.expiresAt].compactMap { $0 }
            if let minutes = campaign.displayPolicy.cooldownMinutes,
               let last = history.history(campaign.key).lastImpressionAt {
                boundaries.append(last.addingTimeInterval(Double(minutes) * 60))
            }
        }
        guard let next = boundaries.filter({ $0 > timestamp }).min() else {
            EngageLogger.verbose("InApp.Evaluator", "next evaluation boundary absent")
            return nil
        }
        let delay = UInt64(max(0.001, next.timeIntervalSince(timestamp) + 0.001) * 1_000_000_000)
        EngageLogger.verbose("InApp.Evaluator", "next evaluation boundary delayNanoseconds=\(delay)")
        return delay
    }

    func consume(_ candidate: ResolvedInAppContent) {
        eligibleAt[candidate.campaign.key] = nil
        EngageLogger.debug("InApp.Evaluator", "candidate consumed messageId=\(candidate.campaign.messageId)")
    }

    func recordImpression(_ candidate: ResolvedInAppContent) {
        EngageLogger.info("InApp.Evaluator", "impression recording messageId=\(candidate.campaign.messageId)")
        history.recordImpression(candidate.campaign.key, at: now())
        if case .overlay = candidate.variant.presentation { consume(candidate) }
        if candidate.campaign.oneShot { consume(candidate) }
    }

    func recordDismiss(_ candidate: ResolvedInAppContent) {
        EngageLogger.info("InApp.Evaluator", "dismiss recording messageId=\(candidate.campaign.messageId)")
        history.recordDismiss(candidate.campaign.key, at: now())
        if !candidate.campaign.displayPolicy.redisplayAfterDismissal { consume(candidate) }
    }

    func remainsContextuallyEligible(_ candidate: ResolvedInAppContent) -> Bool {
        guard campaigns.contains(where: {
            $0.key == candidate.campaign.key && $0.revision == candidate.campaign.revision
        }), isScheduled(candidate.campaign, at: now()) else { return false }
        let screenTriggers = candidate.campaign.triggers.filter { $0.type == .screenView }
        return screenTriggers.isEmpty || screenTriggers.contains(where: { $0.screenName == currentScreen })
    }

    private func isInitiallyEligible(_ trigger: InAppTrigger) -> Bool {
        switch trigger.type {
        case .appOpen: return true
        case .sessionCount: return history.sessionCount >= (trigger.minimumSessions ?? 1)
        case .appUpdate: return versionMatches(appVersion, trigger.versionConstraint)
        case .screenView: return trigger.screenName == currentScreen
        case .event: return false
        }
    }

    private func markEligible(
        _ campaign: InAppCampaign,
        trigger: InAppTrigger,
        at timestamp: Date,
        onlyIfAbsent: Bool = false
    ) {
        if onlyIfAbsent, eligibleAt[campaign.key] != nil { return }
        eligibleAt[campaign.key] = timestamp.addingTimeInterval(Double(max(0, trigger.delaySeconds)))
        EngageLogger.verbose(
            "InApp.Evaluator",
            "campaign eligible messageId=\(campaign.messageId) trigger=\(trigger.type) delaySeconds=\(trigger.delaySeconds)"
        )
    }

    private func isScheduled(_ campaign: InAppCampaign, at timestamp: Date) -> Bool {
        (campaign.startAt.map { timestamp >= $0 } ?? true)
            && (campaign.endAt.map { timestamp < $0 } ?? true)
            && (campaign.availableAt.map { timestamp >= $0 } ?? true)
            && (campaign.expiresAt.map { timestamp < $0 } ?? true)
    }

    private func withinLimits(_ campaign: InAppCampaign, at timestamp: Date) -> Bool {
        let record = history.history(campaign.key)
        let policy = campaign.displayPolicy
        if policy.maxTotalImpressions.map({ record.total >= $0 }) == true { return false }
        if policy.maxImpressionsPerSession.map({
            record.sessionId == history.sessionId && record.sessionCount >= $0
        }) == true { return false }
        let today = utcDay(timestamp)
        if policy.maxImpressionsPerDay.map({ record.day == today && record.dayCount >= $0 }) == true {
            return false
        }
        if let minutes = policy.cooldownMinutes,
           let last = record.lastImpressionAt,
           timestamp.timeIntervalSince(last) < Double(minutes) * 60 { return false }
        if !policy.redisplayAfterDismissal, record.lastDismissedAt != nil { return false }
        return true
    }

    private func selectVariant(_ campaign: InAppCampaign) -> InAppContentVariant? {
        guard let selectedLocale = selectLocale(campaign) else {
            EngageLogger.debug("InApp.Evaluator", "variant unavailable messageId=\(campaign.messageId) reason=locale")
            return nil
        }
        let variants = campaign.variants.filter { normalizeLocale($0.locale) == selectedLocale }
        guard !variants.isEmpty else {
            EngageLogger.debug("InApp.Evaluator", "variant unavailable messageId=\(campaign.messageId) reason=no_variants")
            return nil
        }
        let bucket = stableBucket("\(installationSeed()):\(campaign.experienceId)")
        var upperBound = 0
        for variant in variants {
            upperBound += variant.allocationPercentage
            if bucket < upperBound {
                EngageLogger.debug(
                    "InApp.Evaluator",
                    "variant selected messageId=\(campaign.messageId) variant=\(variant.id ?? variant.key ?? "none") " +
                        "locale=\(selectedLocale) bucket=\(bucket)"
                )
                return variant
            }
        }
        return nil
    }

    private func selectLocale(_ campaign: InAppCampaign) -> String? {
        let available = Set(campaign.variants.map { normalizeLocale($0.locale) })
        for locale in locales() {
            let exact = normalizeLocale(locale.identifier)
            if available.contains(exact) { return exact }
            let language = normalizeLocale(locale.languageCode ?? "")
            if available.contains(language) { return language }
        }
        if let fallback = campaign.fallbackLocale.map(normalizeLocale), available.contains(fallback) {
            return fallback
        }
        let defaultLocale = normalizeLocale(campaign.defaultLocale)
        if available.contains(defaultLocale) { return defaultLocale }
        return available.contains("und") ? "und" : nil
    }
}

private func normalizeLocale(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: "-").lowercased()
}

private func utcDay(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: value)
}

private func versionMatches(_ current: String, _ constraint: String?) -> Bool {
    guard let constraint, !constraint.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
    let pattern = "^(>=|<=|>|<|=|==)?\\s*([0-9]+(?:\\.[0-9]+){0,3})$"
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
              in: constraint,
              range: NSRange(constraint.startIndex..., in: constraint)
          ),
          let versionRange = Range(match.range(at: 2), in: constraint) else { return false }
    let operatorValue = Range(match.range(at: 1), in: constraint).map { String(constraint[$0]) }
        .flatMap { $0.isEmpty ? nil : $0 } ?? "="
    let expected = String(constraint[versionRange]).split(separator: ".").compactMap { Int($0) }
    let actual = current.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
    let count = max(expected.count, actual.count)
    var comparison = 0
    for index in 0..<count {
        let left = index < actual.count ? actual[index] : 0
        let right = index < expected.count ? expected[index] : 0
        if left != right { comparison = left < right ? -1 : 1; break }
    }
    switch operatorValue {
    case ">": return comparison > 0
    case ">=": return comparison >= 0
    case "<": return comparison < 0
    case "<=": return comparison <= 0
    default: return comparison == 0
    }
}

/// SHA-256 first-word bucketing, intentionally identical to Android's evaluator.
private func stableBucket(_ value: String) -> Int {
    let digest = SHA256.hash(Array(value.utf8))
    return (Int(digest[0]) << 8 | Int(digest[1])) % 100
}

private enum SHA256 {
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
    ]

    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var message = bytes
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message += withUnsafeBytes(of: bitLength.bigEndian, Array.init)
        var state = initial
        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = message[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            }
            for index in 16..<64 {
                let s0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let s1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
        return state.flatMap { withUnsafeBytes(of: $0.bigEndian, Array.init) }
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        value >> count | value << (32 - count)
    }
}
