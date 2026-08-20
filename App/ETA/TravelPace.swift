import CoreLocation
import Foundation

/// 실제로 집에 가까워지는 속도를 관측한다.
///
/// 지면 속도가 아니라 **접근 속도**를 잰다. 남은 거리가 줄어드는 속도다.
/// 버스가 돌아가는 구간에서는 시속 40km 로 달려도 집과는 안 가까워진다.
/// 도착 예정 시각을 맞히는 데 필요한 건 후자다.
///
/// 관측값은 외부 추정(MapKit·서버)을 **대체하지 않고 보정한다**.
/// 출발 직후에는 근거가 없고, 신호등 하나에 멈춰도 값이 튀기 때문이다.
struct TravelPace {

    /// 이 시간보다 오래된 표본은 버린다.
    var window: TimeInterval = 6 * 60

    /// 관측 구간이 이보다 짧으면 믿지 않는다.
    var minimumSpan: TimeInterval = 90

    /// 이만큼 좁히지 못했으면 믿지 않는다. 멈춰 있는 것과 구별이 안 된다.
    var minimumClosed: CLLocationDistance = 150

    /// 관측이 아무리 좋아도 외부 추정을 이 비율 이상 밀어내지 않는다.
    var maximumWeight: Double = 0.7

    /// 보정 후 도착 예정이 이보다 멀어지면 관측이 잘못된 것으로 본다.
    var sanityCeiling: TimeInterval = 3 * 60 * 60

    private var samples: [(at: Date, remaining: CLLocationDistance)] = []

    // MARK: - 표본

    mutating func note(remainingMeters: CLLocationDistance, at now: Date = Date()) {
        samples.append((at: now, remaining: remainingMeters))
        samples.removeAll { now.timeIntervalSince($0.at) > window }
    }

    mutating func reset() {
        samples.removeAll()
    }

    // MARK: - 관측값

    /// 접근 속도(m/s). 근거가 부족하거나 멀어지는 중이면 nil.
    func closingSpeed(now: Date = Date()) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }

        let span = last.at.timeIntervalSince(first.at)
        let closed = first.remaining - last.remaining

        guard span >= minimumSpan, closed >= minimumClosed else { return nil }
        return closed / span
    }

    /// 관측을 얼마나 믿을지. 관측 구간이 길수록 커지고 `maximumWeight` 에서 멈춘다.
    func weight(now: Date = Date()) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= minimumSpan else { return 0 }

        let ratio = min(1, (span - minimumSpan) / (window - minimumSpan))
        return maximumWeight * ratio
    }

    /// 외부 추정을 관측으로 보정한 도착 예정 시각.
    ///
    /// 관측이 못 미더우면 받은 값을 그대로 돌려준다.
    /// - Parameter remainingMeters: `note(remainingMeters:)` 에 넣은 것과 **같은 척도**여야 한다.
    ///   직선거리로 재고 경로거리로 나누면 조용히 틀린 값이 나온다.
    func corrected(
        base: Date,
        remainingMeters: Int,
        now: Date = Date()
    ) -> Date {
        guard let speed = closingSpeed(now: now), speed > 0 else { return base }

        let observedSeconds = Double(remainingMeters) / speed
        guard observedSeconds < sanityCeiling else { return base }

        let baseSeconds = max(0, base.timeIntervalSince(now))
        let w = weight(now: now)
        let blended = baseSeconds * (1 - w) + observedSeconds * w

        // 도착 예정이 현재보다 앞설 수는 없다.
        return now.addingTimeInterval(max(30, blended))
    }

    // MARK: - 표시용

    /// 관측 속도(km/h). 화면에 보여 주는 진단값.
    func observedKilometersPerHour(now: Date = Date()) -> Double? {
        closingSpeed(now: now).map { $0 * 3.6 }
    }
}
