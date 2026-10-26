import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
                ForEach(results) { track in
                    TrackRow(track: track) { player.playRadio(from: track) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if isSearching && results.isEmpty {
                    ProgressView()
                } else if results.isEmpty && errorMessage == nil {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: query.isEmpty ? "Search YouTube Music" : "No results",
                        message: query.isEmpty ? "Songs, artists, albums — anything." : "Try a different search."
                    )
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs or artists")
            .autocorrectionDisabled()
            .task(id: query) {
                // Debounce typing; `.task(id:)` cancels the previous run.
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
            .withMiniPlayer()
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await InnerTube.shared.searchSongs(text)
            guard !Task.isCancelled else { return }
            results = found
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
