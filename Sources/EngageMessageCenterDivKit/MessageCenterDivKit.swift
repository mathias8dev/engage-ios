#if canImport(UIKit)
import Foundation
import UIKit
import SwiftUI
import DivKit
import EngageCore
import EngageMessageCenter
@_spi(Rendering) import EngageMessageCenter

public extension MessageCenter {
    @MainActor func display(from presenter: UIViewController? = nil) {
        EngageLogger.info("MessageCenter.UI", "display requested hasPresenter=\(presenter != nil)")
        let controller = UIHostingController(rootView: EngageMessageCenterView(messageCenter: self))
        controller.modalPresentationStyle = .pageSheet
        guard let root = presenter ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            EngageLogger.warning("MessageCenter.UI", "display rejected reason=no_presenter")
            return
        }
        var host = root
        while let presented = host.presentedViewController { host = presented }
        host.present(controller, animated: true)
        EngageLogger.info("MessageCenter.UI", "display presentation requested")
    }
}

public struct EngageMessageCenterView: View {
    @Environment(\.dismiss) private var dismiss
    private let messageCenter: MessageCenter
    @State private var state = InboxPagerState()
    @State private var renderings: [InboxEntryId: InboxRenderingSnapshot] = [:]
    @State private var unreadCount = 0
    @State private var filter = InboxViewFilter.all
    @State private var selectedEntryId: InboxEntryId?
    private let pager: InboxPager

    public init(messageCenter: MessageCenter = MessageCenterModule.shared) {
        self.messageCenter = messageCenter
        pager = messageCenter.inbox.pager(pageSize: 20)
        EngageLogger.debug("MessageCenter.UI", "SwiftUI view initialized")
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !state.entries.isEmpty {
                    filterBar
                }
                content
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Messages").font(.headline)
                        if effectiveUnreadCount > 0 {
                            Text(unreadLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            for await value in pager.state.updates {
                guard !Task.isCancelled else { return }
                EngageLogger.verbose(
                    "MessageCenter.UI",
                    "pager state entries=\(value.entries.count) refreshing=\(value.isRefreshing) " +
                        "loadingMore=\(value.isLoadingMore) hasMore=\(value.hasMore) " +
                        "error=\(String(describing: value.error?.code))"
                )
                await MainActor.run { state = value }
            }
        }
        .task {
            unreadCount = messageCenter.inbox.unreadCount.value
            for await value in messageCenter.inbox.unreadCount.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run { unreadCount = value }
            }
        }
        .task { await pager.refresh() }
        .task(id: state.entries.map(\.id)) {
            guard !state.entries.isEmpty else { return }
            if let resolved = try? await messageCenter.resolveRenderings(state.entries.map(\.id)) {
                let active = Set(state.entries.map(\.id))
                renderings = renderings.filter { active.contains($0.key) }
                renderings.merge(Dictionary(uniqueKeysWithValues: resolved.map { ($0.entryId, $0) })) { _, new in new }
                EngageLogger.info("MessageCenter.UI", "renderings applied count=\(resolved.count)")
            }
        }
        .task(id: unreadPagingKey) {
            if filter == .unread, visibleEntries.isEmpty, state.hasMore, !state.isLoadingMore {
                await pager.loadNextPage()
            }
        }
        .onDisappear { pager.close() }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Message filter", selection: $filter) {
                ForEach(InboxViewFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)

            Spacer(minLength: 0)

            if effectiveUnreadCount > 0 {
                Button("Mark all read") {
                    Task { await messageCenter.inbox.markAllRead() }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder private var content: some View {
        if state.entries.isEmpty && state.isRefreshing {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.entries.isEmpty, state.error != nil {
            MessageCenterEmptyView(
                symbol: "exclamationmark.bubble",
                title: "Messages unavailable",
                message: "We couldn't refresh your messages. Try again.",
                action: "Retry",
                onAction: { Task { await pager.refresh() } }
            )
        } else if state.entries.isEmpty {
            MessageCenterEmptyView(
                symbol: "bubble.left.and.bubble.right",
                title: "You're all caught up",
                message: "Important updates and messages will appear here.",
                action: "Refresh",
                onAction: { Task { await pager.refresh() } }
            )
        } else if visibleEntries.isEmpty, filter == .unread, !state.hasMore, !state.isLoadingMore {
            MessageCenterEmptyView(
                symbol: "checkmark.message",
                title: "No unread messages",
                message: "Everything in your inbox has been read.",
                action: "Refresh",
                onAction: { Task { await pager.refresh() } }
            )
        } else if visibleEntries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if state.error != nil {
                    Text("Some messages may be out of date. Pull to refresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.accentColor.opacity(0.08))
                }
                ForEach(visibleEntries) { entry in
                    ZStack {
                        NavigationLink(
                            tag: entry.id,
                            selection: $selectedEntryId,
                            destination: {
                                if let rendering = renderings[entry.id] {
                                    MessageCenterDetailView(
                                        entry: entry,
                                        rendering: rendering,
                                        messageCenter: messageCenter
                                    )
                                }
                            },
                            label: { EmptyView() }
                        )
                        .opacity(0)
                        MessageCenterCard(
                            entry: entry,
                            rendering: renderings[entry.id],
                            messageCenter: messageCenter,
                            onOpen: {
                                guard renderings[entry.id]?.surface(.detail) != nil else { return }
                                selectedEntryId = entry.id
                            }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await messageCenter.inbox.delete(entry.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        if entry.readAt == nil {
                            Button {
                                Task { await messageCenter.inbox.markRead(entry.id) }
                            } label: {
                                Label("Mark read", systemImage: "envelope.open")
                            }
                            .tint(.accentColor)
                        } else {
                            Button {
                                Task { await messageCenter.inbox.markUnread(entry.id) }
                            } label: {
                                Label("Mark unread", systemImage: "envelope.badge")
                            }
                            .tint(.accentColor)
                        }
                    }
                    if entry.id == visibleEntries.last?.id, state.hasMore {
                        Color.clear.frame(height: 1).task { await pager.loadNextPage() }
                    }
                }
                if state.isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await pager.refresh() }
        }
    }

    private var visibleEntries: [InboxEntry] {
        switch filter {
        case .all: return state.entries
        case .unread: return state.entries.filter { $0.readAt == nil }
        }
    }

    private var effectiveUnreadCount: Int {
        max(unreadCount, state.entries.filter { $0.readAt == nil }.count)
    }

    private var unreadLabel: String {
        "\(effectiveUnreadCount) unread"
    }

    private var unreadPagingKey: String {
        "\(filter.rawValue):\(state.entries.count):\(state.hasMore):\(state.isLoadingMore)"
    }
}

private enum InboxViewFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    var id: Self { self }
    var label: String { self == .all ? "All" : "Unread" }
}

private struct MessageCenterCard: View {
    let entry: InboxEntry
    let rendering: InboxRenderingSnapshot?
    let messageCenter: MessageCenter
    let onOpen: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let rendering {
                    DivKitSnapshotView(snapshot: rendering, surface: .summary, messageCenter: messageCenter)
                } else {
                    Text(entry.key)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .padding(16)
                }
            }
            if entry.readAt == nil {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(12)
                    .accessibilityHidden(true)
            }
        }
        .background(entry.readAt == nil ? Color(uiColor: .systemBackground) : Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            if entry.readAt == nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityValue(entry.readAt == nil ? "Unread" : "Read")
    }
}

private struct MessageCenterDetailView: View {
    let entry: InboxEntry
    let rendering: InboxRenderingSnapshot
    let messageCenter: MessageCenter

    var body: some View {
        DivKitSnapshotView(snapshot: rendering, surface: .detail, messageCenter: messageCenter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Message details")
            .navigationBarTitleDisplayMode(.inline)
            .task { await messageCenter.inbox.markRead(entry.id) }
    }
}

private struct MessageCenterEmptyView: View {
    let symbol: String
    let title: String
    let message: String
    let action: String
    let onAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 112, height: 112)
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.top, 24)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .frame(maxWidth: 310)
            Button(action: onAction) {
                Label(action, systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 48)
            }
            .buttonStyle(.bordered)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 28)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension InboxEntry: Identifiable {}

private struct DivKitSnapshotView: UIViewRepresentable {
    let snapshot: InboxRenderingSnapshot
    let surface: InboxRenderingSurface
    let messageCenter: MessageCenter

