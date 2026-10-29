// Appended to firefox-ios/Client/Application/main.swift by
// option2/tools/apply_client_overlay.py. Imports below are moved to the top of
// main.swift by the overlay; they are here so this file parses on its own.
import Foundation
import ObjectiveC
import UIKit
@preconcurrency import GeckoView

// MARK: - Reynard Gecko engine bootstrap

/// Starts Firefox on top of the Reynard Gecko runtime.
///
/// Gecko on iOS owns the process entry point: `GeckoRuntime.main` boots XPCOM
/// and runs `XRE_main`, whose app shell calls `UIApplicationMain` with Gecko's
/// own `AppShellDelegate`. Firefox does all of its startup (profile, Glean,
/// Nimbus, background tasks, scene configuration) in `AppDelegate`, so the
/// Gecko delegate is taught to forward every app delegate message it does not
/// implement to Firefox's `AppDelegate`, and to call Firefox after its own
/// handling for the lifecycle messages both implement.
enum GeckoFirefoxBootstrap {
    /// Firefox's AppDelegate instance while Gecko's delegate is the real one.
    nonisolated(unsafe) static var firefoxDelegateObject: NSObject?

    /// True once the process was started through Gecko. Tabs only create Gecko
    /// sessions when this is set, so tests and the WebKit fallback are unaffected.
    nonisolated(unsafe) static var isGeckoRunning = false

    /// Launch with the user default `FirefoxGeckoUseWebKit` = YES to start the
    /// unmodified WebKit Firefox instead, for side-by-side debugging.
    static var isGeckoRequested: Bool {
        !UserDefaults.standard.bool(forKey: "FirefoxGeckoUseWebKit")
    }

    /// Main-actor isolated like `GeckoRuntime.main` and the top-level code in
    /// main.swift that calls it, so argv never crosses an isolation boundary.
    @MainActor
    static func run(
        firefoxDelegate: NSObject,
        argc: Int32,
        argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> Never {
        firefoxDelegateObject = firefoxDelegate
        isGeckoRunning = true
        configureSandboxExtension()
        GeckoAppDelegateForwarding.prepare()
        GeckoRuntime.main(argc: argc, argv: argv)
        // XRE_main does not return on iOS; UIApplicationMain never exits.
        exit(0)
    }

    /// Same as Reynard's main.swift: lets Gecko's sandboxed content processes
    /// read the app's Documents folder (downloads, file uploads).
    private static func configureSandboxExtension() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let handle = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "sandbox_extension_issue_file") else {
            return
        }
        typealias IssueFileExtension = @convention(c) (
            UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32
        ) -> UnsafeMutablePointer<CChar>?
        let issue = unsafeBitCast(symbol, to: IssueFileExtension.self)
        let token = "com.apple.app-sandbox.read".withCString { extensionClass in
            documents.path.withCString { path in issue(extensionClass, path, 0) }
        }
        guard let token else { return }
        setenv("MOZ_DOCUMENTS_SANDBOX_EXTENSION", String(cString: token), 1)
        free(UnsafeMutableRawPointer(token))
    }
}

/// Makes Gecko's `AppShellDelegate` behave as Firefox's app delegate too.
enum GeckoAppDelegateForwarding {
    nonisolated(unsafe) private static var patchedClasses = Set<String>()

    /// Lifecycle messages Gecko's delegate implements and Firefox also needs.
    /// Gecko runs first, then Firefox.
    private static let chainedApplicationSelectors = [
        "applicationDidBecomeActive:",
        "applicationWillResignActive:",
        "applicationDidEnterBackground:",
        "applicationWillEnterForeground:",
        "applicationWillTerminate:",
        "applicationDidReceiveMemoryWarning:",
        "applicationSignificantTimeChange:",
        "applicationProtectedDataWillBecomeUnavailable:",
        "applicationProtectedDataDidBecomeAvailable:",
    ]

    static func prepare() {
        // XUL is normally loaded already, so the class exists before main runs.
        if let shellClass = NSClassFromString("AppShellDelegate") {
            patch(shellClass)
        }
        // Otherwise patch it the moment UIKit installs it as the delegate,
        // before UIKit caches which messages the delegate responds to.
        hookSetDelegate()
    }

