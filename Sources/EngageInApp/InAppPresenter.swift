#if canImport(UIKit)
import UIKit
import WebKit
import SwiftUI
import DivKit
import EngageCore

@MainActor final class InAppPresenter {
    static let shared = InAppPresenter()
    private weak var presented: InAppOverlayController?
    private(set) var activeContent: InAppContent?

    @discardableResult
    func present(_ content: InAppContent, owner: InApp) -> Bool {
        guard presented == nil else {
            EngageLogger.debug(
                "InApp.Presenter",
                "presentation rejected messageId=\(content.messageId) active=\(activeContent?.messageId ?? "none")"
            )
            return false
        }
        guard let host = topViewController() else {
            EngageLogger.debug("InApp.Presenter", "presentation rejected messageId=\(content.messageId) reason=no_host")
            return false
        }
        EngageLogger.info(
            "InApp.Presenter",
            "presenting messageId=\(content.messageId) format=\(String(describing: content.overlayFormat)) " +
                "animation=\(String(describing: content.animation))"
        )
        let controller = InAppOverlayController(content: content, owner: owner)
        presented = controller
        activeContent = content
        controller.onClosed = { [weak self, weak owner] in
            self?.presented = nil
            self?.activeContent = nil
            EngageLogger.info("InApp.Presenter", "closed messageId=\(content.messageId)")
            owner?.overlayClosed()
        }
        switch content.animation {
        case .fade: controller.modalTransitionStyle = .crossDissolve
        case .slide: controller.modalTransitionStyle = .coverVertical
        case .scale:
            controller.modalPresentationStyle = .custom
            controller.transitioningDelegate = controller
        case .none: break
        }
        host.present(controller, animated: content.animation != .none)
        EngageLogger.debug("InApp.Presenter", "presentation requested messageId=\(content.messageId)")
        return true
    }

    func dismiss(reportDismissal: Bool) {
        guard let presented else {
            activeContent = nil
            EngageLogger.verbose("InApp.Presenter", "dismiss ignored reason=no_active_overlay")
            return
        }
        EngageLogger.info(
            "InApp.Presenter",
            "dismiss requested messageId=\(presented.content.messageId) reportDismissal=\(reportDismissal)"
        )
        presented.close(track: reportDismissal)
    }

    private func topViewController(_ root: UIViewController? = activeWindow()?.rootViewController) -> UIViewController? {
        if let presented = root?.presentedViewController { return topViewController(presented) }
        if let navigation = root as? UINavigationController { return topViewController(navigation.visibleViewController) }
        if let tabs = root as? UITabBarController { return topViewController(tabs.selectedViewController) }
        return root
    }

