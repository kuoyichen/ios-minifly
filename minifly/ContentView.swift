import SwiftUI

struct ContentView: View {
    @StateObject private var connection = ConnectionManager()
    @StateObject private var motion = MotionManager()

    // Throttle state
    @State private var dotY: CGFloat = 0
    @State private var trackBottom: CGFloat = 0
    @State private var initialized = false
    @State private var unlocked = false
    @State private var unlocking = false
    @State private var unlockProgress: CGFloat = 0
    @State private var isDragging = false
    @State private var bottomSince: Date? = nil

    // Trim
    @State private var trimValue: Int = 5

    // Disconnect detection
    @State private var wasMiniflyConnected = false

    // Blink animation
    @State private var blinkAlpha: Double = 1.0

    // Screen size
    @State private var screenSize: CGSize = .zero

    // Track parameters
    private let trackLengthRatio: CGFloat = 0.133
    private let dotRadiusPt: CGFloat = 30 // half of 60dp equivalent

    var isMiniflyConnected: Bool {
        connection.wifiName.hasPrefix("Minifly")
    }

    var isDisconnected: Bool {
        wasMiniflyConnected && !isMiniflyConnected
    }

    var trackLength: CGFloat {
        screenSize.height * trackLengthRatio
    }

    var trackTop: CGFloat {
        trackBottom - trackLength
    }

