import AppKit
import CoreGraphics
import Foundation

// MARK: - AI Image Creator (Paint's "Image Creator" slot, clean-room)
//
// SELF-TEST (manual, no UI automation available):
//  1. Without configuration, open Image Creator (Lead wires the ribbon/menu to
//     `ImageCreatorPanel.present(for:document:onInsert:)`), type a prompt and
//     press Generate: a friendly alert explains that no key is configured and
//     the app does not crash and stays offline. No request is sent.
//  2. Configure an OpenAI-compatible endpoint:
//       defaults write PaintCraft ImageCreatorBaseURL "https://api.openai.com/v1"
//       defaults write PaintCraft ImageCreatorModel "gpt-image-1"
//       defaults write PaintCraft ImageCreatorAPIKey "sk-…"   (or a local server)
//     Then Generate: a spinner shows, and on success a new layer named "AI image"
//     appears with the picture fitted and centred. Cmd+Z clears the inserted
//     pixels (the empty layer remains — see limitations reported to Lead).
//  3. Point ImageCreatorBaseURL at an unreachable host: Generate fails with a
//     friendly network alert, no crash, key never appears in any log/alert.
//  4. Locked/absent document: panel disables Generate instead of crashing.
//
// Headless check (add to SelfTest.run() if desired):
//   let provider = ImageProviderFactory.makeDefault()
//   // With no key configured this is a NullImageProvider and generate() must
//   // throw ImageProviderError.notConfigured (no network access attempted).

// MARK: - Errors

/// Stable, user-presentable failures for the Image Creator. No case ever carries
/// the API key, and messages are safe to show in an alert or log.
enum ImageProviderError: LocalizedError, Equatable {
    case notConfigured
    case invalidPrompt
    case invalidBaseURL
    case network(String)
    case server(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Image Creator is not configured. Set ImageCreatorAPIKey (and optionally ImageCreatorBaseURL / ImageCreatorModel) in the app defaults, then reopen this panel. The key is read from your user defaults and is never written to logs."
        case .invalidPrompt:
            return "Enter a short description of the image you want to create."
        case .invalidBaseURL:
            return "The configured image endpoint is not a valid http(s) URL. Check ImageCreatorBaseURL in the app defaults."
        case .network(let detail):
            return "Could not reach the image service. Check your internet connection or the configured endpoint. (\(detail))"
        case .server(let detail):
            return "The image service returned an error: \(detail)"
        case .invalidResponse(let detail):
            return "The image service returned a response the app could not read. \(detail)"
        }
    }
}

// MARK: - Provider protocol

/// Any object able to turn a prompt into a CGImage. `RemoteImageProvider` talks
/// to an OpenAI-compatible images endpoint; `NullImageProvider` is the safe
/// default when nothing is configured.
protocol ImageProvider {
    func generate(prompt: String, style: String) async throws -> CGImage
}

// MARK: - Configuration (UserDefaults, never hardcoded)

/// UserDefaults keys and helpers for the Image Creator.
///
/// v1 stores the API key in UserDefaults (the shared task allows this). The key
/// is only read here and handed to the provider; it is never printed, logged,
/// embedded in error messages or persisted anywhere else. Moving the key to the
/// Keychain is a documented follow-up.
enum ImageCreatorSettings {
    static let baseURLKey = "ImageCreatorBaseURL"
    static let apiKeyKey = "ImageCreatorAPIKey"
    static let modelKey = "ImageCreatorModel"

    /// Public, credential-free default. Not a secret.
    static let defaultBaseURLString = "https://api.openai.com/v1"
    /// DALL·E-compatible default; override with ImageCreatorModel.
    static let defaultModel = "gpt-image-1"

    /// True when a non-empty API key exists. "Configured" does not guarantee the
    /// endpoint is reachable (offline still fails gracefully).
    static var isConfigured: Bool {
        isConfigured(defaults: .standard)
    }

