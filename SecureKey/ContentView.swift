import SwiftUI
import Combine
import CoreGraphics
import AVFoundation
import AppKit

// MARK: - Глобальное состояние
class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isLocked = false
    @Published var leftCmdDown = false
    @Published var rightCmdDown = false
}

// MARK: - Модель совета
struct CleaningTip {
    let icon: String
    let text: [AppLanguage: String]
}

// MARK: - Локализация
enum AppLanguage: String, CaseIterable {
    case en = "EN", ru = "RU", ua = "UA", fr = "FR", de = "DE"
    case es = "ES", it = "IT", jp = "JP", ch = "CH", kr = "KR"
    
    var title: String {
        switch self {
        case .en: return "English"; case .ru: return "Русский"; case .ua: return "Українська"
        case .fr: return "Français"; case .de: return "Deutsch"; case .es: return "Español"
        case .it: return "Italiano"; case .jp: return "日本語"; case .ch: return "中文"; case .kr: return "한국어"
        }
    }
}

struct Localizer {
    static let tips: [CleaningTip] = [
        CleaningTip(icon: "square.and.pencil", text: [.en: "Use a dry microfiber cloth.", .ru: "Используйте сухую салфетку из микрофибры.", .ua: "Використовуйте суху серветку з мікрофібри."]),
        CleaningTip(icon: "drop.triangle.fill", text: [.en: "Avoid moisture in the gaps.", .ru: "Избегайте попадания влаги в зазоры.", .ua: "Уникайте потрапляння вологи в зазори."]),
        CleaningTip(icon: "hand.raised.fill", text: [.en: "No heavy pressure. Light movements.", .ru: "Без сильного давления. Легкие движения.", .ua: "Без сильного тиску. Легкі рухи."])
    ]
    static func txt(_ key: String, _ lang: AppLanguage) -> String {
        let data: [String: [AppLanguage: String]] = [
            "start": [.en: "ACTIVATE PROTECTION", .ru: "АКТИВИРОВАТЬ ЗАЩИТУ", .ua: "АКТИВУВАТИ ЗАХИСТ"],
            "hold": [.en: "Hold both CMD keys", .ru: "Зажмите оба CMD", .ua: "Затисніть обидва CMD"],
            "locked_status": [.en: "System Locked", .ru: "Система заблокирована", .ua: "Систему заблоковано"],
            "settings": [.en: "Settings", .ru: "Настройки", .ua: "Налаштування"],
            "done": [.en: "Done", .ru: "Готово", .ua: "Готово"]
        ]
        return data[key]?[lang] ?? key
    }
}

// MARK: - Главный экран
struct ContentView: View {
    @ObservedObject var state = AppState.shared
    @State private var unlockProgress: CGFloat = 0.0
    @State private var appear = false
    @State private var currentTip: CleaningTip = Localizer.tips[0]
    
    @AppStorage("selectedLanguage") private var language: AppLanguage = .en
    @AppStorage("isBlueTheme") private var isBlueTheme = false
    @State private var showSettings = false
    
    @State private var welcomePlayer: AVAudioPlayer?
    @State private var lockPlayer: AVAudioPlayer?
    @State private var tickPlayer: AVAudioPlayer?
    @State private var unlockPlayer: AVAudioPlayer?

