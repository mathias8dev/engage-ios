import Foundation
import EngageCore
@_spi(Modules) import EngageCore

public enum OverlayFormat: String, Sendable { case banner = "BANNER", modal = "MODAL", fullscreen = "FULLSCREEN" }
public enum OverlayPosition: String, Sendable { case top = "TOP", center = "CENTER", bottom = "BOTTOM" }
public enum BackdropPolicy: String, Sendable { case none = "NONE", dimmed = "DIMMED" }
public enum DismissalPolicy: String, Sendable { case requiredAction = "REQUIRED_ACTION", userDismissible = "USER_DISMISSIBLE", autoDismiss = "AUTO_DISMISS" }
public enum InAppAnimation: String, Sendable { case none = "NONE", fade = "FADE", slide = "SLIDE", scale = "SCALE" }
public enum EmptyStatePolicy: String, Sendable { case collapse = "COLLAPSE", reserveSpace = "RESERVE_SPACE" }
public enum InAppContentType: String, Sendable { case scene = "SCENE", image = "IMAGE", web = "WEB", survey = "SURVEY" }

public enum PresentationSpec: Sendable {
    case overlay(OverlayPresentation)
    case embedded(EmbeddedPresentation)
}

public struct OverlayPresentation: Sendable {
    public let format: OverlayFormat
    public let position: OverlayPosition?
    public let backdrop: BackdropPolicy
    public let dismissal: DismissalPolicy
    public let animation: InAppAnimation
    public let autoDismissAfterSeconds: Int?
}

public struct EmbeddedPresentation: Sendable {
    public let placementKey: String
    public let emptyState: EmptyStatePolicy
}

public struct InAppContent: Sendable {
    public let experienceId: String
    public let messageId: String
    public let variantId: String?
    public let type: InAppContentType
    public let payload: EngagePayload
    public let presentation: PresentationSpec
}

public enum DisplayDecision: Sendable { case allow, deferDisplay, discard }

public final class InAppOverlays: @unchecked Sendable {
    private let lock = NSLock()
    private var pauseCount = 0
    private var delegate: (@Sendable (InAppContent) -> DisplayDecision)?
    var onChanged: (@Sendable () -> Void)?

    public var displayDelegate: (@Sendable (InAppContent) -> DisplayDecision)? {
        get { lock.lock(); defer { lock.unlock() }; return delegate }
        set {
            lock.lock(); delegate = newValue; let changed = onChanged; lock.unlock()
            EngageLogger.info("InApp.Overlay", "display delegate changed present=\(newValue != nil)")
            changed?()
        }
    }

    public func pause() {
        lock.lock(); pauseCount += 1; let depth = pauseCount; lock.unlock()
        EngageLogger.info("InApp.Overlay", "paused depth=\(depth)")
    }
    public func resume() {
        lock.lock()
        pauseCount = max(0, pauseCount - 1)
        let changed = onChanged
        let depth = pauseCount
        lock.unlock()
        EngageLogger.info("InApp.Overlay", "resumed depth=\(depth)")
        changed?()
    }

    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pauseCount > 0 }
    func decision(for content: InAppContent) -> DisplayDecision { displayDelegate?(content) ?? .allow }
}

public final class InApp: @unchecked Sendable {
    private let context: EngageModuleContext
    private let lock = NSLock()
    private var placements: [String: EngageState<InAppContent?>] = [:]
    private var runtime: InAppRuntime!
    public let overlays = InAppOverlays()

    init(context: EngageModuleContext) {
        self.context = context
        EngageLogger.info(
            "InApp",
            "initializing generation=\(context.generation.value) installationId=\(context.installationId.value ?? "none")"
        )
        let history = InAppHistory(
            generation: { context.generation.value },
            directory: context.storageDirectory(module: "in-app")
        )
        if !context.installationActive.value { try? history.clearAll() }
        runtime = InAppRuntime(
            context: context,
            owner: self,
            history: history,
            overlays: overlays,
            placementStates: { [weak self] in self?.allPlacementStates() ?? [:] }
        )
        overlays.onChanged = { [weak runtime] in Task { await runtime?.requestEvaluation() } }
        context.register(
            EngageModuleRegistration(
                id: "engage-in-app",
                features: [.inApp],
                syncModules: [.inApp],
                wipe: { [weak runtime] in try await runtime?.wipe() }
            )
        )
        Task {
            await runtime.start()
        }
    }

