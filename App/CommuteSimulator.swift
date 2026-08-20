import Foundation
import Observation

/// 실제 위치 추적 대신 귀가 과정을 압축해서 재생하는 시뮬레이터.
///
/// 데모용이다. 실서비스에서는 이 자리에 CLLocationManager 나 서버 푸시가 들어가고,
/// 거리·ETA 를 계산해 `HomecomingActivityManager.update(...)` 를 부르는 구조는 그대로다.
@Observable
@MainActor
final class CommuteSimulator {

    private let manager: HomecomingActivityManager
    private var task: Task<Void, Never>?

    /// 전체 경로 길이(m).
    private let totalMeters = 11_000

    /// 한 틱마다 줄어드는 거리(m)와 틱 간격(초). 11km 를 약 1분에 주파한다.
    ///
    /// 틱을 1초로 두면 갱신할 때마다 다이나믹 아일랜드가 계속 펼쳐져 화면을 가린다.
    /// 실제 위치 추적도 같은 이유로 갱신을 몰아서 보내는 편이 낫다.
    private let metersPerTick = 1_100
    private let tickSeconds: Double = 6

    private(set) var remainingMeters: Int = 11_000
    private(set) var isSimulating = false
    private(set) var lastError: String?

    var travelerName = "아빠"

    init(manager: HomecomingActivityManager) {
        self.manager = manager
    }

    var isRunning: Bool { manager.isRunning }

    var progressText: String {
        guard isSimulating else { return "대기 중" }
        if remainingMeters < 1_000 { return "\(remainingMeters)m 남음" }
        return String(format: "%.1fkm 남음", Double(remainingMeters) / 1_000)
    }

    // MARK: - 제어

    func start() {
        guard !isSimulating else { return }
        lastError = nil
        remainingMeters = totalMeters

        // 데모는 갱신을 전부 로컬에서 돌린다. 서버가 밀어 줄 것이 없으므로 토큰도 받지 않는다.
        manager.pushType = nil

        do {
            try manager.start(
                travelerName: travelerName,
                transport: .subway,
                totalMeters: totalMeters,
                expectedArrival: arrival(for: totalMeters)
            )
        } catch {
            lastError = error.localizedDescription
            return
        }

        isSimulating = true
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isSimulating = false
        Task { await manager.cancel() }
    }

    // MARK: - 재생 루프

    private func run() async {
        while !Task.isCancelled, remainingMeters > 0 {
            try? await Task.sleep(for: .seconds(tickSeconds))
            guard !Task.isCancelled else { return }

            remainingMeters = max(0, remainingMeters - metersPerTick)

            await manager.update(
                remainingMeters: remainingMeters,
                expectedArrival: arrival(for: remainingMeters),
                transport: transport(for: remainingMeters),
                detail: detail(for: remainingMeters)
            )
        }

        guard !Task.isCancelled else { return }
        await manager.finish()
        isSimulating = false
    }

    // MARK: - 가짜 추정값

    private func arrival(for meters: Int) -> Date {
        Date().addingTimeInterval(TimeInterval(estimatedMinutes(for: meters) * 60))
    }

    /// 남은 거리를 분으로. 지하철 구간은 빠르게, 도보 구간은 느리게 잡는다.
    private func estimatedMinutes(for meters: Int) -> Int {
        if meters <= 800 {
            return max(1, Int(ceil(Double(meters) / 70)))     // 도보 약 70m/분
        }
        return max(1, Int(ceil(Double(meters) / 450)))        // 지하철 약 450m/분
    }

    private func transport(for meters: Int) -> HomecomingAttributes.Transport {
        meters <= 800 ? .walk : .subway
    }

    private func detail(for meters: Int) -> String {
        switch meters {
        case 0:
            return "현관 도착"
        case ..<300:
            return "아파트 정문 앞"
        case ..<800:
            return "역에서 나오는 중"
        case ..<2_500:
            return "2호선 · 1정거장 남음"
        case ..<5_000:
            return "2호선 · 3정거장 남음"
        default:
            return "2호선 · 6정거장 남음"
        }
    }
}
