#if canImport(UIKit)
import UIKit

@MainActor
public struct PreferenceCenterMaterialTheme {
    public let primary: UIColor
    public let onPrimary: UIColor
    public let primaryContainer: UIColor
    public let onPrimaryContainer: UIColor
    public let surface: UIColor
    public let surfaceContainerLow: UIColor
    public let onSurface: UIColor
    public let onSurfaceVariant: UIColor
    public let outlineVariant: UIColor

    public init(
        primary: UIColor,
        onPrimary: UIColor,
        primaryContainer: UIColor,
        onPrimaryContainer: UIColor,
        surface: UIColor,
        surfaceContainerLow: UIColor,
        onSurface: UIColor,
        onSurfaceVariant: UIColor,
        outlineVariant: UIColor
    ) {
        self.primary = primary
        self.onPrimary = onPrimary
        self.primaryContainer = primaryContainer
        self.onPrimaryContainer = onPrimaryContainer
        self.surface = surface
        self.surfaceContainerLow = surfaceContainerLow
        self.onSurface = onSurface
        self.onSurfaceVariant = onSurfaceVariant
        self.outlineVariant = outlineVariant
    }

    public static var system: PreferenceCenterMaterialTheme {
        PreferenceCenterMaterialTheme(
            primary: .systemTeal,
            onPrimary: .white,
            primaryContainer: .secondarySystemBackground,
            onPrimaryContainer: .label,
            surface: .systemBackground,
            surfaceContainerLow: .secondarySystemBackground,
            onSurface: .label,
            onSurfaceVariant: .secondaryLabel,
            outlineVariant: .separator
        )
    }
}

public extension PreferenceCenter {
    /// Builds Engage's ready-to-use UI with the system material theme.
    /// The headless `center(_:)` state remains the source of truth.
    @MainActor
    func makeViewController(_ key: String? = nil) -> UIViewController {
        makeViewController(key, materialTheme: .system)
    }

    /// Builds Engage's ready-to-use UI with a custom material theme.
    /// The headless `center(_:)` state remains the source of truth.
    @MainActor
    func makeViewController(
        _ key: String? = nil,
        materialTheme: PreferenceCenterMaterialTheme
    ) -> UIViewController {
        PreferenceCenterViewController(snapshot: center(key), materialTheme: materialTheme)
    }

    /// Presents the ready-to-use preference center with the system material theme.
    @MainActor
    func display(
        _ key: String? = nil,
        from presenter: UIViewController? = nil
    ) {
        display(key, from: presenter, materialTheme: .system)
    }

    /// Presents the ready-to-use preference center with a custom material theme.
    @MainActor
    func display(
        _ key: String? = nil,
        from presenter: UIViewController? = nil,
        materialTheme: PreferenceCenterMaterialTheme
    ) {
        let content = makeViewController(key, materialTheme: materialTheme)
        let navigation = UINavigationController(rootViewController: content)
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = materialTheme.surface
        navigationAppearance.titleTextAttributes = [.foregroundColor: materialTheme.onSurface]
        navigation.navigationBar.standardAppearance = navigationAppearance
        navigation.navigationBar.scrollEdgeAppearance = navigationAppearance
        navigation.navigationBar.compactAppearance = navigationAppearance
        navigation.navigationBar.tintColor = materialTheme.primary
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
    private let materialTheme: PreferenceCenterMaterialTheme
    private var current: PreferenceCenterSnapshot?
    private var rows: [[Row]] = []
    private var observation: Task<Void, Never>?

    init(snapshot: EngageState<PreferenceCenterSnapshot?>, materialTheme: PreferenceCenterMaterialTheme) {
        self.snapshot = snapshot
        self.materialTheme = materialTheme
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = preferenceCenterLocalized("preference_center.title")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "preference")
        tableView.backgroundColor = materialTheme.surface
        view.backgroundColor = materialTheme.surface
        apply(snapshot.value)
        observation = Task { [weak self, snapshot = self.snapshot] in
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
        configuration.textProperties.color = materialTheme.onSurface
        configuration.secondaryTextProperties.color = materialTheme.onSurfaceVariant
        cell.contentConfiguration = configuration
        cell.backgroundColor = materialTheme.surfaceContainerLow
        let toggle = UISwitch()
        toggle.isOn = row.selected
        toggle.onTintColor = materialTheme.primary
        toggle.accessibilityLabel = row.title
        toggle.tag = encoded(indexPath)
        toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        return cell
    }

    private func apply(_ value: PreferenceCenterSnapshot?) {
        current = value
        title = value?.displayName ?? preferenceCenterLocalized("preference_center.title")
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
        tableView.backgroundView = value?.hasVisiblePreferences == true
            ? nil
            : unavailableView()
        tableView.reloadData()
    }

    private func unavailableView() -> UIView {
        let container = UIView()
        let icon = UIImageView(image: UIImage(systemName: "slider.horizontal.3"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        icon.tintColor = materialTheme.onPrimaryContainer
        icon.contentMode = .scaleAspectFit
        icon.backgroundColor = materialTheme.primaryContainer
        icon.layer.cornerRadius = 24

        let heading = UILabel()
        heading.text = preferenceCenterLocalized("preference_center.unavailable.title")
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.textColor = materialTheme.onSurface
        heading.textAlignment = .center
        heading.adjustsFontForContentSizeCategory = true

        let message = UILabel()
        message.text = preferenceCenterLocalized("preference_center.unavailable.body")
        message.font = .preferredFont(forTextStyle: .body)
        message.textColor = materialTheme.onSurfaceVariant
        message.textAlignment = .center
        message.numberOfLines = 0
        message.adjustsFontForContentSizeCategory = true

        let content = UIStackView(arrangedSubviews: [icon, heading, message])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 10
        content.setCustomSpacing(20, after: icon)
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        return container
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        let indexPath = decoded(sender.tag)
        guard rows.indices.contains(indexPath.section),
              rows[indexPath.section].indices.contains(indexPath.row) else { return }
        let row = rows[indexPath.section][indexPath.row]
        Task {
            let requestedValue = sender.isOn
            do {
                switch row.scope {
                case .installation:
                    try await EngageCore.installation.editSubscriptions {
                        if requestedValue { $0.subscribe(row.listKey) } else { $0.unsubscribe(row.listKey) }
                    }
                case let .profile(channel):
                    try await EngageCore.profile.editSubscriptions {
                        if requestedValue {
                            $0.subscribe(row.listKey, channels: [channel])
                        } else {
                            $0.unsubscribe(row.listKey, channels: [channel])
                        }
                    }
                }
            } catch {
                sender.setOn(!requestedValue, animated: true)
                EngageLogger.error(
                    "Core.PreferenceCenter.UI",
                    "subscription edit failed list=\(row.listKey)",
                    error: error
                )
            }
        }
    }

    @objc private func close() { dismiss(animated: true) }
    private func encoded(_ indexPath: IndexPath) -> Int { indexPath.section * 10_000 + indexPath.row }
    private func decoded(_ value: Int) -> IndexPath {
        IndexPath(row: value % 10_000, section: value / 10_000)
    }
}

private func preferenceCenterLocalized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
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