    var throttlePercent: Int {
        guard trackBottom > trackTop, trackBottom > 0 else { return 0 }
        let ratio = 1.0 - ((dotY - trackTop) / (trackBottom - trackTop))
        return Int((max(0, min(1, ratio)) * 100).rounded())
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Main content
                mainContent(geo: geo)
            }
            .onAppear {
                screenSize = geo.size
                if !initialized {
                    trackBottom = geo.size.height * 0.7
                    dotY = trackBottom
                    initialized = true
                }
                startBlinkAnimation()
                startRSSIRefresh()
            }
        }
        .onChange(of: isMiniflyConnected) { connected in
            if connected { wasMiniflyConnected = true }
        }
        .onChange(of: isDragging) { dragging in
            handleDragRelease(dragging: dragging)
        }
        .onChange(of: motion.rudderValue) { value in
            connection.rudder = value
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            // Sync throttle value to connection manager
            if trackBottom > trackTop, trackBottom > 0 {
                let ratio = 1.0 - ((dotY - trackTop) / (trackBottom - trackTop))
                connection.throttle = Int((1000.0 + max(0, min(1, ratio)) * 1000.0).rounded())
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    func mainContent(geo: GeometryProxy) -> some View {
        // Top: WiFi name + protocol message
        VStack(spacing: 4) {
            Text(connection.wifiName)
                .font(.system(size: 18))
                .foregroundColor(.white)
            Text(String(format: "SRV%04d%04d1%d001500#",
                        connection.rudder, connection.throttle, connection.trim))
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .position(x: geo.size.width / 2, y: geo.safeAreaInsets.top + 60)

        // Logo
        logoView()
            .position(x: geo.size.width / 2, y: geo.safeAreaInsets.top + 140)

        // Track line
        if initialized {
            trackView(geo: geo)
        }

        // Trim controls
        if initialized {
            trimView(geo: geo)
        }

        // Throttle dot
        if initialized {
            throttleDotView(geo: geo)
        }

        // RSSI / disconnect warning (bottom-left)
        rssiView()
            .position(x: 110, y: geo.size.height - 60)

        // Connect + Reset buttons (bottom-right)
        buttonsView()
            .position(x: geo.size.width - 80, y: geo.size.height - 70)

        // Scan dialog
        if connection.showScanDialog {
            scanDialogView()
        }
    }

    // MARK: - Logo

    @ViewBuilder
    func logoView() -> some View {
        if let uiImage = UIImage(named: "minifly") {
            Image(uiImage: processLogo(uiImage))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
        }
    }

    /// Remove white background from logo
    func processLogo(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let r = pixelData[i]
            let g = pixelData[i + 1]
            let b = pixelData[i + 2]
            if r > 220 && g > 220 && b > 220 {
                pixelData[i + 3] = 0 // Make transparent
            }
        }

        guard let outputCGImage = context.makeImage() else { return image }
        return UIImage(cgImage: outputCGImage)
    }

    // MARK: - Track

    @ViewBuilder
    func trackView(geo: GeometryProxy) -> some View {
        Canvas { ctx, size in
            let centerX = size.width / 2
            // Throttle track line
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: centerX, y: trackTop))
                    p.addLine(to: CGPoint(x: centerX, y: trackBottom))
                },
                with: .color(.gray.opacity(0.6)),
                lineWidth: 2
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Trim

    @ViewBuilder
    func trimView(geo: GeometryProxy) -> some View {
        let centerX = geo.size.width / 2
        let trimLineWidth = geo.size.width * 0.56
        let trimLineLeft = centerX - trimLineWidth * 4.0 / 8.0
        let trimLineY = trackTop - 125

        // Trim line + ticks
        Canvas { ctx, size in
            // Horizontal line
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: trimLineLeft, y: trimLineY))
                    p.addLine(to: CGPoint(x: trimLineLeft + trimLineWidth, y: trimLineY))
                },
                with: .color(.gray),
                lineWidth: 1
            )
            // Tick marks 1–9
            for i in 1...9 {
                let x = trimLineLeft + trimLineWidth * CGFloat(i - 1) / 8.0
                let tickH: CGFloat = i == trimValue ? 10 : 5
                let color: Color = i == trimValue ? .yellow : .gray
                let width: CGFloat = i == trimValue ? 2 : 1
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: trimLineY - tickH))
                        p.addLine(to: CGPoint(x: x, y: trimLineY + tickH))
                    },
                    with: .color(color),
                    lineWidth: width
                )
            }
            // Marker circle
            let markerX = trimLineLeft + trimLineWidth * CGFloat(trimValue - 1) / 8.0
            ctx.fill(
                Path(ellipseIn: CGRect(x: markerX - 5, y: trimLineY - 5, width: 10, height: 10)),
                with: .color(.yellow)
            )
        }
        .allowsHitTesting(false)

        // Trim value number
        let markerX = trimLineLeft + trimLineWidth * CGFloat(trimValue - 1) / 8.0
        Text("\(trimValue)")
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(.yellow)
            .position(x: markerX, y: trimLineY - 30)

        // L button
        Button(action: {
            if trimValue > 1 {
                trimValue -= 1
                connection.trim = trimValue
            }
        }) {
            Text("L")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.6))
                .cornerRadius(8)
        }
        .position(x: trimLineLeft - 30, y: trimLineY)

        // R button
        Button(action: {
            if trimValue < 9 {
                trimValue += 1
                connection.trim = trimValue
            }
        }) {
            Text("R")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.6))
                .cornerRadius(8)
        }
        .position(x: trimLineLeft + trimLineWidth + 30, y: trimLineY)
    }

    // MARK: - Throttle Dot

    @ViewBuilder
    func throttleDotView(geo: GeometryProxy) -> some View {
        let centerX = geo.size.width / 2
        let dotColor: Color = unlocked ? Color(red: 0.3, green: 0.69, blue: 0.31) : .red
        let ringGap: CGFloat = 4
        let ringStroke: CGFloat = 20
        let ringRadius = dotRadiusPt + ringGap + ringStroke / 2

        ZStack {
            // Dot
            Circle()
                .fill(dotColor)
                .frame(width: dotRadiusPt * 2, height: dotRadiusPt * 2)

            if unlocked {
                // Background ring
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: ringStroke)
                    .frame(width: ringRadius * 2, height: ringRadius * 2)

                // Throttle arc
                Circle()
                    .trim(from: 0, to: CGFloat(throttlePercent) / 100.0)
                    .stroke(Color.blue, lineWidth: ringStroke)
                    .frame(width: ringRadius * 2, height: ringRadius * 2)
                    .rotationEffect(.degrees(-90))
            }

            if unlocking && !unlocked {
                // Unlock progress arc
                Circle()
                    .trim(from: 0, to: unlockProgress)
                    .stroke(Color(red: 0.3, green: 0.69, blue: 0.31), lineWidth: 3)
                    .frame(width: ringRadius * 2, height: ringRadius * 2)
                    .rotationEffect(.degrees(-90))
            }

            // Text overlay
            if unlocked {
                Text("\(throttlePercent)%")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                    .offset(y: -(ringRadius + 20))
            } else {
                Text("unlock")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(isMiniflyConnected ? blinkAlpha : 1.0))
            }
        }
        .position(x: centerX, y: dotY)
        .gesture(
            unlocked ? DragGesture()
                .onChanged { value in
                    isDragging = true
                    let newY = (dotY + value.translation.height)
                    dotY = max(trackTop, min(trackBottom, newY))
                }
                .onEnded { _ in
                    isDragging = false
                } : nil
        )
        .simultaneousGesture(
            !unlocked ? LongPressGesture(minimumDuration: 0.5)
                .onChanged { _ in
                    if !unlocking {
                        unlocking = true
                        startUnlockAnimation()
                    }
                }
                .onEnded { _ in
                    // Unlock completed
                    unlocking = false
                    unlocked = true
                    motion.captureBase()
                } : nil
        )
        .onLongPressGesture(minimumDuration: 0.01, pressing: { pressing in
            if !unlocked && !pressing && unlocking {
                // Finger released before unlock complete
                cancelUnlockAnimation()
            }
        }, perform: {})

        // Auto-lock after 5 seconds at bottom
        .onChange(of: isAtBottom) { atBottom in
            if atBottom && unlocked {
                bottomSince = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    if self.isAtBottom && self.unlocked {
                        self.unlocked = false
                        self.unlocking = false
                        self.unlockProgress = 0
                        self.motion.lock()
                    }
                }
            }
        }
    }

    var isAtBottom: Bool {
        initialized && dotY >= trackBottom - 1
    }

    // MARK: - RSSI / Disconnect

    @ViewBuilder
    func rssiView() -> some View {
        if isMiniflyConnected {
            let rssiPercent = max(0, min(100, (connection.rssi + 100) * 100 / 70))
            Text("RSSI: \(connection.rssi)dB, \(rssiPercent)%")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        } else if isDisconnected {
            Text("MiniFly wifi disconnect")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.red.opacity(blinkAlpha))
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    func buttonsView() -> some View {
        VStack(spacing: 8) {
            // Reset button
            Button(action: {
                connection.resetConnection()
                trimValue = 5
                unlocked = false
                unlocking = false
                unlockProgress = 0
                motion.lock()
                dotY = trackBottom
            }) {
                Text("reset")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.3, green: 0.69, blue: 0.31))
                    .cornerRadius(8)
            }

            // Connect button
            Button(action: {
                connection.startQuickConnect()
            }) {
                Text(isMiniflyConnected ? "connected" : "connect")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(isMiniflyConnected ? 1.0 : blinkAlpha))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
                    .overlay(
                        !isMiniflyConnected ?
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(blinkAlpha), lineWidth: 2)
                        : nil
                    )
            }
        }
    }

    // MARK: - Scan Dialog

    @ViewBuilder
    func scanDialogView() -> some View {
        Color.black.opacity(0.5)
            .ignoresSafeArea()
            .onTapGesture {
                if !connection.isConnecting {
                    connection.showScanDialog = false
                }
            }

        VStack(spacing: 12) {
            Text("Quick Connect")
                .font(.headline)
                .foregroundColor(.white)

            Text(connection.scanStatus)
                .font(.system(size: 13))
                .foregroundColor(.gray)

            if connection.isConnecting {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }

            Button("Close") {
                connection.showScanDialog = false
            }
            .foregroundColor(.blue)
        }
        .padding(24)
        .background(Color(white: 0.2))
        .cornerRadius(16)
    }

    // MARK: - Animations & Timers

    func startBlinkAnimation() {
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            blinkAlpha = 0.2
        }
    }

    func startRSSIRefresh() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if isMiniflyConnected {
                connection.refreshRSSI()
            }
        }
    }

    func startUnlockAnimation() {
        unlockProgress = 0
        withAnimation(.linear(duration: 0.5)) {
            unlockProgress = 1.0
        }
    }

    func cancelUnlockAnimation() {
        unlocking = false
        withAnimation(.linear(duration: 0.1)) {
            unlockProgress = 0
        }
    }

    func handleDragRelease(dragging: Bool) {
        if !dragging && unlocked && !isAtBottom {
            // Auto-drop throttle after 0.5 second
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard !self.isDragging && self.unlocked && !self.isAtBottom else { return }
                // Smoothly return to bottom
                let startY = self.dotY
                let steps = 20
                for i in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.015) {
                        self.dotY = startY + (self.trackBottom - startY) * CGFloat(i) / CGFloat(steps)
                        if i == steps {
                            self.dotY = self.trackBottom
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
