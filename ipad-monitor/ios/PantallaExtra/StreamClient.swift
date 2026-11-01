import CoreGraphics
import Foundation
import Network

/// Conexion con el servidor del computador.
///
/// * Wi-Fi: el iPad se conecta a <ip>:<puerto>.
/// * USB: el iPad escucha en <puerto>; el computador llega a traves del
///   reenviador USB (iproxy / pymobiledevice3).
///
/// Protocolo: [tipo:1][largo:4 big-endian][datos]
///   1 HELLO (JSON), 2 FRAME (JPEG), 3 INPUT (JSON, del iPad al computador)
final class StreamClient {
    enum Mode: Equatable {
        case wifi(host: String, port: UInt16)
        case usb(port: UInt16)
    }

    enum State {
        case waiting(String)
        case connected(name: String?)
        case failed(String)
    }

    var onState: ((State) -> Void)?
    var onHello: ((CGSize, String?) -> Void)?
    var onFrame: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "pantallaextra.net", qos: .userInteractive)
    private var connection: NWConnection?
    private var listener: NWListener?
    private var mode: Mode?
    private var stopped = true

    private static let msgHello: UInt8 = 1
    private static let msgFrame: UInt8 = 2
    private static let msgInput: UInt8 = 3

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        return params
    }

    func start(_ mode: Mode) {
        queue.async {
            self.stopped = false
            self.mode = mode
            self.begin()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// Envia un evento de entrada (toque, teclado) al computador.
    func send(_ event: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: event) else { return }
        queue.async {
            guard let c = self.connection else { return }
            var packet = Data([Self.msgInput])
            var length = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            packet.append(body)
            c.send(content: packet, completion: .idempotent)
        }
    }

    // MARK: - Conexion

    private func begin() {
        guard !stopped, let mode else { return }
        switch mode {
        case let .wifi(host, port):
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                report(.failed("Puerto invalido"))
                return
            }
            report(.waiting("Conectando a \(host):\(port)…"))
            attach(NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: Self.parameters()))

        case let .usb(port):
            guard listener == nil else { return }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                report(.failed("Puerto invalido"))
                return
            }
            do {
                let l = try NWListener(using: Self.parameters(), on: nwPort)
                l.newConnectionHandler = { [weak self] c in
                    guard let self else { return }
                    self.connection?.cancel()
                    self.attach(c)
                }
                l.stateUpdateHandler = { [weak self] state in
                    if case let .failed(error) = state {
                        self?.report(.failed("No se pudo escuchar en el puerto \(port): \(error.localizedDescription)"))
                    }
                }
                l.start(queue: queue)
                listener = l
                report(.waiting("Esperando al computador por USB…\nEjecuta el servidor con --usb."))
            } catch {
                report(.failed("No se pudo escuchar en el puerto \(port): \(error.localizedDescription)"))
            }
        }
    }

    private func attach(_ c: NWConnection) {
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready:
                self.report(.connected(name: nil))
                self.readHeader(c)
            case .waiting, .failed, .cancelled:
                self.lost(c)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func lost(_ c: NWConnection) {
        guard c === connection else { return }
        connection = nil
        c.cancel()
        guard !stopped, let mode else { return }
        switch mode {
        case .wifi:
            report(.waiting("Sin conexion con el computador. Reintentando…"))
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.connection == nil else { return }
                self.begin()
            }
        case .usb:
            report(.waiting("Esperando al computador por USB…\nEjecuta el servidor con --usb."))
        }
    }

    // MARK: - Lectura de mensajes

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 5 else {
                self.lost(c)
                return
            }
            let b = [UInt8](data)
            let type = b[0]
            let length = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            guard length <= 64 << 20 else {
                self.lost(c)
                return
            }
            if length == 0 {
                self.handle(type, Data())
                self.readHeader(c)
                return
            }
            c.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self else { return }
                guard error == nil, let body, body.count == length else {
                    self.lost(c)
                    return
                }
                self.handle(type, body)
                self.readHeader(c)
            }
        }
    }

    private func handle(_ type: UInt8, _ data: Data) {
        switch type {
        case Self.msgFrame:
            onFrame?(data)
        case Self.msgHello:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let w = (obj["width"] as? NSNumber)?.doubleValue ?? 0
            let h = (obj["height"] as? NSNumber)?.doubleValue ?? 0
            let name = obj["name"] as? String
            onHello?(CGSize(width: w, height: h), name)
            report(.connected(name: name))
        default:
            break
        }
    }

    private func report(_ state: State) {
        onState?(state)
    }
}
