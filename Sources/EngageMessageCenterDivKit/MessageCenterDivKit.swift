#if canImport(UIKit)
import Foundation
import UIKit
import SwiftUI
import DivKit
import EngageCore
import EngageMessageCenter
@_spi(Rendering) import EngageMessageCenter

public enum MessageCenterViewErrorCode: Sendable, Equatable {
    case inbox
    case rendering
}

public struct MessageCenterViewError: Error, Sendable {
    public let code: MessageCenterViewErrorCode
    public let message: String
    public let isRetryable: Bool

    public init(code: MessageCenterViewErrorCode, message: String, isRetryable: Bool) {
        self.code = code
        self.message = message
        self.isRetryable = isRetryable
    }
}

public extension MessageCenter {
    @MainActor func display(entryId: InboxEntryId? = nil, from presenter: UIViewController? = nil) {
        EngageLogger.info(
            "MessageCenter.UI",
            "display requested entryId=\(entryId?.value ?? "list") hasPresenter=\(presenter != nil)"
        )
        let rootView = Group {
            if let entryId {
                EngageMessageCenterDirectDetailHost(entryId: entryId, messageCenter: self)
            } else {
                EngageMessageCenterView(messageCenter: self)
            }
        }
        let controller = UIHostingController(rootView: rootView)
        controller.modalPresentationStyle = .pageSheet
        guard let root = presenter ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            EngageLogger.warning("MessageCenter.UI", "display rejected reason=no_presenter")
            return
        }
        var host = root
        while let presented = host.presentedViewController { host = presented }
        host.present(controller, animated: true)
    }
}

private struct EngageMessageCenterDirectDetailHost: View {
    @Environment(\.dismiss) private var dismiss
    let entryId: InboxEntryId
    let messageCenter: MessageCenter

