import SwiftUI
import PencilKit

struct PresenterView: View {
    @Bindable private var state = PresentationState.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var showOverview = false
    @State private var showPalettes = false
    @State private var showPointerOptions = false
    @State private var editingWidth: Int?
    @State private var confirmClearAll = false
    @State private var toolbarExpanded = true
    @State private var showAssistant = false
    @State private var showSidePicker = false
    @State private var confirmRemoveInsert = false
    @State private var showTabPicker = false
    @State private var tabOverPage = false
    /// Claude's prep notes under the slide (iPad only).
    @AppStorage("prep.showNotes") private var showPrepNotes = true

    var body: some View {
        VStack(spacing: 0) {
            // Both bars at the top, like Goodnotes, so a resting palm can't hit them.
            // Above the page, so a zoomed page that extends under them never takes their taps.
            topBar
                .zIndex(2)
            toolbar
                .background(Color.barBackground)
                .zIndex(2)
            TabBar(onNewTab: { showTabPicker = true }, onCloseLast: { dismiss() })
                .zIndex(3)
            if let deck = state.primary.deck {
                HStack(spacing: 0) {
                    DocumentArea(deck: deck, primaryOverlay: AnyView(Group {
                        if state.externalConnected && state.showNextPreview && !state.projectSecondary {
                            nextPreview(deck)
                        }
                    }))
                    .overlay {
                        if tabOverPage { TabDropHint() }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first(where: { $0.hasPrefix(TabChip.dragPrefix) })?
                                .dropFirst(TabChip.dragPrefix.count),
                              let tab = state.tabs.first(where: { $0.id == String(id) }) else { return false }
                        withAnimation(.snappy) { state.showBeside(tab) }
                        return true
                    } isTargeted: { tabOverPage = $0 }
                    if showAssistant {
                        AssistantPanel { withAnimation(.snappy) { showAssistant = false } }
                            .frame(width: 380)
                            .transition(.move(edge: .trailing))
                    }
                }
                if showPrepNotes && PrepStore.shared.hasNotes {
                    PrepNotesView(slide: deck.slideIndex(ofPage: state.primary.pageIndex))
                }
            }
        }
        .background(Color.stageBackground.ignoresSafeArea())
        .preferredColorScheme(state.appearance.scheme)
        .persistentSystemOverlays(.hidden)
        // Arrow keys, space and page up/down, so Bluetooth clickers and keyboards work.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.rightArrow, .downArrow, .space, .pageDown, .return]) { _ in
            guard !UIResponder.isEditingText else { return .ignored }
            state.next()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .upArrow, .pageUp]) { _ in
            guard !UIResponder.isEditingText else { return .ignored }
            state.previous()
            return .handled
        }
        .onKeyPress("b") {
            guard !UIResponder.isEditingText else { return .ignored }
            state.blackout.toggle()
            return .handled
        }
        .onKeyPress("w") {
            guard !UIResponder.isEditingText else { return .ignored }
            toggleWhiteboard()
            return .handled
        }
        .onAppear {
            focused = true
            #if DEBUG
            // Testing aid: `-PodiumShowAssistant YES` opens the Claude panel on launch.
            if UserDefaults.standard.bool(forKey: "PodiumShowAssistant") { showAssistant = true }
            // Testing aid: `-PodiumTestExport YES` builds the annotated PDF and opens the share sheet.
            if UserDefaults.standard.bool(forKey: "PodiumTestExport") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    Exporter.share(includePrepNotes: true)
                }
            }
            // Testing aid: `-PodiumTestTool eraser` starts with that tool.
            if let raw = UserDefaults.standard.string(forKey: "PodiumTestTool"), let tool = Tool(rawValue: raw) {
                state.tool = tool
            }
            // Testing aid: `-PodiumTestZoom 2.5` zooms into the top-left of the page.
            let testZoom = UserDefaults.standard.double(forKey: "PodiumTestZoom")
            if testZoom > 1 {
                state.zoom(by: testZoom, around: CGPoint(x: 0.1, y: 0.1))
                state.commitZoom()
            }
            #endif
        }
        .onChange(of: state.colorPaletteRequest) {
            withAnimation(.snappy) { toolbarExpanded = true }
            showPalettes = true
        }
        .confirmationDialog("Clear ink on every slide?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All Slides", role: .destructive) { state.clearAllInk() }
        } message: {
            Text("This also deletes the saved notes for this PDF's slides. The whiteboard is kept.")
        }
        .confirmationDialog("Remove this page?", isPresented: $confirmRemoveInsert, titleVisibility: .visible) {
            Button("Remove Page", role: .destructive) { state.active.removeCurrentInsert() }
        } message: {
            Text("The page and anything written on it will be deleted. This can't be undone. Your PDF itself is never changed.")
        }
        .sheet(isPresented: $showSidePicker) {
            SideDocumentPicker()
        }
        .sheet(isPresented: $showTabPicker) {
            SideDocumentPicker(asTab: true)
        }
        .sheet(isPresented: $showOverview) {
            if let deck = state.deck { OverviewSheet(deck: deck) }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }

            Button {
                showOverview = true
            } label: {
                Image(systemName: "square.grid.3x2")
            }

            Menu {
                Button("Blank Page After This Slide", systemImage: "doc") { state.active.insertBlankPage() }
                Button("Photo After This Slide…", systemImage: "photo") {
                    let doc = state.active
                    PhotoPicker.present { image in doc.insertPhoto(image) }
                }
                if state.active.currentInsert != nil {
                    Divider()
                    Button("Remove This Page…", systemImage: "trash", role: .destructive) { confirmRemoveInsert = true }
                }
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .help("Insert a blank page or a photo")

            Button {
                if state.secondary == nil {
                    showSidePicker = true
                } else {
                    withAnimation(.snappy) { state.closeSecondary() }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .frame(width: 36, height: 36)
                    .background(state.secondary != nil ? Color.selectedFill : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .help(state.secondary == nil ? "Open a second PDF side by side" : "Close the side document")

            Button {
                toggleScroll(state.active)
            } label: {
                Image(systemName: "scroll")
                    .frame(width: 36, height: 36)
                    .background(state.active.scrollMode ? Color.selectedFill : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .help("Continuous scrolling (for reading and notes)")

            if let position = state.slidePosition {
                HStack(spacing: 6) {
                    Text("Slide \(position.slide) of \(position.slideCount)")
                    if position.stepCount > 1 {
                        Text("step \(position.step)/\(position.stepCount)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout.monospacedDigit())
            }

            Spacer()

            if state.timerShown {
                Menu {
                    if state.timerRunning {
                        Button("Pause Timer", systemImage: "pause") { state.pauseTimer() }
                    } else {
                        Button("Start Timer", systemImage: "play") { state.startTimer() }
                    }
                    Button("Reset Timer", systemImage: "arrow.counterclockwise") { state.resetTimer() }
                    Button("Hide Timer", systemImage: "eye.slash") { state.timerShown = false }
                } label: {
                    ElapsedTimer(elapsed: state.timerElapsed, started: state.timerStarted)
                }
            }

            Button {
                state.blackout.toggle()
            } label: {
                Image(systemName: state.blackout ? "rectangle.fill" : "rectangle")
            }
            .help("Black out the projector (B)")

            Image(systemName: state.externalConnected ? "display" : "display.trianglebadge.exclamationmark")
                .foregroundStyle(state.externalConnected ? .green : .secondary)
                .help(state.externalConnected ? "Projector connected" : "No projector: the screen is mirrored")

            if PrepStore.shared.hasNotes {
                Button {
                    withAnimation(.snappy) { showPrepNotes.toggle() }
                } label: {
                    Image(systemName: "list.bullet.clipboard")
                        .frame(width: 36, height: 36)
                        .background(showPrepNotes ? Color.selectedFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .help("Show Claude's prep notes under the slide")
            }

            Button {
                withAnimation(.snappy) { showAssistant.toggle() }
            } label: {
                Image(systemName: "sparkles")
                    .frame(width: 36, height: 36)
                    .background(showAssistant ? Color.selectedFill : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .help("Ask Claude about this slide (only you see it)")

            Menu {
                Button("Share PDF with Ink", systemImage: "square.and.arrow.up") {
                    Exporter.share(includePrepNotes: false)
                }
                if PrepStore.shared.hasNotes {
                    Button("Share PDF with Ink + Prep Notes", systemImage: "doc.richtext") {
                        Exporter.share(includePrepNotes: true)
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }

            settingsMenu
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .frame(height: 48)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Keep ink across overlay steps", isOn: $state.inkFollowsSlide)
            Toggle("Draw with finger", isOn: $state.fingerDraws)
            Toggle("Show next step on iPad", isOn: $state.showNextPreview)
            Picker("Appearance", selection: $state.appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            Picker("Page tint (iPad only)", selection: $state.pageTint) {
                ForEach(PageTint.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Margins for notes", isOn: Binding(get: { state.active.margins },
                                                      set: { value in withAnimation(.snappy) { state.active.margins = value } }))
            Toggle("Show timer", isOn: $state.timerShown)
            Toggle("Save notes next to PDFs (linked folders)", isOn: $state.companionEnabled)
            Toggle("Pencil double-tap = next slide (pointer)", isOn: $state.pencilTapAdvances)
            Picker("Pen", selection: $state.penStyle) {
                ForEach(PenStyle.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Clear ink on every slide…", role: .destructive) { confirmClearAll = true }
        } label: {
            Image(systemName: "gearshape")
        }
    }

    private func nextPreview(_ deck: Deck) -> some View {
        let next = state.primary.pageIndex + 1
        return Group {
            if next < deck.pageCount {
                PageImage(deck: deck, page: next, width: 260)
                    .aspectRatio(deck.pageSize(next), contentMode: .fit)
                    .frame(width: 260)
                    .overlay(alignment: .topLeading) {
                        Text("Next")
                            .font(.caption2.bold())
                            .padding(4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 8)
                    .padding(20)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 9) {
            HoldButton(systemImage: "backward.fill", label: "Previous slide",
                       tap: { state.previousSlide() },
                       holdStart: { state.startSeeking(forward: false) },
                       holdEnd: { state.stopSeeking() })
            Button { state.previous() } label: { Image(systemName: "chevron.left") }

            if toolbarExpanded {
                Divider().frame(height: 28)

                ForEach(Tool.allCases) { tool in
                    Button {
                        state.tool = tool
                    } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 40, height: 40)
                            .background(state.tool == tool ? Color.selectedFill : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                Divider().frame(height: 28)

                switch state.tool {
                case .pen, .highlighter:
                    colorDots
                    Divider().frame(height: 28)
                    widthDots
                case .pointer:
                    pointerStyles
                    Divider().frame(height: 28)
                    colorDots
                    pointerOptionsButton
                case .eraser:
                    eraserControls
                }

                Spacer(minLength: 0)

                Button { state.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                Button { state.clearInk() } label: { Image(systemName: "trash") }

                Button {
                    toggleWhiteboard()
                } label: {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        .frame(width: 40, height: 40)
                        .background(state.whiteboardShown ? Color.selectedFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .help("Whiteboard (W)")

                Button {
                    showPalettes = true
                } label: {
                    Image(systemName: "paintpalette")
                }
                .popover(isPresented: $showPalettes) {
                    PalettePicker()
                }
            } else {
                Spacer()
            }

            Button {
                withAnimation(.snappy) { toolbarExpanded.toggle() }
            } label: {
                Image(systemName: toolbarExpanded ? "chevron.up" : "chevron.down")
            }

            Button { state.next() } label: { Image(systemName: "chevron.right") }
            HoldButton(systemImage: "forward.fill", label: "Next slide",
                       tap: { state.nextSlide() },
                       holdStart: { state.startSeeking(forward: true) },
                       holdEnd: { state.stopSeeking() })
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    private func toggleWhiteboard() {
        withAnimation(.snappy) { state.whiteboardShown.toggle() }
    }

    /// The active tool's palette colours, then the user's own, then "+" (the system colour
    /// picker, whose eyedropper can sample any colour on screen). Long-press a custom colour to remove it.
    private var colorDots: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    let paletteCount = state.paletteColors.count
                    ForEach(Array(state.currentColors.enumerated()), id: \.offset) { index, color in
                        if index >= paletteCount {
                            colorDot(color, index: index)
                                .contextMenu {
                                    Button("Remove Colour", systemImage: "trash", role: .destructive) {
                                        state.removeCustomColor(at: index - paletteCount)
                                    }
                                }
                        } else {
                            colorDot(color, index: index)
                        }
                    }
                }
                .padding(6)
            }
            .frame(minWidth: 70, maxWidth: 470)   // room for the nine Podium colours in landscape
            .fixedSize(horizontal: false, vertical: true)

            ColorPicker("Add colour", selection: Binding(
                get: { Color(uiColor: state.currentColor) },
                set: { state.pickColor(UIColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Add a colour. The eyedropper in the picker samples any colour on screen.")
        }
    }

    private func colorDot(_ color: UIColor, index: Int) -> some View {
        Button {
            state.currentColorIndex = index
        } label: {
            Circle()
                .fill(Color(uiColor: color))
                .frame(width: 28, height: 28)
                .overlay {
                    Circle()
                        .stroke(Color.primary, lineWidth: index == state.currentColorIndex ? 3 : 0)
                        .padding(-4)
                }
        }
    }

    /// Whole-stroke or partial erasing, and the eraser's size in points.
    private var eraserControls: some View {
        HStack(spacing: 8) {
            Picker("Eraser", selection: $state.eraserPartial) {
                Text("Strokes").tag(false)
                Text("Partial").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            // Only the partial eraser has a size. Flexible, so the bar still fits in portrait.
            if state.eraserPartial {
                Slider(value: Binding(get: { min(max(state.eraserWidth, PresentationState.eraserWidths.lowerBound),
                                                 PresentationState.eraserWidths.upperBound) },
                                      set: { state.eraserWidth = $0 }),
                       in: PresentationState.eraserWidths, step: 1)
                    .frame(minWidth: 60, maxWidth: 150)
                Text("\(Int(min(max(state.eraserWidth, PresentationState.eraserWidths.lowerBound), PresentationState.eraserWidths.upperBound))) pt")
                    .font(.callout.monospacedDigit())
                    .fixedSize()
            }
        }
    }

    private var pointerOptionsButton: some View {
        Button {
            showPointerOptions = true
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .popover(isPresented: $showPointerOptions) {
            PointerOptions()
        }
    }

    /// Three width presets. Tap the selected one again (or long-press any) to fine-tune it.
    private var widthDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                let diameter = dotDiameter(state.currentWidths[index])
                Circle()
                    .fill(Color(uiColor: state.currentColor))
                    .frame(width: diameter, height: diameter)
                    .frame(width: 32, height: 32)
                    .background(state.widthIndex == index ? Color.selectedFill : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if state.widthIndex == index { editingWidth = index } else { state.widthIndex = index }
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        state.widthIndex = index
                        editingWidth = index
                    }
                    .popover(isPresented: Binding(get: { editingWidth == index },
                                                  set: { if !$0 { editingWidth = nil } })) {
                        WidthEditor(preset: index)
                    }
                    .accessibilityLabel("Width \(index + 1)")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    /// Dot size on a log scale across the tool's width range, so the dots compare like the strokes do.
    private func dotDiameter(_ width: CGFloat) -> CGFloat {
        4 + 20 * WidthEditor.position(of: width, in: state.widthRange)
    }

    private var pointerStyles: some View {
        Picker("Pointer", selection: $state.pointerStyle) {
            ForEach(PointerStyle.allCases) { style in
                Label(style.title, systemImage: style.symbol).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 270)
    }
}

struct PalettePicker: View {
    var body: some View {
        let state = PresentationState.shared
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.palettes) { palette in
                Button {
                    state.selectPalette(palette)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(palette.name).font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                ForEach(Array(palette.inks.enumerated()), id: \.offset) { _, color in
                                    Circle().fill(Color(uiColor: color)).frame(width: 20, height: 20)
                                }
                                Divider().frame(height: 16)
                                ForEach(Array(palette.highlighters.enumerated()), id: \.offset) { _, color in
                                    RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: color)).frame(width: 14, height: 20)
                                }
                                Divider().frame(height: 16)
                                Circle().fill(Color(uiColor: palette.pointer)).frame(width: 12, height: 12)
                            }
                        }
                        Spacer()
                        if palette.id == state.palette.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Text("Tip: the colour well at the end of the colour row opens the picker. Its eyedropper samples any colour on screen, such as your slide's.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 6)
        }
        .padding(12)
        .frame(width: 380)
    }
}

/// Fine control over one width preset: a log-scale slider and a preview stroke drawn by PencilKit
/// in the current colour and pen style.
struct WidthEditor: View {
    let preset: Int
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let state = PresentationState.shared
        let range = state.widthRange
        let width = state.currentWidths[preset]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.tool == .highlighter ? "Highlighter width" : "\(state.penStyle.title) width")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Reset") { state.resetWidths() }
                    .font(.subheadline)
            }
            // All three sizes in points; the one being edited is highlighted.
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Text(String(format: "%.1f pt", state.points(forWidth: state.currentWidths[index])))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == preset ? Color.selectedFill : .clear, in: Capsule())
                        .foregroundStyle(index == preset ? Color.primary : Color.secondary)
                }
            }
            Image(uiImage: preview(width: width))
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            Slider(value: Binding(get: { Self.position(of: width, in: range) },
                                  set: { state.setWidth(Self.width(at: $0, in: range), preset: preset) }))
        }
        .padding(16)
        .frame(width: 320)
    }

    /// 0...1 slider position for a width, on a log scale.
    static func position(of width: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        let clamped = min(max(width, range.lowerBound), range.upperBound)
        return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    static func width(at position: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound * pow(range.upperBound / range.lowerBound, position)
    }

    /// A short wave rendered with the real ink at the width it would have on the slide.
    private func preview(width: CGFloat) -> UIImage {
        let state = PresentationState.shared
        let size = CGSize(width: 288, height: 70)
        let points = state.points(forWidth: width)
        let samples = (0...60).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 60
            let location = CGPoint(x: 20 + t * (size.width - 40), y: size.height / 2 + sin(t * .pi * 2) * 16)
            return PKStrokePoint(location: location, timeOffset: TimeInterval(t), size: CGSize(width: points, height: points),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(state.inkType, color: state.currentColor),
                              path: PKStrokePath(controlPoints: samples, creationDate: .now))
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: [stroke]).image(from: CGRect(origin: .zero, size: size), scale: displayScale)
        }
        return image
    }
}

/// Pointer settings that don't need to sit in the toolbar.
struct PointerOptions: View {
    var body: some View {
        let state = PresentationState.shared
        let pointer = state.primary.pointer
        // One setting for both sides when a second document is open.
        let trail = Binding(get: { pointer.trailLife },
                            set: { value in
                                pointer.trailLife = value
                                state.secondary?.pointer.trailLife = value
                            })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trail length")
                Spacer()
                Text(String(format: "%.1f s", pointer.trailLife))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: trail, in: PointerState.trailRange, step: 0.1)
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// A toolbar button that acts once on tap and calls `holdStart`/`holdEnd` when held.
struct HoldButton: View {
    let systemImage: String
    let label: String
    let tap: () -> Void
    let holdStart: () -> Void
    let holdEnd: () -> Void

    @State private var pressed = false
    @State private var holding = false
    @State private var holdTimer: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(Color.accentColor)
            .frame(width: 36, height: 40)
            .contentShape(Rectangle())
            .opacity(pressed ? 0.5 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        holdTimer = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            holding = true
                            holdStart()
                        }
                    }
                    .onEnded { _ in
                        holdTimer?.cancel()
                        if holding { holdEnd() } else { tap() }
                        holding = false
                        pressed = false
                    }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
    }
}

/// Time so far: `elapsed` from earlier runs plus the current run since `started`. Dimmed while paused.
struct ElapsedTimer: View {
    let elapsed: TimeInterval
    let started: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = elapsed + (started.map { context.date.timeIntervalSince($0) } ?? 0)
            let seconds = max(0, Int(total))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .monospacedDigit()
                .opacity(started == nil ? 0.5 : 1)
        }
    }
}

extension UIResponder {
    nonisolated(unsafe) private static weak var found: UIResponder?

    /// True while any text field or editor has the keyboard (Claude panel, notes editor, popovers),
    /// so slide shortcuts like space and arrows type instead of turning pages.
    static var isEditingText: Bool {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.reportFirstResponder), to: nil, from: nil, for: nil)
        return found is UITextInput
    }

    @objc private func reportFirstResponder() {
        UIResponder.found = self
    }
}
