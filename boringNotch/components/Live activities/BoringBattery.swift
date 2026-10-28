import SwiftUI
import Defaults

/// A view that displays the battery status with an icon and charging indicator.
struct BatteryView: View {

    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    var batteryWidth: CGFloat = 26
    var isForNotification: Bool

    var icon: String = "battery.0"

    /// Determines the icon to display when charging.
    var iconStatus: String {
        if isCharging {
            return "bolt"
        }
        else if isPluggedIn {
            return "plug"
        }
        else {
            return ""
        }
    }

    /// Determines the color of the battery based on its status.
    var batteryColor: Color {
        if isInLowPowerMode {
            return .yellow
        } else if levelBattery <= 20 && !isCharging && !isPluggedIn {
            return .red
        } else if isCharging || isPluggedIn || levelBattery == 100 {
            return .green
        } else {
            return .white
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {

            Image(systemName: icon)
                .resizable()
                .fontWeight(.thin)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white.opacity(0.5))
                .frame(
                    width: batteryWidth + 1
                )

            RoundedRectangle(cornerRadius: 2.5)
                .fill(batteryColor)
                .frame(
                    width: CGFloat(((CGFloat(CFloat(levelBattery)) / 100) * (batteryWidth - 6))),
                    height: (batteryWidth - 2.75) - 18
                )
                .padding(.leading, 2)

            if iconStatus != "" && (isForNotification || Defaults[.showPowerStatusIcons]) {
                ZStack {
                    Image(iconStatus)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.white)
                        .frame(
                            width: 17,
                            height: 17
                        )
                }
                .frame(width: batteryWidth, height: batteryWidth)
            }
        }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// Samples CPU, memory and temperatures while the battery popover is open
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsed: UInt64 = 0
    /// Celsius readings from the XPC helper, keyed "cpu", "ssd" and "battery"
    @Published private(set) var temperatures: [String: Double] = [:]
    let memoryTotal = ProcessInfo.processInfo.physicalMemory

    private let host = mach_host_self()
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var timer: Timer?

    func start() {
        sample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousTicks = nil
    }

    private func sample() {
        if let ticks = cpuTicks() {
            // CPU load is the share of busy ticks since the previous sample
            if let previous = previousTicks, ticks.total > previous.total {
                cpuUsage = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
            }
            previousTicks = ticks
        }
        if let used = usedMemory() {
            memoryUsed = used
        }
        // The sandbox blocks the sensors, so the unsandboxed helper reads them
        Task {
            let readings = await XPCHelperClient.shared.currentTemperatures()
            if !readings.isEmpty { temperatures = readings }
        }
    }

    private func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed
    private func usedMemory() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let appPages = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let pages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }
}

/// A rounded tile in the battery popover's grid
private struct StatTile<Content: View>: View {
    var title: LocalizedStringKey
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// What's normal for a sensor, in Celsius, used to color its reading
private struct TemperatureRange {
    /// Left end of the tile's bar
    var floor: Double
    /// Green up to here
    var normal: Double
    /// Fully red from here
    var hot: Double
    /// Blue below here, for a battery that's too cold to charge well
    var cold: Double? = nil

    // Apple Silicon dies idle around 40–50° and throttle in the high 90s
    static let cpu = TemperatureRange(floor: 30, normal: 60, hot: 95)
    // NAND slows itself down past about 70°
    static let ssd = TemperatureRange(floor: 25, normal: 45, hot: 70)
    // Apple rates the battery for 10–35°; above 45° it ages quickly
    static let battery = TemperatureRange(floor: 10, normal: 35, hot: 45, cold: 10)

    func fraction(_ reading: Double) -> Double {
        min(max((reading - floor) / (hot + 10 - floor), 0), 1)
    }