    private func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private final class InAppOverlayController: UIViewController, UIGestureRecognizerDelegate,
    UIViewControllerTransitioningDelegate {
    let content: InAppContent
    unowned let owner: InApp
    var onClosed: (() -> Void)?
    private var closed = false

    init(content: InAppContent, owner: InApp) {
        self.content = content
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = content.overlayFormat == .fullscreen ? .fullScreen : .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        EngageLogger.debug("InApp.Presenter", "overlay view loading messageId=\(content.messageId)")
        view.backgroundColor = content.backdrop == .dimmed
            ? UIColor.black.withAlphaComponent(0.48)
            : .clear
        let rendered = EngageInAppContentView(
            content: content,
            owner: owner,
            onDismissRequested: { [weak self] in self?.close(track: true) },
            onRenderFailed: { [weak self] in
                guard let self else { return }
                owner.recordRenderFailure(content)
                close(track: false)
            }
        )
        view.addSubview(rendered)
        rendered.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(constraints(for: rendered))

        if content.dismissal == .userDismissible {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(backgroundTap))
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
        if content.dismissal == .autoDismiss, let seconds = content.autoDismissSeconds {
            EngageLogger.debug("InApp.Presenter", "auto-dismiss scheduled messageId=\(content.messageId) seconds=\(seconds)")
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(max(0, seconds))) { [weak self] in
                self?.close(track: true)
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === view
    }

    @objc private func backgroundTap() { close(track: true) }

    func close(track: Bool) {
        guard !closed else {
            EngageLogger.verbose("InApp.Presenter", "close ignored messageId=\(content.messageId) reason=already_closed")
            return
        }
        EngageLogger.info("InApp.Presenter", "closing messageId=\(content.messageId) trackDismissal=\(track)")
        closed = true
        if track { owner.recordDismiss(content) }
        dismiss(animated: content.animation != .none) { [weak self] in self?.onClosed?() }
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        content.animation == .scale ? ScaleTransitionAnimator(presenting: true) : nil
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        content.animation == .scale ? ScaleTransitionAnimator(presenting: false) : nil
    }

    private func constraints(for rendered: UIView) -> [NSLayoutConstraint] {
        guard content.overlayFormat != .fullscreen else {
            return [
                rendered.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                rendered.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                rendered.topAnchor.constraint(equalTo: view.topAnchor),
                rendered.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        }
        var values = [
            rendered.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            rendered.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            rendered.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rendered.heightAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor,
                constant: -24
            ),
        ]
        let availableWidth = rendered.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        availableWidth.priority = .defaultHigh
        values.append(availableWidth)

        let preferredWidth: CGFloat = content.overlayFormat == .banner ? 720 : 560
        values.append(rendered.widthAnchor.constraint(lessThanOrEqualToConstant: preferredWidth))
        let widthFallback = rendered.widthAnchor.constraint(equalToConstant: preferredWidth)
        widthFallback.priority = UILayoutPriority(749)
        values.append(widthFallback)

        let heightFallback = rendered.heightAnchor.constraint(
            equalToConstant: content.overlayFormat == .banner ? 96 : 480
        )
        heightFallback.priority = UILayoutPriority(200)
        values.append(heightFallback)

        switch content.overlayPosition {
        case .top:
            values.append(rendered.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12))
        case .bottom:
            values.append(rendered.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12))
        default:
            values.append(rendered.centerYAnchor.constraint(equalTo: view.centerYAnchor))
        }
        return values
    }
}

private final class ScaleTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.25
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let duration = transitionDuration(using: transitionContext)
        if presenting {
            guard let target = transitionContext.view(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            transitionContext.containerView.addSubview(target)
            target.alpha = 0
            target.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                target.alpha = 1
                target.transform = .identity
            } completion: { finished in
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
        } else {
            guard let source = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseIn, .beginFromCurrentState]
            ) {
                source.alpha = 0
                source.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            } completion: { finished in
                let completed = finished && !transitionContext.transitionWasCancelled
                if completed { source.removeFromSuperview() }
                transitionContext.completeTransition(completed)
            }
        }
    }
}

public final class EngageInAppContentView: UIView {
    private let content: InAppContent
    private unowned let owner: InApp
    private let onDismissRequested: (() -> Void)?
    private let onRenderFailed: (() -> Void)?
    private weak var renderedView: UIView?
    private var divSizeObserver: Any?
    private var contentReady = false
    private var renderFailureReported = false
    private var visibleReported = false

    public convenience init(content: InAppContent, owner: InApp) {
        self.init(content: content, owner: owner, onDismissRequested: nil, onRenderFailed: nil)
    }