    let timer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [appear ? 0.2 : 0.8, appear ? 0.8 : 0.2], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ], colors: [
                Color.black, Color.black, Color.black,
                Color.black, appear ? (isBlueTheme ? Color.blue : Color.orange).opacity(0.4) : Color.indigo.opacity(0.2), Color.black,
                Color.black, Color.black, Color.black
            ])
            .onAppear { withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { appear.toggle() } }
            .edgesIgnoringSafeArea(.all)

            VStack {
                if !state.isLocked {
                    HStack {
                        Spacer()
                        Button(action: { showSettings.toggle() }) {
                            Image(systemName: "gearshape.fill").font(.title2).foregroundColor(Color.white.opacity(0.5))
                        }.buttonStyle(.plain).padding()
                    }
                    Spacer()
                    Image(systemName: isBlueTheme ? "snowflake" : "flame.fill")
                        .font(.system(size: 80, weight: .ultraLight))
                        .foregroundStyle(isBlueTheme ? Color.blue : Color.orange).symbolEffect(.pulse)
                    Text("SecureKey").font(.system(size: 45, weight: .thin, design: .rounded)).tracking(8)
                    Button(action: { startLock() }) {
                        Text(Localizer.txt("start", language))
                            .font(.system(size: 12, weight: .bold)).kerning(2)
                            .padding(.horizontal, 40).padding(.vertical, 15)
                            .background(Color.white.opacity(0.05)).clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    }.buttonStyle(.plain).padding(.top, 20)
                    Spacer()
                } else {
                    VStack(spacing: 40) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.05)).frame(width: 220, height: 220)
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 80))
                                .foregroundStyle(isBlueTheme ? Color.blue : Color.orange)
                                .scaleEffect(1 + unlockProgress * 0.2)
                        }
                        VStack(spacing: 25) {
                            VStack(spacing: 12) {
                                Text(Localizer.txt("locked_status", language)).font(.title3.weight(.light))
                                HStack(spacing: 10) {
                                    Image(systemName: currentTip.icon).font(.system(size: 15))
                                        .foregroundColor(isBlueTheme ? Color.blue : Color.orange)
                                    Text("⌘ " + (currentTip.text[language] ?? "")).font(.system(size: 13)).opacity(0.8)
                                }
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                .background(Color.white.opacity(0.04)).clipShape(Capsule())
                            }
                            HStack(spacing: 40) {
                                KeyUnit(label: "CMD L", active: state.leftCmdDown, color: isBlueTheme ? Color.blue : Color.orange)
                                KeyUnit(label: "CMD R", active: state.rightCmdDown, color: isBlueTheme ? Color.blue : Color.orange)
                            }
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.1)).frame(width: 300, height: 6)
                                Capsule().fill(isBlueTheme ? Color.blue : Color.orange)
                                    .frame(width: 300 * unlockProgress, height: 6)
                                    .shadow(color: (isBlueTheme ? Color.blue : Color.orange).opacity(0.5), radius: 10)
                            }
                            Text(Localizer.txt("hold", language)).font(.caption2).opacity(0.4)
                        }
                        .padding(.horizontal, 40).padding(.vertical, 50)
                        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
                        .clipShape(RoundedRectangle(cornerRadius: 40))
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 700)
        .sheet(isPresented: $showSettings) { SettingsView(lang: $language, blueTheme: $isBlueTheme) }
        .onAppear {
            loadSounds()
            setupGlobalMonitors()
            play(welcomePlayer)
        }
        .onReceive(timer) { _ in updateProgress() }
    }

    private func setupGlobalMonitors() {
        // 1. Фиксация клавиш через NSEvent для гарантированного отклика интерфейса
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let isCmd = event.modifierFlags.contains(.command)
            let keyCode = event.keyCode
            
            DispatchQueue.main.async {
                if keyCode == 55 {
                    AppState.shared.leftCmdDown = isCmd
                }
                if keyCode == 54 || keyCode == 61 {
                    AppState.shared.rightCmdDown = isCmd
                }
            }
        }
        
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let isCmd = event.modifierFlags.contains(.command)
            let keyCode = event.keyCode
            
            DispatchQueue.main.async {
                if keyCode == 55 {
                    AppState.shared.leftCmdDown = isCmd
                }
                if keyCode == 54 || keyCode == 61 {
                    AppState.shared.rightCmdDown = isCmd
                }
            }
            return event
        }

        // 2. Блокировка перехвата ввода для остальной системы
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.keyUp.rawValue) |
                                (1 << CGEventType.leftMouseDown.rawValue) |
                                (1 << CGEventType.leftMouseUp.rawValue) |
                                (1 << CGEventType.rightMouseDown.rawValue) |
                                (1 << CGEventType.rightMouseUp.rawValue) |
                                (1 << CGEventType.mouseMoved.rawValue) |
                                (1 << CGEventType.leftMouseDragged.rawValue) |
                                (1 << CGEventType.rightMouseDragged.rawValue) |
                                (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_, _, event, _) -> Unmanaged<CGEvent>? in
                if AppState.shared.isLocked {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags
                    
                    // Аварийный выход через Cmd + Opt + Esc
                    if flags.contains(.maskCommand) && flags.contains(.maskAlternate) && keyCode == 53 {
                        return Unmanaged.passRetained(event)
                    }
                    return nil // Блокируем весь остальной ввод
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            print("Ошибка доступа Accessibility")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func updateProgress() {
        guard state.isLocked else { return }
        if state.leftCmdDown && state.rightCmdDown {
            if unlockProgress < 1.0 {
                unlockProgress += 0.018
                if Int(unlockProgress * 100) % 15 == 0 { play(tickPlayer) }
            } else { finishUnlock() }
        } else {
            if unlockProgress > 0 { unlockProgress = max(0, unlockProgress - 0.06) }
        }
    }
    
    private func finishUnlock() {
        withAnimation(.spring()) {
            state.isLocked = false
            state.leftCmdDown = false
            state.rightCmdDown = false
            unlockProgress = 0
            NSCursor.unhide()
            play(unlockPlayer)
        }
    }

    private func startLock() {
        currentTip = Localizer.tips.randomElement() ?? Localizer.tips[0]
        withAnimation(.spring()) {
            state.isLocked = true
            NSCursor.hide()
            play(lockPlayer)
        }
    }

    private func loadSounds() {
        welcomePlayer = makePlayer(sound: "Hero")
        lockPlayer = makePlayer(sound: "Submarine")
        tickPlayer = makePlayer(sound: "Blow")
        unlockPlayer = makePlayer(sound: "Glass")
    }

    private func makePlayer(sound: String) -> AVAudioPlayer? {
        let path = "/System/Library/Sounds/\(sound).aiff"
        let url = URL(fileURLWithPath: path)
        return try? AVAudioPlayer(contentsOf: url)
    }

    private func play(_ player: AVAudioPlayer?) {
        player?.currentTime = 0
        player?.play()
    }
}