    /// Green while normal, easing through yellow and orange to red at hot
    func color(_ reading: Double) -> Color {
        if let cold, reading < cold { return .blue }
        let heat = min(max((reading - normal) / (hot - normal), 0), 1)
        return Color(hue: 0.33 * (1 - heat), saturation: 0.75, brightness: 0.95)
    }
}

/// CPU and memory load plus temperatures, laid out as tiles under the battery header
struct SystemMonitorSection: View {
    @StateObject private var monitor = SystemMonitor()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                loadTile(
                    title: "CPU",
                    systemImage: "cpu",
                    value: "\(Int((monitor.cpuUsage * 100).rounded()))%",
                    fraction: monitor.cpuUsage
                )
                loadTile(
                    title: "Memory",
                    systemImage: "memorychip",
                    value: "\(formatGigabytes(monitor.memoryUsed)) GB",
                    fraction: Double(monitor.memoryUsed) / Double(max(monitor.memoryTotal, 1))
                )
            }
            HStack(spacing: 8) {
                temperatureTile(title: "CPU", systemImage: "thermometer.medium", key: "cpu", range: .cpu)
                temperatureTile(title: "SSD", systemImage: "internaldrive", key: "ssd", range: .ssd)
                temperatureTile(title: "Battery", systemImage: "battery.100", key: "battery", range: .battery)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func loadTile(title: LocalizedStringKey, systemImage: String, value: String, fraction: Double) -> some View {
        let fraction = min(max(fraction, 0), 1)
        return StatTile(title: title, systemImage: systemImage) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(fraction > 0.85 ? Color.red : fraction > 0.6 ? Color.yellow : Color.green)
                        .frame(width: max(proxy.size.width * fraction, 4))
                }
            }
            .frame(height: 4)
        }
        .animation(.smooth, value: fraction)
    }

    private func temperatureTile(title: LocalizedStringKey, systemImage: String, key: String, range: TemperatureRange) -> some View {
        let reading = monitor.temperatures[key]
        let color = reading.map(range.color) ?? .gray
        return StatTile(title: title, systemImage: systemImage) {
            Text(reading.map { "\(Int($0.rounded()))°" } ?? "–")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(color)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    if let reading {
                        Capsule()
                            .fill(color)
                            .frame(width: max(proxy.size.width * range.fraction(reading), 4))
                    }
                }
            }
            .frame(height: 4)
        }
        .animation(.smooth, value: reading)
    }

    private func formatGigabytes(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return gigabytes.formatted(.number.precision(.fractionLength(1)))
    }
}

/// A view that displays detailed battery information and system stats.
struct BatteryMenuView: View {

    var isPluggedIn: Bool
    var isCharging: Bool
    var levelBattery: Float
    var maxCapacity: Float
    var timeToFullCharge: Int
    var isInLowPowerMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battery")
                        .font(.headline)
                    statusLine
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
                Text("\(Int(levelBattery))%")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            SystemMonitorSection()
        }
        .padding(12)
        .frame(width: 280)
        .foregroundColor(.white)
    }

    /// One line summing up power state, e.g. "Charging · 40 min to full"
    private var statusLine: Text {
        var parts: [String] = []
        if isInLowPowerMode {
            parts.append(String(localized: "Low Power Mode"))
        }
        if isCharging {
            parts.append(String(localized: "Charging"))
            if timeToFullCharge > 0 {
                parts.append(String(localized: "\(timeToFullCharge) min to full"))
            }
        } else if isPluggedIn && levelBattery >= 80 {
            parts.append(String(localized: "Charging on Hold"))
        } else if isPluggedIn {
            parts.append(String(localized: "Plugged In"))
        }
        parts.append(String(localized: "Max capacity \(Int(maxCapacity))%"))
        return Text(parts.joined(separator: " · "))
    }
}

/// A view that displays the battery status and allows interaction to show detailed information.
struct BoringBatteryView: View {
    
    @State var batteryWidth: CGFloat = 26
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float = 0
    var timeToFullCharge: Int = 0
    @State var isForNotification: Bool = false
    
    @State private var showPopupMenu: Bool = false
    @State private var isPressed: Bool = false
    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil

    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        Button(action: {
            withAnimation {
                showPopupMenu.toggle()
            }
        }) {
            HStack {
                // macOS reports -1 while it's still estimating, so this appears about a minute after plugging in
                if isCharging && timeToFullCharge > 0 && !isForNotification {
                    Label(timeToFullChargeText, systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .foregroundStyle(.gray)
                }
                if Defaults[.showBatteryPercentage] {
                    Text("\(Int32(levelBattery))%")
                        .font(.callout)
                        .foregroundStyle(.white)
                }
                BatteryView(
                    levelBattery: levelBattery,
                    isPluggedIn: isPluggedIn,
                    isCharging: isCharging,
                    isInLowPowerMode: isInLowPowerMode,
                    batteryWidth: batteryWidth,
                    isForNotification: isForNotification
                )
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .popover(
            isPresented: $showPopupMenu,
            arrowEdge: .bottom) {
            BatteryMenuView(
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                levelBattery: levelBattery,
                maxCapacity: maxCapacity,
                timeToFullCharge: timeToFullCharge,
                isInLowPowerMode: isInLowPowerMode
            )
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering {
                    hideTask?.cancel()
                    hideTask = nil
                } else {
                    scheduleHideIfNeeded()
                }
            }
        }
        .onChange(of: showPopupMenu) {
            vm.isBatteryPopoverActive = showPopupMenu
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private var timeToFullChargeText: String {
        let hours = timeToFullCharge / 60
        let minutes = timeToFullCharge % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { showPopupMenu = false } }
        }
    }
}

#Preview {
    BoringBatteryView(
        batteryWidth: 30,
        isCharging: false,
        isInLowPowerMode: false,
        isPluggedIn: true,
        levelBattery: 80,
        maxCapacity: 100,
        timeToFullCharge: 10,
        isForNotification: false
    ).frame(width: 200, height: 200)
}
