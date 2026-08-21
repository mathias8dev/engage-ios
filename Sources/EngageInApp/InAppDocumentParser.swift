import Foundation
import EngageCore
@_spi(Modules) import EngageCore

enum InAppDocumentParser {
    private static let outcomeKeyPattern = #"^[a-z][a-z0-9_.-]{0,127}$"#

    static func parse(_ document: RemoteDocument) -> InAppCampaign? {
        do {
            let campaign = document.payload.string("source") == "AUTOMATION"
                ? try parseAutomation(document)
                : try parseExperience(document)
            EngageLogger.debug(
                "InApp.Parser",
                "document parsed key=\(document.key) revision=\(document.revision) " +
                    "experienceId=\(campaign.experienceId) messageId=\(campaign.messageId) " +
                    "variants=\(campaign.variants.count) triggers=\(campaign.triggers.count)"
            )
            return campaign
        } catch {
            EngageLogger.error(
                "InApp.Parser",
                "document rejected key=\(document.key) revision=\(document.revision)",
                error: error
            )
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
            personalization: parsePersonalization(payload),
            oneShot: false,
            automation: nil
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
            personalization: parsePersonalization(payload),
            oneShot: true,
            automation: InAppAutomationContext(
                automationId: try payload.requiredString("automationId"),
                automationVersion: try payload.requiredInt("automationVersion"),
                runId: try payload.requiredString("automationRunId"),
                nodeId: try payload.requiredString("automationNodeId"),
                experienceVersion: try payload.requiredInt("experienceVersion"),
                outcomeKeys: Set(try payload.requiredArray("outcomeKeys").map { value in
                    guard
                        let key = value.stringValue,
                        key.range(of: outcomeKeyPattern, options: .regularExpression) != nil
                    else {
                        throw ParseError.invalid("outcomeKeys")
                    }
                    return key
                })
            )
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

    private static func parsePersonalization(_ payload: EngagePayload) -> InAppPersonalizationContext {
        guard let personalization = payload.object("personalization") else {
            return InAppPersonalizationContext()
        }
        return InAppPersonalizationContext(
            values: personalization.object("values") ?? [:],
            fallbacks: personalization.object("fallbacks") ?? [:]
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
    func requiredInt(_ key: String) throws -> Int {
        guard let value = number(key), value.rounded() == value else { throw ParseError.missing(key) }
        return Int(value)
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
