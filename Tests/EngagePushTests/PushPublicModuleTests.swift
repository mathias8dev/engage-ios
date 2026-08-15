import XCTest
import EngagePush

#if canImport(UIKit)
final class PushPublicModuleTests: XCTestCase {
    func testActivationAndAPNsCallbacksAreAvailableWithoutTestableOrSPIImports() {
        let prepare: () -> Void = PushModule.prepareForLaunch
        let activate: () -> Push = PushModule.activate
        let registered: (Push, Data) -> Void = { push, token in
            push.didRegisterForRemoteNotifications(deviceToken: token)
        }
        let failed: (Push, Error) -> Void = { push, error in
            push.didFailToRegisterForRemoteNotifications(error: error)
        }
        _ = activate
        _ = prepare
        _ = registered
        _ = failed
    }
}
#endif
