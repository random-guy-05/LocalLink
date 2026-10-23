import SwiftUI
import AppKit

enum Palette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.084)
    static let sidebar = Color(red: 0.073, green: 0.087, blue: 0.105)
    static let surface = Color(red: 0.090, green: 0.106, blue: 0.129)
    static let line = Color.white.opacity(0.08)
    static let accent = Color(red: 0.49, green: 0.91, blue: 0.79)
    static let secondary = Color(red: 0.59, green: 0.65, blue: 0.73)
    static let violet = Color(red: 0.64, green: 0.63, blue: 0.93)
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(Palette.secondary) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).frame(height: 40)
            .foregroundStyle(Color.black.opacity(0.9))
            .background(Palette.accent.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).frame(height: 35)
            .foregroundStyle(.white.opacity(0.88))
            .background(.white.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct ContentView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingHost = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(Palette.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                        if let notification = model.notification { notice(notification) }
                        switch model.page {
                        case .connect: ConnectPage(model: model, editingHost: $editingHost)
                        case .picture: PicturePage(model: model)
                        case .diagnostics: DiagnosticsPage(model: model)
                        case .setup: SetupPage(model: model)
                        }
                    }.padding(30).frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity)
                }
                footer
            }.background(Palette.background)
        }
        .frame(minWidth: 980, idealWidth: 1120, minHeight: 660, idealHeight: 780)
        .preferredColorScheme(.dark).tint(Palette.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.page)
        .task { model.startMonitoring() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.foregrounded() } }
        .sheet(isPresented: $editingHost) { hostEditor }
        .sheet(isPresented: Binding(get: { model.phase == .pairing }, set: { if !$0 { model.disconnect() } })) { PairingSheet(model: model) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 31, height: 31)
                Text("LocalLink").font(.system(size: 19, weight: .semibold, design: .rounded))
            }.padding(.top, 31).padding(.bottom, 39).padding(.horizontal, 22)
            Eyebrow(text: "Your workspace").padding(.horizontal, 24).padding(.bottom, 14)
            ForEach(AppPage.allCases) { page in
                Button { model.page = page } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.icon).font(.system(size: 15, weight: .medium)).frame(width: 20)
                        Text(page.title).font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if page == .setup && model.reachability != .ready { Circle().fill(Palette.violet).frame(width: 5, height: 5) }
                    }.foregroundStyle(model.page == page ? Palette.accent : Palette.secondary)
                        .padding(.horizontal, 13).frame(height: 42)
                        .background(model.page == page ? Palette.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.horizontal, 11).padding(.bottom, 4)
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
            }
            Spacer()
            if model.phase == .session {
                Button { model.showViewer() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.right.video.fill").foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Viewer is open").font(.system(size: 12, weight: .semibold))
                            Text("Return to your desktop").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        }
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).padding(13)
            }
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack(spacing: 9) {
                    Image(systemName: "laptopcomputer").font(.system(size: 17)).foregroundStyle(Palette.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Retina canvas").font(.system(size: 12, weight: .medium))
                        Text(model.hardware.caption).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                }
            }.padding(22)
        }.frame(width: 202).background(Palette.sidebar)
    }

    private var toolbar: some View {
        HStack {
            Text(model.page.title).font(.system(size: 13, weight: .medium))
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.phase == .session || model.reachability == .ready ? Palette.accent : Palette.secondary).frame(width: 5, height: 5)
                Text(model.displayStatus).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Divider().frame(height: 14).padding(.horizontal, 10)
            Button { model.openGuide() } label: { Image(systemName: "questionmark.circle").font(.system(size: 15)).foregroundStyle(Palette.secondary) }
                .buttonStyle(.plain).help("Open setup and keyboard shortcut guide").accessibilityLabel("Setup guide")
        }.padding(.horizontal, 30).frame(height: 59)
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("Your devices. Your private workspace.")
            Spacer()
            if let check = model.lastCheck { Text("Checked \(check.formatted(date: .omitted, time: .shortened))") }
            else { Text("LocalLink 0.3") }
        }.font(.system(size: 10)).foregroundStyle(Palette.secondary.opacity(0.75))
            .padding(.horizontal, 30).frame(height: 32).overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }
    private func notice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Palette.accent).padding(.top, 2)
            Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.notification = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.padding(14).background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
    private var hostEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your host address").font(.title2.weight(.semibold))
            Text("Enter the mini’s Tailscale IP or hostname. This does not change your network settings.").foregroundStyle(Palette.secondary).font(.callout)
            TextField("Host Tailscale IP or hostname", text: $model.settings.host).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Done") { editingHost = false; Task { await model.refresh() } }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 420).preferredColorScheme(.dark)
    }
}

struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Palette.accent)
            Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.background)
        }
    }
}

struct ConnectPage: View {
    @ObservedObject var model: SessionModel
    @Binding var editingHost: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Distance, made smaller")
                Text("A little closer to your Mac.").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text("Your familiar desktop, with room to get things done.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            hero
            HStack(spacing: 13) {
                MetricCard(label: "Network path", value: model.route.title, suffix: "", detail: model.route == .direct ? "Peer to peer over Tailscale" : model.route == .relay || model.route == .peerRelay ? "A relay is carrying the route" : "Run a connection check", icon: "point.3.connected.trianglepath.dotted")
                MetricCard(label: "Network round trip", value: model.rtt.map { String(format: "%.0f", $0) } ?? "—", suffix: model.rtt == nil ? "" : "ms", detail: "Excludes video and input delay", icon: "waveform.path")
                MetricCard(label: "Requested frame rate", value: String(model.settings.fps), suffix: "fps", detail: "Viewer display: \(model.hardware.refresh) Hz", icon: "rectangle.stack")
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Find your flow").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Fine-tune picture", systemImage: "arrow.up.right") { model.page = .picture }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 12) { ForEach(Profile.allCases) { ProfileCard(profile: $0, model: model) } }
            }
            if model.phase == .session { sessionBar }
        }
    }
    private var hero: some View {
        Panel(padding: 22) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 8) {
                        Image(systemName: "macmini").foregroundStyle(Palette.accent)
                        Text("MAC MINI").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
                        Button { editingHost = true } label: { Image(systemName: "pencil").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(Palette.secondary).help("Edit host address").disabled(model.busy)
                    }
                    Text(model.phase == .session ? "Your workspace is open." : model.reachability.title)
                        .font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.5).fixedSize(horizontal: false, vertical: true)
                    Text(model.phase == .session ? "Return to the viewer to use your desktop. Disconnecting here leaves the mini’s apps running." : model.reachability.detail)
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    actions.padding(.top, 3)
                    Text(model.settings.cleanHost).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary.opacity(0.7)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DeviceIllustration(online: model.reachability == .ready).frame(width: 243, height: 172).accessibilityHidden(true)
            }
        }
    }
    @ViewBuilder private var actions: some View {
        if model.phase == .session {
            HStack { Button { model.showViewer() } label: { Label("Return to viewer", systemImage: "arrow.up.right") }.buttonStyle(PrimaryButtonStyle()); Button("Disconnect") { model.disconnect() }.buttonStyle(SecondaryButtonStyle()) }
        } else if model.reachability == .ready {
            HStack {
                Button { model.connect() } label: { Label("Open my Mac", systemImage: "arrow.up.right") }.buttonStyle(PrimaryButtonStyle()).disabled(!model.canConnect)
                Button(model.paired ? "Pair again" : "Pair this Mac") { model.pair() }.buttonStyle(SecondaryButtonStyle()).disabled(model.busy)
            }
        } else {
            HStack {
                Button { Task { await model.refresh() } } label: {
                    HStack(spacing: 8) { if model.checking { ProgressView().controlSize(.small).tint(.black) } else { Image(systemName: "arrow.clockwise") }; Text(model.checking ? "Checking…" : "Check connection") }
                }.buttonStyle(PrimaryButtonStyle()).disabled(model.checking || model.busy)
                Button("Set up host") { model.page = .setup }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }
    private var sessionBar: some View {
        HStack(spacing: 13) {
            Image(systemName: "keyboard").foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Stay in the flow").font(.system(size: 12, weight: .medium))
                Text("⌃⌥⇧Q ends the viewer · ⌃⌥⇧Z releases the pointer · ⌃⌥⇧S toggles stats")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            Spacer()
        }.padding(16).background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DeviceIllustration: View {
    let online: Bool
    var body: some View {
        ZStack {
            Circle().fill(Palette.accent.opacity(online ? 0.07 : 0.025)).frame(width: 185, height: 185).blur(radius: 16)
            Circle().stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [3, 5])).frame(width: 178, height: 178)
            VStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.19, green: 0.22, blue: 0.27)).frame(width: 211, height: 132)
                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(red: 0.10, green: 0.17, blue: 0.22), Color(red: 0.15, green: 0.18, blue: 0.30)], startPoint: .bottomLeading, endPoint: .topTrailing)).frame(width: 201, height: 121).offset(y: -5)
                    desktopShapes.frame(width: 187, height: 103).offset(y: -13)
                    Capsule().fill(Color(red: 0.35, green: 0.39, blue: 0.45)).frame(width: 237, height: 5).offset(y: 3)
                }
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.24)], startPoint: .top, endPoint: .bottom)).frame(width: 46, height: 18)
                        .overlay(alignment: .trailing) { Circle().fill(online ? Palette.accent : .white.opacity(0.4)).frame(width: 2, height: 2).padding(5) }
                    Rectangle().fill(Palette.accent.opacity(0.25)).frame(width: 30, height: 1)
                    Text("YOUR PRIVATE WORKSPACE").font(.system(size: 7, weight: .medium)).tracking(0.7).foregroundStyle(Palette.secondary)
                }.padding(.top, 2)
            }
        }
    }
    private var desktopShapes: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.18)).frame(width: 111, height: 74).rotationEffect(.degrees(-7)).offset(x: 18, y: 3)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.25)).frame(width: 3, height: 3) } }.padding(.bottom, 5)
                    ForEach(0..<4) { index in RoundedRectangle(cornerRadius: 1).fill(.white.opacity(index == 0 ? 0.28 : 0.09)).frame(width: index == 0 ? 25 : 20, height: 3) }
                    Spacer(minLength: 0)
                }.padding(9).frame(width: 45).background(.white.opacity(0.035))
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.accent.opacity(0.65)).frame(width: 38, height: 4)
                    ForEach(0..<3) { index in RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.12)).frame(width: index == 2 ? 39 : 64, height: 2) }
                    HStack(spacing: 4) { ForEach(0..<3) { index in RoundedRectangle(cornerRadius: 3).fill(index == 1 ? Palette.violet.opacity(0.25) : Palette.accent.opacity(0.14)).frame(width: 20, height: 20) } }.padding(.top, 3)
                }.padding(11)
            }.frame(width: 137, height: 83).background(Color(red: 0.13, green: 0.16, blue: 0.20), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.15))).rotationEffect(.degrees(-4))
        }
    }
}