    private static func hookSetDelegate() {
        let selector = NSSelectorFromString("setDelegate:")
        guard let method = class_getInstanceMethod(UIApplication.self, selector) else { return }
        typealias SetDelegate = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: SetDelegate.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { application, delegate in
            if let delegate, let delegateClass = object_getClass(delegate),
               NSStringFromClass(delegateClass).hasSuffix("AppShellDelegate") {
                patch(delegateClass)
            }
            original(application, selector, delegate)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    static func patch(_ shellClass: AnyClass) {
        let name = NSStringFromClass(shellClass)
        guard !patchedClasses.contains(name) else { return }
        patchedClasses.insert(name)

        for selectorName in chainedApplicationSelectors {
            chainVoidMessage(shellClass, NSSelectorFromString(selectorName))
        }
        chainVoidMessage(shellClass, NSSelectorFromString("buildMenuWithBuilder:"))
        chainLaunchMessage(shellClass, NSSelectorFromString("application:didFinishLaunchingWithOptions:"))
        chainLaunchMessage(shellClass, NSSelectorFromString("application:willFinishLaunchingWithOptions:"))
        addForwarding(shellClass)
    }

    /// Only for selectors the Gecko class implements itself; anything else is
    /// forwarded wholesale by `addForwarding`.
    private static func implementsDirectly(_ cls: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return true
        }
        return false
    }

    private static func firefoxTarget(for selector: Selector) -> NSObject? {
        guard let target = GeckoFirefoxBootstrap.firefoxDelegateObject,
              target.responds(to: selector) else {
            return nil
        }
        return target
    }

    private static func chainVoidMessage(_ cls: AnyClass, _ selector: Selector) {
        guard implementsDirectly(cls, selector),
              let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Message.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, argument in
            original(receiver, selector, argument)
            if let target = firefoxTarget(for: selector), let targetClass = object_getClass(target),
               let implementation = class_getMethodImplementation(targetClass, selector) {
                let firefox = unsafeBitCast(implementation, to: Message.self)
                firefox(target, selector, argument)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func chainLaunchMessage(_ cls: AnyClass, _ selector: Selector) {
        guard implementsDirectly(cls, selector),
              let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Message.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Bool = { receiver, application, options in
            let geckoResult = original(receiver, selector, application, options)
            guard let target = firefoxTarget(for: selector), let targetClass = object_getClass(target),
                  let implementation = class_getMethodImplementation(targetClass, selector) else {
                return geckoResult
            }
            let firefox = unsafeBitCast(implementation, to: Message.self)
            return firefox(target, selector, application, options) && geckoResult
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// `respondsToSelector:` also answers for Firefox's delegate, and
    /// `forwardingTargetForSelector:` sends those messages to it unchanged.
    private static func addForwarding(_ cls: AnyClass) {
        let respondsSelector = NSSelectorFromString("respondsToSelector:")
        typealias Responds = @convention(c) (AnyObject, Selector, Selector) -> Bool
        guard let inheritedImplementation = class_getMethodImplementation(cls, respondsSelector) else { return }
        let inherited = unsafeBitCast(inheritedImplementation, to: Responds.self)
        let responds: @convention(block) (AnyObject, Selector) -> Bool = { receiver, selector in
            inherited(receiver, respondsSelector, selector) || firefoxTarget(for: selector) != nil
        }
        class_addMethod(cls, respondsSelector, imp_implementationWithBlock(responds), "B@::")

        let forwardingSelector = NSSelectorFromString("forwardingTargetForSelector:")
        let forwarding: @convention(block) (AnyObject, Selector) -> AnyObject? = { _, selector in
            firefoxTarget(for: selector)
        }
        class_addMethod(cls, forwardingSelector, imp_implementationWithBlock(forwarding), "@@::")
    }
}

/// Sideloaded builds have no App Group entitlement, so
/// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil. Firefox
/// keeps its profile there (Nimbus, history, logins), and without it Nimbus
/// disables itself and onboarding has no cards, so Skip does nothing. When iOS
/// has no group container, answer with a folder inside the app's own sandbox.
/// The app extensions that would share the group are not shipped in this IPA.
enum SideloadAppGroupFallback {
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("containerURLForSecurityApplicationGroupIdentifier:")
        guard let method = class_getInstanceMethod(FileManager.self, selector) else { return }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString) -> NSURL?
        let original = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        let replacement: @convention(block) (AnyObject, NSString) -> NSURL? = { manager, group in
            if let url = original(manager, selector, group) {
                return url
            }
            return fallbackContainer(for: group as String) as NSURL?
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func fallbackContainer(for group: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = support.appendingPathComponent("AppGroupFallback", isDirectory: true)
            .appendingPathComponent(group, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }
}

extension AppDelegate {
    /// FetchDock's background URLSession relaunches the app to finish segments.
    @objc(application:handleEventsForBackgroundURLSession:completionHandler:)
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == FetchDockService.sessionIdentifier else {
            completionHandler()
            return
        }
        FetchDockService.shared.handleBackgroundEvents(completionHandler)
    }
}

extension AppDelegate {
    /// Firefox's AppDelegate, whether it is the UIApplication delegate itself
    /// (WebKit mode, tests) or sits behind Gecko's AppShellDelegate.
    static var current: AppDelegate? {
        (GeckoFirefoxBootstrap.firefoxDelegateObject as? AppDelegate)
            ?? (UIApplication.shared.delegate as? AppDelegate)
    }
}