    public func placement(_ key: String) -> EngageState<InAppContent?> {
        precondition(
            key.range(of: "^[a-z][a-z0-9_.-]{0,127}$", options: .regularExpression) != nil,
            "In-app placement keys must be lowercase product keys"
        )
        lock.lock()
        let state: EngageState<InAppContent?>
        if let existing = placements[key] {
            state = existing
        } else {
            state = EngageState(nil)
            placements[key] = state
        }
        lock.unlock()
        EngageLogger.info("InApp", "placement subscribed key=\(key) existing=\(state.value?.messageId ?? "none")")
        Task { [weak runtime] in await runtime?.requestEvaluation() }
        return state
    }

    public func recordVisible(_ content: InAppContent) {
        EngageLogger.info("InApp", "content visible messageId=\(content.messageId) variant=\(content.variantId ?? "none")")
        Task { [weak runtime] in await runtime?.record(content, interaction: .impression) }
    }
    public func recordClick(_ content: InAppContent) {
        EngageLogger.info("InApp", "content clicked messageId=\(content.messageId) variant=\(content.variantId ?? "none")")
        Task { [weak runtime] in await runtime?.record(content, interaction: .click) }
    }
    public func recordDismiss(_ content: InAppContent) {
        EngageLogger.info("InApp", "content dismissed messageId=\(content.messageId) variant=\(content.variantId ?? "none")")
        Task { [weak runtime] in await runtime?.record(content, interaction: .dismiss) }
    }
    public func recordConversion(_ content: InAppContent) {
        EngageLogger.info("InApp", "conversion reported messageId=\(content.messageId) variant=\(content.variantId ?? "none")")
        Task { [weak runtime] in await runtime?.record(content, interaction: .conversion) }
    }
    public func recordRenderFailure(_ content: InAppContent) {
        EngageLogger.warning("InApp", "render failed messageId=\(content.messageId) variant=\(content.variantId ?? "none")")
        Task { [weak runtime] in await runtime?.renderFailed(content) }
    }
    public func executeAction(_ name: String, arguments: EngagePayload) {
        EngageLogger.info("InApp", "action requested name=\(name) argumentKeys=\(arguments.keys.sorted())")
        Task {
            let completed = await context.executeAction(name, arguments: arguments)
            EngageLogger.info("InApp", "action finished name=\(name) completed=\(completed)")
        }
    }

    func overlayClosed() {
        EngageLogger.debug("InApp", "overlay closed")
        Task { [weak runtime] in await runtime?.requestEvaluation() }
    }

    private func allPlacementStates() -> [String: EngageState<InAppContent?>] {
        lock.lock(); defer { lock.unlock() }
        return placements
    }
}

private enum InAppInteraction: String { case impression = "IMPRESSION", click = "CLICK", dismiss = "DISMISS", conversion = "CONVERSION" }