struct MetricCard: View {
    let label: String
    let value: String
    let suffix: String
    let detail: String
    let icon: String
    var body: some View {
        Panel(padding: 15) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Eyebrow(text: label); Spacer(minLength: 0); Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(suffix).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(2).frame(height: 23, alignment: .top)
            }
        }
    }
}

struct ProfileCard: View {
    let profile: Profile
    @ObservedObject var model: SessionModel
    private var selected: Bool { model.settings.profile == profile }
    private var specification: String {
        var config = StreamSettings(); config.apply(profile, hardware: model.hardware)
        return "\(config.resolution.replacingOccurrences(of: "x", with: " × ")) · \(config.bitrate) Mbps"
    }
    var body: some View {
        Button { model.apply(profile) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: profile.symbol).font(.system(size: 19)).foregroundStyle(selected ? Palette.accent : Palette.secondary)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.accent) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) { Text(profile.title).font(.system(size: 14, weight: .semibold)); if selected && model.profileIsCustom { Text("TUNED").font(.system(size: 7, weight: .semibold)).foregroundStyle(Palette.accent) } }
                    Text(profile.subtitle).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Text(specification).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Palette.accent.opacity(0.055) : Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Palette.accent.opacity(0.55) : Palette.line))
        }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel("\(profile.title) profile, \(specification)")
    }
}