    static func isConfigured(defaults: UserDefaults) -> Bool {
        !(defaults.string(forKey: apiKeyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// Current configuration, normalised. The API key is returned only to the
    /// provider factory; callers should not display it.
    static func current(defaults: UserDefaults = .standard)
        -> (baseURLString: String, apiKey: String, model: String) {
        let rawBase = defaults.string(forKey: baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = rawBase.isEmpty ? defaultBaseURLString : rawBase
        let key = defaults.string(forKey: apiKeyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawModel = defaults.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = rawModel.isEmpty ? defaultModel : rawModel
        return (base, key, model)
    }

    /// Writes configuration (used by a future Preferences pane and by tests).
    /// Passing nil leaves that key unchanged; empty strings remove it.
    static func configure(baseURLString: String? = nil, apiKey: String? = nil,
                          model: String? = nil, defaults: UserDefaults = .standard) {
        if let baseURLString {
            if baseURLString.isEmpty {
                defaults.removeObject(forKey: baseURLKey)
            } else {
                defaults.set(baseURLString, forKey: baseURLKey)
            }
        }
        if let apiKey {
            if apiKey.isEmpty {
                defaults.removeObject(forKey: apiKeyKey)
            } else {
                defaults.set(apiKey, forKey: apiKeyKey)
            }
        }
        if let model {
            if model.isEmpty {
                defaults.removeObject(forKey: modelKey)
            } else {
                defaults.set(model, forKey: modelKey)
            }
        }
    }
}

// MARK: - Null provider (default, always offline-safe)

/// Default provider: always fails with `.notConfigured`, never touches the
/// network. Keeps the feature discoverable and crash-free in an offline build.
struct NullImageProvider: ImageProvider {
    func generate(prompt: String, style: String) async throws -> CGImage {
        throw ImageProviderError.notConfigured
    }
}

/// Backwards-compatible alias used in the shared task description.
typealias DisabledProvider = NullImageProvider

// MARK: - Remote provider (OpenAI-compatible /images/generations)

/// Talks to any endpoint that implements the OpenAI-compatible
/// `POST {base}/images/generations` contract and returns base64 (preferred) or
/// a URL for the generated image.
struct RemoteImageProvider: ImageProvider {
    let baseURL: URL
    private let apiKey: String
    let model: String

    init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    /// Never leaks the key through string interpolation/printing.
    var description: String {
        "RemoteImageProvider(baseURL: \(baseURL.absoluteString), model: \(model), apiKey: <redacted>)"
    }

    func generate(prompt: String, style: String) async throws -> CGImage {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw ImageProviderError.invalidPrompt }
        guard let endpoint = Self.endpointURL(for: baseURL) else {
            throw ImageProviderError.invalidBaseURL
        }

        let styledPrompt = style.isEmpty ? trimmedPrompt : "\(trimmedPrompt). Style: \(style)."
        var body: [String: Any] = [
            "model": model,
            "prompt": styledPrompt,
            "n": 1,
            "size": "1024x1024"
        ]
        // gpt-image-* always returns b64_json; older DALL·E servers (and many
        // compatible local servers) need it requested explicitly.
        if !model.lowercased().hasPrefix("gpt-image") {
            body["response_format"] = "b64_json"
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw ImageProviderError.network("The request was cancelled.")
        } catch let error as URLError {
            throw ImageProviderError.network(Self.describe(error))
        } catch {
            throw ImageProviderError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let detail = Self.serverMessage(from: data) ?? "HTTP \(status)"
            throw ImageProviderError.server(Self.truncated(detail))
        }

        return try await decodeImage(from: data)
    }

    // MARK: Response decoding

    private func decodeImage(from data: Data) async throws -> CGImage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let first = items.first else {
            throw ImageProviderError.invalidResponse("Missing `data` array in the JSON response.")
        }

        if let b64 = first["b64_json"] as? String,
           let imageData = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) {
            return try Self.decodeImageData(imageData)
        }

        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            do {
                let (imageData, imageResponse) = try await URLSession.shared.data(from: url)
                let status = (imageResponse as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    throw ImageProviderError.server("Image download failed with HTTP \(status).")
                }
                return try Self.decodeImageData(imageData)
            } catch let error as ImageProviderError {
                throw error
            } catch let error as URLError {
                throw ImageProviderError.network(Self.describe(error))
            } catch {
                throw ImageProviderError.invalidResponse("The returned image URL could not be downloaded.")
            }
        }

        throw ImageProviderError.invalidResponse("The response contained neither `b64_json` nor `url`.")
    }

    private static func decodeImageData(_ data: Data) throws -> CGImage {
        if let image = NSImage(data: data),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           cgImage.width > 0, cgImage.height > 0 {
            return cgImage
        }
        if let rep = NSBitmapImageRep(data: data),
           let cgImage = rep.cgImage, cgImage.width > 0, cgImage.height > 0 {
            return cgImage
        }
        throw ImageProviderError.invalidResponse("The image bytes could not be decoded.")
    }

    // MARK: URL / error helpers

    /// Builds `{base}/images/generations`, tolerating bases with or without the
    /// `/v1` suffix and bases that already point at the endpoint.
    static func endpointURL(for baseURL: URL) -> URL? {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host?.isEmpty == false else { return nil }
        var string = baseURL.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        guard !string.isEmpty else { return nil }
        if string.hasSuffix("/images/generations") {
            return URL(string: string)
        }
        if string.hasSuffix("/v1") {
            return URL(string: string + "/images/generations")
        }
        return URL(string: string + "/v1/images/generations")
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "No internet connection"
        case .cannotFindHost, .cannotConnectToHost: return "Cannot reach the image service"
        case .timedOut: return "The request timed out"
        case .badURL, .unsupportedURL: return "The endpoint URL is invalid"
        default: return "Network error \(error.code.rawValue)"
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any] {
                if let message = error["message"] as? String { return message }
            }
            if let message = root["message"] as? String { return message }
            if let error = root["error"] as? String { return error }
        }
        return String(data: data, encoding: .utf8)
    }

    private static func truncated(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > 300 ? String(flattened.prefix(300)) + "…" : flattened
    }
}

