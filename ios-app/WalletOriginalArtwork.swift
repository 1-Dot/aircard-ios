import Foundation
import AirliftFFI

// MARK: - Original Wallet Artwork Backup / Restore

private final class OriginalArtworkLogBox: @unchecked Sendable {
    let handler: @Sendable (String) -> Void

    init(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }
}

private let originalArtworkLogCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, message in
    guard let context, let message else { return }
    let box = Unmanaged<OriginalArtworkLogBox>.fromOpaque(context).takeUnretainedValue()
    box.handler(String(cString: message))
}

enum OriginalArtworkBackupPreparation: Equatable {
    case existing
    case created
    case failed

    var isReady: Bool { self != .failed }
    var movedOriginalFiles: Bool { self == .created }
}

extension AppViewModel {
    /// Artwork leaves that AirCard itself may overwrite when applying a skin.
    /// We preserve only files that actually exist on a given card.
    nonisolated static let originalWalletArtworkLeaves: [String] = [
        "cardBackgroundCombined@3x.png",
        "cardBackgroundCombined@2x.png",
        "cardBackgroundCombined.pdf",
        "diffuse@3x.png",
        "diffuse@2x.png",
        "background@3x.png",
        "background@2x.png",
        "background.pdf",
        "strip@3x.png",
        "strip@2x.png",
        "strip.pdf"
    ]

    nonisolated static func originalArtworkBackupDirectory(for cardId: String) -> URL {
        let safeId = cardId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("WalletCards", isDirectory: true)
            .appendingPathComponent("Originals", isDirectory: true)
            .appendingPathComponent(safeId, isDirectory: true)
    }

    nonisolated static func originalArtworkBackupMarker(for cardId: String) -> URL {
        originalArtworkBackupDirectory(for: cardId).appendingPathComponent(".complete")
    }

    nonisolated static func hasOriginalArtworkBackup(for cardId: String) -> Bool {
        validateOriginalArtworkBackup(for: cardId).isValid
    }

    nonisolated static func artworkExportFailureKind(_ error: String?) -> ArtworkExportFailureKind {
        WalletSafety.classifyArtworkExportFailure(error)
    }

