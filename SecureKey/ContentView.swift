import SwiftUI
import Combine
import CoreGraphics
import AVFoundation
import AppKit
import ApplicationServices

// MARK: - Открыть нужный раздел Системных настроек
// pane: "Privacy_Accessibility" (Универсальный доступ) или "Privacy_ListenEvent" (Мониторинг ввода)
func openPrivacyPane(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Окно с ошибкой, если перехват клавиш не запустился
func showTapFailedAlert(_ lang: AppLanguage) {
    let alert = NSAlert()
    alert.messageText = Localizer.txt("tap_failed_title", lang)
    alert.informativeText = Localizer.txt("tap_failed_body", lang)
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

// MARK: - Перехватчик событий (вызывается системой на КАЖДОЕ нажатие / движение мыши)
// Пока блокировка активна — возвращаем nil, и событие «умирает».
private func lockEventCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // Система иногда сама отключает перехватчик — включаем обратно
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        AppState.shared.reEnableTaps()
        return nil
    }

    // Следим за левым и правым CMD
    if type == .flagsChanged {
        let raw = event.flags.rawValue
        let leftDown = (raw & 0x08) != 0
        let rightDown = (raw & 0x10) != 0
        DispatchQueue.main.async {
            AppState.shared.leftCmdDown = leftDown
            AppState.shared.rightCmdDown = rightDown
        }
    }

    if AppState.isLockActive {
        // АВАРИЙНЫЙ ВЫХОД: ⌘ + ⌥ + Esc снимает блокировку
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if flags.contains(.maskCommand) && flags.contains(.maskAlternate) && keyCode == 53 {
                AppState.isLockActive = false
                DispatchQueue.main.async { AppState.shared.emergencyUnlock() }
                return nil
            }
        }
        return nil   // всё остальное (включая верхний ряд, тип 14) — блокируем
    }

    // passUnretained, а не passRetained — иначе утечка памяти на каждое событие
    return Unmanaged.passUnretained(event)
}

// MARK: - Глобальное состояние
class AppState: ObservableObject {
    static let shared = AppState()
    static var isLockActive = false

    @Published var isLocked = false
    @Published var leftCmdDown = false
    @Published var rightCmdDown = false
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var hasInputMonitoring = CGPreflightListenEventAccess()
    @Published var tapsActive = false
    var isCursorHidden = false
    var localMonitor: Any?

    var hidTap: CFMachPort?
    var hidSource: CFRunLoopSource?
    var sessionTap: CFMachPort?
    var sessionSource: CFRunLoopSource?