    init(
        content: InAppContent,
        owner: InApp,
        onDismissRequested: (() -> Void)?,
        onRenderFailed: (() -> Void)?
    ) {
        self.content = content
        self.owner = owner
        self.onDismissRequested = onDismissRequested
        self.onRenderFailed = onRenderFailed
        super.init(frame: .zero)
        EngageLogger.debug(
            "InApp.Render",
            "content view creating messageId=\(content.messageId) variant=\(content.variantId ?? "none") type=\(content.type)"
        )
        do {
            let child = try render()
            renderedView = child
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor),
                widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            ])
            EngageLogger.debug("InApp.Render", "content view created messageId=\(content.messageId) child=\(type(of: child))")
        } catch {
            EngageLogger.error("InApp.Render", "content view creation failed messageId=\(content.messageId)", error: error)
            DispatchQueue.main.async { [weak self] in self?.reportRenderFailure() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        EngageLogger.verbose("InApp.Render", "content window changed messageId=\(content.messageId) attached=\(window != nil)")
        DispatchQueue.main.async { [weak self] in self?.reportVisibilityIfNeeded() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        reportVisibilityIfNeeded()
    }

    public override var intrinsicContentSize: CGSize {
        guard let renderedView else { return super.intrinsicContentSize }
        return renderedView.intrinsicContentSize
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let renderedView else { return .zero }
        return renderedView.sizeThatFits(size)
    }

    public override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        guard let renderedView else { return .zero }
        return renderedView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    private func render() throws -> UIView {
        switch content.type {
        case .scene, .survey: return try divView()
        case .image: return try imageView()
        case .web: return try webView()
        }
    }

    private func divView() throws -> UIView {
        EngageLogger.debug("InApp.Render", "DivKit scene parsing messageId=\(content.messageId)")
        let data = try JSONEncoder().encode(JSONValue.object(content.payload))
        let components = DivKitComponents(urlHandler: DivUrlHandlerDelegate { [weak self] url in
            self?.handle(url)
        })
        let view = DivView(divKitComponents: components)
        divSizeObserver = view.addObserver { [weak self] _ in
            Task { @MainActor [weak self] in self?.contentSizeDidChange() }
        }
        Task { [weak self, weak view] in
            guard let view else { return }
            await view.setSource(
                DivViewSource(kind: .data(data), cardId: DivCardID(rawValue: content.messageId))
            )
            guard view.cardSize != nil else {
                EngageLogger.warning("InApp.Render", "DivKit scene rejected messageId=\(content.messageId)")
                self?.reportRenderFailure()
                return
            }
            self?.markContentReady()
            EngageLogger.debug("InApp.Render", "DivKit scene bound messageId=\(content.messageId)")
        }
        return view
    }

    private func imageView() throws -> UIView {
        guard let raw = content.payload.string("url"),
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw RenderError.invalidPayload
        }
        EngageLogger.debug("InApp.Render", "image loading messageId=\(content.messageId) host=\(url.host ?? "unknown")")
        let image = UIImageView()
        image.contentMode = content.payload.string("contentMode") == "FIT" ? .scaleAspectFit : .scaleAspectFill
        image.clipsToBounds = true
        image.isUserInteractionEnabled = true
        image.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped)))
        URLSession.shared.dataTask(with: url) { [weak self, weak image] data, response, error in
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data,
                  let value = UIImage(data: data),
                  value.size.width > 0,
                  value.size.height > 0 else {
                EngageLogger.error("InApp.Render", "image load failed messageId=\(self?.content.messageId ?? "unknown")", error: error)
                DispatchQueue.main.async { self?.reportRenderFailure() }
                return
            }
            DispatchQueue.main.async {
                guard let self, let image else { return }
                image.image = value
                image.heightAnchor.constraint(
                    equalTo: image.widthAnchor,
                    multiplier: value.size.height / value.size.width
                ).isActive = true
                self.markContentReady()
                EngageLogger.debug(
                    "InApp.Render",
                    "image loaded messageId=\(self.content.messageId) bytes=\(data.count) width=\(value.size.width) height=\(value.size.height)"
                )
            }
        }.resume()
        return image
    }

    private func webView() throws -> UIView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            content.payload.bool("javaScriptEnabled") ?? false
        let web = SelfSizingWebView(frame: .zero, configuration: configuration)
        web.onContentSizeChanged = { [weak self] in self?.contentSizeDidChange() }
        web.navigationDelegate = self
        if let raw = content.payload.string("url"),
           let url = URL(string: raw),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            EngageLogger.debug("InApp.Render", "web URL loading messageId=\(content.messageId) host=\(url.host ?? "unknown")")
            web.load(URLRequest(url: url))
        } else if let html = content.payload.string("html") {
            EngageLogger.debug("InApp.Render", "web HTML loading messageId=\(content.messageId) bytes=\(html.utf8.count)")
            web.loadHTMLString(html, baseURL: content.payload.string("baseUrl").flatMap(URL.init(string:)))
        } else {
            throw RenderError.invalidPayload
        }
        return web
    }

    private func handle(_ url: URL) {
        EngageLogger.info(
            "InApp.Render",
            "navigation messageId=\(content.messageId) scheme=\(url.scheme ?? "none") host=\(url.host ?? "none")"
        )
        owner.recordClick(content)
        guard url.scheme?.lowercased() == "engage" else {
            UIApplication.shared.open(url)
            return
        }
        switch url.host?.lowercased() {
        case "dismiss":
            if let onDismissRequested { onDismissRequested() } else { owner.recordDismiss(content) }
        case "conversion":
            owner.recordConversion(content)
        case "action":
            guard let encoded = url.pathComponents.dropFirst().first,
                  let name = encoded.removingPercentEncoding, !name.isEmpty else { return }
            owner.executeAction(name, arguments: actionArguments(url))
            EngageLogger.debug("InApp.Render", "named action messageId=\(content.messageId) name=\(name)")
        default:
            break
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

    @objc private func imageTapped() { owner.recordClick(content) }

    private func reportRenderFailure() {
        guard !renderFailureReported else {
            EngageLogger.verbose("InApp.Render", "render failure deduplicated messageId=\(content.messageId)")
            return
        }
        renderFailureReported = true
        contentReady = false
        EngageLogger.warning("InApp.Render", "render failed messageId=\(content.messageId)")
        if let onRenderFailed { onRenderFailed() } else { owner.recordRenderFailure(content) }
    }

    private func markContentReady() {
        guard !renderFailureReported else { return }
        contentReady = true
        EngageLogger.debug("InApp.Render", "content ready messageId=\(content.messageId)")
        contentSizeDidChange()
        reportVisibilityIfNeeded()
    }

    private func contentSizeDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
    }

    private func reportVisibilityIfNeeded() {
        guard contentReady,
              !visibleReported,
              let window,
              !isHidden,
              alpha > 0.01,
              bounds.width > 0,
              bounds.height > 0 else { return }
        let frame = convert(bounds, to: window)
        let visible = frame.intersection(window.bounds)
        let totalArea = frame.width * frame.height
        guard totalArea > 0, visible.width * visible.height >= totalArea * 0.5 else { return }
        visibleReported = true
        EngageLogger.info("InApp.Render", "visibility threshold reached messageId=\(content.messageId)")
        owner.recordVisible(content)
    }
}

