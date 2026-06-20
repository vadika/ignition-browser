import Foundation

/// Resolves runtime paths. When bundled, everything lives under the app's
/// Resources/ dir; during `swift run` dev we fall back to vendor/ignition.
struct Config {
    /// The ignition `boot` binary (built from vendor/ignition, bundled in Resources/).
    let bootBinary: URL
    /// The guest kernel Image passed to boot as the positional <kernel> arg.
    let kernelImage: URL
    /// gvisor-tap-vsock proxy binary (gvproxy), bundled in Resources/.
    let gvproxyBinary: URL
    /// ignition snapshot/disk store directory (passed as --store).
    let store: URL
    /// Name of the warm parent snapshot to restore from (--restore).
    let baseSnapshotName: String
    /// Bundled gzip-compressed rootfs (`Resources/rootfs-browser.ext4.gz`); nil in dev.
    let rootfsArchive: URL?
    /// Raw ext4 rootfs for dev (`vendor/ignition/kimage/out/rootfs-browser.ext4`); nil when bundled.
    let rootfsRaw: URL?

    static func resolve() -> Config {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("IgnitionBrowser", isDirectory: true)
        let store = support.appendingPathComponent("store", isDirectory: true)

        // Bundled layout: <App>.app/Contents/Resources/{boot,Image,gvproxy}
        if let resources = Bundle.main.resourceURL,
           fm.fileExists(atPath: resources.appendingPathComponent("boot").path) {
            return Config(
                bootBinary: resources.appendingPathComponent("boot"),
                kernelImage: resources.appendingPathComponent("Image"),
                gvproxyBinary: resources.appendingPathComponent("gvproxy"),
                store: store,
                baseSnapshotName: "browser-base",
                rootfsArchive: resources.appendingPathComponent("rootfs-browser.ext4.gz"),
                rootfsRaw: nil
            )
        }

        // Dev fallback: resolve vendor/ignition relative to this source file's repo root.
        // Sources/IgnitionBrowser/Config.swift -> repo root is two levels up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/IgnitionBrowser
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
        let ignition = repoRoot.appendingPathComponent("vendor/ignition", isDirectory: true)
        return Config(
            bootBinary: ignition.appendingPathComponent("target/release/boot"),
            kernelImage: ignition.appendingPathComponent("kimage/out/Image"),
            // Filtered gvproxy built by scripts/build-gvproxy.sh -> dist/gvproxy.
            gvproxyBinary: repoRoot.appendingPathComponent("dist/gvproxy"),
            store: store,
            baseSnapshotName: "browser-base",
            rootfsArchive: nil,
            rootfsRaw: ignition.appendingPathComponent("kimage/out/rootfs-browser.ext4")
        )
    }
}
