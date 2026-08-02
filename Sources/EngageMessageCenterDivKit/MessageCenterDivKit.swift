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
        let controller = UIHostingController(rootView: EngageMessageCenterView(messageCenter: self))
        controller.modalPresentationStyle = .pageSheet
        guard let root = presenter ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var host = root
        while let presented = host.presentedViewController { host = presented }
        host.present(controller, animated: true)
    }
}

public struct EngageMessageCenterView: View {
    private let messageCenter: MessageCenter
    @State private var state = InboxPagerState()
    @State private var renderings: [InboxEntryId: InboxRenderingSnapshot] = [:]
    private let pager: InboxPager

    public init(messageCenter: MessageCenter = MessageCenterModule.shared) {
        self.messageCenter = messageCenter
        pager = messageCenter.inbox.pager(pageSize: 20)
    }

    public var body: some View {
        NavigationView {
            Group {
                if state.entries.isEmpty && state.isRefreshing { ProgressView() }
                else if state.entries.isEmpty, let error = state.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if error.isRetryable { Button("Retry") { Task { await pager.refresh() } } }
                    }.padding()
                }
                else if state.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.largeTitle)
                        Text("No messages").foregroundStyle(.secondary)
                    }
                }
                else {
                    List {
                        ForEach(state.entries) { entry in
                            VStack(alignment: .leading, spacing: 0) {
                                if let rendering = renderings[entry.id] {
                                    DivKitSnapshotView(snapshot: rendering, messageCenter: messageCenter)
                                        .onTapGesture { Task { await messageCenter.inbox.markRead(entry.id) } }
                                } else {
                                    Text(entry.key).foregroundStyle(.secondary)
                                }
                                if entry.id == state.entries.last?.id, state.hasMore {
                                    Color.clear.frame(height: 1).task { await pager.loadNextPage() }
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                Task { await messageCenter.inbox.delete(state.entries[index].id) }
                            }
                        }
                    }
                    .refreshable { await pager.refresh() }
                }
            }
            .navigationTitle("Messages")
            .toolbar {
                if !state.entries.isEmpty {
                    Button("Mark all read") { Task { await messageCenter.inbox.markAllRead() } }
                }
            }
        }
        .task {
            for await value in pager.state.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run { state = value }
            }
        }
        .task { await pager.refresh() }
        .task(id: state.entries.map(\.id)) {
            guard !state.entries.isEmpty else { return }
            if let resolved = try? await messageCenter.resolveRenderings(state.entries.map(\.id)) {
                let active = Set(state.entries.map(\.id))
                renderings = renderings.filter { active.contains($0.key) }
                renderings.merge(Dictionary(uniqueKeysWithValues: resolved.map { ($0.entryId, $0) })) { _, new in new }
            }
        }
        .onDisappear { pager.close() }
    }
}

extension InboxEntry: Identifiable {}

private struct DivKitSnapshotView: UIViewRepresentable {
    let snapshot: InboxRenderingSnapshot
    let messageCenter: MessageCenter
    func makeUIView(context: Context) -> DivView {
        let components = DivKitComponents(urlHandler: DivUrlHandlerDelegate { url in
            guard url.scheme == "engage", url.host == "action",
                  let name = url.pathComponents.dropFirst().first else {
                UIApplication.shared.open(url); return
            }
            Task { _ = await messageCenter.executeAction(name, arguments: actionArguments(url)) }
        })
        let view = DivView(divKitComponents: components)
        update(view)
        return view
    }
    func updateUIView(_ uiView: DivView, context: Context) { update(uiView) }
    private func update(_ view: DivView) {
        guard let data = try? JSONEncoder().encode(JSONValue.object(snapshot.document)) else { return }
        Task {
            await view.setSource(
                DivViewSource(kind: .data(data), cardId: DivCardID(rawValue: snapshot.entryId.value)),
                shouldResetPreviousCardData: true
            )
        }
    }
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
