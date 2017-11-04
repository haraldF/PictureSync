//
//  ViewController.swift
//  PictureSync
//
//  Created by Harald Fernengel on 28.10.17.
//  Copyright © 2017 Harald Fernengel. All rights reserved.
//

import UIKit

class PictureCollectionDataSource: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {

    let albums: Albums
    var selectionCallback: ((_ didSelectRow: Int) -> Void)? = nil

    init(albums: Albums) {
        self.albums = albums
    }

    func numberOfComponents(in _: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return albums.count
    }

    func pickerView(_: UIPickerView, titleForRow row: Int, forComponent _: Int) -> String? {
        assert(row < albums.count)
        return albums[row].localizedTitle
    }

    func pickerView(_: UIPickerView, didSelectRow: Int, inComponent: Int) {
        selectionCallback?(didSelectRow)
    }
}

class ViewController: UIViewController, PictureSyncDelegate {
    @IBOutlet weak var collectionPicker: UIPickerView!
    @IBOutlet weak var syncButton: UIButton!

    @IBOutlet weak var totalProgress: UIProgressView!
    @IBOutlet weak var fileProgress: UIProgressView!

    @IBOutlet weak var statusLabel: UILabel!

    let pictureSync = PictureSync()
    var dataSource: PictureCollectionDataSource? = nil
    var restoredAlbumId: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        syncButton.isEnabled = false

        guard let userName = UserDefaults.standard.object(forKey: "user_preference") as? String,
            let password = UserDefaults.standard.object(forKey: "password_preference") as? String else {
            print("ERROR: Invalid preferences")
            UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!, completionHandler: nil)
            return
        }

        var path = UserDefaults.standard.object(forKey: "destination_preference") as? String
        if path == nil {
            path = "fritz.box/Seagate-Expansion-Desk-02"
        }

        let url = "ftp://\(userName):\(password)@\(path!)/\(userName)/"

        DispatchQueue.global(qos: .background).async {
            self.pictureSync.initialize(url: url)

            DispatchQueue.main.async {
                self.dataSource = PictureCollectionDataSource(albums: self.pictureSync.albums)
                self.collectionPicker.dataSource = self.dataSource
                self.collectionPicker.delegate = self.dataSource

                self.syncButton.isEnabled = self.pictureSync.albums.count > 0

                self.dataSource!.selectionCallback = { (didSelectRow: Int) in
                    self.syncButton.isEnabled = didSelectRow >= 0
                }

                // restore the album from the last session, if any
                if let restoredAlbumId = self.restoredAlbumId {
                    self.selectAlbum(id: restoredAlbumId)
                } else if let savedAlbumId = UserDefaults.standard.string(forKey: "album_identifier") {
                    self.selectAlbum(id: savedAlbumId)
                }
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)

        if let localIdentifier = getCurrentAlbumId() {
            coder.encode(localIdentifier, forKey: "album_identifier")
        }
    }

    override func decodeRestorableState(with coder: NSCoder) {
        super.decodeRestorableState(with: coder)

        restoredAlbumId = coder.decodeObject(forKey: "album_identifier") as? String
    }

    override func applicationFinishedRestoringState() {
        if let localIdentifier = restoredAlbumId {
            selectAlbum(id: localIdentifier)
        }
    }

    @discardableResult func selectAlbum(id: String) -> Bool {
        guard let datasource = self.dataSource else {
            return false
        }

        for i in 0..<datasource.albums.count {
            if datasource.albums[i].localIdentifier == id {
                collectionPicker.selectRow(i, inComponent: 0, animated: false)
                return true
            }
        }

        return false
    }

    func getCurrentAlbumId() -> String? {
        let selectedRow = collectionPicker.selectedRow(inComponent: 0)

        guard let dataSource = self.dataSource, (0..<dataSource.albums.count).contains(selectedRow) else {
            return nil
        }

        return dataSource.albums[selectedRow].localIdentifier
    }

    @IBAction func onSyncButtonClicked(_ sender: UIButton) {

        guard let localIdentifier = getCurrentAlbumId() else {
            return
        }

        UserDefaults.standard.set(localIdentifier, forKey: "album_identifier")

        totalProgress.isHidden = false
        fileProgress.isHidden = false
        pictureSync.delegate = self
        syncButton.isEnabled = false

        DispatchQueue.global(qos: .background).async {
            let syncResult = self.pictureSync.synchronizeAlbum(localIdentifier: localIdentifier)
            DispatchQueue.main.async {
                self.totalProgress.isHidden = true
                self.fileProgress.isHidden = true
                self.syncButton.isEnabled = true

                if let result = syncResult {
                    self.statusLabel.text = """
                    Synchronization Successful.
                      Total Images: \(result.totalFiles)
                      Uploaded: \(result.syncedFiles)
                      Skipped: \(result.skippedFiles)
                      Errors: \(result.errors)
                    """
                } else {
                    self.statusLabel.text = "Error, could not sync."
                }
            }
        }
    }
    
    func totalUploadProgress(progress: Float) {
        DispatchQueue.main.async {
            self.totalProgress.setProgress(progress, animated: true)
        }
    }
    
    func fileUploadProgress(progress: Float) {
        DispatchQueue.main.async {
            self.fileProgress.setProgress(progress, animated: true)
        }
    }

}

