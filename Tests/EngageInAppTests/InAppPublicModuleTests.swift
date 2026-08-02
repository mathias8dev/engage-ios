import XCTest
import EngageInApp

final class InAppPublicModuleTests: XCTestCase {
    func testActivationIsAvailableWithoutTestableOrSPIImports() {
        let activate: () -> InApp = InAppModule.activate
        let shared: () -> InApp = { InAppModule.shared }
        _ = activate
        _ = shared
    }
}