    final class Coordinator {
        let appearanceVariables = DivVariableStorage()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DivView {
        EngageLogger.debug(
            "MessageCenter.DivKit",
            "view creating entryId=\(snapshot.entryId) revision=\(snapshot.revision) renderer=\(snapshot.renderer)"
        )
        updateAppearance(context.coordinator.appearanceVariables, colorScheme: context.environment.colorScheme)
        let components = DivKitComponents(urlHandler: DivUrlHandlerDelegate { url in
            EngageLogger.info(
                "MessageCenter.DivKit",
                "action entryId=\(snapshot.entryId) scheme=\(url.scheme ?? "none") host=\(url.host ?? "none")"
            )
            guard url.scheme == "engage", url.host == "action",
                  let name = url.pathComponents.dropFirst().first else {
                UIApplication.shared.open(url); return
            }
            Task { _ = await messageCenter.executeAction(name, arguments: actionArguments(url)) }
        }, variablesStorage: DivVariablesStorage(outerStorage: context.coordinator.appearanceVariables))
        let view = DivView(divKitComponents: components)
        update(view)
        return view
    }
    func updateUIView(_ uiView: DivView, context: Context) {
        updateAppearance(context.coordinator.appearanceVariables, colorScheme: context.environment.colorScheme)
        update(uiView)
    }

    private func updateAppearance(_ storage: DivVariableStorage, colorScheme: ColorScheme) {
        storage.put(
            name: DivVariableName(rawValue: messageCenterAppearanceVariableName),
            value: .string(messageCenterDivKitAppearanceValue(for: colorScheme).rawValue)
        )
    }
    private func update(_ view: DivView) {
        guard let document = snapshot.surface(surface),
              let data = try? JSONEncoder().encode(JSONValue.object(document)) else {
            EngageLogger.error(
                "MessageCenter.DivKit",
                "document encoding failed entryId=\(snapshot.entryId) surface=\(surface.rawValue)"
            )
            return
        }
        EngageLogger.debug(
            "MessageCenter.DivKit",
            "source updating entryId=\(snapshot.entryId) surface=\(surface.rawValue) bytes=\(data.count)"
        )
        Task {
            await view.setSource(
                DivViewSource(kind: .data(data), cardId: DivCardID(rawValue: snapshot.entryId.value)),
                shouldResetPreviousCardData: true
            )
            EngageLogger.debug("MessageCenter.DivKit", "source updated entryId=\(snapshot.entryId)")
        }
    }
}

private let messageCenterAppearanceVariableName = "engage_appearance"

private enum MessageCenterDivKitAppearanceValue: String {
    case systemLight = "system_light"
    case systemDark = "system_dark"
}

private func messageCenterDivKitAppearanceValue(for colorScheme: ColorScheme) -> MessageCenterDivKitAppearanceValue {
    colorScheme == .dark ? .systemDark : .systemLight
}

private func actionArguments(_ url: URL) -> EngagePayload {
    guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "arguments" })?.value,
          let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          let object = value.objectValue else { return [:] }
    return object
}
#endif
