import XCTest
import EngageMessageCenter

final class MessageCenterPublicModuleTests: XCTestCase {
    func testActivationIsAvailableWithoutTestableOrSPIImports() {
        let activate: () -> MessageCenter = MessageCenterModule.activate
        let shared: () -> MessageCenter = { MessageCenterModule.shared }
        _ = activate
        _ = shared
    }
}