struct PicturePage: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(kicker: "Make it feel familiar", title: "Clarity. Fluidity. Your balance.", subtitle: "These settings apply when you start your next viewer session.")
            HStack(spacing: 12) { ForEach(Profile.allCases) { ProfileCard(profile: $0, model: model) } }
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    sectionTitle("Picture", subtitle: "Match the canvas, then add detail.")
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Resolution").font(.system(size: 12, weight: .medium))
                            Picker("Resolution", selection: $model.settings.resolution) {
                                let resolutions = Array(Set(["1920x1080", "2560x1440", "2560x1600", "3840x2160", model.hardware.resolution])).sorted()
                                ForEach(resolutions, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                            }.pickerStyle(.menu).labelsHidden()
                        }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Frame rate").font(.system(size: 12, weight: .medium))
                            Picker("Frame rate", selection: $model.settings.fps) { ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) fps").tag($0) } }.pickerStyle(.menu).labelsHidden()
                        }.frame(width: 125)
                        Button("Match this display") { model.matchDisplay() }.buttonStyle(SecondaryButtonStyle()).padding(.top, 21)
                    }
                    VStack(spacing: 9) {
                        HStack { Text("Video bitrate").font(.system(size: 12, weight: .medium)); Spacer(); Text("\(model.settings.bitrate) Mbps").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent) }
                        Slider(value: Binding(get: { Double(model.settings.bitrate) }, set: { model.settings.bitrate = Int($0.rounded()) }), in: 5...120)
                        HStack { Text("Less bandwidth"); Spacer(); Text("More picture detail") }.font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    }
                    Text("Requested resolution doesn’t change the mini’s display mode. Its display must also provide the detail you want to stream.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("Response", subtitle: "Consistent motion or the shortest presentation delay.")
                    Picker("Presentation", selection: $model.settings.pacing) { ForEach(Pacing.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                    Text(model.settings.pacing.detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Divider()
                    Toggle(isOn: $model.settings.fullscreen) { settingsLabel("Open full screen", detail: "Keeps your remote workspace front and center.") }.toggleStyle(.switch).controlSize(.small)
                    Toggle(isOn: $model.settings.relativeMouse) { settingsLabel("Relative mouse for games", detail: "Leave off for normal desktop work and precise pointer positioning.") }.toggleStyle(.switch).controlSize(.small)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("Decoding & color", subtitle: "Use this Mac’s video hardware and keep unnecessary work low.")
                    HStack {
                        settingsLabel("Video codec", detail: "Automatic lets the two Macs negotiate compatibility.")
                        Spacer()
                        Picker("Codec", selection: $model.settings.codec) { Text("Automatic").tag("auto"); Text("HEVC").tag("HEVC"); Text("H.264").tag("H.264") }.labelsHidden().frame(width: 150)
                    }
                    Toggle(isOn: $model.settings.hardwareOnly) { settingsLabel("Require hardware decoding", detail: "Avoids an unnoticed CPU fallback. Turn off to troubleshoot compatibility.") }.toggleStyle(.switch).controlSize(.small)
                    Toggle(isOn: $model.settings.chroma444) { settingsLabel("Full color detail · 4:4:4", detail: "For colored text and design work. Requires compatible hardware on both Macs.") }.toggleStyle(.switch).controlSize(.small)
                    Toggle(isOn: $model.settings.overlay) { settingsLabel("Show in-stream performance", detail: "Actual FPS, dropped frames, and decoding time from the viewer.") }.toggleStyle(.switch).controlSize(.small)
                }
            }
            Label(model.recommendation, systemImage: "lightbulb").font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
        }.disabled(model.busy)
    }
    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 16, weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
    }
    private func settingsLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PageHeading: View {
    let kicker: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { Eyebrow(text: kicker); Text(title).font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.6); Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}

