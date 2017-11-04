import Foundation

class SlidingBuffer {

    public let capacity: Int
    public let buffer: UnsafeMutablePointer<UInt8>
    public var length: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    var tailingBuffer: UnsafeMutablePointer<UInt8> {
        return self.buffer + length
    }

    var tailingCapacity: Int {
        return self.capacity - length
    }

    func reset(offset: Int) {
        assert(offset >= 0)
        assert(offset <= self.length)

        let remainingBytes = self.length - offset
        if remainingBytes > 0 {
            memmove(buffer, buffer + offset, length)
        }
        self.length = remainingBytes
    }
}

public protocol UploadDelegate {
    func fileUploadProgress(progress: Float) -> Void
}

class FtpRequest {

    let url: String
    public var delegate: UploadDelegate?

    init(url: String) {
        self.url = url
    }

    func dumpError(_ stream: CFWriteStream) {
        let error = CFWriteStreamGetError(stream)
        print(error)
    }

    func dumpError(_ stream: CFReadStream) {
        let error = CFReadStreamGetError(stream)
        print(error)
    }

    /*
    func upload(localFile: String, remoteFile: String) -> Bool {
        let localURL = NSURL(fileURLWithPath: localFile)

        guard let readStream = CFReadStreamCreateWithFile(nil, localURL) else {
            return false
        }

        guard CFReadStreamOpen(readStream) == true else {
            dumpError(readStream)
            return false
        }

        defer {
            CFReadStreamClose(readStream)
        }

        return self.upload(readStream: readStream, remoteFile: remoteFile)
    }
    */

    func upload(data: Data, remoteFile: String) -> Bool {
        guard let ftpURL = NSURL(string: url + remoteFile) else {
            return false
        }

        let stream = CFWriteStreamCreateWithFTPURL(nil, ftpURL).takeRetainedValue()
        guard CFWriteStreamOpen(stream) == true else {
            dumpError(stream)
            return false
        }

        defer {
            CFWriteStreamClose(stream)
        }

        data.withUnsafeBytes() { (ptr: UnsafePointer<UInt8>) in
            var totalBytesWritten = 0
            self.delegate?.fileUploadProgress(progress: 0.0)
            while totalBytesWritten < data.count {

                let bytesWritten = CFWriteStreamWrite(stream, ptr + totalBytesWritten, data.count - totalBytesWritten)
                //print("\(remoteFile): bytes total: \(data.count), bytes written: \(bytesWritten), total written: \(totalBytesWritten)")
                guard bytesWritten > 0 else {
                    dumpError(stream)
                    return
                }
                totalBytesWritten += bytesWritten
                
                self.delegate?.fileUploadProgress(progress: Float(totalBytesWritten) / Float(data.count))
            }
        }

        return true
    }

    func ls() -> [String: [String: Any]]? {
        guard let ftpURL = NSURL(string: url) else {
            print("ERROR: Invalid URL")
            return nil
        }

        let stream = CFReadStreamCreateWithFTPURL(nil, ftpURL).takeRetainedValue()

        let status = CFReadStreamOpen(stream)

        if (status == false) {
            dumpError(stream)
            return nil
        }

        defer {
            CFReadStreamClose(stream)
        }

        let buffer = SlidingBuffer(capacity: 4096)

        var bytesRead: CFIndex

        var files = [String: [String: Any]]()
        let entries = UnsafeMutablePointer<Unmanaged<CFDictionary>?>.allocate(capacity: 1)
        defer { entries.deinitialize() }

        var parsedBytes: CFIndex = 0
        repeat {
            bytesRead = CFReadStreamRead(stream, buffer.tailingBuffer, buffer.tailingCapacity)
            if (bytesRead < 0) {
                dumpError(stream)
                return nil
            }
            buffer.length += bytesRead

            if bytesRead > 0 {
                var bytesConsumed: CFIndex = 0
                repeat {
                    parsedBytes = CFFTPCreateParsedResourceListing(nil, buffer.buffer + bytesConsumed, buffer.length - bytesConsumed, entries)
                    bytesConsumed += parsedBytes
                    let entryPtr = entries.pointee?.takeUnretainedValue()
                    //print("resource listing: \(parsedBytes) \(String(describing: entryPtr))")

                    if let entry = entryPtr as? [String: Any], let fileName = entry[kCFFTPResourceName as String] as? String {
                        files[fileName] = entry
                    }
                } while (parsedBytes > 0)

                if (parsedBytes == -1) {
                    return nil
                }

                buffer.reset(offset: bytesConsumed)
            }

        } while (bytesRead > 0)

        return files
    }
}

public enum FtpSyncResult {
    case Skipped
    case Synchronized
    case Error
}

public class FtpSync {
    let url: String
    let ftpRequest: FtpRequest
    let contents: [String: [String: Any]]

    public var delegate: UploadDelegate? {
        set(newDelegate) { self.ftpRequest.delegate = newDelegate }
        get { return self.ftpRequest.delegate }
    }

    public init?(url: String) {
        self.url = url
        self.ftpRequest = FtpRequest(url: url)
        guard let contents = self.ftpRequest.ls() else {
            return nil
        }
        self.contents = contents
    }

    public func sync(data: Data, fileName: String) -> FtpSyncResult {
        let remoteFileInfo = contents[fileName]
        var doSync = remoteFileInfo == nil

        if let size = remoteFileInfo?[kCFFTPResourceSize as String] as? Int {
            doSync = size != data.count
        }
        
        if doSync == true {
            if ftpRequest.upload(data: data, remoteFile: fileName) == false {
                return FtpSyncResult.Error
            }
        }
        
        return doSync == true ? FtpSyncResult.Synchronized : FtpSyncResult.Skipped
    }
}
