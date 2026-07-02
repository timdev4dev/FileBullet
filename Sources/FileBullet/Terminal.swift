import SwiftUI
import Citadel
import NIOCore
import NIOSSH
import SwiftTerm

/// Bridges an interactive SSH shell (PTY) to a SwiftTerm view.
@available(macOS 15.0, *)
@MainActor
final class PTYSession {
    private let client: SSHClient
    private var outbound: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var cols = 80
    private var rows = 24

    var onOutput: (([UInt8]) -> Void)?
    var onClosed: ((String?) -> Void)?

    init(client: SSHClient) { self.client = client }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            var failure: String?
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: self.cols,
                terminalRowHeight: self.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            do {
                try await self.client.withPTY(request) { inbound, outbound in
                    await self.attach(outbound)
                    for try await chunk in inbound {
                        let buffer: ByteBuffer
                        switch chunk {
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        let bytes = Array(buffer.readableBytesView)
                        await MainActor.run { self.onOutput?(bytes) }
                    }
                }
            } catch is CancellationError {
                failure = nil
            } catch {
                failure = String(describing: error)
            }
            await MainActor.run {
                self.outbound = nil
                self.onClosed?(failure)
            }
        }
    }

    private func attach(_ writer: TTYStdinWriter) async {
        outbound = writer
        try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func send(_ data: ArraySlice<UInt8>) {
        let buffer = ByteBuffer(bytes: data)
        Task { try? await outbound?.write(buffer) }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }   // ignore transient 0/negative sizes
        self.cols = cols
        self.rows = rows
        Task { try? await outbound?.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    func stop() {
        task?.cancel()
        task = nil
        outbound = nil
    }
}

/// TerminalView that grabs keyboard focus as soon as it is shown.
@available(macOS 15.0, *)
final class FocusTerminalView: TerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }
}

/// Owns a live terminal — the SwiftTerm view, the PTY session and the delegate.
/// Held by the SFTPManager so the shell and on-screen state survive tab switches
/// and panel toggling; torn down only on disconnect.
@available(macOS 15.0, *)
@MainActor
final class TerminalHost {
    let view: FocusTerminalView
    private let session: PTYSession
    private let bridge: Bridge

    init(client: SSHClient) {
        view = FocusTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        session = PTYSession(client: client)
        bridge = Bridge(session: session)
        view.terminalDelegate = bridge

        view.feed(text: "\u{1b}[2m[opening shell…]\u{1b}[0m\r\n")
        session.onOutput = { [weak view] bytes in view?.feed(byteArray: bytes[...]) }
        session.onClosed = { [weak view] message in
            let text = message.map { "\r\n\u{1b}[31m[session closed: \($0)]\u{1b}[0m\r\n" }
                ?? "\r\n\u{1b}[2m[session closed]\u{1b}[0m\r\n"
            view?.feed(text: text)
        }
        session.start()
    }

    func stop() { session.stop() }

    final class Bridge: NSObject, TerminalViewDelegate {
        let session: PTYSession
        init(session: PTYSession) { self.session = session }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session.send(data) }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let string = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Hosts the manager's persistent terminal view inside a fresh container per
/// representable, re-parenting it so tab switches don't leave stale views.
@available(macOS 15.0, *)
struct SSHTerminalView: NSViewRepresentable {
    let host: TerminalHost?

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        guard let term = host?.view, term.superview !== container else { return }
        term.removeFromSuperview()
        term.frame = container.bounds
        term.autoresizingMask = [.width, .height]
        container.addSubview(term)
    }
}

/// Bottom panel hosting the real terminal (macOS 15+).
@available(macOS 15.0, *)
struct TerminalContainer: View {
    @ObservedObject var manager: SFTPManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(loc("Terminal", "Терминал", "Terminal", "Terminal")).font(.headline)
                Spacer()
                Button { manager.closeTerminal() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(loc("Close", "Закрыть", "Schließen", "Cerrar"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            SSHTerminalView(host: manager.terminalHost())
        }
    }
}
