import Foundation

public final class FeatureFlags: @unchecked Sendable {
    private let runtime: CoreRuntime
    private let exposureLock = NSLock()
    private var scheduledExposures: Set<String> = []

    init(runtime: CoreRuntime) {
        self.runtime = runtime
        EngageLogger.debug("Core.Flags", "feature flag service initialized")
    }

    public func getBoolean(_ key: String, default fallback: Bool) -> Bool {
        resolve(key, type: "BOOLEAN")?.boolValue ?? fallback
    }
    public func getString(_ key: String, default fallback: String) -> String {
        resolve(key, type: "STRING")?.stringValue ?? fallback
    }
    public func getNumber(_ key: String, default fallback: Double) -> Double {
        resolve(key, type: "NUMBER")?.numberValue ?? fallback
    }
    public func getJSON<T: Decodable>(_ key: String, as type: T.Type, default fallback: T) -> T {
        guard let value = resolve(key, type: "JSON"),
              let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return decoded
    }

    private func resolve(_ key: String, type: String) -> JSONValue? {
        precondition(CoreRuntime.keyPattern(key))
        EngageLogger.debug("Core.Flags", "evaluation requested key=\(key) type=\(type)")
        guard runtime.privacy.value == .optedIn,
              runtime.enabledFeatures.value.contains(.featureFlags) else {
            EngageLogger.debug("Core.Flags", "fallback used key=\(key) reason=privacy_or_feature")
            return nil
        }
        let snapshot = runtime.syncSnapshot.value
        guard snapshot.generation == runtime.generation.value,
              let payload = snapshot.documents.first(where: {
                  $0.module == .featureFlags && $0.key == "snapshot"
              })?.payload,
              let flag = payload.object("flags")?.object(key),
              flag.string("type") == type,
              let value = flag["value"] else {
            EngageLogger.debug(
                "Core.Flags",
                "fallback used key=\(key) reason=missing_or_type_mismatch revision=\(snapshot.revision)"
            )
            return nil
        }
        EngageLogger.info(
            "Core.Flags",
            "evaluated key=\(key) type=\(type) revision=\(flag.integer("revision") ?? snapshot.revision) " +
                "variant=\(flag.string("variantKey") ?? "none")"
        )
        scheduleExposure(flagKey: key, flag: flag)
        return value
    }

    private func scheduleExposure(flagKey: String, flag: EngagePayload) {
        guard let experimentId = flag.string("experimentId"),
              let variantKey = flag.string("variantKey"),
              let revision = flag.integer("revision"), revision > 0 else {
            EngageLogger.verbose("Core.Flags", "exposure not required flagKey=\(flagKey)")
            return
        }
        let seed = [
            runtime.installationId.value ?? "", String(runtime.generation.value), experimentId,
            String(revision), variantKey,
        ].joined(separator: "\u{0}")
        let operationId = stableUUID(seed)
        exposureLock.lock()
        let inserted = scheduledExposures.insert(operationId).inserted
        exposureLock.unlock()
        guard inserted else {
            EngageLogger.verbose("Core.Flags", "exposure deduplicated flagKey=\(flagKey) operationId=\(operationId)")
            return
        }
        EngageLogger.debug(
            "Core.Flags",
            "exposure scheduled flagKey=\(flagKey) variant=\(variantKey) revision=\(revision) operationId=\(operationId)"
        )
        Task {
            if await runtime.containsExposure(operationId) {
                EngageLogger.verbose("Core.Flags", "exposure already persisted operationId=\(operationId)")
                return
            }
            do {
                try await runtime.enqueue(type: "FLAG_EXPOSED", payload: [
                    "flagKey": .string(flagKey),
                    "experimentId": .string(experimentId),
                    "variantKey": .string(variantKey),
                    "revision": .integer(revision),
                ], operationId: operationId)
                try await runtime.markExposure(operationId)
                EngageLogger.info("Core.Flags", "exposure persisted operationId=\(operationId)")
            } catch {
                EngageLogger.error("Core.Flags", "exposure failed operationId=\(operationId)", error: error)
                self.removeScheduledExposure(operationId)
            }
        }
    }

    private func removeScheduledExposure(_ operationId: String) {
        exposureLock.lock(); scheduledExposures.remove(operationId); exposureLock.unlock()
        EngageLogger.verbose("Core.Flags", "exposure schedule released operationId=\(operationId)")
    }
}

private func stableUUID(_ value: String) -> String {
    let bytes = Array(value.utf8)
    var high: UInt64 = 0xcbf29ce484222325
    var low: UInt64 = 0x84222325cbf29ce4
    for byte in bytes {
        high = (high ^ UInt64(byte)) &* 0x100000001b3
        low = (low ^ UInt64(byte &+ 31)) &* 0x100000001b3
    }
    var raw = withUnsafeBytes(of: high.bigEndian, Array.init) + withUnsafeBytes(of: low.bigEndian, Array.init)
    raw[6] = (raw[6] & 0x0f) | 0x50
    raw[8] = (raw[8] & 0x3f) | 0x80
    let hex = raw.map { String(format: "%02x", $0) }.joined()
    return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
}