struct DiagnosticsPage: View {
    @ObservedObject var model: SessionModel
    @State private var showingLog = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(kicker: "Know your connection", title: "Good performance starts with a clear signal.", subtitle: "Network measurements here are real round trips. Video performance is measured inside the viewer.")
            HStack(spacing: 12) {
                MetricCard(label: "Latest round trip", value: model.rtt.map { String(format: "%.1f", $0) } ?? "—", suffix: model.rtt == nil ? "" : "ms", detail: "Tailscale path measurement", icon: "waveform.path")
                MetricCard(label: "RTT variation", value: model.variation.map { String(format: "%.1f", $0) } ?? "—", suffix: model.variation == nil ? "" : "ms", detail: "Mean change between recent samples", icon: "waveform.path.ecg")
                MetricCard(label: "Route", value: model.route.title, suffix: "", detail: model.tailnetRunning ? "Tailscale is connected" : "Private network is disconnected", icon: "point.topleft.down.to.point.bottomright.curvepath")
            }
            Panel {
                VStack(alignment: .leading, spacing: 19) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text("The path between your Macs").font(.system(size: 15, weight: .semibold)); Text("Last \(model.samples.count) network samples · milliseconds").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                        Spacer()
                        Button { Task { await model.refresh(measure: true) } } label: { Label(model.measuring ? "Measuring…" : "Measure path", systemImage: "arrow.clockwise") }.buttonStyle(SecondaryButtonStyle()).disabled(model.checking || model.busy)
                    }
                    NetworkChart(samples: model.samples).frame(height: 127)
                    Text("A low round trip helps responsiveness. It does not measure available bandwidth, video FPS, dropped frames, or total input delay.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 17) {
                    Text("Your playback pipeline").font(.system(size: 15, weight: .semibold))
                    pipelineRow("Viewer canvas", value: model.hardware.caption, symbol: "display")
                    Divider()
                    pipelineRow("H.264 hardware decode", value: model.hardware.h264 ? "Available" : "Not reported", symbol: "cpu")
                    pipelineRow("HEVC hardware decode", value: model.hardware.hevc ? "Available" : "Not reported", symbol: "cpu")
                    Divider()
                    pipelineRow("Requested video", value: model.settings.summary, symbol: "rectangle.stack")
                    Text("Hardware availability is checked using VideoToolbox. Actual codec selection, decode time, and delivered frames are confirmed by the in-stream overlay (⌃⌥⇧S).")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.history.isEmpty { history }
            Panel {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text("Session & setup details").font(.system(size: 15, weight: .semibold)); Spacer(); Button("Save report") { model.exportReport() }.buttonStyle(SecondaryButtonStyle()) }
                    if model.log.isEmpty { Text("Engine messages will appear after pairing, opening a viewer, or installing the host.").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    else {
                        DisclosureGroup("Show engine output", isExpanded: $showingLog) {
                            ScrollView([.vertical, .horizontal]) { Text(model.log).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(height: 220)
                        }.font(.system(size: 11))
                    }
                }
            }
        }
    }
    private func pipelineRow(_ label: String, value: String, symbol: String) -> some View {
        HStack { Label(label, systemImage: symbol).font(.system(size: 11)).foregroundStyle(Palette.secondary); Spacer(); Text(value).font(.system(size: 11, weight: .medium)).textSelection(.enabled) }
    }
    private var history: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recent viewer sessions").font(.system(size: 15, weight: .semibold))
                ForEach(model.history.prefix(5)) { record in
                    HStack(spacing: 13) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.secondary)
                        VStack(alignment: .leading, spacing: 4) { Text(record.outcome).font(.system(size: 11, weight: .medium)); Text(record.configuration).font(.system(size: 9)).foregroundStyle(Palette.secondary) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) { Text("\(record.seconds / 60)m \(record.seconds % 60)s").font(.system(size: 10, design: .monospaced)); Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(Palette.secondary) }
                    }
                }
                Text("Durations track the viewer process, including connection setup.").font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
        }
    }
}

