import Foundation
import EngageCore
@_spi(Modules) import EngageCore

enum InAppDocumentParser {
    static func parse(_ document: RemoteDocument) -> InAppCampaign? {
        do {
            return document.payload.string("source") == "AUTOMATION"
                ? try parseAutomation(document)
                : try parseExperience(document)
        } catch {
            return nil
        }
    }

    private static func parseExperience(_ document: RemoteDocument) throws -> InAppCampaign {
        let payload = document.payload
        let experienceId = try payload.requiredString("experienceId")
        let definition = try payload.requiredObject("definition")
        let schedule = try definition.requiredObject("schedule")
        let variants = try definition.requiredArray("contentVariants").map {
            try parseVariant($0.requiredObject())
        }
        guard !variants.isEmpty else { throw ParseError.invalid("contentVariants") }
        return InAppCampaign(
            key: document.key,
            revision: document.revision,
            experienceId: experienceId,
            messageId: "\(experienceId):\(Int64(payload.number("version") ?? Double(document.revision)))",
            publishedAt: payload.date("publishedAt") ?? .distantPast,
            availableAt: nil,
            expiresAt: nil,
            triggers: try definition.requiredArray("triggers").map {
                try parseTrigger($0.requiredObject())
            },
            startAt: schedule.date("startAt"),
            endAt: schedule.date("endAt"),
            priority: Int(definition.number("priority") ?? 0),
            conflictPolicy: try definition.enumValue("conflictPolicy", default: .queue),
            displayPolicy: try parseDisplayPolicy(definition.requiredObject("displayPolicy")),
            defaultLocale: definition.string("defaultLocale") ?? "und",
            fallbackLocale: definition.string("fallbackLocale"),
            variants: variants,
            oneShot: false
        )
    }

    private static func parseAutomation(_ document: RemoteDocument) throws -> InAppCampaign {
        let payload = document.payload
        let experienceId = try payload.requiredString("experienceId")
        let content = try payload.requiredObject("content")
        let variant = InAppContentVariant(
            id: nil,
            key: nil,
            locale: "und",
            allocationPercentage: 100,
            type: try content.enumValue("type", default: .scene),
            payload: try content.requiredObject("payload"),
            presentation: try parsePresentation(payload.requiredObject("presentation"))
        )
        return InAppCampaign(
            key: document.key,
            revision: document.revision,
            experienceId: experienceId,
            messageId: try payload.requiredString("messageId"),
            publishedAt: payload.date("availableAt") ?? .distantPast,
            availableAt: payload.date("availableAt"),
            expiresAt: payload.date("expiresAt"),
            triggers: [],
            startAt: nil,
            endAt: nil,
            priority: 0,
            conflictPolicy: .queue,
            displayPolicy: InAppDisplayPolicy(
                maxTotalImpressions: 1,
                maxImpressionsPerSession: 1,
                maxImpressionsPerDay: 1,
                cooldownMinutes: nil,
                redisplayAfterDismissal: false
            ),
            defaultLocale: "und",
            fallbackLocale: nil,
            variants: [variant],
            oneShot: true
        )
    }

    private static func parseTrigger(_ value: EngagePayload) throws -> InAppTrigger {
        InAppTrigger(
            id: try value.requiredString("id"),
            type: try value.enumValue("type", default: .appOpen),
            delaySeconds: max(0, Int(value.number("delaySeconds") ?? 0)),
            screenName: value.string("screenName"),
            eventName: value.string("eventName"),
            minimumSessions: value.number("minimumSessions").map(Int.init),
            versionConstraint: value.string("versionConstraint")
        )
    }

    private static func parseDisplayPolicy(_ value: EngagePayload) -> InAppDisplayPolicy {
        InAppDisplayPolicy(
            maxTotalImpressions: value.number("maxTotalImpressions").map(Int.init),
            maxImpressionsPerSession: value.number("maxImpressionsPerSession").map(Int.init),
            maxImpressionsPerDay: value.number("maxImpressionsPerDay").map(Int.init),
            cooldownMinutes: value.number("cooldownMinutes").map(Int.init),
            redisplayAfterDismissal: value.bool("redisplayAfterDismissal") ?? false
        )
    }

    private static func parseVariant(_ value: EngagePayload) throws -> InAppContentVariant {
        let content = try value.requiredObject("content")
        return InAppContentVariant(
            id: value.string("id"),
            key: value.string("key"),
            locale: value.string("locale") ?? "und",
            allocationPercentage: min(100, max(0, Int(value.number("allocationPercentage") ?? 0))),
            type: try content.enumValue("type", default: .scene),
            payload: try content.requiredObject("payload"),
            presentation: try parsePresentation(value.requiredObject("presentation"))
        )
    }

    private static func parsePresentation(_ value: EngagePayload) throws -> PresentationSpec {
        switch try value.requiredString("mode") {
        case "OVERLAY":
            let overlay = try value.requiredObject("overlay")
            return .overlay(OverlayPresentation(
                format: try overlay.enumValue("format", default: .modal),
                position: try overlay.optionalEnumValue("position"),
                backdrop: try overlay.enumValue("backdrop", default: .none),
                dismissal: try overlay.enumValue("dismissal", default: .userDismissible),
                animation: try overlay.enumValue("animation", default: .none),
                autoDismissAfterSeconds: overlay.number("autoDismissAfterSeconds").map(Int.init)
            ))
        case "EMBEDDED":
            let embedded = try value.requiredObject("embedded")
            return .embedded(EmbeddedPresentation(
                placementKey: try embedded.requiredString("placementKey"),
                emptyState: try embedded.enumValue("emptyState", default: .collapse)
            ))
        default:
            throw ParseError.invalid("presentation.mode")
        }
    }
}

private enum ParseError: Error { case missing(String), invalid(String) }

private extension JSONValue {
    func requiredObject() throws -> EngagePayload {
        guard let objectValue else { throw ParseError.invalid("object") }
        return objectValue
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw ParseError.missing(key) }
        return value
    }
    func requiredObject(_ key: String) throws -> EngagePayload {
        guard let value = object(key) else { throw ParseError.missing(key) }
        return value
    }
    func requiredArray(_ key: String) throws -> [JSONValue] {
        guard let value = array(key) else { throw ParseError.missing(key) }
        return value
    }
    func date(_ key: String) -> Date? { string(key).flatMap(parseInAppDate) }

    func enumValue<T: RawRepresentable>(_ key: String, default fallback: T) throws -> T
    where T.RawValue == String {
        guard let raw = string(key) else { return fallback }
        guard let value = T(rawValue: raw) else { throw ParseError.invalid(key) }
        return value
    }

    func optionalEnumValue<T: RawRepresentable>(_ key: String) throws -> T?
    where T.RawValue == String {
        guard let raw = string(key) else { return nil }
        guard let value = T(rawValue: raw) else { throw ParseError.invalid(key) }
        return value
    }
}

private func parseInAppDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
