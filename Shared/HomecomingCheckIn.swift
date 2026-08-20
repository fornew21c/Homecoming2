import ActivityKit
import AppIntents
import Foundation

/// 안심 확인. 앱과 위젯 양쪽이 같은 구현을 쓴다.
enum HomecomingCheckIn {

    /// 확인 한 번의 유효 시간. 이만큼 지나도록 다시 누르지 않으면 무응답으로 본다.
    static let defaultInterval: TimeInterval = 15 * 60

    /// 마지막으로 확인을 누른 시각. 앱이 자기 타이머를 맞추는 데 쓴다.
    ///
    /// `LiveActivityIntent` 는 **앱 프로세스에서** 수행되므로 앱 그룹 없이도
    /// 같은 UserDefaults 를 본다. 위젯 익스텐션에서 돌았다면 앱 그룹이 필요했다.
    static let lastCheckInKey = "homecoming.lastCheckIn"

    static var lastCheckIn: Date? {
        let raw = UserDefaults.standard.double(forKey: lastCheckInKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    /// 확인을 기록하고 마감을 뒤로 민다.
    ///
    /// 액티비티를 직접 갱신한다. 사용자는 잠금화면에서 버튼만 눌렀을 뿐이고
    /// 앱 화면은 떠 있지도 않기 때문에, 여기서 끝까지 처리해야 한다.
    @discardableResult
    static func record(
        activityID: String,
        interval: TimeInterval = HomecomingCheckIn.defaultInterval
    ) async -> Bool {

        guard let activity = Activity<HomecomingAttributes>.activities.first(where: { $0.id == activityID })
        else { return false }

        var state = activity.content.state
        state.checkInDeadline = Date().addingTimeInterval(interval)

        // 확인이 왔으니 무응답은 해소된다. 다른 이상(지연·정지)은 그대로 둔다 —
        // "확인은 눌렀지만 여전히 한곳에 멈춰 있다" 는 지워선 안 되는 정보다.
        if state.anomaly == .unresponsive { state.anomaly = nil }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckInKey)

        await activity.update(ActivityContent(state: state, staleDate: state.staleDate))
        return true
    }
}

/// 잠금화면과 확장된 다이나믹 아일랜드에서 바로 누르는 버튼.
///
/// 앱을 열지 않고 확인이 끝나는 것이 핵심이다. 위급할 때 앱을 찾아 실행할 시간은 없다.
struct HomecomingCheckInIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "안심 확인"
    static var description = IntentDescription("귀가 중 안심 확인을 보냅니다.")

    /// 확인을 반영할 액티비티. 여러 개가 떠 있을 수 있으므로 명시해서 받는다.
    @Parameter(title: "Activity ID")
    var activityID: String

    init() {}

    init(activityID: String) {
        self.activityID = activityID
    }

    func perform() async throws -> some IntentResult {
        await HomecomingCheckIn.record(activityID: activityID)
        return .result()
    }
}