struct NetworkChart: View {
    let samples: [PingSample]
    var body: some View {
        GeometryReader { geo in
            let values = samples.map(\.milliseconds), ceiling = max(20, (values.max() ?? 20) * 1.2)
            ZStack {
                VStack { ForEach(0..<4) { _ in Rectangle().fill(Palette.line).frame(height: 1); Spacer(minLength: 0) } }
                if values.count < 2 {
                    VStack(spacing: 8) { Image(systemName: "waveform.path").font(.system(size: 22)); Text("Measure a live path to see its consistency.").font(.system(size: 11)) }.foregroundStyle(Palette.secondary)
                } else {
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let point = CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * geo.size.width, y: geo.size.height - CGFloat(value / ceiling) * (geo.size.height - 14))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }.stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }.accessibilityLabel(samples.count < 2 ? "No network measurements yet" : "Network round trip chart with \(samples.count) real samples")
    }
}

struct SetupPage: View {
    @ObservedObject var model: SessionModel
    @State private var showChecklist = false
    private var completedChecks: Int {
        [LocalPaths.moonlight != nil, model.tailnetRunning,
         model.peerOnline == true || model.reachability == .ready || model.reachability == .hostMissing,
         model.reachability == .ready, model.paired].filter { $0 }.count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(kicker: "A few steps, once", title: "A workspace of your own.", subtitle: "Set up the mini, pair your MacBook, and make the next connection one click.")
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your host address").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 12) {
                        TextField("Tailscale IP or hostname", text: $model.settings.host).textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.refresh() } }
                        Button("Check host") { Task { await model.refresh() } }.buttonStyle(SecondaryButtonStyle()).disabled(model.checking || model.busy)
                    }.disabled(model.busy)
                    Text("Find it in Tailscale on the host Mac. Addresses and SSH trust are saved only on your computer.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 18) {
                    DisclosureGroup(isExpanded: $showChecklist) {
                        VStack(alignment: .leading, spacing: 16) {
                            checkRow("Viewer installed", detail: "Moonlight is the native streaming engine on this Mac.", done: LocalPaths.moonlight != nil)
                            checkRow("Private network connected", detail: "Both Macs use the same Tailscale network.", done: model.tailnetRunning)
                            checkRow("Mac mini available", detail: "The mini is awake and reachable through your network.", done: model.peerOnline == true || model.reachability == .ready || model.reachability == .hostMissing)
                            checkRow("Streaming host responding", detail: "Sunshine is open and responding on the mini.", done: model.reachability == .ready)
                            checkRow("Paired from LocalLink", detail: "Pair once. If paired elsewhere, you can try connecting directly.", done: model.paired)
                        }.padding(.top, 18)
                    } label: {
                        HStack { Text("Connection checklist").font(.system(size: 15, weight: .semibold)); Spacer(); Text("\(completedChecks) of 5 ready").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    }
                    HStack { Button { Task { await model.refresh() } } label: { Label("Refresh checklist", systemImage: "arrow.clockwise") }.buttonStyle(SecondaryButtonStyle()).disabled(model.checking || model.busy); Spacer(); Button("Open Tailscale") { model.openTailscale() }.buttonStyle(.link).font(.system(size: 11)) }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 11) { stepNumber("01"); VStack(alignment: .leading, spacing: 5) { Text("Install the host, privately").font(.system(size: 16, weight: .semibold)); Text("Uses a temporary SSH connection to your Mac mini.").font(.system(size: 11)).foregroundStyle(Palette.secondary) } }
                    Text("On the mini, turn on Remote Login in System Settings → General → Sharing and allow your account. Authenticate in Terminal here; your Mac password is not saved. Then install the verified host release.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { model.authenticateSSH() } label: { Label(model.sshAuthenticated ? "Authenticate again" : "Authenticate SSH", systemImage: "terminal") }.buttonStyle(SecondaryButtonStyle()).disabled(model.busy)
                        Button { Task { await model.installHost() } } label: { Label(model.phase == .installing ? "Installing…" : "Install on mini", systemImage: "arrow.down.to.line") }.buttonStyle(PrimaryButtonStyle()).disabled(!model.sshAuthenticated || model.busy)
                        Spacer(minLength: 0)
                    }
                    Label(model.sshAuthenticated ? "Temporary SSH connection is available" : "No authenticated SSH connection yet", systemImage: model.sshAuthenticated ? "checkmark.shield" : "lock").font(.system(size: 10)).foregroundStyle(model.sshAuthenticated ? Palette.accent : Palette.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 11) { stepNumber("02"); VStack(alignment: .leading, spacing: 5) { Text("Give your mini permission").font(.system(size: 16, weight: .semibold)); Text("Apple requires these approvals on the host Mac.").font(.system(size: 11)).foregroundStyle(Palette.secondary) } }
                    Text("On the mini, allow Sunshine under Privacy & Security → Screen & System Audio Recording and Accessibility. Allow audio access if requested. Quit and reopen Sunshine afterward. These permissions aren’t granted by the installer.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    Button { Task { await model.openDashboard() } } label: { Label("Open mini’s dashboard", systemImage: "arrow.up.right.square") }.buttonStyle(SecondaryButtonStyle()).disabled(!model.sshAuthenticated)
                    Text("The dashboard opens through a local SSH tunnel. It remains private to your mini.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 11) { stepNumber("03"); VStack(alignment: .leading, spacing: 5) { Text("Pair, then make yourself at home").font(.system(size: 16, weight: .semibold)); Text("A four-digit PIN links this viewer with the mini.").font(.system(size: 11)).foregroundStyle(Palette.secondary) } }
                    Text("Create a Sunshine admin login in its dashboard. Click Pair this Mac, then enter the displayed PIN on the dashboard’s PIN page. Choose Smooth for your first session, and tune from there.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    HStack { Button { model.pair() } label: { Label("Pair this Mac", systemImage: "link") }.buttonStyle(SecondaryButtonStyle()).disabled(!model.canConnect); Button("Setup guide & shortcuts") { model.openGuide() }.buttonStyle(.link).font(.system(size: 11)) }
                }
            }
        }
    }
    private func stepNumber(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent).frame(width: 34, height: 34).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
    private func checkRow(_ title: String, detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 16)).foregroundStyle(done ? Palette.accent : Palette.secondary.opacity(0.5)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer()
        }
    }
}

struct PairingSheet: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "link.circle.fill").font(.system(size: 41)).foregroundStyle(Palette.accent)
            Text("Make the connection yours.").font(.system(size: 23, weight: .semibold, design: .rounded))
            Text("Enter this code in Sunshine → PIN on your Mac mini.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack(spacing: 12) { ForEach(Array(model.pin.enumerated()), id: \.offset) { _, digit in Text(String(digit)).font(.system(size: 35, weight: .medium, design: .monospaced)).frame(width: 57, height: 73).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent.opacity(0.25))) } }
            HStack { Button("Copy code") { model.copy(model.pin) }.buttonStyle(SecondaryButtonStyle()); if model.sshAuthenticated { Button("Open PIN dashboard") { Task { await model.openDashboard() } }.buttonStyle(SecondaryButtonStyle()) } }
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for the mini · up to two minutes").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
            Button("Cancel pairing") { model.disconnect() }.buttonStyle(.plain).foregroundStyle(Palette.secondary).font(.system(size: 11))
        }.padding(36).frame(width: 440).background(Palette.background).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
}