// MARK: - Вспомогательные компоненты
struct SettingsView: View {
    @Binding var lang: AppLanguage
    @Binding var blueTheme: Bool
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 25) {
            Text(Localizer.txt("settings", lang)).font(.headline).padding(.top)
            Form {
                Picker("Language", selection: $lang) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Ice Theme (Blue)", isOn: $blueTheme)
            }.formStyle(.grouped)
            Divider()
            VStack(spacing: 8) {
                Text("Created by Dmitry Miroshnik").font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(blueTheme ? Color.blue : Color.orange)
                Text("SecureKey 26 • Version 1.3").font(.caption2).opacity(0.4)
            }
            Button(Localizer.txt("done", lang)) { dismiss() }.buttonStyle(.borderedProminent).tint(blueTheme ? Color.blue : Color.orange).controlSize(.large).padding(.bottom)
        }.frame(width: 350, height: 420)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = blendingMode; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct KeyUnit: View {
    let label: String; let active: Bool; let color: Color
    var body: some View {
        VStack {
            Text(label).font(.system(size: 10, weight: .bold)).opacity(active ? 1 : 0.3)
            Circle().fill(active ? color : Color.white.opacity(0.1)).frame(width: 15, height: 15)
                .shadow(color: active ? color.opacity(0.8) : .clear, radius: 10)
                .scaleEffect(active ? 1.3 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.5), value: active)
        }
    }
}

