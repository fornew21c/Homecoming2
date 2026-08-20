import CoreLocation
import Foundation

/// 안전귀가 이상 상황 판정.
///
/// 판정 자체는 상태를 거의 갖지 않는 순수 계산이다. 예외는 '멈춰 있음' 하나로,
/// 그건 시간을 재야 알 수 있어서 마지막으로 실제 이동한 지점을 들고 있는다.
///
/// > 중요: 이건 **최선 노력** 판정이다.
/// > '멈춰 있음'과 '무응답'은 정의상 아무 일도 안 일어날 때 성립하는데,
/// > 그 시점의 앱은 대개 잠들어 있다. 실서비스에서는 마감 시각을 아는 서버가
/// > 판정해서 푸시로 밀어 넣어야 한다. 여기 있는 건 앱이 깨어 있는 동안의 보조 장치다.
struct SafetyWatch {

    /// 도착 예정을 이만큼 넘기면 '지연'.
    var lateGrace: TimeInterval = 10 * 60

    /// 이 반경 안에서 이만큼 머무르면 '정지'.
    var stallRadius: CLLocationDistance = 80
    var stallWindow: TimeInterval = 8 * 60

    /// 집 근처에서는 멈춰 있어도 정상이다(엘리베이터, 주차, 편의점).
    /// 이 거리 안이면 '정지'로 보지 않는다.
    var stallIgnoreNearHome: CLLocationDistance = 400

    // MARK: 이동 추적

    private var anchor: CLLocation?
    private var anchoredAt: Date?
    private var lastFixAt: Date?

    /// 픽스가 이 시간 이상 끊겼으면 '멈춰 있음'을 판정하지 않는다.
    ///
    /// 앱이 백그라운드에서 잠들면 위치가 끊긴다. 그건 그 사람이 멈춘 것과 다르다.
    /// 구분할 수 없을 때 경고를 띄우면, 그 경고는 곧 아무도 안 믿는 경고가 된다.
    var fixFreshness: TimeInterval = 120

    /// 새 위치를 반영한다. 기준점에서 충분히 벗어났으면 기준점을 옮긴다.
    mutating func note(_ location: CLLocation, now: Date = Date()) {
        defer { lastFixAt = now }

        // 픽스가 오래 끊겼다가 돌아왔다면 그동안의 정지 시간은 근거가 없다. 다시 센다.
        if let lastFixAt, now.timeIntervalSince(lastFixAt) > fixFreshness {
            anchor = location
            anchoredAt = now
            return
        }

        guard let anchor else {
            self.anchor = location
            anchoredAt = now
            return
        }
        if location.distance(from: anchor) > stallRadius {
            self.anchor = location
            anchoredAt = now
        }
    }

    mutating func reset() {
        anchor = nil
        anchoredAt = nil
        lastFixAt = nil
    }

    // MARK: 판정

    /// 성립하는 이상 상황 중 가장 심각한 하나를 돌려준다.
    ///
    /// - Parameters:
    ///   - distanceToHome: 현재 위치에서 집까지의 직선 거리. 모르면 nil.
    func anomaly(
        expectedArrival: Date,
        checkInDeadline: Date?,
        distanceToHome: CLLocationDistance?,
        now: Date = Date()
    ) -> HomecomingAttributes.Anomaly? {

        var candidates: [HomecomingAttributes.Anomaly] = []

        if let checkInDeadline, now > checkInDeadline {
            candidates.append(.unresponsive)
        }

        if let anchoredAt,
           let lastFixAt,
           now.timeIntervalSince(lastFixAt) <= fixFreshness,   // 잠들어 있었던 것과 구분
           now.timeIntervalSince(anchoredAt) > stallWindow,
           (distanceToHome ?? .greatestFiniteMagnitude) > stallIgnoreNearHome {
            candidates.append(.stalled)
        }

        if now > expectedArrival.addingTimeInterval(lateGrace) {
            candidates.append(.delayed)
        }

        // `.offRoute` 는 경로 폴리라인이 있어야 판정할 수 있어 여기서 만들지 않는다.
        // 서버가 판정해 푸시로 내려보내는 값이다.
        return candidates.min { $0.priority < $1.priority }
    }
}
