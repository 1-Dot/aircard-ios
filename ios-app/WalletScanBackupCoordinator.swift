import SwiftUI

/// Coordinates the first-scan immutable backup without changing the preview reader's
/// move-and-write-back transaction. The preview/identity scan is allowed to complete
/// first, but a missing preview must never prevent preservation of the raw artwork.
struct WalletScanBackupRootView: View {
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var operationStore = WalletCardOperationStore.shared
    @State private var backupStartedForCards: Set<String> = []

    var body: some View {
        AirCardFeatureRootView()
            .onChange(of: operationStore.phases) { _, phases in
                for (cardId, phase) in phases {
                    let previewAttemptFinished: Bool

                    switch phase {
                    case .ready(let label):
                        previewAttemptFinished = label.contains("Artwork loaded")
                    case .failed(let label):
                        previewAttemptFinished = label.contains("Wallet preview unavailable")
                    default:
                        previewAttemptFinished = false
                    }

                    guard previewAttemptFinished,
                          !backupStartedForCards.contains(cardId) else {
                        continue
                    }

                    let cleanId = CardItem.cleanCardId(cardId) ?? cardId

                    // If the preview reader retained a recovery copy, do not start a
                    // second move-based transaction until the first one is repaired.
                    // A normal "preview unavailable" result with no pending recovery
                    // still proceeds to immutable backup creation.
                    guard AppViewModel.walletRecoveryItems(for: cleanId).isEmpty else {
                        WalletCardOperationStore.shared.set(
                            .failed("Preview recovery required before original backup"),
                            for: cleanId
                        )
                        continue
                    }

                    backupStartedForCards.insert(cleanId)
                    vm.preserveFirstDetectedArtworkAfterScan(for: cleanId)
                }
            }
            .onChange(of: vm.cards.map(\.id)) { _, ids in
                let current = Set(ids.map { CardItem.cleanCardId($0) ?? $0 })
                backupStartedForCards = backupStartedForCards.intersection(current)
            }
    }
}

extension AppViewModel {
    /// Captures a best-effort Wallet-rendered reference and then creates/verifies the
    /// authoritative immutable raw-artwork backup. The two stores have different jobs:
    ///
    /// - RenderedReferences = what Wallet appears to render, when a decodable cache
    ///   entry is available. This is display/reproduction evidence only.
    /// - Originals = exact provider files used by Restore Original.
    ///
    /// Failure or absence of a rendered reference never prevents the raw backup.
    func preserveFirstDetectedArtworkAfterScan(for cardId: String) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        guard hasPairingFile else {
            WalletCardOperationStore.shared.set(.failed("Pairing required for original backup"), for: cleanId)
            return
        }

        let pairingPath = PairingController.pairingFilePath()
        WalletCardOperationStore.shared.set(.backingUp("Checking Wallet-rendered face…"), for: cleanId)
        scanStatusText = "Found card: \(cleanId.prefix(12))… Checking rendered Wallet face…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let rendered = await Self.captureRenderedWalletReference(
                cardId: cleanId,
                pairingPath: pairingPath
            )

            await MainActor.run {
                guard let self else { return }
                switch rendered {
                case .captured(let manifest):
                    self.log.append(
                        "🎨 Wallet-rendered reference captured for \(cleanId.prefix(12))… " +
                        "from \(manifest.cacheSuffix)/\(manifest.leaf) " +
                        "(\(manifest.pixelWidth)×\(manifest.pixelHeight), \(manifest.byteCount) bytes)"
                    )
                    WalletCardOperationStore.shared.set(
                        .backingUp("Rendered face captured · preserving original…"),
                        for: cleanId
                    )
                case .unavailable(let attempted, let detail):
                    var line = "ℹ️ No directly decodable Wallet-rendered reference found for \(cleanId.prefix(12))… after \(attempted) cache candidates"
                    if let detail { line += ": \(detail)" }
                    self.log.append(line)
                    WalletCardOperationStore.shared.set(
                        .backingUp("Rendered face unavailable · preserving original…"),
                        for: cleanId
                    )
                case .unsafe(let error):
                    self.log.append(
                        "⚠️ Wallet-rendered reference probe stopped: \(error). " +
                        "Immutable raw backup will continue."
                    )
                    WalletCardOperationStore.shared.set(
                        .backingUp("Rendered probe stopped · preserving original…"),
                        for: cleanId
                    )
                }
                self.objectWillChange.send()
            }

            // The rendered-reference probe is deliberately non-authoritative. Always
            // continue into raw backup validation/creation regardless of its result.
            let existing = Self.validateOriginalArtworkBackup(for: cleanId)
            if existing.isValid {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.ready("Artwork + original backup verified ✅"), for: cleanId)
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Original backup verified ✅"
                    self.objectWillChange.send()
                }
                return
            }

            if case .invalid(let reason) = existing {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.failed("Existing backup needs recovery"), for: cleanId)
                    self.log.append("❌ Cannot create scan backup for \(cleanId.prefix(12)): \(reason)")
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                WalletCardOperationStore.shared.set(.backingUp("Preserving first-detected artwork…"), for: cleanId)
                self.scanStatusText = "Found card: \(cleanId.prefix(12))… Saving original artwork…"
            }

            let preparation = await Self.ensureOriginalArtworkBackup(
                cardId: cleanId,
                pairingPath: pairingPath,
                log: { line in
                    DispatchQueue.main.async {
                        AppViewModel.shared?.log.append(line)
                    }
                }
            )

            guard preparation.isReady else {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.failed("Original backup failed"), for: cleanId)
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Original backup failed"
                    self.errorMessage = "The card was scanned, but its first-detected artwork could not be preserved safely."
                }
                return
            }

            if preparation.movedOriginalFiles {
                await MainActor.run {
                    WalletCardOperationStore.shared.set(.restoring("Writing first-detected artwork back to Wallet…"), for: cleanId)
                }

                var restore: (ok: Bool, error: String?) = (false, nil)
                for attempt in 0..<2 {
                    restore = await Self.restoreOriginalArtworkBackupFiles(
                        cardId: cleanId,
                        pairingPath: pairingPath,
                        log: { line in
                            DispatchQueue.main.async {
                                AppViewModel.shared?.log.append("    " + line)
                            }
                        }
                    )
                    if restore.ok { break }
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }

                guard restore.ok else {
                    await MainActor.run {
                        guard let self else { return }
                        WalletCardOperationStore.shared.set(.failed("Backup saved; Wallet write-back failed"), for: cleanId)
                        self.scanStatusText = "Found card: \(cleanId.prefix(12))… Write-back failed"
                        self.errorMessage = "The original artwork backup is safely stored, but AirCard could not write the moved artwork back to Wallet. Use Restore Original or Recovery Diagnostics before flashing this card."
                    }
                    return
                }
            }

            let verified = Self.validateOriginalArtworkBackup(for: cleanId)
            guard verified.isValid else {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.failed("Original backup verification failed"), for: cleanId)
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Backup verification failed"
                    self.errorMessage = "The scan completed, but the original-artwork backup did not pass integrity verification."
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                WalletCardOperationStore.shared.set(.ready("Artwork + original backup saved ✅"), for: cleanId)
                self.scanStatusText = "Found card: \(cleanId.prefix(12))… Original artwork saved ✅"
                self.log.append("✅ First-detected Wallet artwork preserved and verified for \(cleanId.prefix(12))…")
                self.objectWillChange.send()
            }
        }
    }
}
