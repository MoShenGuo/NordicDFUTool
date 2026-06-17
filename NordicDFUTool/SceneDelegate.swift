import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        window = UIWindow(windowScene: windowScene)
        let mainVC = MainViewController()
        let nav = UINavigationController(rootViewController: mainVC)
//        nav.navigationBar.prefersLargeTitles = false
        
        // 确保导航栏不透明，避免顶部空白
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance
        
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
    }
}
