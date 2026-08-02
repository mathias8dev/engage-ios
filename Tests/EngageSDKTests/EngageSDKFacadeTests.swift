import XCTest
@testable import EngageSDK

final class EngageSDKFacadeTests: XCTestCase {
    func testFacadeExposesTheCompleteModuleSurface() {
        // Compile-time contract: the umbrella exposes Core and every headless module from one import.
        let start: (EngageConfig) -> Void = Engage.start
        let inApp: () -> InApp = { Engage.inApp }
        let messageCenter: () -> MessageCenter = { Engage.messageCenter }
        _ = start
        _ = inApp
        _ = messageCenter
    }
}
