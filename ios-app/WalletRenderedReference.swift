import Foundation
import UIKit
import CryptoKit
import AirliftFFI

/// Describes the Wallet-rendered reference captured from the per-card cache.
/// This is deliberately separate from the immutable provider-file backup used by
/// Restore Original. A rendered reference may be useful for reproducing the exact
/// face Wallet shows, but it must never replace the raw restore backup.
struct WalletRenderedReferenceManifest: Codable, Equatable, Sendable {
    let version: Int
    let cardId: String
    let capturedAt: Date
    let cacheSuffix: String
    let leaf: String
    let byteCount: Int
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int
}

enum WalletRenderedReferenceCaptureResult: Sendable {
    case captured(WalletRenderedReferenceManifest)
    case unavailable(attempted: Int, detail: String?)
    case unsafe(error: String)
}

private struct WalletRenderedCacheCandidate: Sendable {
    let suffix: String
    let leaf: String
}

private struct WalletRenderedCacheReadResult: Sendable {
    let data: Data?
    let sourceMissing: Bool
    let error: String?
}

extension AppViewModel {
    /// Wallet cache entries observed/used by the existing cache invalidation path.
    /// FrontFace is intentionally preferred because it is the best candidate for the
    /// final face Wallet actually renders. Preview and PlaceHolder are fallbacks only.
    private nonisolated static let renderedWalletCacheCandidates: [WalletRenderedCacheCandidate] = [
        .init(suffix: ".pkcache", leaf: "FrontFace"),
        .init(suffix: ".cache", leaf: "FrontFace"),
        .init(suffix: ".pkcache", leaf: "Preview"),
        .init(suffix: ".cache", leaf: "Preview"),
        .init(suffix: ".pkcache", leaf: "PlaceHolder"),
        .init(suffix: ".cache", leaf: "PlaceHolder")
    ]

    nonisolated static func renderedWalletReferenceDirectory(for cardId: String) -> URL {
        let safeId = scannedCardSafeId(cardId)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalletCards", isDirectory: true)
            .appendingPathComponent("RenderedReferences", isDirectory: true)
            .appendingPathComponent(safeId, isDirectory: true)
    }

    nonisolated static func renderedWalletReferenceImagePath(for cardId: String) -> URL {
        renderedWalletReferenceDirectory(for: cardId)
            .appendingPathComponent("reference.png")
    }

    nonisolated static func renderedWalletReferenceManifestPath(for cardId: String) -> URL {
        renderedWalletReferenceDirectory(for: cardId)
            .appendingPathComponent("manifest.json")
    }

    nonisolated static func renderedWalletReferenceImage(for cardId: String) -> UIImage? {
        let url = renderedWalletReferenceImagePath(for: cardId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ImageEngine.safeImageFromData(data, maxDimension: 2048)
    }

    nonisolated static func renderedWalletReferenceManifest(for cardId: String) -> WalletRenderedReferenceManifest? {
        let url = renderedWalletReferenceManifestPath(for: cardId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalletRenderedReferenceManifest.self, from: data)
    }

    /// Best-effort probe of Wallet's rendered per-card cache. Failure or absence is
    /// non-fatal and must never block creation of the immutable raw artwork backup.
    /// Every successful move-based read is written back before the bytes are inspected.
    nonisolated static func captureRenderedWalletReference(
        cardId: String,
        pairingPath: String
    ) async -> WalletRenderedReferenceCaptureResult {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        var attempted = 0
        var lastDetail: String? = nil

        for candidate in renderedWalletCacheCandidates {
            attempted += 1
            let cacheDirectory = "/var/mobile/Library/Passes/Cards/\(cleanId)\(candidate.suffix)"
            let read = await readRenderedWalletCacheFileAndRestore(
                cardId: cleanId,
                cacheSuffix: candidate.suffix,
                leaf: candidate.leaf,
                pairingPath: pairingPath,
                targetDirectory: cacheDirectory
            )

            if read.sourceMissing {
                continue
            }

            if let error = read.error {
                // A non-missing failure after a destructive export is treated as a
                // safety event. The raw original-artwork backup may still continue,
                // but do not probe additional cache entries in this transaction.
                return .unsafe(error: error)
            }

            guard let data = read.data else { continue }

            // Keep a raw diagnostic copy even if the cache payload is not directly
            // decodable as an image. This lets us inspect the container format later.
            persistRenderedWalletRawDiagnostic(
                data: data,
                cardId: cleanId,
                cacheSuffix: candidate.suffix,
                leaf: candidate.leaf
            )

            guard let image = ImageEngine.safeImageFromData(data, maxDimension: 2048),
                  let normalized = ImageEngine.normalizeAndDownsample(image, maxDimension: 2048).pngData() else {
                lastDetail = "\(candidate.suffix)/\(candidate.leaf) existed (\(data.count) bytes) but was not directly decodable as an image"
                continue
            }

            let directory = renderedWalletReferenceDirectory(for: cleanId)
            let imageURL = renderedWalletReferenceImagePath(for: cleanId)
            let manifestURL = renderedWalletReferenceManifestPath(for: cleanId)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let manifest = WalletRenderedReferenceManifest(
                version: 1,
                cardId: cleanId,
                capturedAt: Date(),
                cacheSuffix: candidate.suffix,
                leaf: candidate.leaf,
                byteCount: data.count,
                sha256: digest,
                pixelWidth: Int(image.size.width * image.scale),
                pixelHeight: Int(image.size.height * image.scale)
            )

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try normalized.write(to: imageURL, options: .atomic)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
                return .captured(manifest)
            } catch {
                return .unsafe(error: "Rendered Wallet reference was decoded but could not be persisted: \(error.localizedDescription)")
            }
        }

        return .unavailable(attempted: attempted, detail: lastDetail)
    }

