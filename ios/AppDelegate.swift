import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Create the window
        window = UIWindow(frame: UIScreen.main.bounds)
        
        // Set the root view controller
        let cameraVC = CameraViewController()
        window?.rootViewController = cameraVC
        window?.makeKeyAndVisible()
        
        return true
    }
}
