import Foundation
@_exported import EngageCore
@_exported import EngagePush
@_exported import EngageInApp
@_exported import EngageMessageCenter
@_exported import EngageMessageCenterDivKit

/// The production iOS facade. Starting it activates every module carried by the `EngageSDK` product.
public enum Engage {
    private static let modules = EngageSDKModules()

    public static var state: EngageState<Bool> { EngageCore.state }

    public static func start(config: EngageConfig) {
        EngageLogger.info("SDK", "facade start requested")
        EngageCore.start(config: config)
        modules.activate()
        EngageLogger.info("SDK", "facade modules activated")
    }

    public static var installation: Installation { EngageCore.installation }
    public static var profile: Profile { EngageCore.profile }
    public static var events: Events { EngageCore.events }
    public static var actions: Actions { EngageCore.actions }
    public static var sdkFeatures: SdkFeatures { EngageCore.sdkFeatures }
    public static var flags: FeatureFlags { EngageCore.flags }
    public static var preferenceCenter: PreferenceCenter { EngageCore.preferenceCenter }
    public static var privacy: Privacy { EngageCore.privacy }
    public static var inApp: InApp { modules.inApp }
    public static var messageCenter: MessageCenter { modules.messageCenter }

    #if canImport(UIKit)
    public static var push: Push { modules.push }
    #endif
}

private final class EngageSDKModules: @unchecked Sendable {
    private let lock = NSLock()
    private var activated = false
    private var storedInApp: InApp?
    private var storedMessageCenter: MessageCenter?
    #if canImport(UIKit)
    private var storedPush: Push?
    #endif

    func activate() {
        lock.lock(); defer { lock.unlock() }
        guard !activated else {
            EngageLogger.verbose("SDK", "module activation ignored reason=already_activated")
            return
        }
        EngageLogger.debug("SDK", "module activation started")
        storedInApp = InAppModule.activate()
        storedMessageCenter = MessageCenterModule.activate()
        #if canImport(UIKit)
        storedPush = PushModule.activate()
        #endif
        activated = true
        EngageLogger.info("SDK", "module activation completed")
    }

    var inApp: InApp {
        activate()
        lock.lock(); defer { lock.unlock() }
        return storedInApp!
    }

    var messageCenter: MessageCenter {
        activate()
        lock.lock(); defer { lock.unlock() }
        return storedMessageCenter!
    }

    #if canImport(UIKit)
    var push: Push {
        activate()
        lock.lock(); defer { lock.unlock() }
        return storedPush!
    }
    #endif
}
