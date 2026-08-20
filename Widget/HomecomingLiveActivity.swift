import ActivityKit
import SwiftUI
import WidgetKit

/// 귀가마중 Live Activity.
///
/// 잠금화면 카드 하나와 Dynamic Island 세 가지 프레젠테이션(expanded / compact / minimal)을
/// 한 선언에 묶는다. 어떤 프레젠테이션이 보일지는 시스템이 정하므로 넷 다 채워야 한다.
struct HomecomingLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HomecomingAttributes.self) { context in

            // 잠금화면 · 배너 · Dynamic Island 가 없는 기기
            HomecomingLockScreenView(
                attributes: context.attributes,
                state: context.state,
                activityID: context.activityID
            )

        } dynamicIsland: { context in

            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HomecomingIsland.Leading(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HomecomingIsland.Trailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HomecomingIsland.Bottom(
                        attributes: context.attributes,
                        state: context.state,
                        activityID: context.activityID
                    )
                }
            } compactLeading: {
                HomecomingCompactLeading(state: context.state)
            } compactTrailing: {
                HomecomingCompactTrailing(state: context.state)
            } minimal: {
                HomecomingMinimal(state: context.state)
            }
            .keylineTint(context.state.tint)
            .widgetURL(URL(string: "homecoming://activity"))
        }
    }
}

// MARK: - 프리뷰

#Preview("Dynamic Island · 확장", as: .dynamicIsland(.expanded), using: HomecomingAttributes.preview) {
    HomecomingLiveActivity()
} contentStates: {
    HomecomingAttributes.ContentState.moving
    HomecomingAttributes.ContentState.nearby
    HomecomingAttributes.ContentState.arrived
}

#Preview("Dynamic Island · 축소", as: .dynamicIsland(.compact), using: HomecomingAttributes.preview) {
    HomecomingLiveActivity()
} contentStates: {
    HomecomingAttributes.ContentState.moving
    HomecomingAttributes.ContentState.checkInDue
    HomecomingAttributes.ContentState.arrived
}

#Preview("귀가자 본인", as: .content, using: HomecomingAttributes.previewTraveler) {
    HomecomingLiveActivity()
} contentStates: {
    HomecomingAttributes.ContentState.safetyMoving
    HomecomingAttributes.ContentState.unresponsive
    HomecomingAttributes.ContentState.arrived
}

#Preview("가족", as: .content, using: HomecomingAttributes.preview) {
    HomecomingLiveActivity()
} contentStates: {
    HomecomingAttributes.ContentState.safetyMoving
    HomecomingAttributes.ContentState.unresponsive
    HomecomingAttributes.ContentState.arrived
}

#Preview("안전귀가", as: .dynamicIsland(.expanded), using: HomecomingAttributes.preview) {
    HomecomingLiveActivity()
} contentStates: {
    HomecomingAttributes.ContentState.safetyMoving
    HomecomingAttributes.ContentState.checkInDue
    HomecomingAttributes.ContentState.unresponsive
    HomecomingAttributes.ContentState.stalled
}

#Preview("Dynamic Island · 최소", as: .dynamicIsland(.minimal), using: HomecomingAttributes.preview) {
    HomecomingLiveActivity()
} contentStates: {
    HomecomingAttributes.ContentState.moving
}

#Preview("잠금화면", as: .content, using: HomecomingAttributes.preview) {
    HomecomingLiveActivity()
} contentStates: {
    HomecomingAttributes.ContentState.moving
    HomecomingAttributes.ContentState.nearby
    HomecomingAttributes.ContentState.arrived
}