    // Какие события перехватываем. Тип 14 = NSSystemDefined = верхний ряд (яркость, громкость, медиа)
    static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged
        ]
        var mask: CGEventMask = 0
        for t in types { mask |= (CGEventMask(1) << CGEventMask(t.rawValue)) }
        // Системные события, которых нет в списке выше:
        // 14 = клавиши верхнего ряда (яркость, громкость, медиа)
        // 18, 19, 20 = вращение, начало и конец жеста
        // 29 = жест на трекпаде (касания несколькими пальцами)
        // 30 = щипок и жесты Dock (Mission Control, смена рабочих столов и полноэкранных приложений)
        // 31 = свайп, 32 = двойное касание двумя пальцами, 34 = сила нажатия
        for raw in [14, 18, 19, 20, 29, 30, 31, 32, 34] {
            mask |= (CGEventMask(1) << CGEventMask(raw))
        }
        return mask
    }()

    // MARK: Разрешения

    /// Обновляет статусы разрешений (вызывать только из главного потока)
    func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        let im = CGPreflightListenEventAccess()
        let active = anyTapEnabled
        if hasAccessibility != ax { hasAccessibility = ax }
        if hasInputMonitoring != im { hasInputMonitoring = im }
        if tapsActive != active { tapsActive = active }
    }

    /// Показывает системный запрос и открывает нужный раздел настроек
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }

    // MARK: Перехватчики

    private func isEnabled(_ tap: CFMachPort?) -> Bool {
        guard let tap = tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    var anyTapEnabled: Bool { isEnabled(sessionTap) || isEnabled(hidTap) }

    func reEnableTaps() {
        if let t = hidTap { CGEvent.tapEnable(tap: t, enable: true) }
        if let t = sessionTap { CGEvent.tapEnable(tap: t, enable: true) }
    }

    private func makeTap(location: CGEventTapLocation) -> (tap: CFMachPort, source: CFRunLoopSource)? {
        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: AppState.eventMask,
            callback: lockEventCallback,
            userInfo: nil
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, source)
    }

    func removeTaps() {
        if let t = sessionTap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = sessionSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = hidTap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = hidSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        sessionTap = nil; sessionSource = nil
        hidTap = nil; hidSource = nil
    }

    /// Создаёт перехватчики (если ещё нет). Возвращает true, если хотя бы один реально работает.
    @discardableResult
    func installTaps() -> Bool {
        guard AXIsProcessTrusted() else {
            refreshPermissions()
            return false
        }

        // Если перехватчики есть, но «мёртвые» (например, после смены разрешений) — пересоздаём
        if (sessionTap != nil || hidTap != nil) {
            reEnableTaps()
            if !anyTapEnabled { removeTaps() }
        }

        // 1. Уровень сессии (Mission Control, Spotlight, глобальные горячие клавиши)
        if sessionTap == nil, let made = makeTap(location: .cgSessionEventTap) {
            sessionTap = made.tap
            sessionSource = made.source
        }
        // 2. Уровень HID (физические клавиши и мультимедиа-клавиши верхнего ряда)
        if hidTap == nil, let made = makeTap(location: .cghidEventTap) {
            hidTap = made.tap
            hidSource = made.source
        }

        reEnableTaps()
        refreshPermissions()
        return anyTapEnabled
    }

    // MARK: Локальный монитор (события внутри окна самого приложения)

    func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged, .systemDefined,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
            .gesture, .magnify, .swipe, .rotate, .smartMagnify
        ]) { event in
            AppState.isLockActive ? nil : event
        }
    }

    // MARK: Аварийная разблокировка (⌘⌥Esc)

    func emergencyUnlock() {
        AppState.isLockActive = false
        isLocked = false
        leftCmdDown = false
        rightCmdDown = false
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        if isCursorHidden {
            CGDisplayShowCursor(kCGNullDirectDisplay)
            NSCursor.unhide()
            isCursorHidden = false
        }
        setKioskMode(false)
    }

    // MARK: Режим «киоска»: прячем Dock и строку меню, отключаем ⌘Tab
    // Действует только пока приложение активно; при разблокировке всё возвращается.
    func setKioskMode(_ on: Bool) {
        if on {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
        } else {
            NSApp.presentationOptions = []
        }
    }
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
    // Советы по чистке — на всех 10 языках
    static let tips: [CleaningTip] = [
        CleaningTip(icon: "square.and.pencil", text: [
            .en: "Use a dry microfiber cloth.",
            .ru: "Используйте сухую салфетку из микрофибры.",
            .ua: "Використовуйте суху серветку з мікрофібри.",
            .fr: "Utilisez un chiffon sec en microfibre.",
            .de: "Verwende ein trockenes Mikrofasertuch.",
            .es: "Usa un paño seco de microfibra.",
            .it: "Usa un panno asciutto in microfibra.",
            .jp: "乾いたマイクロファイバークロスを使ってください。",
            .ch: "请使用干燥的超细纤维布。",
            .kr: "마른 마이크로파이버 천을 사용하세요."
        ]),
        CleaningTip(icon: "drop.triangle.fill", text: [
            .en: "Avoid moisture in the gaps.",
            .ru: "Избегайте попадания влаги в зазоры.",
            .ua: "Уникайте потрапляння вологи в зазори.",
            .fr: "Évitez que de l’humidité pénètre entre les touches.",
            .de: "Vermeide Feuchtigkeit in den Zwischenräumen.",
            .es: "Evita que entre humedad en los huecos.",
            .it: "Evita che l’umidità penetri negli spazi.",
            .jp: "すき間に水分が入らないようにしてください。",
            .ch: "避免水分进入缝隙。",
            .kr: "틈새로 습기가 들어가지 않게 주의하세요."
        ]),
        CleaningTip(icon: "hand.raised.fill", text: [
            .en: "No heavy pressure. Light movements.",
            .ru: "Без сильного давления. Легкие движения.",
            .ua: "Без сильного тиску. Легкі рухи.",
            .fr: "Sans forte pression. Des gestes légers.",
            .de: "Nicht fest aufdrücken. Leichte Bewegungen.",
            .es: "Sin presionar fuerte. Movimientos suaves.",
            .it: "Senza premere forte. Movimenti leggeri.",
            .jp: "強く押さず、軽く動かしてください。",
            .ch: "不要用力按压，动作轻柔。",
            .kr: "세게 누르지 말고 가볍게 닦으세요."
        ])
    ]

    // Все тексты приложения: ключ → язык → перевод
    static let strings: [String: [AppLanguage: String]] = [
        "start": [
            .en: "ACTIVATE PROTECTION",
            .ru: "АКТИВИРОВАТЬ ЗАЩИТУ",
            .ua: "АКТИВУВАТИ ЗАХИСТ",
            .fr: "ACTIVER LA PROTECTION",
            .de: "SCHUTZ AKTIVIEREN",
            .es: "ACTIVAR PROTECCIÓN",
            .it: "ATTIVA LA PROTEZIONE",
            .jp: "保護を有効にする",
            .ch: "启用保护",
            .kr: "보호 활성화"
        ],
        "hold": [
            .en: "Hold both CMD keys",
            .ru: "Зажмите оба CMD",
            .ua: "Затисніть обидва CMD",
            .fr: "Maintenez les deux touches CMD",
            .de: "Beide CMD-Tasten gedrückt halten",
            .es: "Mantén pulsadas ambas teclas CMD",
            .it: "Tieni premuti entrambi i tasti CMD",
            .jp: "両方のCMDキーを長押しします",
            .ch: "同时按住两个 CMD 键",
            .kr: "두 CMD 키를 길게 누르세요"
        ],
        "locked_status": [
            .en: "System Locked",
            .ru: "Система заблокирована",
            .ua: "Систему заблоковано",
            .fr: "Système verrouillé",
            .de: "System gesperrt",
            .es: "Sistema bloqueado",
            .it: "Sistema bloccato",
            .jp: "システムはロックされています",
            .ch: "系统已锁定",
            .kr: "시스템이 잠겼습니다"
        ],
        "settings": [
            .en: "Settings",
            .ru: "Настройки",
            .ua: "Налаштування",
            .fr: "Réglages",
            .de: "Einstellungen",
            .es: "Ajustes",
            .it: "Impostazioni",
            .jp: "設定",
            .ch: "设置",
            .kr: "설정"
        ],
        "done": [
            .en: "Done",
            .ru: "Готово",
            .ua: "Готово",
            .fr: "Terminé",
            .de: "Fertig",
            .es: "Listo",
            .it: "Fine",
            .jp: "完了",
            .ch: "完成",
            .kr: "완료"
        ],
        "language": [
            .en: "Language",
            .ru: "Язык",
            .ua: "Мова",
            .fr: "Langue",
            .de: "Sprache",
            .es: "Idioma",
            .it: "Lingua",
            .jp: "言語",
            .ch: "语言",
            .kr: "언어"
        ],
        "ice_theme": [
            .en: "Ice Theme (Blue)",
            .ru: "Ледяная тема (синяя)",
            .ua: "Крижана тема (синя)",
            .fr: "Thème glace (bleu)",
            .de: "Eis-Design (Blau)",
            .es: "Tema hielo (azul)",
            .it: "Tema ghiaccio (blu)",
            .jp: "アイステーマ（ブルー）",
            .ch: "冰雪主题（蓝色）",
            .kr: "아이스 테마(파랑)"
        ],
        "need_access": [
            .en: "Enable Accessibility in Settings",
            .ru: "Включите доступ в Настройках",
            .ua: "Увімкніть доступ у Налаштуваннях",
            .fr: "Activez l’accès dans les Réglages",
            .de: "Zugriff in den Einstellungen aktivieren",
            .es: "Activa el acceso en Ajustes",
            .it: "Attiva l’accesso nelle Impostazioni",
            .jp: "設定でアクセスを有効にしてください",
            .ch: "请在设置中开启辅助功能权限",
            .kr: "설정에서 접근 권한을 켜 주세요"
        ],
        "diagnostics": [
            .en: "Diagnostics",
            .ru: "Диагностика",
            .ua: "Діагностика",
            .fr: "Diagnostic",
            .de: "Diagnose",
            .es: "Diagnóstico",
            .it: "Diagnostica",
            .jp: "診断",
            .ch: "诊断",
            .kr: "진단"
        ],
        "ax_title": [
            .en: "Accessibility",
            .ru: "Универсальный доступ",
            .ua: "Універсальний доступ",
            .fr: "Accessibilité",
            .de: "Bedienungshilfen",
            .es: "Accesibilidad",
            .it: "Accessibilità",
            .jp: "アクセシビリティ",
            .ch: "辅助功能",
            .kr: "손쉬운 사용"
        ],
        "im_title": [
            .en: "Input Monitoring",
            .ru: "Мониторинг ввода",
            .ua: "Моніторинг введення",
            .fr: "Surveillance de l’entrée",
            .de: "Eingabeüberwachung",
            .es: "Supervisión de entradas",
            .it: "Monitoraggio input",
            .jp: "入力監視",
            .ch: "输入监控",
            .kr: "입력 모니터링"
        ],
        "taps": [
            .en: "Key interception",
            .ru: "Перехват клавиш",
            .ua: "Перехоплення клавіш",
            .fr: "Interception des touches",
            .de: "Tastenblockierung",
            .es: "Interceptación de teclas",
            .it: "Intercettazione tasti",
            .jp: "キー入力の遮断",
            .ch: "按键拦截",
            .kr: "키 입력 가로채기"
        ],
        "open": [
            .en: "Open",
            .ru: "Открыть",
            .ua: "Відкрити",
            .fr: "Ouvrir",
            .de: "Öffnen",
            .es: "Abrir",
            .it: "Apri",
            .jp: "開く",
            .ch: "打开",
            .kr: "열기"
        ],
        "tap_failed_title": [
            .en: "Can't start protection",
            .ru: "Не удалось включить защиту",
            .ua: "Не вдалося увімкнути захист",
            .fr: "Impossible d’activer la protection",
            .de: "Schutz konnte nicht gestartet werden",
            .es: "No se pudo activar la protección",
            .it: "Impossibile attivare la protezione",
            .jp: "保護を開始できません",
            .ch: "无法启动保护",
            .kr: "보호를 시작할 수 없습니다"
        ],
        "tap_failed_body": [
            .en: "Access looks granted, but key interception did not start. Open System Settings → Privacy & Security → Accessibility, remove SecureKey with the «–» button, add it again, then quit and reopen the app.",
            .ru: "Доступ выдан, но перехват клавиш не запустился. Откройте Настройки → Конфиденциальность и безопасность → Универсальный доступ, удалите SecureKey кнопкой «–», добавьте заново, затем полностью закройте и откройте приложение.",
            .ua: "Доступ надано, але перехоплення клавіш не запустилось. Відкрийте Налаштування → Конфіденційність і безпека → Універсальний доступ, видаліть SecureKey кнопкою «–», додайте знову, потім повністю закрийте та відкрийте застосунок.",
            .fr: "L’accès semble accordé, mais l’interception des touches n’a pas démarré. Ouvrez Réglages Système → Confidentialité et sécurité → Accessibilité, supprimez SecureKey avec le bouton «–», ajoutez-le de nouveau, puis quittez et rouvrez l’app.",
            .de: "Der Zugriff scheint erteilt, aber die Tastenblockierung wurde nicht gestartet. Öffne Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen, entferne SecureKey mit der Schaltfläche «–», füge die App erneut hinzu und beende sie danach vollständig und öffne sie erneut.",
            .es: "El acceso parece concedido, pero la interceptación de teclas no se inició. Abre Ajustes del Sistema → Privacidad y seguridad → Accesibilidad, elimina SecureKey con el botón «–», vuelve a añadirlo y luego cierra y abre la app de nuevo.",
            .it: "L’accesso sembra concesso, ma l’intercettazione dei tasti non è partita. Apri Impostazioni di Sistema → Privacy e sicurezza → Accessibilità, rimuovi SecureKey con il pulsante «–», aggiungilo di nuovo, poi chiudi e riapri l’app.",
            .jp: "アクセスは許可されているようですが、キー入力の遮断を開始できませんでした。システム設定 → プライバシーとセキュリティ → アクセシビリティ を開き、SecureKey を「–」ボタンで削除してから追加し直し、アプリを完全に終了してもう一度開いてください。",
            .ch: "辅助功能权限看似已授予，但按键拦截未能启动。请打开「系统设置 → 隐私与安全性 → 辅助功能」，用「–」按钮移除 SecureKey，再重新添加，然后完全退出并重新打开应用。",
            .kr: "접근 권한이 허용된 것처럼 보이지만 키 입력 가로채기가 시작되지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 SecureKey를 «–» 버튼으로 제거한 뒤 다시 추가하고, 앱을 완전히 종료한 후 다시 열어 주세요."
        ]
    ]

    static func txt(_ key: String, _ lang: AppLanguage) -> String {
        // Если перевода нет — показываем английский, а не «сырой» ключ
        return strings[key]?[lang] ?? strings[key]?[.en] ?? key
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
    let trustTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

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

                    if !state.hasAccessibility {
                        Button(action: { state.requestAccessibility() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                Text(Localizer.txt("need_access", language))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
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
                                    Text("⌘ " + (currentTip.text[language] ?? currentTip.text[.en] ?? "")).font(.system(size: 13)).opacity(0.8)
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
            state.refreshPermissions()
            state.installTaps()
            state.installLocalMonitor()
            play(welcomePlayer)
        }
        .onDisappear {
            state.setKioskMode(false)
            if state.isCursorHidden {
                CGDisplayShowCursor(kCGNullDirectDisplay)
                NSCursor.unhide()
                state.isCursorHidden = false
            }
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }
        // Когда вы возвращаетесь в приложение из Системных настроек — перепроверяем доступ
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshPermissions()
            if state.hasAccessibility { state.installTaps() }
        }
        // Раз в секунду проверяем, не выдали ли доступ (предупреждение исчезнет само)
        .onReceive(trustTimer) { _ in
            guard !state.isLocked else { return }
            let wasTrusted = state.hasAccessibility
            state.refreshPermissions()
            if !wasTrusted && state.hasAccessibility { state.installTaps() }
        }
        .onReceive(timer) { _ in updateProgress() }
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
            AppState.isLockActive = false
            state.isLocked = false
            unlockProgress = 0
            state.leftCmdDown = false
            state.rightCmdDown = false

            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

            if state.isCursorHidden {
                CGDisplayShowCursor(kCGNullDirectDisplay)
                NSCursor.unhide()
                state.isCursorHidden = false
            }

            state.setKioskMode(false)
            play(unlockPlayer)
        }
    }

    private func startLock() {
        state.refreshPermissions()

        // 1. Нет доступа — показываем системный запрос и открываем настройки
        guard state.hasAccessibility else {
            state.requestAccessibility()
            return
        }

        // 2. Доступ есть, но перехватчик не запустился (обычно «протухшая» запись в настройках)
        guard state.installTaps() else {
            showTapFailedAlert(language)
            openPrivacyPane("Privacy_Accessibility")
            return
        }

        state.installLocalMonitor()
        NSApp.activate(ignoringOtherApps: true)
        state.setKioskMode(true)
        currentTip = Localizer.tips.randomElement() ?? Localizer.tips[0]
        withAnimation(.spring()) {
            AppState.isLockActive = true
            state.isLocked = true
            state.leftCmdDown = false
            state.rightCmdDown = false
            unlockProgress = 0

            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))

            if !state.isCursorHidden {
                CGDisplayHideCursor(kCGNullDirectDisplay)
                NSCursor.hide()
                state.isCursorHidden = true
            }

            state.reEnableTaps()
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
    @ObservedObject var state = AppState.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text(Localizer.txt("settings", lang)).font(.headline).padding(.top)
            Form {
                Picker(Localizer.txt("language", lang), selection: $lang) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(Localizer.txt("ice_theme", lang), isOn: $blueTheme)

                Section(Localizer.txt("diagnostics", lang)) {
                    StatusRow(title: Localizer.txt("ax_title", lang), ok: state.hasAccessibility,
                              openLabel: Localizer.txt("open", lang),
                              action: { openPrivacyPane("Privacy_Accessibility") })
                    StatusRow(title: Localizer.txt("im_title", lang), ok: state.hasInputMonitoring,
                              openLabel: Localizer.txt("open", lang),
                              action: { openPrivacyPane("Privacy_ListenEvent") })
                    StatusRow(title: Localizer.txt("taps", lang), ok: state.tapsActive,
                              openLabel: "", action: nil)
                }
            }.formStyle(.grouped)
            Divider()
            VStack(spacing: 8) {
                Text("Created by Dmitry Miroshnik").font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(blueTheme ? Color.blue : Color.orange)
                Text("SecureKey • Version 1.3").font(.caption2).opacity(0.4)
            }
            Button(Localizer.txt("done", lang)) { dismiss() }.buttonStyle(.borderedProminent).tint(blueTheme ? Color.blue : Color.orange).controlSize(.large).padding(.bottom)
        }.frame(width: 380, height: 580)
    }
}

struct StatusRow: View {
    let title: String
    let ok: Bool
    let openLabel: String
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? Color.green : Color.red)
            Text(title)
            Spacer()
            if !ok, let action = action {
                Button(openLabel, action: action).buttonStyle(.borderless)
            }
        }
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
