import SwiftUI
import AppKit

struct ScriptReviewView: View {
    @ObservedObject var library: LibraryStore
    let wallpaper: Wallpaper
    @Environment(\.dismiss) private var dismiss
    @State private var review: SceneScriptReview?
    @State private var selected: String?
    @State private var search = ""
    @State private var acknowledged = false
    @State private var approving = false
    @State private var approvalTask: Task<Void, Never>?
    @State private var message: String?
    private var source: SceneScriptSource? { review?.sources.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Review SceneScript").font(.title2.bold())
                    Text(wallpaper.title).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Source review", systemImage: "doc.text.magnifyingglass").font(.caption).foregroundStyle(.secondary)
            }
            Text("Read the scene’s source before approving it. Approval applies to all SceneScript in this wallpaper and leaves scripts off. Use the separate Run SceneScript toggle when ready.")
                .font(.callout).foregroundStyle(.secondary)
            if let review {
                if !review.issues.isEmpty {
                    DisclosureGroup("Review incomplete — approval unavailable") {
                        ScrollView { Text(review.issues.joined(separator: "\n\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
                    }.foregroundStyle(.orange)
                }
                if review.sources.isEmpty {
                    ContentUnavailableView("No SceneScript found", systemImage: "doc.text.magnifyingglass", description: Text("No readable script sources were found in this project. SceneScript will remain disabled."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        List(selection: $selected) {
                            ForEach(review.sources) { script in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(script.file).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                    Text(script.location).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                                }.padding(.vertical, 4).tag(script.id)
                            }
                        }.frame(minWidth: 200, idealWidth: 250, maxWidth: 310)
                        VStack(alignment: .leading, spacing: 10) {
                            if let source {
                                Text(source.file).font(.caption.bold()).textSelection(.enabled)
                                Text(source.location).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack {
                                    TextField("Find in this script", text: $search).textFieldStyle(.roundedBorder)
                                    Button("Copy Source") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.code, forType: .string) }
                                }
                                ScriptSourceReader(source: source.code, search: search)
                                    .accessibilityLabel("SceneScript source code")
                            } else { Text("Select a script to read its source.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }.padding(12).frame(minWidth: 400, maxWidth: .infinity)
                    }.frame(maxHeight: .infinity).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text("\(review.sources.count) script source\(review.sources.count == 1 ? "" : "s") · Includes inline JSON scripts and script files in the project and its packages.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("I have reviewed and approve these scripts.", isOn: $acknowledged)
                        .font(.callout).disabled(!review.canApprove || approving)
                }
            } else if message == nil {
                ProgressView("Reading scene source…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer() }
            if let message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { approvalTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if approving { ProgressView().controlSize(.small) }
                Button("Approve Scripts") { approve() }
                    .buttonStyle(.borderedProminent)
                    .disabled(review?.canApprove != true || !acknowledged || approving)
            }
        }.padding(24).frame(width: 940, height: 680)
        .task {
            do {
                let folder = library.folder(wallpaper)
                let loaded = try await Task.detached(priority: .userInitiated) { try SceneScriptReview.inspect(folder: folder) }.value
                try Task.checkCancellation()
                review = loaded; selected = loaded.sources.first?.id
            } catch is CancellationError {} catch { message = error.localizedDescription }
        }
        .onDisappear { approvalTask?.cancel() }
    }
    private func approve() {
        guard let review, review.canApprove, acknowledged, !approving else { return }
        approving = true; message = nil
        approvalTask = Task { @MainActor in
            defer { approving = false }
            do {
                // Re-read before saving consent; changing files while the reader
                // is open requires a fresh review of the changed source.
                let folder = library.folder(wallpaper)
                let current = try await Task.detached(priority: .userInitiated) { try SceneScriptReview.inspect(folder: folder) }.value
                try Task.checkCancellation()
                guard current.canApprove, current.fingerprint == review.fingerprint else {
                    self.review = current; selected = current.sources.first?.id; acknowledged = false
                    message = "The scene source changed or could not be fully read. Review the current source before approving."
                    return
                }
                guard library.state.wallpapers.contains(where: { $0.id == wallpaper.id }) else { message = "This wallpaper is no longer in your library."; return }
                library.edit(wallpaper.id) { $0.scriptApprovalFingerprint = current.fingerprint; $0.trustedScripts = false }
                dismiss()
            } catch is CancellationError {} catch { message = error.localizedDescription; acknowledged = false }
        }
    }
}

private struct ScriptSourceReader: NSViewRepresentable {
    let source: String
    let search: String
    final class Coordinator { var source = ""; var search = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize; text.textContainer?.widthTracksTextView = false
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let sourceChanged = context.coordinator.source != source
        guard sourceChanged || context.coordinator.search != search else { return }
        if sourceChanged { text.string = source; text.scrollToBeginningOfDocument(nil) }
        context.coordinator.source = source; context.coordinator.search = search
        let string = source as NSString
        text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: string.length))
        guard !search.isEmpty else { return }
        var remaining = NSRange(location: 0, length: string.length)
        var first: NSRange?
        for _ in 0..<2000 {
            let match = string.range(of: search, options: [.caseInsensitive], range: remaining)
            guard match.location != NSNotFound else { break }
            if first == nil { first = match }
            text.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: match)
            remaining = NSRange(location: NSMaxRange(match), length: string.length - NSMaxRange(match))
        }
        if let first { text.scrollRangeToVisible(first) }
    }
}
