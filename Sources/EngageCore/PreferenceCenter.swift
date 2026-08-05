import Foundation

public struct PreferenceCenterSnapshot: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let description: String?
    public let sections: [PreferenceSection]
}
public struct PreferenceSection: Equatable, Sendable {
    public let key: String
    public let title: String?
    public let description: String?
    public let subscriptions: [SubscriptionPreference]
}
public struct SubscriptionPreference: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let description: String?
    public let profileChoices: [Channel: Bool]?
    public let installationChoice: Bool?
}

public final class PreferenceCenter: @unchecked Sendable {
    private let runtime: CoreRuntime
    private let lock = NSLock()
    private var centers: [String: EngageState<PreferenceCenterSnapshot?>] = [:]
    private var observationTasks: [String: [Task<Void, Never>]] = [:]

    init(runtime: CoreRuntime) {
        self.runtime = runtime
        EngageLogger.debug("Core.Preferences", "preference center service initialized")
    }

    public func center(_ key: String? = nil) -> EngageState<PreferenceCenterSnapshot?> {
        if let key { precondition(CoreRuntime.keyPattern(key)) }
        let identity = key ?? "\u{0}default"
        EngageLogger.info("Core.Preferences", "center requested key=\(key ?? "default")")
        lock.lock()
        if let value = centers[identity] {
            lock.unlock()
            EngageLogger.debug("Core.Preferences", "existing center returned key=\(key ?? "default")")
            return value
        }
        let state = EngageState<PreferenceCenterSnapshot?>(nil)
        centers[identity] = state
        lock.unlock()
        observe(state: state, identity: identity, requestedKey: key)
        EngageLogger.debug("Core.Preferences", "center observer created key=\(key ?? "default")")
        return state
    }

    private func observe(
        state: EngageState<PreferenceCenterSnapshot?>,
        identity: String,
        requestedKey: String?
    ) {
        let update: @Sendable () async -> Void = { [weak self, weak state] in
            guard let self, let state else { return }
            let projection = await self.project(requestedKey: requestedKey)
            EngageLogger.debug(
                "Core.Preferences",
                "center projected key=\(requestedKey ?? "default") available=\(projection != nil) " +
                    "sections=\(projection?.sections.count ?? 0)"
            )
            state.set(projection)
        }
        let tasks = [
            Task { [runtime] in for await _ in runtime.syncSnapshot.updates { await update() } },
            Task { [runtime] in for await _ in runtime.outboxRevision.updates { await update() } },
            Task { [runtime] in for await _ in runtime.generation.updates { await update() } },
            Task { [runtime] in for await _ in runtime.privacy.updates { await update() } },
            Task { [runtime] in for await _ in runtime.enabledFeatures.updates { await update() } },
        ]
        lock.lock()
        observationTasks[identity] = tasks
        lock.unlock()
    }

