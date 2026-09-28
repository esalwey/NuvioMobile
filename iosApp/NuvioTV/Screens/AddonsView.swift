import SwiftUI
import SharedCore

/// Add-ons manager. Paste a Stremio-compatible manifest URL (e.g. your TorBox or Torrentio addon URL
/// with your debrid key embedded) to install a streaming source, then manage installed addons.
struct AddonsView: View {
    @StateObject private var model = AddonsViewModel()
    @State private var newUrl = ""
    /// Addon pending a remove confirmation (drives the alert below).
    @State private var addonPendingRemoval: ManagedAddon?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    installSection
                        .focusSection()
                    installedSection
                        .focusSection()
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .reportsScrollToTabBar(tab: "Add-ons")
            // FEAT-30: Menu summons the sidebar in sidebar mode (a second Menu, with focus in the
            // sidebar, exits as before). No modifier at all in tabs mode.
            .sidebarMenuReveal()
            .navigationTitle("Add-ons")
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(
            "Remove \(addonPendingRemoval.map { model.displayName($0) } ?? "")?",
            isPresented: Binding(
                get: { addonPendingRemoval != nil },
                set: { if !$0 { addonPendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let addon = addonPendingRemoval { model.remove(addon) }
                addonPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its catalogs and streams will no longer appear.")
        }
    }

    @ViewBuilder
    private var installSection: some View {
        if model.managedByPrimary {
            // ADD-2: the shared repository ignores every change on this profile — say so instead
            // of offering controls that silently do nothing. Rows below stay focusable so a long
            // list can still be scrolled.
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text(model.managedByPrimaryMessage)
                        .font(Theme.Font.body)
                        .frame(maxWidth: 1200, alignment: .leading)
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .foregroundStyle(.secondary)
                if let status = model.statusMessage {
                    Text(status).font(Theme.Font.body).foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Install from manifest URL").font(Theme.Font.screenTitle)
                Text("Paste the manifest URL from your streaming addon's config page (e.g. your TorBox or Torrentio URL with your API key). It ends in /manifest.json.")
                    .font(Theme.Font.body).foregroundStyle(.secondary)
                    .frame(maxWidth: 1200, alignment: .leading)

                HStack(spacing: 16) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("https://\u{2026}/manifest.json", text: $newUrl)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.screenTitle.weight(.regular))
                }
                .padding(20)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 20) {
                    Button {
                        // ADD-3: the field is cleared only once the install succeeded, so a typo'd
                        // or unreachable URL can be fixed instead of retyped.
                        let submitted = newUrl
                        model.install(submitted) {
                            if newUrl == submitted { newUrl = "" }
                        }
                    } label: {
                        Label("Install", systemImage: "plus.circle.fill")
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstalling)

                    #if DEBUG
                    if DebugConfig.hasManifestURL {
                        Button {
                            model.install(DebugConfig.manifestURL)
                        } label: {
                            Label("Quick install (from DebugConfig)", systemImage: "wrench.and.screwdriver")
                                .padding(.horizontal, 16).padding(.vertical, 6)
                        }
                        .buttonStyle(.chip)
                        .disabled(model.isInstalling)
                    }
                    #endif

                    if model.isInstalling { ProgressView() }
                    if let status = model.statusMessage {
                        Text(status).font(Theme.Font.body).foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                    }
                }
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installed").font(Theme.Font.screenTitle)

            if model.addons.isEmpty {
                Text("No addons installed yet.").foregroundStyle(.secondary)
            }

            // ADD-3: identity by manifest URL (unique in the repository), not by position — a
            // removal or reorder no longer hands one row's state to its neighbour.
            ForEach(model.addons, id: \.manifestUrl) { addon in
                let errorMessage: String? = addon.errorMessage
                AddonRow(
                    title: model.displayName(addon),
                    subtitle: AddonsViewModel.maskedUrl(addon.manifestUrl),
                    enabled: addon.enabled,
                    isRefreshing: addon.isRefreshing,
                    errorMessage: addon.manifest == nil ? errorMessage : nil,
                    locked: model.managedByPrimary,
                    onToggle: { model.setEnabled(addon, !addon.enabled) },
                    onRetry: { model.retry(addon) },
                    onRemove: { addonPendingRemoval = addon }
                )
            }
        }
    }
}

/// A focusable add-on card. Select toggles enabled/disabled; long-press (context menu) removes.
private struct AddonRow: View {
    let title: String
    let subtitle: String
    let enabled: Bool
    /// ADD-3: manifest fetch in flight.
    var isRefreshing: Bool = false
    /// ADD-3: why the manifest failed to load (nil once it has loaded).
    var errorMessage: String? = nil
    /// ADD-2: the profile uses the main profile's add-ons — no toggle, no remove.
    var locked: Bool = false
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 24) {
                Image(systemName: errorMessage != nil ? "exclamationmark.triangle.fill" : (enabled ? "checkmark.circle.fill" : "circle"))
                    .font(Theme.Font.body)
                    .rowAccentTint(enabled && errorMessage == nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.Font.sectionTitle).lineLimit(1)
                    Text(subtitle).font(Theme.Font.caption).rowTextColor(secondary: true).lineLimit(1)
                    if let errorMessage {
                        Text(String(localized: "Couldn't load the manifest: \(errorMessage)"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if isRefreshing {
                    ProgressView()
                }
                if locked {
                    Image(systemName: "lock.fill")
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                }
                Text(enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
        .contextMenu {
            if errorMessage != nil {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            if !locked {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Add-on", systemImage: "trash")
                }
            }
        }
    }
}