    /// Reads one extensionless Wallet cache entry through the same move-based export
    /// primitive used elsewhere, but restores it to its original cache directory before
    /// returning any bytes to the caller.
    nonisolated private static func readRenderedWalletCacheFileAndRestore(
        cardId: String,
        cacheSuffix: String,
        leaf: String,
        pairingPath: String,
        targetDirectory: String
    ) async -> WalletRenderedCacheReadResult {
        let stageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_rendered_probe_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        } catch {
            return .init(data: nil, sourceMissing: false, error: "Could not create rendered-reference staging: \(error.localizedDescription)")
        }

        var shouldDeleteStage = true
        defer {
            if shouldDeleteStage {
                try? FileManager.default.removeItem(at: stageDirectory)
            }
        }

        let exportedURL = stageDirectory.appendingPathComponent(leaf)
        let export = await exportRenderedWalletCacheFile(
            pairingPath: pairingPath,
            devicePath: "\(targetDirectory)/\(leaf)",
            outputPath: exportedURL.path
        )

        guard export.ok else {
            let missing = WalletSafety.classifyArtworkExportFailure(export.error) == .sourceMissing
            return .init(data: nil, sourceMissing: missing, error: missing ? nil : export.error)
        }

        let recoveryRoot = renderedWalletReferenceRecoveryDirectory(
            for: cardId,
            cacheSuffix: cacheSuffix,
            leaf: leaf
        )
        let recoveryFile = recoveryRoot.appendingPathComponent(leaf)

        do {
            try? FileManager.default.removeItem(at: recoveryRoot)
            try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: exportedURL, to: recoveryFile)
        } catch {
            // If persistent recovery creation fails, immediately restore from staging.
            let emergency = await writeWalletDirectory(
                pairingPath: pairingPath,
                sourceDirectory: stageDirectory,
                targetDirectory: targetDirectory
            )
            if !emergency.ok {
                shouldDeleteStage = false
                return .init(
                    data: nil,
                    sourceMissing: false,
                    error: "Rendered cache \(cacheSuffix)/\(leaf) was moved but recovery creation and emergency write-back both failed. Staging retained at \(stageDirectory.path). \(emergency.error ?? "unknown write error")"
                )
            }
            return .init(
                data: nil,
                sourceMissing: false,
                error: "Rendered cache recovery copy could not be created; the Wallet cache entry was safely written back: \(error.localizedDescription)"
            )
        }

        var writeBack: (ok: Bool, error: String?) = (false, nil)
        for attempt in 0..<2 {
            writeBack = await writeWalletDirectory(
                pairingPath: pairingPath,
                sourceDirectory: recoveryRoot,
                targetDirectory: targetDirectory
            )
            if writeBack.ok { break }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        guard writeBack.ok else {
            return .init(
                data: nil,
                sourceMissing: false,
                error: "Rendered cache \(cacheSuffix)/\(leaf) was read but could not be written back. Recovery retained at \(recoveryRoot.path). \(writeBack.error ?? "unknown write error")"
            )
        }

        guard let data = try? Data(contentsOf: exportedURL) else {
            try? FileManager.default.removeItem(at: recoveryRoot)
            return .init(
                data: nil,
                sourceMissing: false,
                error: "Rendered cache \(cacheSuffix)/\(leaf) was restored, but the local probe copy could not be read"
            )
        }

        try? FileManager.default.removeItem(at: recoveryRoot)
        return .init(data: data, sourceMissing: false, error: nil)
    }

    nonisolated private static func renderedWalletReferenceRecoveryDirectory(
        for cardId: String,
        cacheSuffix: String,
        leaf: String
    ) -> URL {
        let safeSuffix = cacheSuffix.replacingOccurrences(of: ".", with: "")
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalletCards", isDirectory: true)
            .appendingPathComponent("RenderedReferenceRecovery", isDirectory: true)
            .appendingPathComponent(scannedCardSafeId(cardId), isDirectory: true)
            .appendingPathComponent("\(safeSuffix)-\(leaf)", isDirectory: true)
    }

    nonisolated private static func persistRenderedWalletRawDiagnostic(
        data: Data,
        cardId: String,
        cacheSuffix: String,
        leaf: String
    ) {
        let directory = renderedWalletReferenceDirectory(for: cardId)
            .appendingPathComponent("Raw", isDirectory: true)
        let safeSuffix = cacheSuffix.replacingOccurrences(of: ".", with: "")
        let url = directory.appendingPathComponent("\(safeSuffix)-\(leaf).bin")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Diagnostic persistence must never change scan/backup safety semantics.
        }
    }

    nonisolated private static func exportRenderedWalletCacheFile(
        pairingPath: String,
        devicePath: String,
        outputPath: String
    ) async -> (ok: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairC in
                    devicePath.withCString { deviceC in
                        outputPath.withCString { outputC in
                            al_exploit_export_file(pairC, deviceC, outputC, nil, nil, &outError)
                        }
                    }
                }
                let error = outError.flatMap { String(validatingUTF8: $0) }
                if let pointer = outError { al_string_free(pointer) }
                continuation.resume(returning: (rc == 0, error))
            }
        }
    }
}
