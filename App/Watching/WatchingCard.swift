import CoreLocation
import SwiftUI

/// 가족과 귀가자가 **똑같이** 보는 카드.
///
/// 가족이 앱을 열었을 때 가장 먼저 봐야 할 것이었다 — 지금까지 앱을 열면
/// 귀가자용 조종석(귀가 시작 버튼, 집 등록)이 그대로 나왔고, 기다리는 사람에게는
/// 아무 쓸모가 없었다.
///
/// 귀가자도 같은 뷰를 그대로 쓴다. 자기 폰에 "아빠가 오는 중" 이라고 뜨는 건
/// 어색하지만 그게 요점이다 — 귀가자가 보는 것은 자기 상태가 아니라 **가족에게
/// 나가고 있는 그림**이다. 두 화면이 한 글자라도 다르면 "가족에게 이렇게 보인다"는
/// 확인이 거짓말이 된다. 그래서 뷰를 둘로 나누지 않고, `entry` 대신 `attributes`·
/// `state`·`lastFixedAt` 세 값만 받는다 — 가족 쪽은 `WatchingStore.Entry` 에서,
/// 귀가자 쪽은 진행 중인 액티비티에서 꺼내 준다.
struct HomecomingJourneyCard: View {

    let attributes: HomecomingAttributes
    let state: HomecomingAttributes.ContentState
    /// 마지막으로 위치가 확인된 때. 가족 쪽은 갱신 푸시를 받은 시각, 귀가자 쪽은
    /// 마지막으로 서버에 보고한 시각이다.
    ///
    /// **둘은 뜻이 같지 않다.** 제자리 보고(heartbeat)는 새 픽스가 없을 때 들고 있던
    /// 옛 픽스를 다시 보내므로, 보고한 시각은 새것인데 자리는 옛것이다. 그래서 이 값은
    /// `state.measuredAt` 이 없을 때만 쓰는 대체값이다 — 나이의 주인은 픽스 시각이다.
    let lastFixedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TransportBadge(state: state, size: 44)