// MARK: - Provider factory

/// Chooses the provider for the current UserDefaults configuration.
enum ImageProviderFactory {
    /// Returns a `RemoteImageProvider` when an API key is configured (and the
    /// base URL parses), otherwise `NullImageProvider`. Never throws.
    static func makeDefault(defaults: UserDefaults = .standard) -> ImageProvider {
        let config = ImageCreatorSettings.current(defaults: defaults)
        guard !config.apiKey.isEmpty else { return NullImageProvider() }
        guard let url = URL(string: config.baseURLString),
              RemoteImageProvider.endpointURL(for: url) != nil else {
            return NullImageProvider()
        }
        return RemoteImageProvider(baseURL: url, apiKey: config.apiKey, model: config.model)
    }
}

// MARK: - Styles

/// Style choices offered by the panel. Titles are the exact popup labels.
enum ImageCreatorStyle: String, CaseIterable, Identifiable {
    case photo
    case illustration
    case watercolor
    case pixelArt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return "Photo"
        case .illustration: return "Illustration"
        case .watercolor: return "Watercolor"
        case .pixelArt: return "Pixel art"
        }
    }

    /// Extra wording appended to the prompt sent to the provider.
    var promptHint: String {
        switch self {
        case .photo: return "photorealistic photograph, natural lighting, high detail"
        case .illustration: return "clean digital illustration, bold shapes, smooth shading"
        case .watercolor: return "watercolor painting, soft washes, textured paper"
        case .pixelArt: return "pixel art, crisp pixels, limited palette, 16-bit game style"
        }
    }
}

// MARK: - Image Creator panel

/// Prompt + style sheet that generates an image and inserts it on a new layer.
final class ImageCreatorPanel: NSWindowController {
    private weak var paintingDocument: Document?
    private var provider: ImageProvider = NullImageProvider()
    private var onInsert: (() -> Void)?
    private var isGenerating = false
    private var generationTask: Task<Void, Never>?

    private var promptField: NSTextField!
    private var stylePopup: NSPopUpButton!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var previewView: NSImageView!
    private var generateButton: NSButton!
    private var configNote: NSTextField!

    init(document: Document) {
        self.paintingDocument = document
        self.provider = ImageProviderFactory.makeDefault()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Image Creator"
        super.init(window: window)
        build()
        updateConfigurationNote()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        generationTask?.cancel()
    }

