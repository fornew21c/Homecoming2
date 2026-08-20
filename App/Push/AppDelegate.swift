import UIKit

/// APNs 기기 토큰은 SwiftUI 만으로는 받을 수 없다.
/// 이 델리게이트 하나를 두는 이유가 그것뿐이다.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 앱 구성 요소를 한 군데서 만들고 나눠 준다.
    let environment = HomecomingEnvironment()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        environment.push.start()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        environment.push.handle(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        environment.push.handleRegistrationFailure(error)
    }
}
