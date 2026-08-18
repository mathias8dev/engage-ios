import XCTest
@testable import EngageCore

final class PreferenceCenterPresentationTests: XCTestCase {
    func testMissingChoicesAreNotVisible() {
        XCTAssertFalse(snapshot(sections: []).hasVisiblePreferences)
        XCTAssertFalse(snapshot(sections: [section(subscriptions: [])]).hasVisiblePreferences)
    }

    func testInstallationAndProfileChoicesAreVisible() {
        XCTAssertTrue(
            snapshot(
                sections: [section(subscriptions: [preference(installationChoice: true)])]
            ).hasVisiblePreferences
        )
        XCTAssertTrue(
            snapshot(
                sections: [section(subscriptions: [preference(profileChoices: [.push: false])])]
            ).hasVisiblePreferences
        )
    }

    private func snapshot(sections: [PreferenceSection]) -> PreferenceCenterSnapshot {
        PreferenceCenterSnapshot(
            key: "communications",
            displayName: "Communication preferences",
            description: nil,
            sections: sections
        )
    }

    private func section(subscriptions: [SubscriptionPreference]) -> PreferenceSection {
        PreferenceSection(
            key: "notifications",
            title: "Notifications",
            description: nil,
            subscriptions: subscriptions
        )
    }

    private func preference(
        profileChoices: [Channel: Bool]? = nil,
        installationChoice: Bool? = nil
    ) -> SubscriptionPreference {
        SubscriptionPreference(
            key: "news",
            displayName: "News",
            description: nil,
            profileChoices: profileChoices,
            installationChoice: installationChoice
        )
    }
}
