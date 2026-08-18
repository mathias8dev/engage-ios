import Foundation
import EngageCore

private let engageValueBindingMarker = "$engageValue"

struct InAppPersonalizationContext: Sendable {
    let values: EngagePayload
    let fallbacks: EngagePayload

    init(values: EngagePayload = [:], fallbacks: EngagePayload = [:]) {
        self.values = values
        self.fallbacks = fallbacks
    }
}

enum InAppPersonalization {
    static func resolve(payload: EngagePayload, values: EngagePayload, fallbacks: EngagePayload) -> EngagePayload {
        guard case let .object(result) = resolve(.object(payload), values: values, fallbacks: fallbacks) else {
            return payload
        }
        return result
    }

    static func values(
        base: EngagePayload,
        event: EngagePayload,
        appVersion: String,
        locale: String,
        screenName: String?,
        sessionCount: Int
    ) -> EngagePayload {
        var result = base
        result["event"] = .object(merge(result["event"]?.objectValue, event))
        var runtime: EngagePayload = [
            "app_version": .string(appVersion),
            "locale": .string(locale),
            "session_count": .integer(Int64(sessionCount)),
        ]
        if let screenName { runtime["screen_name"] = .string(screenName) }
        result["runtime"] = .object(merge(result["runtime"]?.objectValue, runtime))
        return result
    }

    private static func resolve(
        _ value: JSONValue,
        values: EngagePayload,
        fallbacks: EngagePayload
    ) -> JSONValue {
        switch value {
        case let .object(object):
            if object.count == 1,
               let path = object[engageValueBindingMarker]?.stringValue {
                let fallback = read(fallbacks, path: path)
                let live = read(values, path: path)
                if let live, let fallback, sameType(live, fallback) { return live }
                return fallback ?? .null
            }
            return .object(object.mapValues { resolve($0, values: values, fallbacks: fallbacks) })
        case let .array(items):
            return .array(items.map { resolve($0, values: values, fallbacks: fallbacks) })
        default:
            return value
        }
    }

    private static func sameType(_ left: JSONValue, _ right: JSONValue) -> Bool {
        valueType(left) == valueType(right)
    }

    private static func valueType(_ value: JSONValue) -> ValueType {
        switch value {
        case .null: return .null
        case .bool: return .boolean
        case .integer, .number: return .number
        case .string: return .string
        case .array: return .array
        case .object: return .object
        }
    }

    private static func read(_ context: EngagePayload, path: String) -> JSONValue? {
        var current: JSONValue = .object(context)
        for segment in path.split(separator: ".").map(String.init) {
            guard let next = current.objectValue?[segment] else { return nil }
            current = next
        }
        return current
    }

    private static func merge(_ base: EngagePayload?, _ override: EngagePayload) -> EngagePayload {
        var result = base ?? [:]
        for (key, latest) in override {
            if case .null = latest { continue }
            if case let .object(current)? = result[key], case let .object(next) = latest {
                result[key] = .object(merge(current, next))
            } else {
                result[key] = latest
            }
        }
        return result
    }

    private enum ValueType { case null, boolean, number, string, array, object }
}
