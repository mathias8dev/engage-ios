#if canImport(UIKit)
import UIKit

public extension PreferenceCenter {
    /// Builds Engage's ready-to-use UI. The headless `center(_:)` state remains the source of truth.
    @MainActor
    func makeViewController(_ key: String? = nil) -> UIViewController {
        PreferenceCenterViewController(snapshot: center(key))
    }

    /// Presents the ready-to-use preference center from the current application hierarchy.
    @MainActor
    func display(_ key: String? = nil, from presenter: UIViewController? = nil) {
        let content = makeViewController(key)
        let navigation = UINavigationController(rootViewController: content)
        guard let host = presenter ?? UIApplication.shared.engageTopViewController else {
            assertionFailure("Engage could not find a view controller to present the Preference Center")
            return
        }
        host.present(navigation, animated: true)
    }
}

@MainActor
private final class PreferenceCenterViewController: UITableViewController {
    private struct Row {
        enum Scope { case installation, profile(Channel) }
        let listKey: String
        let title: String
        let subtitle: String?
        let selected: Bool
        let scope: Scope
    }

    private let snapshot: EngageState<PreferenceCenterSnapshot?>
    private var current: PreferenceCenterSnapshot?
    private var rows: [[Row]] = []
    private var observation: Task<Void, Never>?

    init(snapshot: EngageState<PreferenceCenterSnapshot?>) {
        self.snapshot = snapshot
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Preferences"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "preference")
        apply(snapshot.value)
        observation = Task { [weak self] in
            for await value in snapshot.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.apply(value) }
            }
        }
    }

    deinit { observation?.cancel() }

    override func numberOfSections(in tableView: UITableView) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows[section].count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        current?.sections[section].title
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        current?.sections[section].description
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let row = rows[indexPath.section][indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "preference", for: indexPath)
        var configuration = cell.defaultContentConfiguration()
        configuration.text = row.title
        configuration.secondaryText = row.subtitle
        cell.contentConfiguration = configuration
        let toggle = UISwitch()
        toggle.isOn = row.selected
        toggle.accessibilityLabel = row.title
        toggle.tag = encoded(indexPath)
        toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        return cell
    }

    private func apply(_ value: PreferenceCenterSnapshot?) {
        current = value
        title = value?.displayName ?? "Preferences"
        rows = value?.sections.map { section in
            section.subscriptions.flatMap { preference -> [Row] in
                var values: [Row] = []
                if let selected = preference.installationChoice {
                    values.append(Row(
                        listKey: preference.key,
                        title: preference.displayName,
                        subtitle: preference.description,
                        selected: selected,
                        scope: .installation
                    ))
                }
                if let profile = preference.profileChoices {
                    values.append(contentsOf: profile.sorted { $0.key.rawValue < $1.key.rawValue }.map { channel, selected in
                        Row(
                            listKey: preference.key,
                            title: preference.displayName,
                            subtitle: [preference.description, channel.displayName]
                                .compactMap { $0 }.joined(separator: " · "),
                            selected: selected,
                            scope: .profile(channel)
                        )
                    })
                }
                return values
            }
        } ?? []
        tableView.reloadData()
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        let indexPath = decoded(sender.tag)
        guard rows.indices.contains(indexPath.section),
              rows[indexPath.section].indices.contains(indexPath.row) else { return }
        let row = rows[indexPath.section][indexPath.row]
        switch row.scope {
        case .installation:
            EngageCore.installation.editSubscriptions {
                if sender.isOn { $0.subscribe(row.listKey) } else { $0.unsubscribe(row.listKey) }
            }
        case let .profile(channel):
            EngageCore.profile.editSubscriptions {
                if sender.isOn {
                    $0.subscribe(row.listKey, channels: [channel])
                } else {
                    $0.unsubscribe(row.listKey, channels: [channel])
                }
            }
        }
    }

    @objc private func close() { dismiss(animated: true) }
    private func encoded(_ indexPath: IndexPath) -> Int { indexPath.section * 10_000 + indexPath.row }
    private func decoded(_ value: Int) -> IndexPath {
        IndexPath(row: value % 10_000, section: value / 10_000)
    }
}

private extension Channel {
    var displayName: String {
        switch self {
        case .email: return "Email"
        case .sms: return "SMS"
        case .push: return "Push"
        case .whatsapp: return "WhatsApp"
        }
    }
}

@MainActor
private extension UIApplication {
    var engageTopViewController: UIViewController? {
        let root = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        return root?.engageTopViewController
    }
}

@MainActor
private extension UIViewController {
    var engageTopViewController: UIViewController {
        if let presentedViewController { return presentedViewController.engageTopViewController }
        if let navigation = self as? UINavigationController,
           let visible = navigation.visibleViewController { return visible.engageTopViewController }
        if let tabs = self as? UITabBarController,
           let selected = tabs.selectedViewController { return selected.engageTopViewController }
        return self
    }
}
#endif
