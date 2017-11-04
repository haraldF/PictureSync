//
//  PictureCollection.swift
//  PictureSync
//
//  Created by Harald Fernengel on 28.10.17.
//  Copyright © 2017 Harald Fernengel. All rights reserved.
//

import Foundation
import Photos

typealias Albums = Array<(localizedTitle: String, localIdentifier: String)>

protocol PictureSyncDelegate: UploadDelegate {
    func totalUploadProgress(progress: Float) -> Void
}

class SyncResult {
    var totalFiles = 0
    var syncedFiles = 0
    var skippedFiles = 0
    var errors = 0
}

class PictureSyncOperation: Operation {

    enum State {
        case None
        case Executing
        case Finished
    }
    
    let asset: PHAsset
    let ftpSync: FtpSync
    let result: SyncResult
    let delegate: PictureSyncDelegate?
    let currentBatchId: Int
    
    init(asset: PHAsset, ftpSync: FtpSync, result: SyncResult, delegate: PictureSyncDelegate?, jobNumber: Int) {
        self.asset = asset
        self.ftpSync = ftpSync
        self.result = result
        self.delegate = delegate
        self.currentBatchId = jobNumber
    }

    var state: State = .None {
        willSet(newState) {
            assert(newState == .Executing || newState == .Finished)
            willChangeValue(forKey: "isExecuting")
            if newState == .Finished {
                willChangeValue(forKey: "isFinished")
            }
        }
        didSet {
            assert(state == .Executing || state == .Finished)
            didChangeValue(forKey: "isExecuting")
            if state == .Finished {
                didChangeValue(forKey: "isFinished")
            }
        }
    }
    
    override var isAsynchronous: Bool { return true }
    override var isExecuting: Bool { return state == .Executing }
    override var isFinished: Bool { return state == .Finished }

    func syncImageData(imageData: Data?, info: [AnyHashable : Any]?) {
        if info?[PHImageResultIsInCloudKey] as? Bool == true {
            print("Asset in cloud, skipping")
            return
        }
        
        guard let fileURL = info?["PHImageFileURLKey"] as? URL else {
            print("ERROR: Asset has no file URL")
            return
        }
        
        let fileName = fileURL.lastPathComponent
        guard fileName.count > 0 else {
            print("ERROR: Empty filename")
            return
        }
        
        guard let data = imageData else {
            print("ERROR: File has no data")
            return
        }
        
        let syncResult = ftpSync.sync(data: data, fileName: fileName)
        
        switch syncResult {
        case .Skipped:
            result.skippedFiles += 1
        case .Synchronized:
            result.syncedFiles += 1
        case .Error:
            result.errors += 1
        }
        
        self.delegate?.totalUploadProgress(progress: Float(currentBatchId + 1) / Float(result.totalFiles))
    }
    
    override func start() {
        self.state = .Executing
        PHImageManager.self().requestImageData(for: asset, options: nil) { (imageData, _, _, info) in
            self.syncImageData(imageData: imageData, info: info)
            self.state = .Finished
        }
    }
}

class PictureSync {

    var albums = Albums()
    var url: String?
    var delegate: PictureSyncDelegate?

    func initialize(url: String) {

        self.url = url

        if #available(iOS 11.0, *) {
            let results = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            //print("result count: \(results.count)")
            for i in 0..<results.count {
                let result = results[i]
                //print("   \(result.localIdentifier) \(String(describing: result.localizedTitle))")
                let localizedTitle = result.localizedTitle == nil ? "<no name>" : result.localizedTitle
                albums.append((localizedTitle: localizedTitle!, localIdentifier: result.localIdentifier))
            }
        } else {
            print("Not supported")
            // Fallback on earlier versions
        }
    }

    func synchronizeAlbum(localIdentifier: String) -> SyncResult? {
        let assetCollections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil);

        guard assetCollections.count == 1 else {
            print("ERROR: Unable to get asset collection for selected album")
            return nil
        }

        let assetCollection = assetCollections[0]
        return self.syncImages(assetCollection: assetCollection)
    }

    func syncImages(assetCollection: PHAssetCollection) -> SyncResult? {
        
        guard let url = self.url else {
            print("ERROR: Call initialize() first")
            return nil
        }

        guard let ftpSync = FtpSync(url: url) else {
            print("ERROR: Cannot create FtpSync")
            return nil // ### Error handling
        }
        
        ftpSync.delegate = delegate

        delegate?.totalUploadProgress(progress: 0.0)
        
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let assets = PHAsset.fetchAssets(in: assetCollection, options: nil)

        let result = SyncResult()
        result.totalFiles = assets.count

        for i in 0..<assets.count {
            queue.addOperation(PictureSyncOperation(asset: assets[i], ftpSync: ftpSync, result: result, delegate: delegate, jobNumber: i))
        }
        
        queue.waitUntilAllOperationsAreFinished()

        return result
    }
}
