import CryptoKit
import Foundation
import OSLog

public struct ModelDescriptor: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case speech, vad, translation }

    public struct Asset: Codable, Sendable {
        public let name: String
        public let url: URL?
        public let sha256: String
        public let bytes: Int64
    }

    public let id: String
    public let name: String
    public let detail: String
    public let kind: Kind
    public let assets: [Asset]
    public let version: String?
    public let license: String?
    public let licenseURL: URL?
    public var bytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
    public var requiresImport: Bool { assets.contains { $0.url == nil } }
}

public actor ModelStore {
    public nonisolated let directory: URL
    public nonisolated let catalog: [ModelDescriptor]
    private var verifiedSpeechModels: [String: FileStamp] = [:]
    private var verifiedTranslations: [String: [String: FileStamp]] = [:]

    private struct FileStamp: Equatable {
        let identity: AnyHashable
        let modification: Date
        let size: Int
    }

    public init(directory: URL) throws {
        self.directory = directory
        let manifest = Bundle.main.url(forResource: "Models", withExtension: "json")
            ?? Bundle.module.url(forResource: "Models", withExtension: "json")
        guard let manifest else { throw CaptionFailure("The model catalog is missing from this build.") }
        catalog = try JSONDecoder().decode([ModelDescriptor].self, from: Data(contentsOf: manifest))
    }

    public func installedIDs() -> Set<String> {
        Set(catalog.filter { model in
            model.requiresImport ? (try? verifiedTranslationModel(model.id)) != nil : installed(model)
        }.map(\.id))
    }

    public func path(_ id: String) -> URL? {
        guard let model = catalog.first(where: { $0.id == id }), installed(model) else { return nil }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        if model.kind == .translation { return folder }
        return model.assets.first.map { folder.appendingPathComponent($0.name) }
    }

    public func verifiedSpeechModel(_ id: String) throws -> URL {
        guard let model = catalog.first(where: { $0.id == id && $0.kind == .speech }),
              let asset = model.assets.first else {
            throw CaptionFailure("The selected speech model is missing from the model catalog.")
        }
        let file = directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(asset.name)
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw CaptionFailure("Install \(model.name) in Settings → Models before starting, or check that its file is readable.")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, Int64(size) == asset.bytes else {
            throw CaptionFailure("\(model.name) is incomplete or invalid. Reinstall it in Settings → Models.")
        }
        let stamp: FileStamp?
        if let identity = values.fileResourceIdentifier as? AnyHashable, let modified = values.contentModificationDate {
            stamp = FileStamp(identity: identity, modification: modified, size: size)
        } else {
            stamp = nil
        }
        let needsValidation = verifiedSpeechModels[id] != stamp
        if stamp == nil || needsValidation {
            try Self.validate(file, asset: asset)
            verifiedSpeechModels[id] = stamp
        }
        return file
    }

    public func verifiedTranslationModel(_ id: String) throws -> URL {
        guard let model = catalog.first(where: { $0.id == id && $0.kind == .translation }),
              let folder = path(id) else {
            let name = catalog.first(where: { $0.id == id })?.name ?? id
            throw CaptionFailure("Install \(name) in Settings → Models, or check that its files are complete.")
        }
        guard model.requiresImport else { return folder }
        var stamps: [String: FileStamp] = [:]
        for asset in model.assets {
            let file = folder.appendingPathComponent(asset.name)
            let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw CaptionFailure("Reimport \(model.name). Model files must be regular files.")
            }
            if let identity = values.fileResourceIdentifier as? AnyHashable,
               let modified = values.contentModificationDate, let size = values.fileSize {
                stamps[asset.name] = FileStamp(identity: identity, modification: modified, size: size)
            }
            if let stamp = stamps[asset.name], stamp == verifiedTranslations[id]?[asset.name] { continue }
            try Self.validate(file, asset: asset)
        }
        verifiedTranslations[id] = stamps
        return folder
    }

    private func installed(_ model: ModelDescriptor) -> Bool {
        let folder = directory.appendingPathComponent(model.id, isDirectory: true)
        return model.assets.allSatisfy { asset in
            let values = try? folder.appendingPathComponent(asset.name)
                .resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return values?.isRegularFile == true && values?.fileSize.map(Int64.init) == asset.bytes
        }
    }

    public func remove(_ model: ModelDescriptor) throws {
        verifiedSpeechModels[model.id] = nil
        verifiedTranslations[model.id] = nil
        let folder = directory.appendingPathComponent(model.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func install(_ model: ModelDescriptor, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        let stage = try stageInstallation(model)
        defer {
            do { try manager.removeItem(at: stage) }
            catch where !manager.fileExists(atPath: stage.path) {}
            catch { Logger(subsystem: "local.caption", category: "models").error("Could not clean installation staging directory.") }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var completed = Int64(0)
        for asset in model.assets {
            try Task.checkCancellation()
            guard let url = asset.url else { throw CaptionFailure("Use Install from Folder for \(model.name).") }
            let offset = completed
            let delegate = DownloadProgress { written in
                progress(min(0.99, Double(offset + min(written, asset.bytes)) / Double(model.bytes)))
            }
            let (download, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
            defer { try? manager.removeItem(at: download) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CaptionFailure("The model server could not provide \(asset.name). Try the download again.")
            }
            let validated = stage.appendingPathComponent(asset.name)
            try manager.moveItem(at: download, to: validated)
            try Self.validate(validated, asset: asset)
            completed += asset.bytes
        }
        try Task.checkCancellation()
        try publishInstallation(model, stage: stage)
        progress(1)
    }

    public func importModel(_ id: String, from folder: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let model = catalog.first(where: { $0.id == id && $0.requiresImport }) else {
            throw CaptionFailure("This model does not support folder installation.")
        }
        let manager = FileManager.default
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let stage = try stageInstallation(model)
        defer { try? manager.removeItem(at: stage) }
        var completed: Int64 = 0
        for asset in model.assets {
            try Task.checkCancellation()
            let source = folder.appendingPathComponent(asset.name)
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink == false,
                  values?.fileSize.map(Int64.init) == asset.bytes else {
                throw CaptionFailure("The selected folder is missing a valid \(asset.name). Select the prepared NLLB folder.")
            }
            let destination = stage.appendingPathComponent(asset.name)
            try manager.copyItem(at: source, to: destination)
            let offset = completed
            try Self.validate(destination, asset: asset) { bytes in
                progress(min(0.99, Double(offset + bytes) / Double(model.bytes)))
            }
            completed += asset.bytes
        }
        try Task.checkCancellation()
        try publishInstallation(model, stage: stage)
        progress(1)
    }

    private func stageInstallation(_ model: ModelDescriptor) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, free < model.bytes {
            throw CaptionFailure("Free up at least \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)) to install \(model.name).")
        }
        let stage = directory.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        return stage
    }

    private func publishInstallation(_ model: ModelDescriptor, stage: URL) throws {
        let manager = FileManager.default
        let destination = directory.appendingPathComponent(model.id, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: stage)
        } else {
            try manager.moveItem(at: stage, to: destination)
        }
        verifiedSpeechModels[model.id] = nil
        verifiedTranslations[model.id] = nil
    }

    public static func validate(_ file: URL, asset: ModelDescriptor.Asset,
                                progress: ((Int64) -> Void)? = nil) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == asset.bytes else {
            throw CaptionFailure("\(asset.name) has an unexpected file size. Download the model again.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        var read: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
            read += Int64(bytes.count)
            progress?(read)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == asset.sha256 else {
            let recovery = asset.url == nil ? "Prepare and reimport the model folder." : "Download the model again."
            throw CaptionFailure("\(asset.name) failed its SHA-256 integrity check. \(recovery)")
        }
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        update(totalBytesWritten)
    }
}