    private func project(requestedKey: String?) async -> PreferenceCenterSnapshot? {
        EngageLogger.verbose("Core.Preferences", "projection started key=\(requestedKey ?? "default")")
        let source = await runtime.preferenceProjectionSource()
        let snapshot = source.snapshot
        guard source.privacy == .optedIn,
              source.enabledFeatures.contains(.preferences),
              snapshot.generation == source.generation,
              let payload = snapshot.documents.first(where: {
                  $0.module == .preferences && $0.key == "subscriptions"
              })?.payload,
              let centerDefinitions = payload.object("centers") else {
            EngageLogger.verbose("Core.Preferences", "projection unavailable key=\(requestedKey ?? "default")")
            return nil
        }
        let selected = centerDefinitions.first { key, value in
            guard let definition = value.objectValue?.object("definition") else { return false }
            return requestedKey.map { $0 == key } ?? (definition.bool("isDefault") == true)
        }
        guard let (key, value) = selected,
              let definition = value.objectValue?.object("definition") else {
            EngageLogger.debug("Core.Preferences", "center definition not found key=\(requestedKey ?? "default")")
            return nil
        }
        let catalog = payload.array("catalog")?.compactMap(\.objectValue) ?? []
        var installation: [String: Bool] = [:]
        for value in payload.array("installation") ?? [] {
            guard let item = value.objectValue,
                  let key = item.string("listKey"),
                  let subscribed = item.bool("subscribed") else { continue }
            installation[key] = subscribed
        }
        var profile: [String: Bool] = [:]
        for value in payload.array("profile") ?? [] {
            guard let item = value.objectValue,
                  let key = item.string("listKey"),
                  let channel = item.string("channel"),
                  let subscribed = item.bool("subscribed") else { continue }
            profile["\(key)\u{0}\(channel)"] = subscribed
        }
        for operation in source.pending {
            switch operation.type {
            case "INSTALLATION_SUBSCRIPTIONS_EDITED":
                for value in operation.payload.array("changes") ?? [] {
                    guard let change = value.objectValue,
                          let list = change.string("list"),
                          let subscribed = change.bool("subscribed") else { continue }
                    installation[list] = subscribed
                }
            case "PROFILE_SUBSCRIPTIONS_EDITED" where operation.generation == source.generation:
                for value in operation.payload.array("changes") ?? [] {
                    guard let change = value.objectValue,
                          let list = change.string("list"),
                          let channel = change.string("channel"),
                          let subscribed = change.bool("subscribed") else { continue }
                    profile["\(list)\u{0}\(channel)"] = subscribed
                }
            default:
                break
            }
        }
        let sections = (definition.array("sections") ?? []).compactMap { sectionValue -> PreferenceSection? in
            guard let section = sectionValue.objectValue, let sectionKey = section.string("key") else { return nil }
            let listKeys = section.array("subscriptionListKeys")?.compactMap(\.stringValue) ?? []
            return PreferenceSection(
                key: sectionKey,
                title: localized(section["title"]),
                description: localized(section["description"]),
                subscriptions: listKeys.compactMap { listKey -> SubscriptionPreference? in
                    guard let item = catalog.first(where: { $0.string("key") == listKey }) else { return nil }
                    let fallback = item.bool("defaultSubscribed") ?? false
                    let scopes = Set(item.array("scopes")?.compactMap(\.stringValue) ?? [])
                    let channels = item.array("channels")?.compactMap(\.stringValue).compactMap(Channel.init(rawValue:)) ?? []
                    return SubscriptionPreference(
                        key: listKey,
                        displayName: localized(item["displayName"]) ?? listKey,
                        description: localized(item["description"]),
                        profileChoices: scopes.contains("PROFILE") ? channels.reduce(into: [:]) {
                            $0[$1] = profile["\(listKey)\u{0}\($1.rawValue)"] ?? fallback
                        } : nil,
                        installationChoice: scopes.contains("INSTALLATION") ? installation[listKey] ?? fallback : nil
                    )
                }
            )
        }
        return PreferenceCenterSnapshot(
            key: key,
            displayName: localized(definition["displayName"]) ?? key,
            description: localized(definition["description"]),
            sections: sections
        ).alsoLogged
    }
}

struct PreferenceProjectionSource: Sendable {
    let snapshot: SyncSnapshot
    let pending: [SdkOperation]
    let generation: Int64
    let privacy: PrivacyState
    let enabledFeatures: Set<SdkFeature>
}

private func localized(_ value: JSONValue?) -> String? {
    if let string = value?.stringValue { return string }
    guard let values = value?.objectValue else { return nil }
    let locale = Locale.current
    let candidates = [locale.identifier.replacingOccurrences(of: "_", with: "-"), locale.languageCode, "default"].compactMap { $0 }
    return candidates.compactMap { values[$0]?.stringValue }.first ?? values.values.compactMap(\.stringValue).first
}

private extension PreferenceCenterSnapshot {
    var alsoLogged: PreferenceCenterSnapshot {
        EngageLogger.info("Core.Preferences", "projection completed key=\(key) sections=\(sections.count)")
        return self
    }
}
