import Flutter
import PDFKit
import Photos
import QuickLook
import UIKit

// The app's own platform channels on iOS: `dsh/files` (open in another app, save to
// Files, PDF preview) and `dsh/media` (save to Photos). The Android side is under
// android/app/src/main/kotlin/io/github/tsukii12/dshremote/.

final class DshChannels: NSObject, FlutterPlugin {
  private static var instance: DshChannels?

  private let files: FilesChannel
  private let media: MediaChannel

  static func register(with registrar: any FlutterPluginRegistrar) {
    instance = DshChannels(messenger: registrar.messenger())
  }

  private init(messenger: any FlutterBinaryMessenger) {
    files = FilesChannel(messenger: messenger)
    media = MediaChannel(messenger: messenger)
  }
}

func arguments(_ call: FlutterMethodCall) -> [String: Any] {
  call.arguments as? [String: Any] ?? [:]
}

func onMain(_ work: @escaping () -> Void) {
  DispatchQueue.main.async(execute: work)
}

// MARK: - dsh/files

/// Opening, saving and previewing the files a turn produced.
private final class FilesChannel: NSObject, QLPreviewControllerDataSource {
  private let channel: FlutterMethodChannel
  private let pdfQueue = DispatchQueue(label: "dsh.pdf")
  private var pdf: (path: String, document: PDFDocument)?
  private var previewing: URL?

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/files", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      let args = arguments(call)
      let path = args["path"] as? String ?? ""
      switch call.method {
      case "open":
        self.open(path: path, name: args["name"] as? String, chooser: args["chooser"] as? Bool ?? false, result: result)
      case "saveToDownloads": self.save(path: path, name: args["name"] as? String, result: result)
      case "pdfInfo": self.pdfInfo(path: path, result: result)
      case "pdfPage":
        self.pdfPage(path: path, page: args["page"] as? Int ?? 0, width: args["width"] as? Int ?? 0, result: result)
      case "pdfClose":
        self.pdfQueue.async {
          self.pdf = nil
          onMain { result(nil) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  // Open

  private func open(path: String, name: String?, chooser: Bool, result: FlutterResult) {
    guard FileManager.default.isReadableFile(atPath: path), let top = topViewController() else {
      return result(FlutterError(code: "missing", message: "no such file", details: nil))
    }
    let url: URL
    do {
      url = try named(URL(fileURLWithPath: path), as: name)
    } catch {
      return result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    }
    if !chooser && QLPreviewController.canPreview(url as NSURL) {
      previewing = url
      let preview = QLPreviewController()
      preview.dataSource = self
      top.present(preview, animated: true)
    } else {
      let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = share.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      top.present(share, animated: true)
    }
    result(nil)
  }

  /// The preview and other apps go by the file's extension, and the cache may not
  /// have it under the name the file should show.
  private func named(_ url: URL, as name: String?) throws -> URL {
    guard let name, !name.isEmpty, name != url.lastPathComponent else { return url }
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent("open/\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent((name as NSString).lastPathComponent)
    try manager.copyItem(at: url, to: copy)
    return copy
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewing == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
    (previewing ?? URL(fileURLWithPath: "/")) as NSURL
  }

  // Save

  /// Into the app's Documents, which the Files app shows under the app's name
  /// (UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace). No dialog, like the
  /// save on Android; returns where it landed.
  private func save(path: String, name: String?, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let manager = FileManager.default
      guard manager.isReadableFile(atPath: path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such file", details: nil)) }
      }
      do {
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let wanted = name?.isEmpty == false ? name! : URL(fileURLWithPath: path).lastPathComponent
        let target = Self.free(in: documents, name: (wanted as NSString).lastPathComponent)
        try manager.copyItem(at: URL(fileURLWithPath: path), to: target)
        onMain { result("YuRemote/\(target.lastPathComponent)") }
      } catch {
        onMain { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  /// `report.pdf`, then `report (1).pdf`, the first name not taken.
  private static func free(in folder: URL, name: String) -> URL {
    let manager = FileManager.default
    let plain = folder.appendingPathComponent(name)
    if !manager.fileExists(atPath: plain.path) { return plain }
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 1
    while true {
      let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)")
      if !manager.fileExists(atPath: candidate.path) { return candidate }
      number += 1
    }
  }

  // PDF preview

  private func document(_ path: String) -> PDFDocument? {
    if let pdf, pdf.path == path { return pdf.document }
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
    pdf = (path, document)
    return document
  }

  /// A page's size as it is shown: rotated pages swap width and height.
  private static func size(of page: PDFPage) -> CGSize {
    let box = page.bounds(for: .mediaBox).size
    return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
  }

  private func pdfInfo(path: String, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard let document = self.document(path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such PDF", details: nil)) }
      }
      let pages: [[String: Int]] = (0..<document.pageCount).compactMap { index in
        guard let page = document.page(at: index) else { return nil }
        let size = Self.size(of: page)
        return ["width": Int(size.width.rounded()), "height": Int(size.height.rounded())]
      }
      onMain { result(pages) }
    }
  }

  private func pdfPage(path: String, page index: Int, width: Int, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard width > 0, let page = self.document(path)?.page(at: index) else {
        return onMain { result(FlutterError(code: "missing", message: "no such page", details: nil)) }
      }
      let size = Self.size(of: page)
      guard size.width > 0, size.height > 0 else {
        return onMain { result(FlutterError(code: "failed", message: "empty page", details: nil)) }
      }
      let scale = CGFloat(width) / size.width
      let target = CGSize(width: CGFloat(width), height: (size.height * scale).rounded())
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let png = UIGraphicsImageRenderer(size: target, format: format).pngData { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: target))
        context.cgContext.translateBy(x: 0, y: target.height)
        context.cgContext.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context.cgContext)
      }
      onMain { result(FlutterStandardTypedData(bytes: png)) }
    }
  }
}

func topViewController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
  while let presented = top?.presentedViewController { top = presented }
  return top
}

func openAppSettings(_ address: String, result: @escaping FlutterResult) {
  guard let url = URL(string: address) else { return result(false) }
  UIApplication.shared.open(url) { result($0) }
}

// MARK: - dsh/media

private final class MediaChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "saveImage":
        let args = arguments(call)
        guard let bytes = args["bytes"] as? FlutterStandardTypedData, let name = args["name"] as? String else {
          return result(FlutterError(code: "invalid", message: "no image", details: nil))
        }
        Self.save(bytes.data, name: name, result: result)
      case "saveVideoFile":
        let args = arguments(call)
        guard let path = args["path"] as? String, let name = args["name"] as? String,
          let file = Self.videoFile(path, name: name) else {
          return result(FlutterError(code: "invalid", message: "invalid local video", details: nil))
        }
        Self.saveVideo(file, name: name, result: result)
      case "openSettings": openAppSettings(UIApplication.openSettingsURLString, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func videoFile(_ path: String, name: String) -> URL? {
    guard path.hasPrefix("/"), !name.isEmpty, name.utf8.count <= 255,
      name == (name as NSString).lastPathComponent,
      ["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(root + "/"),
      ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()),
      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return file
  }

  private static func saveVideo(_ file: URL, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        options.shouldMoveFile = false
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
      }) { saved, error in
        onMain {
          if saved { result("Photos/\(name)") }
          else { result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil)) }
        }
      }
    }
  }

  /// Add-only access: saving doesn't need to read the rest of the library.
  private static func save(_ data: Data, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
      }) { saved, error in
        onMain {
          if saved {
            result("Photos/\(name)")
          } else {
            result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}