extension EngageInAppContentView: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme?.lowercased() == "engage" {
            handle(url)
            return .cancel
        }
        if action.navigationType == .linkActivated { owner.recordClick(content) }
        EngageLogger.verbose(
            "InApp.Render",
            "web navigation allowed messageId=\(content.messageId) type=\(action.navigationType.rawValue)"
        )
        return .allow
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        EngageLogger.debug("InApp.Render", "web content loaded messageId=\(content.messageId)")
        markContentReady()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        EngageLogger.error("InApp.Render", "web navigation failed messageId=\(content.messageId)", error: error)
        reportRenderFailure()
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        EngageLogger.error("InApp.Render", "web provisional navigation failed messageId=\(content.messageId)", error: error)
        reportRenderFailure()
    }
}

public struct EngageInAppPlacement: UIViewRepresentable {
    private let key: String
    private let inApp: InApp

    public init(_ key: String, inApp: InApp = InAppModule.shared) {
        self.key = key
        self.inApp = inApp
        EngageLogger.debug("InApp.Placement", "SwiftUI placement initialized key=\(key)")
    }

    public func makeUIView(context: Context) -> EngageInAppPlacementView {
        EngageLogger.debug("InApp.Placement", "SwiftUI placement view creating key=\(key)")
        EngageInAppPlacementView(key: key, inApp: inApp)
    }
    public func updateUIView(_ uiView: EngageInAppPlacementView, context: Context) {}
}

