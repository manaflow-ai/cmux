public import CmuxiOSFeatureKit
public import CmuxiOSOnboardingCore
public import Foundation
public import UIKit

/// Everything onboarding needs from the composition root.
@MainActor
public struct OnboardingDependencies {
    public var devices: any DeviceRegistry
    public var hosts: any HostsStore
    public var permissions: any PermissionCenter
    public var clock: any Clock<Duration>
    public var metrics: any OnboardingMetricsSink
    public var store: any OnboardingProgressPersisting
    /// The kept sign-in screen without its standalone chrome.
    public var signIn: @MainActor () -> UIViewController
    public var macDownloadURL: URL
    /// DEBUG: the scanner placeholder offers a sample code.
    public var offersSampleScan: Bool
    /// Lane C12: creates the first Cloud machine; nil hides the Cloud step.
    public var cloud: OnboardingCloudHook?
    /// Lane E5: the keep-awake card's control; nil hides the card.
    public var keepAwake: OnboardingKeepAwakeHook?

    public init(
        devices: any DeviceRegistry, hosts: any HostsStore, permissions: any PermissionCenter,
        clock: any Clock<Duration>, metrics: any OnboardingMetricsSink, store: any OnboardingProgressPersisting,
        signIn: @escaping @MainActor () -> UIViewController,
        macDownloadURL: URL = URL(string: "https://cmux.com")!, offersSampleScan: Bool = false,
        cloud: OnboardingCloudHook? = nil,
        keepAwake: OnboardingKeepAwakeHook? = nil
    ) {
        self.devices = devices
        self.hosts = hosts
        self.permissions = permissions
        self.clock = clock
        self.metrics = metrics
        self.store = store
        self.signIn = signIn
        self.macDownloadURL = macDownloadURL
        self.offersSampleScan = offersSampleScan
        self.cloud = cloud
        self.keepAwake = keepAwake
    }
}
