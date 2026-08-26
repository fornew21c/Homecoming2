import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 공통 조각

// 배지·진행 바·카운트다운은 Shared/HomecomingViewParts.swift 로 옮겼다.
// 가족용 앱 화면에서도 같은 모양을 써야 하기 때문이다.

/// 안심 확인 버튼. 앱을 열지 않고 잠금화면에서 바로 눌린다.
///
/// 위급할 때 앱을 찾아 실행할 시간은 없다. 이 버튼이 안전귀가 모드의 핵심이다.
struct CheckInButton: View {
    let state: HomecomingAttributes.ContentState
    let activityID: String
    var compact = false

    var body: some View {
        if let range = state.checkInRange, !state.stage.isFinished {
            Button(intent: HomecomingCheckInIntent(activityID: activityID)) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    if !compact {
                        Text("안심 확인")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(timerInterval: range, countsDown: true)
                        .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(width: compact ? 38 : 42)
                }
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, compact ? 5 : 6)
            }
            .buttonStyle(.plain)
            .background(
                Capsule().fill(accent.opacity(0.22))
            )
            .foregroundStyle(accent)
        }
    }

    /// 무응답이면 버튼 자체가 경고가 된다.
    private var accent: Color {
        state.anomaly == .unresponsive
            ? state.tint
            : Color(red: 0.42, green: 0.85, blue: 0.62)
    }
}

// MARK: - 잠금화면 / 배너

