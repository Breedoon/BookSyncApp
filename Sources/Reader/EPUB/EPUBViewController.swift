//
//  EPUBViewController.swift
//  r2-testapp-swift
//
//  Created by Alexandre Camilleri on 7/3/17.
//
//  Copyright 2018 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import UIKit
import R2Shared
import R2Navigator

class EPUBViewController: ReaderViewController {
    var popoverUserconfigurationAnchor: UIBarButtonItem?
    var userSettingNavigationController: UserSettingsNavigationController
    var playerHighlightColorCSS = "rgba(255, 255, 0, 0.3)"
    
    init(publication: Publication, locator: Locator?, bookId: Book.Id, books: BookRepository, bookmarks: BookmarkRepository, highlights: HighlightRepository, resourcesServer: ResourcesServer) {
        var navigatorEditingActions = EditingAction.defaultActions
        navigatorEditingActions.append(EditingAction(title: "Start Playing", action: #selector(playFromSelection)))
        var navigatorConfig = EPUBNavigatorViewController.Configuration()
        navigatorConfig.editingActions = navigatorEditingActions
        
        let navigator = EPUBNavigatorViewController(publication: publication, initialLocation: locator, resourcesServer: resourcesServer, config: navigatorConfig)

        let settingsStoryboard = UIStoryboard(name: "UserSettings", bundle: nil)
        userSettingNavigationController = settingsStoryboard.instantiateViewController(withIdentifier: "UserSettingsNavigationController") as! UserSettingsNavigationController
        userSettingNavigationController.fontSelectionViewController =
            (settingsStoryboard.instantiateViewController(withIdentifier: "FontSelectionViewController") as! FontSelectionViewController)
        userSettingNavigationController.advancedSettingsViewController =
            (settingsStoryboard.instantiateViewController(withIdentifier: "AdvancedSettingsViewController") as! AdvancedSettingsViewController)
        
        super.init(navigator: navigator, publication: publication, bookId: bookId, books: books, bookmarks: bookmarks, highlights: highlights)

        playerHighlightColorCSS = playerHighlightColor.cssValue(alpha: playerHighlightAlpha)

        navigator.delegate = self
    }
    
    var epubNavigator: EPUBNavigatorViewController {
        return navigator as! EPUBNavigatorViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
  
        /// Set initial UI appearance.
        if let appearance = publication.userProperties.getProperty(reference: ReadiumCSSReference.appearance.rawValue) {
            setUIColor(for: appearance)
        }
        
        let userSettings = epubNavigator.userSettings
        userSettingNavigationController.userSettings = userSettings
        userSettingNavigationController.modalPresentationStyle = .popover
        userSettingNavigationController.usdelegate = self
        userSettingNavigationController.userSettingsTableViewController.publication = publication
        

        publication.userSettingsUIPresetUpdated = { [weak self] preset in
            guard let `self` = self, let presetScrollValue:Bool = preset?[.scroll] else {
                return
            }
            
            if let scroll = self.userSettingNavigationController.userSettings.userProperties.getProperty(reference: ReadiumCSSReference.scroll.rawValue) as? Switchable {
                if scroll.on != presetScrollValue {
                    self.userSettingNavigationController.scrollModeDidChange()
                }
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        epubNavigator.userSettings.save()
    }

    override func makeNavigationBarButtons() -> [UIBarButtonItem] {
        var buttons = super.makeNavigationBarButtons()

        // User configuration button
        let userSettingsButton = UIBarButtonItem(image: #imageLiteral(resourceName: "settingsIcon"), style: .plain, target: self, action: #selector(presentUserSettings))
        buttons.insert(userSettingsButton, at: 1)
        popoverUserconfigurationAnchor = userSettingsButton

        return buttons
    }
    
    override var currentBookmark: Bookmark? {
        guard let locator = navigator.currentLocation else {
            return nil
        }
        
        return Bookmark(bookId: bookId, locator: locator)
    }
    
    @objc func presentUserSettings() {
        let popoverPresentationController = userSettingNavigationController.popoverPresentationController!
        
        popoverPresentationController.delegate = self
        popoverPresentationController.barButtonItem = popoverUserconfigurationAnchor

        userSettingNavigationController.publication = publication
        present(userSettingNavigationController, animated: true) {
            // Makes sure that the popover is dismissed also when tapping on one of the other UIBarButtonItems.
            // ie. http://karmeye.com/2014/11/20/ios8-popovers-and-passthroughviews/
            popoverPresentationController.passthroughViews = nil
        }
    }

    @objc func highlightSelection() {
        if let navigator = navigator as? SelectableNavigator, let selection = navigator.currentSelection {
            let highlight = Highlight(bookId: bookId, locator: selection.locator, color: .yellow)
            saveHighlight(highlight)
            navigator.clearSelection()
        }
    }

    func evaluateJavaScript(_ script: String, completion: ((Result<Any, Error>) -> Void)? = nil) {
        if let controller = self.navigator as? R2Navigator.EPUBNavigatorViewController {
            controller.evaluateJavaScript(script, completion: completion)
        }
    }

    override func highlightNthWord(_ wordIdx: Int) {
        evaluateJavaScript("highlightWordIdx(\(wordIdx), \"\(playerHighlightColorCSS)\")")
    }

    @objc func playFromSelection() {
        evaluateJavaScript("getSelectedWord()") { [self] result in
            switch result {
            case .success(let value):
                if let wordIdx = value as? Int {
                    seekToWordIdx(wordIdx)
                } else {
                    toast(NSLocalizedString("reader_player_cannot_play_from_selection", comment: "Error in js function to get word id from highlight"), on: self.view, duration: 2)
                }
            case .failure(let error):
                self.log(.error, error)
            }
        }
    }

    func splitterScriptText() -> String? {
        (Bundle.main.url(forResource: "word-splitter", withExtension: "js").flatMap { try? String(contentsOf: $0) })
    }
}

extension EPUBViewController: EPUBNavigatorDelegate {
    func spreadViewDidLoad(_ spreadView: JSExecutable) {
        guard let splitter_script = splitterScriptText() else {
            return
        }
        spreadView.evaluateScript(splitter_script, inHREF: nil) { result in
            switch result {
            case .success(let value):
                spreadView.evaluateScript("splitBodyIntoWords()", inHREF: nil) { result in
                    switch result {
                    case .success(let value):
                        self.seekToWordIdx(self.latestWordIdx)
                    case .failure(let error):
                        self.log(.error, error)
                    }
                }
            case .failure(let error):
                self.log(.error, error)
            }
        }

    }
}

extension EPUBViewController: UIGestureRecognizerDelegate {
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
}

extension EPUBViewController: UserSettingsNavigationControllerDelegate {

    internal func getUserSettings() -> UserSettings {
        return epubNavigator.userSettings
    }
    
    internal func updateUserSettingsStyle() {
        DispatchQueue.main.async {
            self.epubNavigator.updateUserSettingStyle()
        }
    }
    
    /// Synchronyze the UI appearance to the UserSettings.Appearance.
    ///
    /// - Parameter appearance: The appearance.
    internal func setUIColor(for appearance: UserProperty) {
        self.appearanceChanged(appearance)
        let colors = AssociatedColors.getColors(for: appearance)
        
        navigator.view.backgroundColor = colors.mainColor
        view.backgroundColor = colors.mainColor
        //
        navigationController?.navigationBar.barTintColor = colors.mainColor
        navigationController?.navigationBar.tintColor = colors.textColor
        
        navigationController?.navigationBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: colors.textColor]
    }

}