                // **이름이 숫자보다 먼저다.** 좁은 화면에서 폭이 모자라면 숫자가
                // 작아지고 이름은 온전히 남아야 한다.
                //
                // 2026-08-19 iPhone SE2 에서 `아빠 집으로 가...` 와
                // `국회의사당역까지…` 로 잘렸다. 큰 숫자가 `1:11:20` 일곱 글자로
                // 늘어난 뒤 오른쪽이 폭을 다 가져갔기 때문이다(그날 아침에
                // `style: .relative` 에서 `Text(timerInterval:)` 로 바꿨다).
                //
                // **잘린 이름은 안 잘린 이름보다 나쁘다** — 어디인지 알아볼 수 없다.
                // 숫자는 등폭 숫자라 조금 작아져도 읽히고, 남은 시간은 아래 도착
                // 시각으로도 확인된다. 그래서 양보하는 쪽은 숫자다.
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.headline(for: attributes.travelerName))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        // 정류장 이름이 길면 잘리는 것보다 조금 작아지는 편이 낫다.
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    CountdownText(state: state, font: .system(size: 26, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    // 공유를 껐으면 도착 예정 시각은 더 이상 아무 뜻이 없다.
                    if !state.isStopped {
                        Text(state.arrivalClockLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            // `도착 예정` 이 붙어 세 글자 길어졌다. 좁은 화면에서
                            // 두 줄로 접히면 카드 높이가 흔들린다.
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }

            // 경로가 있으면 노선도, 없으면 진행 바. 경로 없이 시작한 귀가는
            // 그릴 선이 없다.
            //
            // 도착(isFinished)해도 노선도를 그대로 보여 준다 — 진행 바로
            // 바꿔 버리면 방금까지 정류장을 채워 가며 보던 화면이 도착하는
            // 순간 다른 그림으로 뒤바뀐다. 노선도는 "다 지났다"는 상태(마지막
            // 정류장까지 채워진 점)를 이미 표현할 수 있으므로 바꿀 이유가 없다.
            if let shape = attributes.routeShape {
                RouteStripView(shape: shape, state: state, lastFixedAt: lastFixedAt)
            } else {
                HomecomingProgressBar(state: state, height: 8)
            }

            HStack(spacing: 8) {
                Label(attributes.destinationName, systemImage: "house.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !state.stage.isFinished {
                    Text("\(state.remainingDistanceText) 남음")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(state.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(state.tint.opacity(0.35), lineWidth: 1)
        )
    }

    /// **`detailWithDelay` 를 쓴다. `detail` 이 아니다.**
    ///
    /// 잠금화면과 확장 아일랜드는 처음부터 `detailWithDelay` 였는데 이 카드만 `detail`
    /// 이었다. 그래서 같은 상태를 그리면서 지연 표기가 카드에만 없었다 — 화면마다
    /// 다른 말을 하면 "가족에게 이렇게 보인다" 가 성립하지 않는다.
    ///
    /// 지연을 따로 놓지 않고 문구 뒤에 붙이는 이유는 `detailWithDelay` 주석에 있다.
    private var subtitle: String {
        if state.isStopped { return "위치 공유가 중지되었습니다" }
        if state.stage.isFinished { return "\(attributes.destinationName)에 도착했어요" }
        if let line = state.detailWithDelay, !line.isEmpty { return line }
        return "\(state.transport.title) 이동 중"
    }
}

/// 카드와 지도를 함께 그린다. **귀가자와 가족이 이걸 똑같이 본다.**
///
/// 위 `HomecomingJourneyCard` 주석의 이유가 지도에도 그대로 적용된다 — 귀가자가
/// 보는 것은 자기 상태가 아니라 **가족에게 나가고 있는 그림**이다. 지도를 가족
/// 쪽에만 두면 귀가자는 자기 위치가 가족에게 어떻게 보이는지 확인할 수 없다.
/// 좌표가 틀려도(4km 어긋난 집을 "집" 이라고 그리던 일) 본인 화면에서는 안
/// 드러난다.
///
/// 그래서 두 화면이 이 뷰 하나를 공유한다. 다른 것은 넘겨받는 값의 출처뿐이다 —
/// 가족 쪽은 `WatchingStore.Entry`, 귀가자 쪽은 진행 중인 액티비티에서 꺼낸다.
struct HomecomingJourneySection: View {

    let attributes: HomecomingAttributes
    let state: HomecomingAttributes.ContentState
    let lastFixedAt: Date?

    /// 어느 귀가인가. 지도가 경로 좌표를 받아 올 열쇠다.
    ///
    /// 가족 쪽은 액티비티 고정값에서 온다(서버가 넣어 준다). 귀가자 쪽은
    /// 코디네이터가 들고 있는 값을 쓴다 — 첫 출발에서는 액티비티가 세션보다
    /// 먼저 떠서 고정값이 비어 있기 때문이다.
    let sessionID: String?

    let routes: RouteGeometryStore

    var body: some View {
        VStack(spacing: 10) {
            // **지도가 위다.** 예전에는 카드가 위였는데, 카드가 정류장 10개짜리
            // 노선도 때문에 450pt 를 먹어서 지도가 화면 606pt 에서 시작했다.
            // 화면이 874pt 니 스크롤하지 않으면 지도의 268pt 만 보였고, 하필
            // 귀가자 마커는 영역의 가장자리라(`region()` 이 bbox × 1.25 다) 그
            // 잘린 띠에 들어갔다 — 지도를 열었는데 사람이 안 보였다(2026-08-25).
            //
            // 카드를 줄이는 길도 있었지만 노선도는 다 보여야 한다. 그래서 순서를
            // 바꿨다. 지도는 제목 바로 아래에서 시작해 통째로 들어오고, 카드는
            // 스크롤해서 본다 — 카드가 답하는 "얼마나 남았나" 는 잠금화면과
            // 아일랜드에도 있지만, "어디쯤인가" 는 이 지도에만 있다.
            //
            // 좌표가 없으면 이 뷰가 스스로 아무것도 그리지 않는다.
            HomecomingJourneyMap(
                travelerName: attributes.travelerName,
                destinationName: attributes.destinationName,
                state: state,
                lastFixedAt: lastFixedAt,
                sessionID: sessionID,
                routes: routes)

            HomecomingJourneyCard(
                attributes: attributes, state: state, lastFixedAt: lastFixedAt)
        }
    }
}

/// 연결은 되어 있는데 아직 아무도 귀가 중이 아닐 때.
struct WatchingIdleCard: View {

    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("지켜보는 사람")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Text(names.joined(separator: ", "))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("아직 귀가 중이 아니에요. 출발하면 여기와 잠금화면에 표시됩니다.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }
}
