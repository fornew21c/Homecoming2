import Foundation
import OSLog

/// 귀가 알림은 사용자가 보고 있지 않은 동안 대부분의 일이 벌어진다.
/// 왜 액티비티가 안 떴는지, 왜 도착 판정이 늦었는지는 로그 없이는 재현이 안 된다.
enum HomecomingLog {
    static let activity = Logger(subsystem: "com.kona.homecoming2", category: "activity")
    static let location = Logger(subsystem: "com.kona.homecoming2", category: "location")
    static let eta = Logger(subsystem: "com.kona.homecoming2", category: "eta")
    static let push = Logger(subsystem: "com.kona.homecoming2", category: "push")
}