    nonisolated private static func exportDeviceFile(
        pairingPath: String,
        devicePath: String,
        outputPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let logContext = Unmanaged.passRetained(OriginalArtworkLogBox(log)).toOpaque()
                defer { Unmanaged<OriginalArtworkLogBox>.fromOpaque(logContext).release() }

                let rc = pairingPath.withCString { pairC in
                    devicePath.withCString { deviceC in
                        outputPath.withCString { outputC in
                            al_exploit_export_file(
                                pairC,
                                deviceC,
                                outputC,
                                originalArtworkLogCallback,
                                logContext,
                                &outError
                            )
                        }
                    }
                }
                let error = outError.flatMap { String(validatingUTF8: $0) }
                if let p = outError { al_string_free(p) }
                continuation.resume(returning: (rc == 0, error))
            }
        }
    }

    nonisolated private static func writeArtworkDirectory(
        pairingPath: String,
        sourceDirectory: URL,
        targetDirectory: String,
        requireVerifiedManifestFor cardId: String?,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, error: String?) {
        var leavesToWrite = originalWalletArtworkLeaves

        if let cardId {
            let validation = validateOriginalArtworkBackup(for: cardId)
            guard case .valid(let manifest) = validation else {
                return (false, "Original-artwork backup failed integrity validation: \(validation.message)")
            }
            // Only bytes explicitly covered by the verified manifest may be restored.
            // Extra files in the backup directory are ignored rather than trusted.
            leavesToWrite = manifest.files.map(\.name)
        }

        let stageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_original_restore_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
            var copiedCount = 0
            for leaf in leavesToWrite {
                let source = sourceDirectory.appendingPathComponent(leaf)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(at: source, to: stageDirectory.appendingPathComponent(leaf))
                copiedCount += 1
            }
            guard copiedCount > 0 else {
                try? FileManager.default.removeItem(at: stageDirectory)
                return (false, "No original Wallet artwork files are available in the backup")
            }
        } catch {
            try? FileManager.default.removeItem(at: stageDirectory)
            return (false, "Could not stage original Wallet artwork: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: stageDirectory) }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let logContext = Unmanaged.passRetained(OriginalArtworkLogBox(log)).toOpaque()
                defer { Unmanaged<OriginalArtworkLogBox>.fromOpaque(logContext).release() }

                let rc = pairingPath.withCString { pairC in
                    stageDirectory.path.withCString { sourceC in
                        targetDirectory.withCString { targetC in
                            al_exploit_write_dir(
                                pairC,
                                sourceC,
                                targetC,
                                originalArtworkLogCallback,
                                logContext,
                                &outError
                            )
                        }
                    }
                }
                let error = outError.flatMap { String(validatingUTF8: $0) }
                if let p = outError { al_string_free(p) }
                continuation.resume(returning: (rc == 0, error))
            }
        }
    }

    nonisolated static func restoreOriginalArtworkBackupFiles(
        cardId: String,
        pairingPath: String,
        allowIncompleteRecovery: Bool = false,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, error: String?) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        let targetDir = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"
        return await writeArtworkDirectory(
            pairingPath: pairingPath,
            sourceDirectory: backupDir,
            targetDirectory: targetDir,
            requireVerifiedManifestFor: allowIncompleteRecovery ? nil : cleanId,
            log: log
        )
    }

    /// Ensures an immutable, verified original-artwork backup exists before the first skin write.
    /// AirTraffic export is move-based, so successfully exported originals are absent from the
    /// card until the custom skin replaces them. Any failure rolls already-exported files back.
    nonisolated static func ensureOriginalArtworkBackup(
        cardId: String,
        pairingPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> OriginalArtworkBackupPreparation {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let validation = validateOriginalArtworkBackup(for: cleanId)
        if validation.isValid {
            log("  🗃️ Original artwork backup already exists and is verified")
            return .existing
        }
        if case .invalid(let reason) = validation {
            log("  ❌ Existing original-artwork backup is invalid: \(reason)")
            log("  ❌ Refusing to overwrite an unverified backup; use Recovery diagnostics")
            return .failed
        }

        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        let marker = originalArtworkBackupMarker(for: cleanId)
        let targetDir = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"

        let existingIncomplete = originalWalletArtworkLeaves.filter {
            FileManager.default.fileExists(atPath: backupDir.appendingPathComponent($0).path)
        }
        if !existingIncomplete.isEmpty {
            log("  ❌ An incomplete original-artwork recovery set already exists")
            log("  ❌ Refusing to overwrite it; open Recovery diagnostics for this card")
            return .failed
        }

        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: marker)
        } catch {
            log("  ❌ Cannot create original-artwork backup directory: \(error.localizedDescription)")
            return .failed
        }

        log("  🗃️ Backing up original Wallet artwork…")
        var backedUp: [String] = []

        for leaf in originalWalletArtworkLeaves {
            let devicePath = "\(targetDir)/\(leaf)"
            let localPath = backupDir.appendingPathComponent(leaf).path
            let result = await exportDeviceFile(
                pairingPath: pairingPath,
                devicePath: devicePath,
                outputPath: localPath,
                log: { line in
                    if line.contains("airlift-export:") { log("    " + line) }
                }
            )

            if result.ok {
                backedUp.append(leaf)
                log("    ✅ Preserved \(leaf)")
                continue
            }

            if artworkExportFailureKind(result.error) == .sourceMissing {
                log("    · Not present: \(leaf)")
                continue
            }

            log("    ❌ Backup failed at \(leaf): \(result.error ?? "unknown export error")")

            if !backedUp.isEmpty {
                log("  ↩️ Rolling back exported original artwork…")
                let rollback = await restoreOriginalArtworkBackupFiles(
                    cardId: cleanId,
                    pairingPath: pairingPath,
                    allowIncompleteRecovery: true,
                    log: { line in
                        if line.contains("airlift:") { log("    " + line) }
                    }
                )
                if rollback.ok {
                    log("  ✅ Original artwork rollback completed")
                } else {
                    log("  ❌ Original artwork rollback failed: \(rollback.error ?? "unknown write error")")
                    log("  ⚠️ Recovery files retained locally")
                }
            }
            return .failed
        }

        guard !backedUp.isEmpty else {
            log("  ❌ No original Wallet artwork files could be preserved; skin write cancelled")
            return .failed
        }

        do {
            let manifest = try finalizeOriginalArtworkBackup(cardId: cleanId, directory: backupDir)
            let verified = validateOriginalArtworkBackup(for: cleanId)
            guard verified.isValid else {
                throw NSError(
                    domain: "AirCardOriginalArtwork",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: verified.message]
                )
            }
            log("  ✅ Original artwork backup saved and verified (\(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s"))")
            return .created
        } catch {
            log("  ❌ Could not finalize original-artwork backup: \(error.localizedDescription)")
            let rollback = await restoreOriginalArtworkBackupFiles(
                cardId: cleanId,
                pairingPath: pairingPath,
                allowIncompleteRecovery: true,
                log: { _ in }
            )
            if !rollback.ok {
                log("  ❌ Rollback also failed: \(rollback.error ?? "unknown write error")")
                log("  ⚠️ Incomplete original files retained for Recovery diagnostics")
            }
            return .failed
        }
    }

    nonisolated static func invalidateWalletCardCaches(
        cardId: String,
        pairingPath: String
    ) async {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlift_restore_inv_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: stageDir.appendingPathComponent(leaf))
        }

        for ext in [".cache", ".pkcache"] {
            let cacheTarget = "/var/mobile/Library/Passes/Cards/\(cleanId)\(ext)"
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var outError: UnsafeMutablePointer<CChar>? = nil
                    _ = pairingPath.withCString { pairC in
                        stageDir.path.withCString { sourceC in
                            cacheTarget.withCString { targetC in
                                al_exploit_write_dir(pairC, sourceC, targetC, nil, nil, &outError)
                            }
                        }
                    }
                    if let p = outError { al_string_free(p) }
                    continuation.resume()
                }
            }
        }
        try? FileManager.default.removeItem(at: stageDir)
    }

    /// Legacy non-exact restore entry point retained for compatibility. New UI uses exact restore.
    func restoreOriginalArtwork(for cardId: String) {
        restoreOriginalArtworkExactly(for: cardId)
    }
}