private actor InAppRuntime {
    private let context: EngageModuleContext
    private weak var owner: InApp?
    private let history: InAppHistory
    private let evaluator: InAppEvaluator
    private let overlays: InAppOverlays
    private let placementStates: @Sendable () -> [String: EngageState<InAppContent?>]

    private var documents: [RemoteDocument] = []
    private var enabled = false
    private var currentGeneration: Int64
    private var activePlacements: [String: ResolvedInAppContent] = [:]
    private var resolutions: [String: ResolvedInAppContent] = [:]
    private var delayedEvaluation: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []

    init(
        context: EngageModuleContext,
        owner: InApp,
        history: InAppHistory,
        overlays: InAppOverlays,
        placementStates: @escaping @Sendable () -> [String: EngageState<InAppContent?>]
    ) {
        self.context = context
        self.owner = owner
        self.history = history
        self.overlays = overlays
        self.placementStates = placementStates
        currentGeneration = context.generation.value
        evaluator = InAppEvaluator(
            history: history,
            installationSeed: { context.installationId.value ?? context.config.appKey },
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        EngageLogger.debug("InApp.Runtime", "created generation=\(currentGeneration)")
    }

    func start() {
        guard observationTasks.isEmpty else {
            EngageLogger.debug("InApp.Runtime", "start ignored reason=already_started")
            return
        }
        EngageLogger.info("InApp.Runtime", "starting observers")
        let remoteDocuments = context.documents(.inApp)
        let privacy = context.privacy
        let features = context.enabledFeatures
        let generation = context.generation
        let installationId = context.installationId
        let signals = context.signals
        observationTasks = [
            Task { [weak self] in
                for await value in remoteDocuments.updates { await self?.setDocuments(value) }
            },
            Task { [weak self] in
                for await _ in privacy.updates { await self?.runtimeStateChanged() }
            },
            Task { [weak self] in
                for await _ in features.updates { await self?.runtimeStateChanged() }
            },
            Task { [weak self] in
                for await _ in generation.updates { await self?.runtimeStateChanged() }
            },
            Task { [weak self] in
                for await _ in installationId.updates { await self?.runtimeStateChanged() }
            },
            Task { [weak self] in
                guard let self else { return }
                for await signal in signals.events { await receive(signal) }
            },
        ]
        Task { await runtimeStateChanged() }
        EngageLogger.info("InApp.Runtime", "observers started count=\(observationTasks.count)")
    }

    func wipe() async throws {
        EngageLogger.warning("InApp.Runtime", "wipe started")
        delayedEvaluation?.cancel()
        try history.clearAll()
        documents = []
        enabled = false
        evaluator.resetContext()
        await clearPresentations()
        EngageLogger.warning("InApp.Runtime", "wipe completed")
    }

    func requestEvaluation() async {
        EngageLogger.verbose("InApp.Runtime", "evaluation requested")
        await evaluate()
    }

    func record(_ content: InAppContent, interaction: InAppInteraction) async {
        guard enabled, let candidate = resolutions[content.identity] else {
            EngageLogger.warning(
                "InApp.Runtime",
                "interaction ignored messageId=\(content.messageId) type=\(interaction.rawValue) reason=unknown_or_disabled"
            )
            return
        }
        switch interaction {
        case .impression: evaluator.recordImpression(candidate)
        case .dismiss: evaluator.recordDismiss(candidate)
        case .click, .conversion: break
        }
        let queued = await context.enqueue(type: "INTERACTION_TRACKED", payload: [
            "experienceId": .string(candidate.campaign.experienceId),
            "messageId": .string(candidate.campaign.messageId),
            "variantId": (candidate.variant.id ?? candidate.variant.key).map(JSONValue.string) ?? .null,
            "type": .string(interaction.rawValue),
        ])
        EngageLogger.info(
            "InApp.Runtime",
            "interaction queued experienceId=\(candidate.campaign.experienceId) " +
                "messageId=\(candidate.campaign.messageId) type=\(interaction.rawValue) queued=\(queued)"
        )
        if interaction == .impression || interaction == .dismiss { await evaluate() }
    }

    func renderFailed(_ content: InAppContent) async {
        guard let candidate = resolutions[content.identity] else {
            EngageLogger.debug("InApp.Runtime", "render failure ignored messageId=\(content.messageId) reason=unknown")
            return
        }
        EngageLogger.warning("InApp.Runtime", "render failure consuming messageId=\(content.messageId)")
        evaluator.consume(candidate)
        let failedPlacementKeys = activePlacements.compactMap { key, active in
            active.publicContent.identity == content.identity ? key : nil
        }
        let states = placementStates()
        for key in failedPlacementKeys {
            activePlacements[key] = nil
            states[key]?.set(nil)
        }
        resolutions[content.identity] = nil
        await evaluate()
    }

    private func setDocuments(_ value: [RemoteDocument]) async {
        documents = value
        EngageLogger.debug("InApp.Runtime", "documents received count=\(value.count)")
        await runtimeStateChanged()
    }

    private func runtimeStateChanged() async {
        let generation = context.generation.value
        if generation != currentGeneration {
            EngageLogger.info(
                "InApp.Runtime",
                "generation changed previous=\(currentGeneration) next=\(generation); resetting context"
            )
            currentGeneration = generation
            evaluator.resetContext()
            activePlacements = [:]
            resolutions = [:]
        }
        let canRun = context.installationId.value != nil
            && context.privacy.value == .optedIn
            && context.enabledFeatures.value.contains(.inApp)
        enabled = canRun
        let campaigns = canRun ? documents.compactMap(InAppDocumentParser.parse) : []
        evaluator.replaceCampaigns(campaigns)
        EngageLogger.info(
            "InApp.Runtime",
            "state updated enabled=\(enabled) campaigns=\(campaigns.count) foreground=\(context.foreground.value)"
        )
        if canRun, context.foreground.value, !evaluator.isForeground {
            evaluator.onSignal(.appOpened)
        }
        if !canRun { await clearPresentations() }
        await evaluate()
    }

    private func receive(_ signal: EngageSignal) async {
        if case .localDataWiped = signal {
            do { try await wipe() }
            catch { EngageLogger.error("InApp.Runtime", "wipe signal failed", error: error) }
            return
        }
        guard enabled else {
            EngageLogger.verbose("InApp.Runtime", "signal ignored reason=disabled")
            return
        }
        let signalType: String
        switch signal {
        case .appOpened: signalType = "appOpened"; evaluator.onSignal(.appOpened)
        case .appBackgrounded: signalType = "appBackgrounded"; evaluator.onSignal(.appBackgrounded)
        case let .event(name, _): signalType = "event:\(name)"; evaluator.onSignal(.event(name))
        case let .screenViewed(key): signalType = "screen:\(key)"; evaluator.onSignal(.screenViewed(key))
        case .screenCleared: signalType = "screenCleared"; evaluator.onSignal(.screenCleared)
        case .networkAvailable: signalType = "networkAvailable"
        case .localDataWiped: signalType = "localDataWiped"
        }
        EngageLogger.debug("InApp.Runtime", "signal applied type=\(signalType)")
        await evaluate()
    }

    private func evaluate() async {
        delayedEvaluation?.cancel()
        delayedEvaluation = nil
        guard enabled else {
            EngageLogger.verbose("InApp.Runtime", "evaluation skipped reason=disabled")
            return
        }
        let candidates = evaluator.candidates()
        EngageLogger.debug(
            "InApp.Runtime",
            "evaluation candidates=\(candidates.count) placements=\(placementStates().keys.sorted())"
        )
        updatePlacements(candidates)
        await updateOverlay(candidates)
        if let delay = evaluator.nextEvaluationDelayNanoseconds() {
            EngageLogger.verbose("InApp.Runtime", "next evaluation scheduled delayNanoseconds=\(delay)")
            delayedEvaluation = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                await self?.evaluate()
            }
        }
    }

    private func updatePlacements(_ candidates: [ResolvedInAppContent]) {
        for (key, state) in placementStates() {
            if let current = activePlacements[key], evaluator.remainsContextuallyEligible(current) {
                continue
            }
            let selected = candidates.first { candidate in
                if case let .embedded(presentation) = candidate.variant.presentation {
                    return presentation.placementKey == key
                }
                return false
            }
            if let selected {
                activePlacements[key] = selected
                resolutions[selected.publicContent.identity] = selected
                state.set(selected.publicContent)
                EngageLogger.info(
                    "InApp.Runtime",
                    "placement selected key=\(key) experienceId=\(selected.campaign.experienceId) " +
                        "messageId=\(selected.campaign.messageId)"
                )
            } else {
                activePlacements[key] = nil
                state.set(nil)
                EngageLogger.debug("InApp.Runtime", "placement cleared key=\(key)")
            }
        }
    }

    private func updateOverlay(_ candidates: [ResolvedInAppContent]) async {
        let overlays = candidates.filter {
            if case .overlay = $0.variant.presentation { return true }
            return false
        }
        let activeContent = await MainActor.run { InAppPresenter.shared.activeContent }
        if let activeContent {
            guard let active = resolutions[activeContent.identity],
                  evaluator.remainsContextuallyEligible(active) else {
                await MainActor.run { InAppPresenter.shared.dismiss(reportDismissal: false) }
                EngageLogger.info("InApp.Runtime", "active overlay dismissed reason=no_longer_eligible")
                return
            }
            guard let challenger = overlays.first(where: { $0.instanceKey != active.instanceKey }) else { return }
            switch challenger.campaign.conflictPolicy {
            case .queue:
                EngageLogger.debug("InApp.Runtime", "challenger queued messageId=\(challenger.campaign.messageId)")
                break
            case .skip:
                evaluator.consume(challenger)
                EngageLogger.debug("InApp.Runtime", "challenger skipped messageId=\(challenger.campaign.messageId)")
            case .replaceLowerPriority where challenger.campaign.priority > active.campaign.priority:
                await MainActor.run { InAppPresenter.shared.dismiss(reportDismissal: false) }
                EngageLogger.info(
                    "InApp.Runtime",
                    "active overlay replaced active=\(active.campaign.messageId) challenger=\(challenger.campaign.messageId)"
                )
            case .replaceLowerPriority:
                break
            }
            return
        }
        guard !self.overlays.isPaused else {
            EngageLogger.debug("InApp.Runtime", "overlay selection deferred reason=paused")
            return
        }
        guard let selected = overlays.first, let owner else {
            EngageLogger.verbose("InApp.Runtime", "overlay selection skipped reason=no_candidate_or_owner")
            return
        }
        let content = selected.publicContent
        let decision = await MainActor.run { self.overlays.decision(for: content) }
        EngageLogger.info("InApp.Runtime", "overlay decision messageId=\(content.messageId) decision=\(decision)")
        switch decision {
        case .deferDisplay:
            return
        case .discard:
            evaluator.consume(selected)
        case .allow:
            resolutions[content.identity] = selected
            let shown = await MainActor.run { InAppPresenter.shared.present(content, owner: owner) }
            EngageLogger.info("InApp.Runtime", "overlay presentation result messageId=\(content.messageId) shown=\(shown)")
            if !shown {
                delayedEvaluation = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self?.evaluate()
                }
            }
        }
    }

    private func clearPresentations() async {
        EngageLogger.debug(
            "InApp.Runtime",
            "clearing presentations placements=\(activePlacements.count) resolutions=\(resolutions.count)"
        )
        delayedEvaluation?.cancel()
        delayedEvaluation = nil
        activePlacements = [:]
        resolutions = [:]
        placementStates().values.forEach { $0.set(nil) }
        await MainActor.run { InAppPresenter.shared.dismiss(reportDismissal: false) }
    }
}

extension InAppContent {
    var identity: String { "\(experienceId)\u{0}\(messageId)\u{0}\(variantId ?? "")" }
}

/// Public entry point when the standalone `EngageInApp` Swift Package product is used.
///
/// `EngageSDK` activates this module automatically. With a modular installation, call
/// `EngageCore.start(config:)` first, then `InAppModule.activate()`.
public enum InAppModule {
    @discardableResult
    public static func activate() -> InApp {
        EngageLogger.debug("InApp", "module activation requested")
        return InAppHolder.shared
    }

    public static var shared: InApp { activate() }
}
private enum InAppHolder { static let shared = InApp(context: EngageCore.moduleContext) }
