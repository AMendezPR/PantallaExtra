import SwiftUI
import UIKit

@main
struct PantallaExtraApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}

/// Estado de la sesion: conexion + vista de pantalla.
final class Session: ObservableObject {
    @Published var active = false
    @Published var connected = false
    @Published var status = ""

    let client = StreamClient()
    let screen = ScreenView(frame: .zero)

    init() {
        let client = self.client
        screen.sendEvent = { event in client.send(event) }
        client.onFrame = { [weak self] data in
            DispatchQueue.main.async { self?.screen.enqueue(data) }
        }
        client.onHello = { [weak self] size, _ in
            DispatchQueue.main.async { self?.screen.remoteSize = size }
        }
        client.onState = { [weak self] state in
            DispatchQueue.main.async { self?.apply(state) }
        }
    }

    func start(_ mode: StreamClient.Mode) {
        screen.clear()
        status = ""
        active = true
        UIApplication.shared.isIdleTimerDisabled = true
        client.start(mode)
    }

    func stop() {
        client.stop()
        screen.resignFirstResponder()
        active = false
        connected = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func apply(_ state: StreamClient.State) {
        guard active else { return }
        switch state {
        case let .waiting(text):
            connected = false
            status = text
        case .connected:
            connected = true
            status = ""
        case let .failed(text):
            connected = false
            status = text
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        if session.active {
            DisplayView()
        } else {
            ConnectView()
        }
    }
}

// MARK: - Pantalla de conexion

struct ConnectView: View {
    @EnvironmentObject var session: Session
    @AppStorage("useUSB") private var useUSB = false
    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = "7001"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Conexion", selection: $useUSB) {
                        Text("Wi-Fi").tag(false)
                        Text("Cable USB").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if !useUSB {
                        TextField("IP del computador (ej. 192.168.1.20)", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("Puerto", text: $port)
                        .keyboardType(.numberPad)
                } footer: {
                    Text(useUSB
                         ? "Conecta el iPad por cable y en el computador ejecuta el reenviador USB y el servidor con --usb (ver README)."
                         : "Ejecuta el servidor en el computador; muestra la IP y el puerto a usar. Ambos deben estar en la misma red Wi-Fi.")
                }

                Section {
                    Button(action: connect) {
                        Label("Usar como monitor", systemImage: "display.2")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canConnect)
                }

                Section("Gestos") {
                    gesture("hand.tap", "Toque", "Clic")
                    gesture("hand.draw", "Arrastrar con un dedo", "Mantener clic y arrastrar")
                    gesture("hand.point.up.left", "Mantener presionado", "Clic derecho")
                    gesture("hand.tap", "Toque con dos dedos", "Clic derecho")
                    gesture("arrow.up.and.down", "Arrastrar con dos dedos", "Desplazar")
                    gesture("keyboard", "Boton de teclado", "Escribir en el computador")
                }
            }
            .navigationTitle("PantallaExtra")
        }
    }

    private var portNumber: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }

    private var canConnect: Bool {
        guard portNumber != nil else { return false }
        return useUSB || !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func connect() {
        guard let p = portNumber else { return }
        if useUSB {
            session.start(.usb(port: p))
        } else {
            session.start(.wifi(host: host.trimmingCharacters(in: .whitespaces), port: p))
        }
    }

    private func gesture(_ icon: String, _ title: String, _ result: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 28)
            Text(title)
            Spacer()
            Text(result).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pantalla del monitor

struct DisplayView: View {
    @EnvironmentObject var session: Session
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScreenRepresentable(view: session.screen)
                .ignoresSafeArea()

            if !session.connected {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(session.status).multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 10) {
                if showControls {
                    controlButton("keyboard") { session.screen.toggleKeyboard() }
                    controlButton("xmark") { session.stop() }
                }
                controlButton(showControls ? "chevron.right" : "chevron.left") {
                    withAnimation { showControls.toggle() }
                }
            }
            .padding(14)
            .opacity(0.6)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private func controlButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.7), in: Circle())
                .foregroundStyle(.white)
        }
    }
}

struct ScreenRepresentable: UIViewRepresentable {
    let view: ScreenView
    func makeUIView(context: Context) -> ScreenView { view }
    func updateUIView(_ uiView: ScreenView, context: Context) {}
}
