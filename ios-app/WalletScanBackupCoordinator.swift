import SwiftUI

/// Coordinates the first-scan immutable backup without changing the preview reader's
/// move-and-write-back transaction. The preview/identity scan completes first; only
/// then is the exact raw artwork set preserved and restored.
struct WalletScanBackupRootView: View {
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var operationStore = WalletCardOperationStore.shared
    @State private var backupStartedForCards: Set<String> = []

    var body: some View {
        AirCardFeatureRootView()
            .onChange(of: operationStore.phases) { _, phases in
                guard vm.isScanningCards else { return }

                for (cardId, phase) in phases {
                    guard case .ready(let label) = phase,
                          label.contains("Artwork loaded"),
                          !backupStartedForCards.contains(cardId) else {
                        continue
                    }

                    backupStartedForCards.insert(cardId)
                    vm.preserveFirstDetectedArtworkAfterScan(for: cardId)
                }
            }
            .onChange(of: vm.cards.map(\.id)) { _, ids in
                let current = Set(ids.map { CardItem.cleanCardId($0) ?? $0 })
                backupStartedForCards = backupStartedForCards.intersection(current)
            }
    }
}

extension AppViewModel {
    /// Creates the authoritative immutable backup immediately after the first successful
    /// scan/preview transaction. `ensureOriginalArtworkBackup` is move-based, so when it
    /// creates a new backup this method writes the exact raw files straight back to Wallet
    /// before declaring the scan complete.
    func preserveFirstDetectedArtworkAfterScan(for cardId: String) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        guard hasPairingFile else {
            WalletCardOperationStore.shared.set(.failed("Pairing required for original backup"), for: cleanId)
            return
        }

        let existing = Self.validateOriginalArtworkBackup(for: cleanId)
        if existing.isValid {
            WalletCardOperationStore.shared.set(.ready("Artwork + original backup verified ✅"), for: cleanId)
            scanStatusText = "Found card: \(cleanId.prefix(12))… Original backup verified ✅"
            objectWillChange.send()
            return
        }

        if case .invalid(let reason) = existing {
            WalletCardOperationStore.shared.set(.failed("Existing backup needs recovery"), for: cleanId)
            log.append("❌ Cannot create scan backup for \(cleanId.prefix(12)): \(reason)")
            return
        }

        let pairingPath = PairingController.pairingFilePath()
        WalletCardOperationStore.shared.set(.backingUp("Preserving first-detected artwork…"), for: cleanId)
        scanStatusText = "Found card: \(cleanId.prefix(12))… Saving original artwork…"

        Task.detached(priority: .userInitiated) { [weak self] in
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
