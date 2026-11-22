import SwiftUI

/// The open PDFs as tabs under the tool bar. Tap a tab to switch to it; hold a tab and drag it onto
/// the page to show it beside the current one; + opens another PDF in a new tab.
struct TabBar: View {
    let onNewTab: () -> Void
    let onCloseLast: () -> Void
    private var state: PresentationState { PresentationState.shared }

    var body: some View {
        HStack(spacing: 6) {
            // Tabs slide sideways when there are more than fit; the bar itself never gets wider than the screen.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.tabs) { tab in
                            TabChip(tab: tab, onCloseLast: onCloseLast)
                                .id(tab.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(state.currentTabID, anchor: .center) }
                .onChange(of: state.currentTabID) { _, id in
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.callout.weight(.semibold))
                    .frame(width: 30, height: 28)
            }
            .help("Open another PDF in a new tab")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.barBackground)
    }
}

struct TabChip: View {
    let tab: OpenTab
    @State private var dropTarget = false
    let onCloseLast: () -> Void
    private var state: PresentationState { PresentationState.shared }

    /// Long names are shortened in the middle, so the start and the end (often a lecture number) stay.
    private var shortTitle: String { Self.shorten(tab.title, to: 26) }

    static func shorten(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        let half = (length - 1) / 2
        return "\(text.prefix(half))…\(text.suffix(half))"
    }

    /// Marks a drag as one of Podium's tabs (anything else dropped on the page is ignored).
    static let dragPrefix = "podium-tab:"

    var body: some View {
        let isCurrent = tab.id == state.currentTabID
        let isBeside = tab.id == state.besideTabID
        let isActive = (isCurrent && !state.activeIsSecondary) || (isBeside && state.activeIsSecondary)
        HStack(spacing: 6) {
            if state.loadingTabID == tab.id {
                ProgressView().controlSize(.mini)
            } else if isBeside {
                Image(systemName: "rectangle.split.2x1").font(.caption)
            }
            HStack(spacing: 3) {
                if let folder = tab.folder {
                    Text(Self.shorten(folder, to: 16) + " /")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // The tab on screen shows its whole name; the others are shortened.
                Text(isCurrent || isBeside ? tab.title : shortTitle)
                    .font(.callout)
            }
            .lineLimit(1)
            .fixedSize()
            Button {
                withAnimation(.snappy) {
                    if !state.closeTab(tab) { onCloseLast() }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(isCurrent || isBeside ? Color.primary : Color.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(minHeight: 28)
        .background(isActive ? Color.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if isCurrent || isBeside {
                RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(isActive ? 0.8 : 0.35), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { withAnimation(.snappy) { state.select(tab) } }
        // Hold any tab, then drag it onto another tab to reorder, or (if it isn't on screen) onto the page to
        // show it side by side. System drag and drop, so swiping sideways still scrolls the tab strip.
        .modifier(TabDrag(tab: tab))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first(where: { $0.hasPrefix(TabChip.dragPrefix) })?.dropFirst(TabChip.dragPrefix.count)
            else { return false }
            withAnimation(.snappy) { state.moveTab(String(id), to: tab) }
            return true
        } isTargeted: { dropTarget = $0 }
        .overlay(alignment: .leading) {
            if dropTarget {
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 2).offset(x: -4)
            }
        }
        .help(isCurrent || isBeside ? (tab.place ?? tab.title) : "Tap to switch; hold and drag to reorder, or onto the page to show it side by side")
    }
}

/// Shown over the page while a tab is dragged over it.
struct TabDropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3))
            .overlay {
                Label("Release to show side by side", systemImage: "rectangle.split.2x1")
                    .font(.headline)
                    .padding(14)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}

/// Lets a tab be lifted (hold, then drag): onto another tab to reorder, onto the page to show it side by side.
private struct TabDrag: ViewModifier {
    let tab: OpenTab

    func body(content: Content) -> some View {
        content.draggable(TabChip.dragPrefix + tab.id) {
            Text(tab.title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        }
    }
}