    /// Presents the Image Creator sheet.
    /// - Parameters:
    ///   - parent: window to attach to (nil shows a standalone window).
    ///   - document: document that receives the generated image on a new layer.
    ///   - onInsert: called on the main thread after the new layer is inserted
    ///     (Lead can refresh canvas/inspector/status).
    static func present(for parent: NSWindow?, document: Document,
                        onInsert: (() -> Void)? = nil) {
        let panel = ImageCreatorPanel(document: document)
        panel.onInsert = onInsert
        if let parent {
            parent.beginSheet(panel.window!) { _ in panel.close() }
        } else {
            panel.window?.center()
            panel.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Insertion (also usable by the Lead / self-test)

    /// Inserts `image` as a new layer named `layerName`, fitted and centred in
    /// the document. The pixels are one undo step; the layer itself is not
    /// removed by undo (Document has no layer-stack undo API — see report).
    @discardableResult
    static func insert(_ image: CGImage, into document: Document,
                       layerName: String = "AI image") -> Layer? {
        guard image.width > 0, image.height > 0 else { return nil }
        let canvasWidth = CGFloat(document.width)
        let canvasHeight = CGFloat(document.height)
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scale = min(canvasWidth / imageWidth, canvasHeight / imageHeight)
        let drawWidth = max(1, (imageWidth * scale).rounded())
        let drawHeight = max(1, (imageHeight * scale).rounded())
        let rect = CGRect(x: ((canvasWidth - drawWidth) / 2).rounded(),
                          y: ((canvasHeight - drawHeight) / 2).rounded(),
                          width: drawWidth, height: drawHeight)

        // Top of the stack, regardless of which layer is active.
        let layer = document.addLayer(name: layerName, above: document.layers.count - 1)
        let pending = document.beginUndo(named: "Insert AI Image", rects: [rect])
        layer.raster.bitmapContext.saveGState()
        layer.raster.bitmapContext.interpolationQuality = .high
        layer.raster.bitmapContext.draw(image, in: rect)
        layer.raster.bitmapContext.restoreGState()
        document.commitUndo(pending)
        document.notifyChange(rect)
        return layer
    }

    // MARK: UI

    private func build() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "Create an image with AI")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Describe the picture and pick a style. The result is added on a new layer named “AI image”.")
        subtitle.font = NSFont.systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.widthAnchor.constraint(equalToConstant: 468).isActive = true
        root.addArrangedSubview(subtitle)

        promptField = NSTextField()
        promptField.placeholderString = "A cozy cabin in a snowy forest at dusk"
        promptField.font = NSFont.systemFont(ofSize: 13)
        promptField.translatesAutoresizingMaskIntoConstraints = false
        promptField.widthAnchor.constraint(equalToConstant: 468).isActive = true
        promptField.target = self
        promptField.action = #selector(generateTapped)
        root.addArrangedSubview(promptField)

        let styleRow = NSStackView()
        styleRow.orientation = .horizontal
        styleRow.spacing = 8
        styleRow.alignment = .centerY
        let styleTitle = NSTextField(labelWithString: "Style")
        styleTitle.font = NSFont.systemFont(ofSize: 11)
        styleTitle.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stylePopup = NSPopUpButton()
        stylePopup.addItems(withTitles: ImageCreatorStyle.allCases.map { $0.title })
        stylePopup.selectItem(at: 0)
        styleRow.addArrangedSubview(styleTitle)
        styleRow.addArrangedSubview(stylePopup)
        root.addArrangedSubview(styleRow)

        let progressRow = NSStackView()
        progressRow.orientation = .horizontal
        progressRow.spacing = 8
        progressRow.alignment = .centerY
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        progressRow.addArrangedSubview(spinner)
        progressRow.addArrangedSubview(statusLabel)
        root.addArrangedSubview(progressRow)

        previewView = NSImageView()
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.borderWidth = 1
        previewView.layer?.borderColor = NSColor.separatorColor.cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.widthAnchor.constraint(equalToConstant: 468).isActive = true
        previewView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        previewView.isHidden = true
        root.addArrangedSubview(previewView)

        configNote = NSTextField(wrappingLabelWithString: "")
        configNote.font = NSFont.systemFont(ofSize: 9)
        configNote.textColor = .tertiaryLabelColor
        configNote.translatesAutoresizingMaskIntoConstraints = false
        configNote.widthAnchor.constraint(equalToConstant: 468).isActive = true
        root.addArrangedSubview(configNote)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(NSView())
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        closeButton.bezelStyle = .rounded
        generateButton = NSButton(title: "Generate", target: self, action: #selector(generateTapped))
        generateButton.bezelStyle = .rounded
        generateButton.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(closeButton)
        buttonRow.addArrangedSubview(generateButton)
        root.addArrangedSubview(buttonRow)

        if paintingDocument?.activeLayer == nil {
            generateButton.isEnabled = false
            statusLabel.stringValue = "No document is open."
        }
    }

    private func updateConfigurationNote() {
        let configured = ImageCreatorSettings.isConfigured
        if configured {
            let current = ImageCreatorSettings.current()
            configNote.stringValue = "Configured endpoint: \(current.baseURLString) · model \(current.model)"
        } else {
            configNote.stringValue = "Not configured. Set ImageCreatorAPIKey (plus optional ImageCreatorBaseURL / ImageCreatorModel) in the app defaults to enable generation — works with any OpenAI-compatible images endpoint, including a local server. Offline use fails gracefully."
            statusLabel.stringValue = "Not configured — see note below."
        }
    }

    // MARK: Actions

    @objc private func generateTapped() {
        guard !isGenerating else { return }
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            presentFriendlyAlert(message: "Image Creator",
                                 detail: ImageProviderError.invalidPrompt.localizedDescription)
            contentViewFirstResponder()
            return
        }
        guard paintingDocument?.activeLayer != nil else {
            presentFriendlyAlert(message: "Image Creator", detail: "Open a document first.")
            return
        }
        let style = selectedStyle()
        let provider = self.provider
        beginGenerating()

        generationTask = Task { [weak self] in
            do {
                let image = try await provider.generate(prompt: prompt, style: style.promptHint)
                await MainActor.run { self?.finishSuccess(image) }
            } catch {
                await MainActor.run { self?.finishFailure(error) }
            }
        }
    }

