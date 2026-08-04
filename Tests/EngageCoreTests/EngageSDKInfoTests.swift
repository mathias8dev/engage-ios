import XCTest
@testable import EngageCore

final class EngageSDKInfoTests: XCTestCase {
    func testVersionIsAReleaseCoordinate() {
        XCTAssertNotNil(
            EngageSDKInfo.version.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            )
        )
    }
}