/// UIKit host for an embedded Engage in-app placement.
public final class EngageInAppPlacementView: UIView {
    private var task: Task<Void, Never>?
    private var emptyState = EmptyStatePolicy.collapse
    private var reservedHeight: CGFloat = 0

    public convenience init(key: String, inApp: InApp = InAppModule.shared) {
        self.init(state: inApp.placement(key), owner: inApp)
    }

    private init(state: EngageState<InAppContent?>, owner: InApp) {
        super.init(frame: .zero)
        EngageLogger.debug("InApp.Placement", "UIKit placement view created")
        task = Task { [weak self] in
            for await content in state.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if bounds.height > 0 { reservedHeight = bounds.height }
                    subviews.forEach { $0.removeFromSuperview() }
                    guard let content else {
                        EngageLogger.verbose(
                            "InApp.Placement",
                            "placement empty reservedHeight=\(reservedHeight) policy=\(emptyState)"
                        )
                        isHidden = emptyState == .collapse
                        invalidateIntrinsicContentSize()
                        return
                    }
                    if case let .embedded(presentation) = content.presentation {
                        emptyState = presentation.emptyState
                    }
                    isHidden = false
                    EngageLogger.info("InApp.Placement", "placement rendering messageId=\(content.messageId)")
                    let view = EngageInAppContentView(content: content, owner: owner)
                    addSubview(view)
                    view.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        view.leadingAnchor.constraint(equalTo: leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: trailingAnchor),
                        view.topAnchor.constraint(equalTo: topAnchor),
                        view.bottomAnchor.constraint(equalTo: bottomAnchor),
                    ])
                    invalidateIntrinsicContentSize()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }

    public override var intrinsicContentSize: CGSize {
        if subviews.isEmpty, emptyState == .reserveSpace, reservedHeight > 0 {
            return CGSize(width: UIView.noIntrinsicMetric, height: reservedHeight)
        }
        return subviews.first?.intrinsicContentSize ?? super.intrinsicContentSize
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        subviews.first?.sizeThatFits(size) ?? .zero
    }

    public override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        guard let child = subviews.first else { return intrinsicContentSize }
        return child.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }
}

private final class SelfSizingWebView: WKWebView {
    var onContentSizeChanged: (() -> Void)?
    private var contentSizeObservation: NSKeyValueObservation?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                invalidateIntrinsicContentSize()
                onContentSizeChanged?()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let height = scrollView.contentSize.height
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: height > 0 ? height : UIView.noIntrinsicMetric
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(0, scrollView.contentSize.height))
    }
}

private enum RenderError: Error { case invalidPayload }

private extension InAppContent {
    var overlay: OverlayPresentation? {
        if case let .overlay(value) = presentation { return value }
        return nil
    }
    var overlayFormat: OverlayFormat? { overlay?.format }
    var overlayPosition: OverlayPosition? { overlay?.position }
    var backdrop: BackdropPolicy? { overlay?.backdrop }
    var dismissal: DismissalPolicy? { overlay?.dismissal }
    var animation: InAppAnimation? { overlay?.animation }
    var autoDismissSeconds: Int? { overlay?.autoDismissAfterSeconds }
}
#else
@MainActor final class InAppPresenter {
    static let shared = InAppPresenter()
    var activeContent: InAppContent? { nil }
    func present(_ content: InAppContent, owner: InApp) -> Bool { false }
    func dismiss(reportDismissal: Bool) {}
}
#endif
