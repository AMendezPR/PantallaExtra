import AVFoundation
import UIKit

/// Muestra la pantalla del computador y convierte los gestos en eventos de mouse.
///
///  * 1 toque ............. clic izquierdo (2 toques rapidos = doble clic)
///  * 1 dedo arrastrando .. mantener clic y arrastrar
///  * mantener presionado . clic derecho
///  * toque con 2 dedos ... clic derecho
///  * 2 dedos arrastrando . desplazar (scroll)
///  * Apple Pencil / trackpad flotando: mueve el puntero
final class ScreenView: UIView, UIKeyInput {
    var sendEvent: (([String: Any]) -> Void)?
    var remoteSize: CGSize = .zero

    private let imageView = UIImageView()
    private let decodeQueue = DispatchQueue(label: "pantallaextra.decode", qos: .userInteractive)
    private var pendingFrame: Data?
    private var decoding = false

    private var scrollAccum = CGPoint.zero
    private var lastMoveSent = CFAbsoluteTime(0)
    private let scrollStep: CGFloat = 18

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    // MARK: - Video

    /// Llamar en el hilo principal. Si llegan frames mientras se decodifica,
    /// se conserva solo el mas reciente.
    func enqueue(_ data: Data) {
        pendingFrame = data
        decodeNextIfIdle()
    }

    func clear() {
        pendingFrame = nil
        imageView.image = nil
    }

    private func decodeNextIfIdle() {
        guard !decoding, let data = pendingFrame else { return }
        pendingFrame = nil
        decoding = true
        decodeQueue.async { [weak self] in
            let image = UIImage(data: data)?.preparingForDisplay()
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.imageView.image = image }
                self.decoding = false
                self.decodeNextIfIdle()
            }
        }
    }

    // MARK: - Coordenadas

    private var contentSize: CGSize {
        if remoteSize.width > 0, remoteSize.height > 0 { return remoteSize }
        return imageView.image?.size ?? CGSize(width: 16, height: 9)
    }

    /// Punto de la vista -> coordenadas 0...1 dentro de la imagen mostrada.
    private func normalized(_ p: CGPoint) -> [String: Any] {
        let rect = AVMakeRect(aspectRatio: contentSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return ["x": 0, "y": 0] }
        let x = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((p.y - rect.minY) / rect.height, 0), 1)
        return ["x": Double(x), "y": Double(y)]
    }

    private func send(_ type: String, at point: CGPoint) {
        var ev = normalized(point)
        ev["t"] = type
        sendEvent?(ev)
    }

    // MARK: - Gestos

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.numberOfTouchesRequired = 1

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = 0.55

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .continuous   // scroll del trackpad/mouse del iPad

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))

        [tap, twoTap, longPress, pan, scroll, hover].forEach(addGestureRecognizer)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        send("click", at: g.location(in: self))
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        send("rclick", at: g.location(in: self))
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            send("rclick", at: g.location(in: self))
        }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            // El gesto empieza tras unos puntos de movimiento: presionamos
            // donde realmente se toco y luego movemos hasta el dedo.
            let t = g.translation(in: self)
            send("down", at: CGPoint(x: p.x - t.x, y: p.y - t.y))
            send("move", at: p)
        case .changed:
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastMoveSent > 0.008 {
                lastMoveSent = now
                send("move", at: p)
            }
        case .ended, .cancelled, .failed:
            send("up", at: p)
        default:
            break
        }
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            scrollAccum = .zero
            g.setTranslation(.zero, in: self)
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            scrollAccum.x += t.x
            scrollAccum.y += t.y
            let dy = Int(scrollAccum.y / scrollStep)
            let dx = Int(-scrollAccum.x / scrollStep)
            if dx != 0 || dy != 0 {
                sendEvent?(["t": "scroll", "dx": dx, "dy": dy])
                scrollAccum.x += CGFloat(dx) * scrollStep
                scrollAccum.y -= CGFloat(dy) * scrollStep
            }
        default:
            break
        }
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveSent > 0.016 {
            lastMoveSent = now
            send("move", at: g.location(in: self))
        }
    }

    // MARK: - Teclado (en pantalla o fisico)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func toggleKeyboard() {
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
    }

    func insertText(_ text: String) {
        if text == "\n" {
            sendEvent?(["t": "key", "k": "enter"])
        } else if text == "\t" {
            sendEvent?(["t": "key", "k": "tab"])
        } else {
            sendEvent?(["t": "text", "s": text])
        }
    }

    func deleteBackward() {
        sendEvent?(["t": "key", "k": "backspace"])
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardLeftArrow?: sendEvent?(["t": "key", "k": "left"])
            case .keyboardRightArrow?: sendEvent?(["t": "key", "k": "right"])
            case .keyboardUpArrow?: sendEvent?(["t": "key", "k": "up"])
            case .keyboardDownArrow?: sendEvent?(["t": "key", "k": "down"])
            case .keyboardEscape?: sendEvent?(["t": "key", "k": "esc"])
            case .keyboardDeleteForward?: sendEvent?(["t": "key", "k": "delete"])
            default: unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
}
