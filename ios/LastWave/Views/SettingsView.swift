import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var lastFm: LastFm

    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var loginError: String?
    @State private var confirmClearHistory = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Autoplay similar songs", isOn: $player.autoplay)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("When the queue ends, keep playing YouTube Music's radio for the last song.")
                }

                lastFmSection

                Section("Library") {
                    Button("Clear listening history", role: .destructive) {
                        confirmClearHistory = true
                    }
                    .disabled(library.recent.isEmpty)
                    .confirmationDialog("Clear listening history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                        Button("Clear history", role: .destructive) { library.clearHistory() }
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    Link("LastWave on GitHub", destination: URL(string: "https://github.com/Clash-Projects/LastWave-Native")!)
                    Link("Lyrics by LRCLIB", destination: URL(string: "https://lrclib.net")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Unofficial client. Not affiliated with YouTube, Google or Last.fm.")
                }
            }
            .navigationTitle("Settings")
            .withMiniPlayer()
        }
    }

    @ViewBuilder
    private var lastFmSection: some View {
        Section {
            if lastFm.isConnected {
                LabeledContent("Signed in as", value: lastFm.username ?? "")
                Toggle("Scrobble plays", isOn: $lastFm.scrobblingEnabled)
                Button("Sign out", role: .destructive) { lastFm.logout() }
            } else {
                TextField("API key", text: $lastFm.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Shared secret", text: $lastFm.apiSecret)
                TextField("Last.fm username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if let loginError {
                    Text(loginError).foregroundStyle(.red).font(.footnote)
                }
                Button {
                    Task { await login() }
                } label: {
                    if isLoggingIn {
                        ProgressView()
                    } else {
                        Text("Connect Last.fm")
                    }
                }
                .disabled(isLoggingIn || username.isEmpty || password.isEmpty || lastFm.apiKey.isEmpty || lastFm.apiSecret.isEmpty)
            }
        } header: {
            Text("Last.fm")
        } footer: {
            if !lastFm.isConnected {
                Text("Create a free API account at last.fm/api/account/create to get a key and secret. Your password is only sent to Last.fm to get a session and is not stored.")
            }
        }
    }

    private func login() async {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            try await lastFm.login(username: username, password: password)
            password = ""
        } catch {
            loginError = error.localizedDescription
        }
    }
}