    var body: some View {
        NavigationView {
            EngageMessageCenterDetailView(entryId: entryId, messageCenter: messageCenter)
                .navigationTitle("Message details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Back")
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

/// Complete Engage-owned Message Center presentation used by `display()`.
public struct EngageMessageCenterView: View {
    @Environment(\.dismiss) private var dismiss
    private let messageCenter: MessageCenter
    @State private var selectedEntry: InboxEntry?

    public init(messageCenter: MessageCenter = MessageCenterModule.shared) {
        self.messageCenter = messageCenter
    }

    public var body: some View {
        NavigationView {
            ZStack {
                EngageMessageCenterListView(
                    messageCenter: messageCenter,
                    onEntryTap: { selectedEntry = $0 }
                )
                NavigationLink(
                    isActive: Binding(
                        get: { selectedEntry != nil },
                        set: { if !$0 { selectedEntry = nil } }
                    ),
                    destination: {
                        if let entry = selectedEntry {
                            EngageMessageCenterDetailView(
                                entryId: entry.id,
                                messageCenter: messageCenter
                            )
                            .navigationTitle("Message details")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    },
                    label: { EmptyView() }
                )
                .hidden()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .principal) {
                    Text("Messages").font(.headline)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Engage-rendered Inbox summaries without a route or navigation chrome.
public struct EngageMessageCenterListView: View {
    private let messageCenter: MessageCenter
    private let onEntryTap: (InboxEntry) -> Void
    private let onError: ((MessageCenterViewError) -> Void)?
    @State private var state = InboxPagerState()
    @State private var renderings: [InboxEntryId: InboxRenderingSnapshot] = [:]
    @State private var unreadCount = 0
    @State private var filter = InboxViewFilter.all
    @StateObject private var pagerOwner: MessageCenterPagerOwner
    private var pager: InboxPager { pagerOwner.pager }

    public init(
        messageCenter: MessageCenter = MessageCenterModule.shared,
        onEntryTap: @escaping (InboxEntry) -> Void,
        onError: ((MessageCenterViewError) -> Void)? = nil
    ) {
        self.messageCenter = messageCenter
        self.onEntryTap = onEntryTap
        self.onError = onError
        _pagerOwner = StateObject(
            wrappedValue: MessageCenterPagerOwner(inbox: messageCenter.inbox, pageSize: 20)
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !state.entries.isEmpty { filterBar }
            content
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            for await value in pager.state.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    state = value
                    if let error = value.error {
                        onError?(
                            MessageCenterViewError(
                                code: .inbox,
                                message: error.message,
                                isRetryable: error.isRetryable
                            )
                        )
                    }
                }
            }
        }
        .task {
            unreadCount = messageCenter.inbox.unreadCount.value
            for await value in messageCenter.inbox.unreadCount.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run { unreadCount = value }
            }
        }
        .task(id: state.entries.map(\.id)) {
            guard !state.entries.isEmpty else { return }
            do {
                let resolved = try await messageCenter.resolveRenderings(state.entries.map(\.id))
                let active = Set(state.entries.map(\.id))
                renderings = renderings.filter { active.contains($0.key) }
                renderings.merge(Dictionary(uniqueKeysWithValues: resolved.map { ($0.entryId, $0) })) { _, new in new }
            } catch is CancellationError {
                return
            } catch {
                onError?(
                    MessageCenterViewError(
                        code: .rendering,
                        message: String(describing: error),
                        isRetryable: true
                    )
                )
            }
        }
        .task(id: unreadPagingKey) {
            if filter == .unread, visibleEntries.isEmpty, state.hasMore, !state.isLoadingMore {
                await pager.loadNextPage()
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Message filter", selection: $filter) {
                ForEach(InboxViewFilter.allCases) { option in Text(option.label).tag(option) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)
            Spacer(minLength: 0)
            if effectiveUnreadCount > 0 {
                Button("Mark all read") { Task { await messageCenter.inbox.markAllRead() } }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                    MessageCenterCard(
                        entry: entry,
                        rendering: renderings[entry.id],
                        messageCenter: messageCenter,
                        onOpen: { onEntryTap(entry) }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await messageCenter.inbox.delete(entry.id) }
                        } label: { Label("Delete", systemImage: "trash") }
                        if entry.readAt == nil {
                            Button { Task { await messageCenter.inbox.markRead(entry.id) } } label: {
                                Label("Mark read", systemImage: "envelope.open")
                            }
                            .tint(.accentColor)
                        } else {
                            Button { Task { await messageCenter.inbox.markUnread(entry.id) } } label: {
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
        filter == .all ? state.entries : state.entries.filter { $0.readAt == nil }
    }
    private var effectiveUnreadCount: Int { max(unreadCount, state.entries.filter { $0.readAt == nil }.count) }
    private var unreadPagingKey: String {
        "\(filter.rawValue):\(state.entries.count):\(state.hasMore):\(state.isLoadingMore)"
    }
}

private final class MessageCenterPagerOwner: ObservableObject {
    let pager: InboxPager

    init(inbox: Inbox, pageSize: Int) {
        pager = inbox.pager(pageSize: pageSize)
    }

    deinit { pager.close() }
}

/// Engage-rendered immutable Inbox detail without navigation chrome.
public struct EngageMessageCenterDetailView: View {
    private let entryId: InboxEntryId
    private let messageCenter: MessageCenter
    private let onUnavailable: (() -> Void)?
    private let onError: ((MessageCenterViewError) -> Void)?
    private let initialLifecycleRevision: Int64
    @State private var snapshot: InboxRenderingSnapshot?
    @State private var loading = true
    @State private var unavailable = false
    @State private var didMarkRead = false
    @State private var knownByInbox: Bool

    public init(
        entryId: InboxEntryId,
        messageCenter: MessageCenter = MessageCenterModule.shared,
        onUnavailable: (() -> Void)? = nil,
        onError: ((MessageCenterViewError) -> Void)? = nil
    ) {
        self.entryId = entryId
        self.messageCenter = messageCenter
        self.onUnavailable = onUnavailable
        self.onError = onError
        let presentation = messageCenter.presentationState.value
        initialLifecycleRevision = presentation.lifecycleRevision
        _knownByInbox = State(initialValue: presentation.entryIds.contains(entryId))
    }

    public var body: some View {
        Group {
            if let snapshot {
                DivKitSnapshotView(
                    snapshot: snapshot,
                    surface: .detail,
                    messageCenter: messageCenter,
                    onContentVisible: {
                        guard !didMarkRead else { return }
                        didMarkRead = true
                        Task { await messageCenter.inbox.markRead(entryId) }
                    },
                    onEntryDeleted: { invalidate() }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if unavailable {
                Text("Message unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: entryId) { await resolve() }
        .task(id: entryId) { await observePresentation() }
        .task(id: snapshot?.expiresAt) { await invalidateAtExpiry() }
    }

    @MainActor private func resolve() async {
        loading = true
        unavailable = false
        let initialPresentation = messageCenter.presentationState.value
        guard initialPresentation.lifecycleRevision == initialLifecycleRevision,
              initialPresentation.isEnabled else {
            invalidate()
            return
        }
        knownByInbox = initialPresentation.entryIds.contains(entryId)
        do {
            let resolved = try await messageCenter.resolveRenderings([entryId]).first
            let presentation = messageCenter.presentationState.value
            if presentation.entryIds.contains(entryId) { knownByInbox = true }
            guard !shouldInvalidateMessageCenterDetail(
                entryId: entryId,
                expectedLifecycleRevision: initialLifecycleRevision,
                state: presentation,
                knownByInbox: knownByInbox,
                rendered: resolved != nil
            ), presentation.isEnabled else {
                invalidate()
                return
            }
            snapshot = resolved
            loading = false
            if snapshot?.surface(.detail) == nil {
                snapshot = nil
                unavailable = true
                onUnavailable?()
            }
        } catch is CancellationError {
            return
        } catch {
            let presentation = messageCenter.presentationState.value
            if presentation.lifecycleRevision != initialLifecycleRevision || !presentation.isEnabled {
                invalidate()
                return
            }
            loading = false
            snapshot = nil
            unavailable = true
            onError?(
                MessageCenterViewError(
                    code: .rendering,
                    message: String(describing: error),
                    isRetryable: true
                )
            )
        }
    }

    @MainActor private func observePresentation() async {
        for await state in messageCenter.presentationState.updates {
            guard !Task.isCancelled else { return }
            if state.entryIds.contains(entryId) { knownByInbox = true }
            let identityChanged = state.lifecycleRevision != initialLifecycleRevision
            let removed = knownByInbox && !state.entryIds.contains(entryId)
            let disabledAfterRender = snapshot != nil && !state.isEnabled
            if shouldInvalidateMessageCenterDetail(
                entryId: entryId,
                expectedLifecycleRevision: initialLifecycleRevision,
                state: state,
                knownByInbox: knownByInbox,
                rendered: snapshot != nil
            ) {
                EngageLogger.warning(
                    "MessageCenter.DetailView",
                    "rendering invalidated entryId=\(entryId) identityChanged=\(identityChanged) " +
                        "removed=\(removed) disabled=\(disabledAfterRender)"
                )
                invalidate()
                return
            }
        }
    }

    @MainActor private func invalidateAtExpiry() async {
        guard let expiresAt = snapshot?.expiresAt else { return }
        let delay = expiresAt.timeIntervalSinceNow
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        EngageLogger.info("MessageCenter.DetailView", "rendering expired entryId=\(entryId)")
        invalidate()
    }

    @MainActor private func invalidate() {
        let notify = !unavailable
        snapshot = nil
        loading = false
        unavailable = true
        didMarkRead = false
        if notify { onUnavailable?() }
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
                    DivKitSnapshotView(
                        snapshot: rendering,
                        surface: .summary,
                        messageCenter: messageCenter,
                        onContentVisible: nil,
                        onEntryDeleted: nil
                    )
                } else {
                    Text(entry.key)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .padding(16)
                }
            }
            if entry.readAt == nil {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(12).accessibilityHidden(true)
            }
        }
        .background(entry.readAt == nil ? Color(uiColor: .systemBackground) : Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            if entry.readAt == nil {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 4)
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
                Image(systemName: symbol).font(.system(size: 46)).foregroundStyle(Color.accentColor)
            }
            Text(title).font(.title3.weight(.bold)).padding(.top, 24)
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
    let onContentVisible: (() -> Void)?
    let onEntryDeleted: (() -> Void)?

    final class Coordinator {
        let appearanceVariables = DivVariableStorage()
        var renderingKey: String?
        var renderingTask: Task<Void, Never>?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MessageCenterVisibilityView {
        updateAppearance(context.coordinator.appearanceVariables, colorScheme: context.environment.colorScheme)
        let components = DivKitComponents(
            urlHandler: DivUrlHandlerDelegate { url in handle(url) },
            variablesStorage: DivVariablesStorage(outerStorage: context.coordinator.appearanceVariables)
        )
        let view = MessageCenterVisibilityView(contentView: DivView(divKitComponents: components))
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MessageCenterVisibilityView, context: Context) {
        updateAppearance(context.coordinator.appearanceVariables, colorScheme: context.environment.colorScheme)
        update(uiView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ uiView: MessageCenterVisibilityView, coordinator: Coordinator) {
        coordinator.renderingTask?.cancel()
        uiView.stopTracking()
    }

    private func handle(_ url: URL) {
        guard url.scheme == "engage" else {
            UIApplication.shared.open(url)
            return
        }
        switch url.host {
        case "mark-read": Task { await messageCenter.inbox.markRead(snapshot.entryId) }
        case "mark-unread": Task { await messageCenter.inbox.markUnread(snapshot.entryId) }
        case "delete": Task {
            await messageCenter.inbox.delete(snapshot.entryId)
            await MainActor.run { onEntryDeleted?() }
        }
        case "action":
            guard let name = url.pathComponents.dropFirst().first else { return }
            Task {
                await messageCenter.inbox.markRead(snapshot.entryId)
                _ = await messageCenter.executeAction(name, arguments: actionArguments(url))
            }
        default: break
        }
    }

    private func updateAppearance(_ storage: DivVariableStorage, colorScheme: ColorScheme) {
        storage.put(
            name: DivVariableName(rawValue: messageCenterAppearanceVariableName),
            value: .string(messageCenterDivKitAppearanceValue(for: colorScheme).rawValue)
        )
    }

    private func update(_ view: MessageCenterVisibilityView, coordinator: Coordinator) {
        guard let document = snapshot.surface(surface),
              let data = try? JSONEncoder().encode(JSONValue.object(document)) else { return }
        let renderingKey = "\(snapshot.entryId.value):\(surface.rawValue):\(snapshot.revision)"
        view.configureVisibility(
            identity: renderingKey,
            enabled: surface == .detail,
            onVisible: onContentVisible
        )
        guard coordinator.renderingKey != renderingKey else { return }
        coordinator.renderingKey = renderingKey
        coordinator.renderingTask?.cancel()
        view.setContentReady(false)
        coordinator.renderingTask = Task { @MainActor in
            await view.contentView.setSource(
                DivViewSource(kind: .data(data), cardId: DivCardID(rawValue: snapshot.entryId.value)),
                shouldResetPreviousCardData: true
            )
            guard !Task.isCancelled, coordinator.renderingKey == renderingKey else { return }
            view.setContentReady(true)
        }
    }
}

private final class MessageCenterVisibilityView: UIView {
    let contentView: DivView
    private var visibilityIdentity: String?
    private var visibilityEnabled = false
    private var contentReady = false
    private var visibilityReported = false
    private var onVisible: (() -> Void)?
    private var scheduledCheck: DispatchWorkItem?

    init(contentView: DivView) {
        self.contentView = contentView
        super.init(frame: .zero)
        contentView.frame = bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { scheduledCheck?.cancel() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { scheduledCheck?.cancel() } else { scheduleVisibilityCheck(immediate: true) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleVisibilityCheck(immediate: true)
    }

    func configureVisibility(identity: String, enabled: Bool, onVisible: (() -> Void)?) {
        if visibilityIdentity != identity {
            visibilityIdentity = identity
            visibilityReported = false
            contentReady = false
        }
        visibilityEnabled = enabled
        self.onVisible = onVisible
        scheduleVisibilityCheck(immediate: true)
    }

    func setContentReady(_ ready: Bool) {
        contentReady = ready
        scheduleVisibilityCheck(immediate: true)
    }

    func stopTracking() {
        scheduledCheck?.cancel()
        scheduledCheck = nil
        onVisible = nil
    }

    private func scheduleVisibilityCheck(immediate: Bool) {
        scheduledCheck?.cancel()
        guard visibilityEnabled, contentReady, !visibilityReported, window != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.checkVisibility() }
        scheduledCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.1), execute: work)
    }

    private func checkVisibility() {
        scheduledCheck = nil
        guard visibilityEnabled, contentReady, !visibilityReported, isEffectivelyVisible,
              let window, bounds.width > 0, bounds.height > 0 else {
            scheduleVisibilityCheck(immediate: false)
            return
        }
        var visibleRect = convert(bounds, to: window).intersection(window.bounds)
        var ancestor = superview
        while let current = ancestor, !visibleRect.isNull, !visibleRect.isEmpty {
            if current.clipsToBounds {
                visibleRect = visibleRect.intersection(current.convert(current.bounds, to: window))
            }
            ancestor = current.superview
        }
        let visibleArea = visibleRect.width * visibleRect.height
        let totalArea = bounds.width * bounds.height
        guard isMessageCenterContentVisible(
            visibleArea: Double(visibleArea),
            totalArea: Double(totalArea)
        ) else {
            scheduleVisibilityCheck(immediate: false)
            return
        }
        visibilityReported = true
        onVisible?()
    }

    private var isEffectivelyVisible: Bool {
        var current: UIView? = self
        while let view = current {
            if view.isHidden || view.alpha <= 0.01 { return false }
            current = view.superview
        }
        return true
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