    private func selectedStyle() -> ImageCreatorStyle {
        let index = stylePopup.indexOfSelectedItem
        guard ImageCreatorStyle.allCases.indices.contains(index) else { return .photo }
        return ImageCreatorStyle.allCases[index]
    }

    private func beginGenerating() {
        isGenerating = true
        generateButton.isEnabled = false
        previewView.isHidden = true
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Generating… this can take a few moments."
        statusLabel.textColor = .secondaryLabelColor
    }

    private func finishSuccess(_ image: CGImage) {
        isGenerating = false
        spinner.stopAnimation(nil)
        generateButton.isEnabled = true
        guard let document = paintingDocument else {
            statusLabel.stringValue = "The document was closed. The image was not inserted."
            return
        }
        guard let layer = ImageCreatorPanel.insert(image, into: document) else {
            statusLabel.stringValue = "The image could not be inserted."
            return
        }
        previewView.image = NSImage(cgImage: image,
                                    size: NSSize(width: image.width, height: image.height))
        previewView.isHidden = false
        statusLabel.stringValue = "Inserted on layer “\(layer.name)” (\(image.width)×\(image.height) px, fitted to canvas)."
        statusLabel.textColor = .systemGreen
        onInsert?()
    }

    private func finishFailure(_ error: Error) {
        isGenerating = false
        spinner.stopAnimation(nil)
        generateButton.isEnabled = true
        let detail: String
        if let providerError = error as? ImageProviderError {
            detail = providerError.localizedDescription
        } else {
            detail = error.localizedDescription
        }
        statusLabel.stringValue = "Generation failed."
        statusLabel.textColor = .systemOrange
        presentFriendlyAlert(message: "Could not create the image", detail: detail)
    }

    private func presentFriendlyAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func contentViewFirstResponder() {
        window?.makeFirstResponder(promptField)
    }

    @objc private func closeTapped() {
        generationTask?.cancel()
        generationTask = nil
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            close()
        }
    }
}