/// 잠금화면과 알림 센터에 뜨는 확장 카드.
struct HomecomingLockScreenView: View {
    let attributes: HomecomingAttributes
    let state: HomecomingAttributes.ContentState
    let activityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TransportBadge(state: state, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        // 정류장 이름이 길면 잘리는 것보다 조금 작아지는 편이 낫다.
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    // **양보하는 쪽은 숫자다.** `layoutPriority` 는 왼쪽 이름이 갖는다 —
                    // 이유는 `HomecomingJourneyCard` 의 같은 자리 주석에 있다.
                    CountdownText(state: state)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !state.isStopped {
                        Text(state.arrivalClockLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }

            HomecomingProgressBar(state: state)

            // **다음에 탈 버스.** 서버가 승차 15분 전부터만 싣고, 서울 시내버스는
            // 자료가 없어 영영 안 온다 — 그래서 평소에는 이 줄이 없다.
            //
            // 문구는 `ContentState.busArrivalLine` 이 만든다. 노선도가 같은 것을
            // 쓰므로 두 화면이 갈라질 수 없다.
            if let line = state.busArrivalLine {
                HStack(spacing: 4) {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(line)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 8) {
                Label(attributes.destinationName, systemImage: "house.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))

                if !state.stage.isFinished {
                    Text("\(state.remainingDistanceText) 남음")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 4)

                // 확인은 본인만 누를 수 있다. 가족에게는 버튼이 아니라 상태로 보여야 한다.
                if attributes.audience == .traveler {
                    CheckInButton(state: state, activityID: activityID)
                } else if let range = state.checkInRange, !state.stage.isFinished {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(timerInterval: range, countsDown: true)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 38)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(state.tint)
    }

    /// 귀가자에게는 공유가 돌고 있다는 사실이, 가족에게는 그가 어디쯤인지가 헤드라인이다.
    private var headline: String {
        guard attributes.audience == .traveler else {
            return state.headline(for: attributes.travelerName)
        }
        if state.stage.isFinished { return "도착했어요" }
        if let anomaly = state.anomaly { return anomaly.title }
        return "가족에게 공유 중"
    }

    /// 헤드라인 아래 한 줄.
    ///
    /// **귀가자와 가족이 같은 것을 본다.** 예전에는 귀가자에게만 집 이름과 남은
    /// 거리를 보여 줬는데, 그건 카드 맨 아래 줄이 이미 하는 말이다. 한 줄을 중복에
    /// 쓰면서 집 이름이 길면 잘리기까지 했다 — 실기기에서
    /// "○○아파트3단지…" 로 끊겼다.
    ///
    /// 그 자리에는 새 정보가 와야 한다. 지금 어느 구간에 있고 다음 지점까지 몇
    /// 분인가 — 그게 기다리는 사람에게도, 가는 사람에게도 알고 싶은 것이다.
    private var subtitle: String {
        if state.isStopped { return "위치 공유가 중지되었습니다" }
        if state.stage.isFinished { return "\(attributes.destinationName)에 도착했어요" }
        if let line = state.detailWithDelay, !line.isEmpty { return line }
        // 경로 없이 도는 귀가는 말할 구간이 없다. 그때만 거리로 말한다.
        return "\(state.remainingDistanceText) · \(state.transport.title)"
    }
}

// MARK: - Dynamic Island 확장

/// 길게 눌렀을 때 펼쳐지는 영역. leading / trailing / bottom 세 슬롯으로 나뉜다.
enum HomecomingIsland {

    struct Leading: View {
        let attributes: HomecomingAttributes
        let state: HomecomingAttributes.ContentState

        var body: some View {
            HStack(spacing: 8) {
                TransportBadge(state: state, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.audience == .traveler ? "공유 중" : attributes.travelerName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(statusLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(state.tint)
                }
            }
            .padding(.leading, 10)
        }

        private var statusLabel: String {
            if let anomaly = state.anomaly, !state.stage.isFinished { return anomaly.shortLabel }
            return state.stage.shortLabel
        }
    }

    struct Trailing: View {
        let state: HomecomingAttributes.ContentState

        var body: some View {
            VStack(alignment: .trailing, spacing: 1) {
                CountdownText(state: state, font: .system(size: 20, weight: .semibold, design: .rounded))
                // 도착 후에도 같은 형식을 쓴다. 예정 시각이 실제 시각으로 바뀔 뿐이다.
                if !state.isStopped {
                    Text(state.arrivalClockLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.trailing, 10)
        }
    }

    struct Bottom: View {
        let attributes: HomecomingAttributes
        let state: HomecomingAttributes.ContentState
        let activityID: String

        var body: some View {
            VStack(spacing: 8) {
                HomecomingProgressBar(state: state, height: 7)

                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 4)

                    if state.isSafetyMode && !state.stage.isFinished && attributes.audience == .traveler {
                        // 안전귀가 모드에서는 남은 거리보다 확인 버튼이 중요하다.
                        // 단 본인 화면에서만 — 가족이 대신 눌러 줄 수 있으면 확인의 의미가 없다.
                        CheckInButton(state: state, activityID: activityID, compact: true)
                    } else {
                        if !state.stage.isFinished {
                            Text(state.remainingDistanceText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Image(systemName: "house.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(state.tint)
                    }
                }
            }
            // 확장 영역의 좌우 끝은 아일랜드 곡면에 물려 잘린다.
            // 여백을 충분히 줘야 첫 글자("2호선"의 2)가 살아남는다.
            .padding(.horizontal, 14)
            .padding(.top, 2)
        }

        /// 도착한 뒤에는 이동 수단 문구가 남으면 안 된다("차량 이동 중" 같은).
        private var subtitle: String {
            if state.isStopped { return "위치 공유가 중지되었습니다" }
            if state.stage.isFinished { return "\(attributes.destinationName)에 도착했어요" }
            if let anomaly = state.anomaly { return anomaly.title }
            if let line = state.detailWithDelay, !line.isEmpty { return line }
            return "\(state.transport.title) 이동 중"
        }
    }
}

// MARK: - Dynamic Island 축소

/// 다른 앱을 쓰는 동안 알약 좌우에 붙는 조각.
/// 축소 아일랜드의 왼쪽 — 이동수단 아이콘.
///
/// 애플 타이머와 같은 문법이다: 아이콘이 왼쪽, 숫자가 오른쪽. 숫자를 왼쪽에 두면
/// 알약이 넓어지고 균형이 어색하다.
///
/// **이상 상황이 수단을 이긴다.** 늦거나 연락이 끊긴 것은 뭘 타고 있는지보다 급하다.
struct HomecomingCompactLeading: View {
    let state: HomecomingAttributes.ContentState

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(state.tint)
    }

    private var symbolName: String {
        if let anomaly = state.anomaly, !state.stage.isFinished { return anomaly.symbolName }
        if state.stage.isFinished { return "house.fill" }
        if state.isStopped { return "eye.slash.fill" }
        return state.transport.symbolName
    }
}

struct HomecomingCompactTrailing: View {
    let state: HomecomingAttributes.ContentState

    var body: some View {
        if state.stage.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.tint)
        } else if let range = state.checkInRange, state.checkInIsPressing() {
            // 확인 마감이 코앞이면 도착 시간보다 그쪽이 급하다.
            HStack(spacing: 3) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(timerInterval: range, countsDown: true)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 40)
            }
            .foregroundStyle(state.tint)
        } else {
            // **남은 시간을 `1:21` 로.** 도착 시각(18:52)이 여기 있었는데, 한눈에
            // 알고 싶은 건 "얼마나 남았나" 라 바꿨다. 도착 시각은 확장 화면과
            // 잠금화면에 그대로 있다.
            //
            // **시스템이 굴리는 이 형식은 만들 수 없다.** 네 가지를 실기기에서
            // 시험했고 전부 실패했다 — `maxPrecision` 을 분으로 두면 `1시간21분` 처럼
            // 말로 쓰고(로케일을 바꿔도 `1 hour, 21 min`), `1:21:45` 를 그려 초만
            // 잘라 내려 하면 `frame`+`clipped` 는 `1:…` 으로 줄임표가 붙고
            // `fixedSize` 를 먼저 넣으면 아무것도 안 그려진다.
            //
            // 굴리려면 초가 보여야 하고, 초를 감추려면 굴리기를 포기해야 한다. 그
            // 사이가 없다. `81:45` 는 굴러가지만 mm:ss 가 59:59 에서 넘어가는 관례를
            // 깨고, `1:21:45` 는 여섯 글자라 알약이 벌어진다. 그래서 직접 그린다.
            //
            // 대가는 heartbeat 가 줄여 준다. 2분마다 제자리를 보고하므로 평소에는
            // 최대 2분 뒤처지는데, 화면 자체가 분 단위라 오차도 그만큼이다. 진짜
            // 신호가 끊기면 얼어붙지만 그때는 노선도에 "N분 전 확인" 이 떠서 낡은
            // 값이라고 말해 준다.
            Text(state.remainingClockText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(state.tint)
        }
    }
}

/// 다른 Live Activity 와 자리를 나눠 쓸 때 남는 아주 작은 원.
struct HomecomingMinimal: View {
    let state: HomecomingAttributes.ContentState

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(state.tint)
    }

    private var symbolName: String {
        if let anomaly = state.anomaly, !state.stage.isFinished { return anomaly.symbolName }
        return state.stage.isFinished ? "house.fill" : "figure.walk"
    }
}
