import AudioToolbox
import Foundation
import OSLog
import Security

enum CaptureDiagnostics {
    static let session = Logger(subsystem: "local.caption", category: "session")
    static let audio = Logger(subsystem: "local.caption", category: "capture")

    struct Identity {
        let bundle: String
        let executable: String
        let identifier: String
        let signingIdentifier: String
        let build: String
        let macOS: String
        let hash: String
        let team: String
        let signingStatus: String
        let location: String

        var summary: String {
            """
            macOS \(macOS) · build \(build) · \(location)
            Bundle \(identifier) · signing identifier \(signingIdentifier)
            Team \(team) · \(signingStatus)
            CDHash \(hash)
            Bundle path \(bundle)
            Executable \(executable)
            """
        }
    }

    static func identity() -> Identity {
        let bundle = Bundle.main
        let location: String
        if bundle.bundlePath.contains("/DerivedData/") { location = "DerivedData" }
        else if bundle.bundlePath.hasPrefix("/Applications/") { location = "/Applications" }
        else { location = "Local bundle" }

        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        var informationStatus = errSecSuccess
        var codeStatus = SecCodeCopySelf([], &code)
        if codeStatus == errSecSuccess, let code {
            codeStatus = SecCodeCopyStaticCode(code, [], &staticCode)
            if codeStatus == errSecSuccess, let staticCode {
                informationStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                codeStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
            }
        }
        let signature = information as? [String: Any]
        let hash = (signature?[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }.joined() ?? "unknown"
        let signingStatus: String
        if codeStatus != errSecSuccess {
            signingStatus = "Signing check status \(codeStatus)"
        } else if informationStatus == errSecSuccess, signature?[kSecCodeInfoCertificates as String] == nil {
            signingStatus = "Ad hoc signature valid"
        } else {
            signingStatus = "Signature valid"
        }

        return Identity(
            bundle: bundle.bundlePath, executable: bundle.executableURL?.path ?? "unknown",
            identifier: bundle.bundleIdentifier ?? "unknown",
            signingIdentifier: signature?[kSecCodeInfoIdentifier as String] as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            hash: hash, team: signature?[kSecCodeInfoTeamIdentifier as String] as? String ?? "none",
            signingStatus: signingStatus, location: location
        )
    }

    static func systemAudioRequested(selection: String) {
        let app = identity()
        audio.info("System Audio requested; selection=\(selection, privacy: .public) id=\(app.identifier, privacy: .public) signingID=\(app.signingIdentifier, privacy: .public) build=\(app.build, privacy: .public) macOS=\(app.macOS, privacy: .public) cdhash=\(app.hash, privacy: .public) team=\(app.team, privacy: .public) signature=\(app.signingStatus, privacy: .public) location=\(app.location, privacy: .public)")
        audio.info("System Audio bundle path=\(app.bundle, privacy: .private) executable=\(app.executable, privacy: .private)")
    }

    static func failure(_ step: String, _ error: any Error, logger: Logger = session) {
        var current: NSError? = error as NSError
        for depth in 0..<4 {
            guard let value = current else { break }
            let type = depth == 0 ? String(reflecting: Swift.type(of: error)) : String(reflecting: Swift.type(of: value))
            logger.error("\(step, privacy: .public) failed; depth=\(depth) type=\(type, privacy: .public) domain=\(value.domain, privacy: .public) code=\(value.code) description=\(value.localizedDescription, privacy: .private)")
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
                current = underlying
            } else if depth == 0, let underlying = (error as? SystemAudioCaptureFailure)?.underlying {
                current = underlying as NSError
            } else {
                current = nil
            }
        }
    }

    static func cleanup(_ operation: String, status: OSStatus) {
        if status != noErr {
            audio.warning("\(operation, privacy: .public) returned Core Audio status \(status)")
        }
    }
}
