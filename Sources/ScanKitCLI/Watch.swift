import Foundation
import ScanKit

/// `scankit watch`: scans each stack as it's loaded and files it into `--out`, until Ctrl-C.
@MainActor
func watch(_ arguments: Arguments) async throws {
    guard let output = try ScanOutput(arguments), let out = output.cabinet else { throw CLIError("watch needs --out <dir>") }
    // One line at a time, even into a pipe or a log file.
    setvbuf(stdout, nil, _IOLBF, 0)
    let root = arguments.options["--root"] == nil ? out : try arguments.root()
    let interval = Duration.seconds(Double(arguments.options["--interval"] ?? "2") ?? 2)
    let photos = arguments.options["--photos-dir"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    let job = ScanJob(reader: try arguments.reader(root: root),
                      photoWriter: DryRunPhotoWriter(directory: FileManager.default.temporaryDirectory.appending(path: "scankit-photos")))

    await job.discover()
    guard case .ready(let endpoint) = job.state else { throw CLIError(describe(job.state)) }
    let button = arguments.flags.contains("--on-button") ? try ScannerButton(scanner: endpoint.ipv4, clientName: ScannerButton.localName) : nil

    // Ctrl-C while waiting stops at once; during a scan it stops the scanner, and what came
    // through is filed first. A second Ctrl-C quits right away.
    let interrupt = Interrupt { [job] scanning in
        if scanning { job.stop() } else { button?.stop() }
    }

    if let button {
        print("Watching \(endpoint.name) at \(endpoint.ipv4). Press its start button to scan a stack into \(out.path); Ctrl-C to stop.")
        print("Answering the scanner as \(ScannerButton.localName) at \(button.advertisedAddress).")
        for await event in button.events {
            switch event {
            case .asked:
                print("The scanner's button was pressed; answered.")
            case .request(.jobList(let capabilities)):
                print("The scanner sent its job list (\(capabilities.joined(separator: ", "))); answered OK.")
                // The scanner waits for this job before it asks for the scan.
                do {
                    try await ScannerSession.acceptButtonJob(at: endpoint)
                    print("Wrote and read back the job.")
                } catch {
                    print("error writing the job: \(error.localizedDescription)")
                }
            case .request(.pushScan(let number)):
                print("The scanner asked for job \(number); scanning…")
                interrupt.scanning = true
                do {
                    let result = try await scanStack(job, to: output, photosDirectory: photos, printReport: false)
                    report(result, under: out)
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                interrupt.scanning = false
                if interrupt.requested { button.stop() }
            case .request(.scanEnd):
                print("The scanner says the scan is over.")
            case .request(.other(let name)):
                print("The scanner sent \(name.isEmpty ? "a request FastScan doesn't know" : name); answered OK.")
            }
        }
        print("Stopped.")
        return
    }

    print("Watching \(endpoint.name) at \(endpoint.ipv4). Load a stack to scan it into \(out.path); Ctrl-C to stop.")

    var notice: String?
    func say(_ message: String) {
        guard message != notice else { return }
        notice = message
        print(message)
    }

    while !interrupt.requested {
        do {
            try await checkReady(endpoint)
            // Paper is in. Give the stack a moment to settle before feeding it.
            try await Task.sleep(for: interval)
            guard !interrupt.requested else { break }
            try await checkReady(endpoint)

            say("Scanning…")
            interrupt.scanning = true
            defer { interrupt.scanning = false }
            report(try await scanStack(job, to: output, photosDirectory: photos, printReport: false), under: out)
            notice = nil
        } catch ScannerError.feederEmpty {
            say("Waiting for paper…")
        } catch ScannerError.jammed, ScannerError.doubleFeed {
            say("The scanner needs attention: open it, clear the paper, and close it.")
        } catch ScannerError.busy {
            say("Another app or computer is using the scanner; waiting for it to finish.")
        } catch {
            say("error: \(error.localizedDescription)")
        }
        guard !interrupt.requested else { break }
        try? await Task.sleep(for: interval)
    }
    print("Stopped.")
}

private func report(_ result: ScanReport, under out: URL) {
    let name = result.savedTo.map { URL(filePath: $0).path.replacingOccurrences(of: out.path + "/", with: "") } ?? "nothing (no paper pages)"
    print("Filed \(name): \(result.pages) page(s), \(result.photos) photo(s)\(result.receipt.map { "; receipt \($0)" } ?? "")")
    if result.jammed { print("The paper jammed; the pages before the jam were filed. Clear the scanner and load the rest.") }
}

/// Opens a session only long enough to ask whether the scanner could start a scan.
@MainActor
private func checkReady(_ endpoint: ScannerEndpoint) async throws {
    let session = ScannerSession()
    do {
        try await session.open(endpoint)
        try await session.checkReady()
        await session.close()
    } catch {
        await session.close()
        throw error
    }
}

/// Catches Ctrl-C instead of letting it end the process mid-scan.
@MainActor
final class Interrupt {
    private(set) var requested = false
    var scanning = false
    private let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

    init(onInterrupt: @escaping @MainActor (_ scanning: Bool) -> Void) {
        signal(SIGINT, SIG_IGN)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.requested { exit(130) }
                self.requested = true
                print(self.scanning ? "\nStopping the scan; what came through will be filed. Ctrl-C again to quit now." : "")
                onInterrupt(self.scanning)
            }
        }
        source.resume()
    }
}
