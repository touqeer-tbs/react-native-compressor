//
//  Uploader.swift
//  react-native-compressor
//
//  Created by Numan on 10/09/2023.
//

// Touqeer Ahmed

import Foundation
import MobileCoreServices

enum UploaderUploadType: Int {
    case UploaderInvalidType = -1
    case UploaderBinaryContent = 0
    case UploaderMultipart = 1
}

struct UploadError: Error {
  private let message: String

  var localizedDescription: String {
    return message
  }
  
  init(message: String) {
    self.message = message
  }
}

class Uploader : NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    static var uploadResolvers: [String: RCTPromiseResolveBlock] = [:]
    static var uploadRejectors: [String: RCTPromiseRejectBlock] = [:]
    static var responseData: [String: Data] = [:]
    private static var taskManager = UrlTaskManager()
    private static var temporaryFiles: [String: URL] = [:]
    private static var filesToCleanup: [String: URL] = [:]
    private static var lastProgressUpdate: [String: TimeInterval] = [:]
    private static let lock = NSLock()

    // Shared background session
    private static var _backgroundSession: URLSession?
    private static var backgroundSession: URLSession {
        if let session = _backgroundSession { return session }
        let config = URLSessionConfiguration.background(withIdentifier: "com.reactnativecompressor.uploader")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        
        _backgroundSession = URLSession(configuration: config, delegate: Uploader.shared, delegateQueue: nil)
        return _backgroundSession!
    }

    // Standard foreground session
    private static var _standardSession: URLSession?
    private static var standardSession: URLSession {
        if let session = _standardSession { return session }
        let config = URLSessionConfiguration.default
        
        _standardSession = URLSession(configuration: config, delegate: Uploader.shared, delegateQueue: nil)
        return _standardSession!
    }
    
    static let shared = Uploader()
    
    override init() {
        super.init()
        self.cleanUpOrphanedFiles()
    }
    
    func cleanUpOrphanedFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        DispatchQueue.global(qos: .background).async {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
                // Delete files older than 24 hours
                let threshold = Date().addingTimeInterval(-24 * 60 * 60)
                
                for fileUrl in files {
                    if fileUrl.lastPathComponent.hasPrefix("upload_") {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
                           let creationDate = attributes[.creationDate] as? Date,
                           creationDate < threshold {
                            try? FileManager.default.removeItem(at: fileUrl)
                             print("Cleaned up orphaned file: \(fileUrl.lastPathComponent)")
                        }
                    }
                }
            } catch {
                print("Failed to cleanup orphaned files: \(error)")
            }
        }
    }

    func upload(filePath: String, options: [String: Any], resolve:@escaping RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
        let fileUrl = Utils.makeValidUri(filePath: filePath)
      
      guard let uuid = options["uuid"] as? String else {
        reject("Upload Failed", "UUID is missing", UploadError(message: "UUID is missing"))
        return
      }

      guard let remoteUrlString = options["url"] as? String, let remoteUrl = URL(string: remoteUrlString) else {
        reject("Upload Failed", "url is missing or invalid", UploadError(message: "url is missing or invalid"))
        return
      }

      guard let method = options["method"] as? String else {
        reject("Upload Failed", "method is missing", UploadError(message: "method is missing"))
        return
      }

      guard let localFile = URL(string: fileUrl) else{
        reject("Failed", "Upload Failed", UploadError(message: "invalid file url"))
        return
      }
        
      let fieldName = options["fieldName"] as? String ?? "file"
      let mimeType = options["mimeType"] as? String ?? ""
      let parameters = options["parameters"] as? [String: String]
      let uploadType = options["uploadType"] as? Int ?? 0
      let headers = options["headers"] as? [String: String] ?? [:]

      var request = URLRequest(url: remoteUrl)
      request.httpMethod = method
      for(header, v) in headers {
        request.setValue(v, forHTTPHeaderField: header)
      }

      Uploader.uploadResolvers[uuid] = resolve
      Uploader.uploadRejectors[uuid] = reject
      Uploader.responseData[uuid] = Data()
        
      let type = self.getUploadType(from: uploadType)
 
      let isBackground = options["isBackground"] as? Bool ?? false
      let session = isBackground ? Uploader.backgroundSession : Uploader.standardSession
      var task: URLSessionUploadTask!

      if type == .UploaderBinaryContent {
        task = session.uploadTask(with: request, fromFile: localFile)
      } else if type == .UploaderMultipart {
        let boundaryString = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundaryString)", forHTTPHeaderField: "Content-Type")
        
        do {
            let tempUrl = try createMultipartFile(uuid: uuid, boundary: boundaryString, sourceUrl: localFile, parameters: parameters, fieldName: fieldName, mimeType: mimeType)
            Uploader.temporaryFiles[uuid] = tempUrl
            task = session.uploadTask(with: request, fromFile: tempUrl)
        } catch {
            reject("Upload Failed", "Failed to create multipart body", error)
            return
        }
      } else {
        let errorMessage = String(format: "Invalid upload type: '%@'.", options["uploadType"] as? String ?? "")
        reject("ERR_FILESYSTEM_INVALID_UPLOAD_TYPE", errorMessage, nil)
        return
      }
      
      task.taskDescription = uuid
      
        // Check if file should be cleaned up after upload (if in shared_media or Caches)
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.partysharing") {
            let sharedFolder = containerURL.appendingPathComponent("shared_media", isDirectory: true)
            if localFile.path.contains(sharedFolder.path) {
                print("Marking file for cleanup (shared_media): \(localFile.lastPathComponent)")
                Uploader.lock.lock()
                Uploader.filesToCleanup[uuid] = localFile
                Uploader.lock.unlock()
            }
        }
        
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
             if localFile.path.contains(cachesDir.path) {
                 print("Marking file for cleanup (Caches): \(localFile.lastPathComponent)")
                 Uploader.lock.lock()
                 Uploader.filesToCleanup[uuid] = localFile
                 Uploader.lock.unlock()
             }
        }

        // Check for files in temporary directory (e.g. from getRealPath)
        let tempDir = FileManager.default.temporaryDirectory
        if localFile.path.contains(tempDir.path) {
            print("Marking file for cleanup (Temporary): \(localFile.lastPathComponent)")
            Uploader.lock.lock()
            Uploader.filesToCleanup[uuid] = localFile
            Uploader.lock.unlock()
        }
      
      Uploader.taskManager.registerTask(task, uuid: uuid)
      task.resume()
    }
    
    func cancelUpload(uuid:String,shouldCancelAll:Bool) {
        if(shouldCancelAll==true) {
            Uploader.taskManager.cancelAllTasks()
        } else if(uuid=="") {
            Uploader.taskManager.taskPop()?.cancel()
        } else {
            Uploader.taskManager.uploadTaskForId(uuid)?.cancel()
        }
    }
    
    func createMultipartFile(uuid: String, boundary: String, sourceUrl: URL, parameters: [String: String]? = nil, fieldName: String? = nil, mimeType: String? = nil) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempUrl = tempDir.appendingPathComponent("upload_\(uuid)_\(UUID().uuidString).tmp")
        
        if FileManager.default.fileExists(atPath: tempUrl.path) {
            try? FileManager.default.removeItem(at: tempUrl)
        }
        
        FileManager.default.createFile(atPath: tempUrl.path, contents: nil, attributes: nil)
        let handle = try FileHandle(forWritingTo: tempUrl)
        
        defer { handle.closeFile() }
        
        let boundaryPrefix = "--\(boundary)\r\n"
        handle.write(boundaryPrefix.data(using: .utf8)!)
        
        let contentDisposition = "Content-Disposition: form-data; name=\"\(fieldName ?? "file")\"; filename=\"\(sourceUrl.lastPathComponent)\"\r\n"
        handle.write(contentDisposition.data(using: .utf8)!)
        
        if let mimeType = mimeType {
            let contentType = "Content-Type: \(mimeType)\r\n"
            handle.write(contentType.data(using: .utf8)!)
        }
        
        handle.write("\r\n".data(using: .utf8)!)
        
        let sourceHandle = try FileHandle(forReadingFrom: sourceUrl)
        let bufferSize = 1024 * 1024 * 8 // 8MB chunks
        var shouldKeepReading = true
        while shouldKeepReading {
            autoreleasepool {
                let data = sourceHandle.readData(ofLength: bufferSize)
                if data.isEmpty {
                    shouldKeepReading = false
                } else {
                    handle.write(data)
                }
            }
        }
        sourceHandle.closeFile()
        
        if let parameters = parameters {
            for (key, value) in parameters {
                handle.write("\r\n--\(boundary)\r\n".data(using: .utf8)!)
                let paramCD = "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n"
                handle.write(paramCD.data(using: .utf8)!)
                handle.write(value.data(using: .utf8)!)
            }
        }
        
        handle.write("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        return tempUrl
    }
    
    private func getUuid(for task: URLSessionTask) -> String? {
        return task.taskDescription
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let uuid = getUuid(for: dataTask) else { return }
        if Uploader.responseData[uuid] == nil { Uploader.responseData[uuid] = Data() }
        Uploader.responseData[uuid]?.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      guard let uuid = getUuid(for: task) else { return }
      
      if let tempUrl = Uploader.temporaryFiles[uuid] {
          try? FileManager.default.removeItem(at: tempUrl)
          Uploader.temporaryFiles.removeValue(forKey: uuid)
      }
        
      Uploader.lock.lock()
      let cleanupUrl = Uploader.filesToCleanup[uuid]
      Uploader.filesToCleanup.removeValue(forKey: uuid)
      Uploader.lastProgressUpdate.removeValue(forKey: uuid)
      Uploader.lock.unlock()

      if let cleanupUrl = cleanupUrl {
           do {
               if FileManager.default.fileExists(atPath: cleanupUrl.path) {
                   try FileManager.default.removeItem(at: cleanupUrl)
                   print("Successfully cleaned up file: \(cleanupUrl.lastPathComponent)")
               }
           } catch {
               print("Failed to clean up file: \(error)")
           }
      }
      
      guard let resolve = Uploader.uploadResolvers[uuid], let reject = Uploader.uploadRejectors[uuid] else { return }
      
      if let error = error {
        reject("failed", "Upload Failed", error)
      } else if let response = task.response as? HTTPURLResponse {
        var bodyString = ""
        if let data = Uploader.responseData[uuid] {
          bodyString = String(data: data, encoding: .utf8) ?? ""
        }
        let result: [String : Any] = ["status": response.statusCode, "headers": response.allHeaderFields, "body": bodyString]
        resolve(result)
      } else {
        reject("failed", "Upload Failed", UploadError(message: "Response is missing"))
      }
      
      Uploader.uploadResolvers.removeValue(forKey: uuid)
      Uploader.uploadRejectors.removeValue(forKey: uuid)
      Uploader.responseData.removeValue(forKey: uuid)
      Uploader.taskManager.unregisterTask(uuid)
    }
      
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
      guard let uuid = getUuid(for: task) else { return }
        
      let now = Date().timeIntervalSince1970
      var shouldSend = false
        
      Uploader.lock.lock()
      if let lastUpdate = Uploader.lastProgressUpdate[uuid] {
          if now - lastUpdate > 0.1 || totalBytesSent == totalBytesExpectedToSend { // 100ms throttle or complete
              shouldSend = true
              Uploader.lastProgressUpdate[uuid] = now
          }
      } else {
          shouldSend = true
          Uploader.lastProgressUpdate[uuid] = now
      }
      Uploader.lock.unlock()
        
      if shouldSend {
          EventEmitterHandler.emituploadProgress(uuid, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
      }
    }
    
    func getUploadType(from type: Int?) -> UploaderUploadType {
        guard let typeValue = type, let uploadType = UploaderUploadType(rawValue: typeValue) else {
            return .UploaderInvalidType
        }
        return uploadType
    }
}
