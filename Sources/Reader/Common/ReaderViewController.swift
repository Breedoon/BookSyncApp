//
//  ReaderViewController.swift
//  r2-testapp-swift
//
//  Created by Mickaël Menu on 07.03.19.
//
//  Copyright 2019 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import Combine
import SafariServices
import UIKit
import R2Navigator
import R2Shared
import SwiftSoup
import WebKit
import SwiftUI
import SwiftAudioEx
import SwiftAudioPlayer


/// This class is meant to be subclassed by each publication format view controller. It contains the shared behavior, eg. navigation bar toggling.
class ReaderViewController: UIViewController, Loggable {
    weak var moduleDelegate: ReaderFormatModuleDelegate?
    
    let navigator: UIViewController & Navigator
    let publication: Publication
    let bookId: Book.Id
    private let books: BookRepository
    private let bookmarks: BookmarkRepository
    private let highlights: HighlightRepository?

    private(set) var stackView: UIStackView!
    private lazy var positionLabel = UILabel()
    private var subscriptions = Set<AnyCancellable>()
    
    private var searchViewModel: SearchViewModel?
    private var searchViewController: UIHostingController<SearchView>?
    
    /// This regex matches any string with at least 2 consecutive letters (not limited to ASCII).
    /// It's used when evaluating whether to display the body of a noteref referrer as the note's title.
    /// I.e. a `*` or `1` would not be used as a title, but `on` or `好書` would.
    private static var noterefTitleRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: "[\\p{Ll}\\p{Lu}\\p{Lt}\\p{Lo}]{2}")
    }()
    
    private var highlightContextMenu: UIHostingController<HighlightContextMenu>?
    private let highlightDecorationGroup = "highlights"
    private var currentHighlightCancellable: AnyCancellable?

    private var audioBookPath: String? = nil

    private var lastLoadFailed: Bool = false

    private let playButton = UIButton()
    private let playButtonSize = CGFloat(40)
    private var playButtonImageConfig: UIImage.SymbolConfiguration;

    private let rateButton = UIButton()
    private let rateButtonFrameSize = CGFloat(40)
    private let rateButtonSize = CGFloat(15)
    private let rateOptions = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private let rateOptionsLabels = ["½×", "¾×", "1×", "1¼×", "1½×", "1¾×", "2×"]
    private var rateOptionsSelectedIdx = 2  // 1x by default

    private var timer = Timer()

    private final var syncPathCacheSize = 200;  /* words retained in memory at every time (fetched from db) */
    private final var wordsLeftToReloadSyncPathCache = 5;  /* reload cache when reached Xth word from end of cache */
    private var syncPathCacheOffset = 0;
    private var syncPathCacheFirstIdx = 0;
    private var syncPathCache: [Int] = [];
    private var isSyncPathCacheUpdatingNow = false;
    private var latestWordIdx = -1;

    private final var textCacheSize = 5000;  /* n characters of book retained in memory */
    private final var charsLeftToReloadTextCache = 500;  /* reload cache when reached Xth character from end of cache */
    private var textCacheOffset = 0;
    private var textCacheFirstTextIdx = 0;
    private var textCache: String = "";
    private var wordStartTextIdx: [Int] = [];
    private var wordEndTextIdx: [Int] = [];
    private var textWordOffset = 0;
    private var isTextCacheUpdatingNow = false;

    var beingSeeked: Bool = false

    var downloadId: UInt?
    var playingStatusId: UInt?
    var elapsedId: UInt?

    var duration: Double = 0.0
    var elapsed: Double = 0.0
    var playbackStatus: SAPlayingStatus = .paused

    var lastPlayedAudioIndex: Int?

    var isPlayable: Bool = false {
        didSet {
            if isPlayable {
                playButton.isEnabled = true
                rateButton.isEnabled = true
//                skipBackwardButton.isEnabled = true
//                skipForwardButton.isEnabled = true
            } else {
                playButton.isEnabled = false
                rateButton.isEnabled = false
//                skipBackwardButton.isEnabled = false
//                skipForwardButton.isEnabled = false
            }
        }
    }

    init(navigator: UIViewController & Navigator, publication: Publication, bookId: Book.Id, books: BookRepository, bookmarks: BookmarkRepository, highlights: HighlightRepository? = nil) {
        self.navigator = navigator
        self.publication = publication
        self.bookId = bookId
        self.books = books
        self.bookmarks = bookmarks
        self.highlights = highlights
        self.playButtonImageConfig = UIImage.SymbolConfiguration(pointSize: playButtonSize, weight: .bold, scale: .medium)
        self.syncPathCache.reserveCapacity(self.syncPathCacheSize + self.wordsLeftToReloadSyncPathCache)
        self.wordStartTextIdx.reserveCapacity(self.textCacheSize + self.charsLeftToReloadTextCache)  // overestimate
        self.wordEndTextIdx.reserveCapacity(self.textCacheSize + self.charsLeftToReloadTextCache)

        super.init(nibName: nil, bundle: nil)
        
        addHighlightDecorationsObserverOnce()
        updateHighlightDecorations()

        NotificationCenter.default.addObserver(self, selector: #selector(voiceOverStatusDidChange), name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .white

        makeNavigationBar()
        updateAudioBookPath()

        stackView = UIStackView(frame: view.bounds)
        stackView.distribution = .fill
        stackView.axis = .vertical
        view.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        let topConstraint = stackView.topAnchor.constraint(equalTo: view.topAnchor)
        // `accessibilityTopMargin` takes precedence when VoiceOver is enabled.
        topConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint,
            stackView.rightAnchor.constraint(equalTo: view.rightAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stackView.leftAnchor.constraint(equalTo: view.leftAnchor)
        ])

        addChild(navigator)
        stackView.addArrangedSubview(navigator.view)
        navigator.didMove(toParent: self)
        
        stackView.addArrangedSubview(accessibilityToolbar)

        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.font = .systemFont(ofSize: 12)
        positionLabel.textColor = .darkGray
        view.addSubview(positionLabel)
        NSLayoutConstraint.activate([
            positionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            positionLabel.bottomAnchor.constraint(equalTo: navigator.view.bottomAnchor, constant: -20)
        ])

        stackView.addArrangedSubview(playerToolbar)
        NSLayoutConstraint.activate([
            playerToolbar.heightAnchor.constraint(equalToConstant: 20 + playButtonSize * 1.5),  // TODO: make less arbitrary
        ])

        subscribeToChanges()
        setPlayButtonState(forAudioPlayerState: playbackStatus)
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true, block: { _ in
            self.updatePlayHighlight()
        })

        updateSyncPathCache()
        updateTextCache()
    }
    
    override func willMove(toParent parent: UIViewController?) {
        // Restore library's default UI colors
        navigationController?.navigationBar.tintColor = .black
        navigationController?.navigationBar.barTintColor = .white
    }
    
    
    // MARK: - Navigation bar
    
    private var navigationBarHidden: Bool = true {
        didSet {
            updateNavigationBar()
        }
    }
    
    func makeNavigationBarButtons() -> [UIBarButtonItem] {
        var buttons: [UIBarButtonItem] = []
        // Table of Contents
        buttons.append(UIBarButtonItem(image: #imageLiteral(resourceName: "menuIcon"), style: .plain, target: self, action: #selector(presentOutline)))
        // DRM management
        if publication.isProtected {
            buttons.append(UIBarButtonItem(image: #imageLiteral(resourceName: "drm"), style: .plain, target: self, action: #selector(presentDRMManagement)))
        }
        // Bookmarks
        buttons.append(UIBarButtonItem(image: #imageLiteral(resourceName: "bookmark"), style: .plain, target: self, action: #selector(bookmarkCurrentPosition)))
        
        // Search
        if publication._isSearchable {
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), style: .plain, target: self, action: #selector(showSearchUI)))
        }

        if audioBookPath == nil {  // no audiobook added yet, so add button for that
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "waveform.path.badge.plus"), style: .plain, target: self, action: #selector(importAudioBook)))
        }
        return buttons
    }

    func updateAudioBookPath() {
        books.get(id: bookId)
                .receive(on: DispatchQueue.main)
                .sink { completion in
                    if case .failure(let error) = completion {
                        self.moduleDelegate?.presentError(error, from: self)
                    }
                } receiveValue: { [self] book in
                    if (book == nil) {
                        return
                    }
                    let book = book!
                    let newAudioBookPath = book.audioPath
                    if audioBookPath != newAudioBookPath {  // value changed so need to update navbar
                        audioBookPath = newAudioBookPath
                        makeNavigationBar(animated: true)

                        guard let newAudioBookPath = newAudioBookPath else {
                            return // if new audio path is nil, just exit, otherwise, add new audio to player
                        }
                        if let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                            SAPlayer.shared.startSavedAudio(withSavedUrl: documents.appendingPathComponent(newAudioBookPath))
                        }
                    }
                }
                .store(in: &subscriptions)
    }

    func makeNavigationBar(animated: Bool=false) {
        navigationItem.rightBarButtonItems = makeNavigationBarButtons()
        updateNavigationBar(animated: animated)
    }

    func toggleNavigationBar() {
        navigationBarHidden = !navigationBarHidden
    }
    
    func updateNavigationBar(animated: Bool = true) {
        let hidden = navigationBarHidden && !UIAccessibility.isVoiceOverRunning
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        setNeedsStatusBarAppearanceUpdate()
    }
    
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }
    
    override var prefersStatusBarHidden: Bool {
        return navigationBarHidden && !UIAccessibility.isVoiceOverRunning
    }

    
    // MARK: - Locations
    /// FIXME: This should be implemented in a shared Navigator interface, using Locators.
    
    var currentBookmark: Bookmark? {
        fatalError("Not implemented")
    }


    // MARK: - Outlines

    @objc func presentOutline() {
        guard let locatorPublisher = moduleDelegate?.presentOutline(of: publication, bookId: bookId, from: self) else {
             return
        }
            
        locatorPublisher
            .sink(receiveValue: { locator in
                self.navigator.go(to: locator, animated: false) {
                    self.dismiss(animated: true)
                }
            })
            .store(in: &subscriptions)
    }
    
    private var colorScheme = ColorScheme()
    func appearanceChanged(_ appearance: UserProperty) {
        colorScheme.update(with: appearance)
    }
    
    // MARK: - Bookmarks
    
    @objc func bookmarkCurrentPosition() {
        guard let bookmark = currentBookmark else {
            return
        }
        
        bookmarks.add(bookmark)
            .sink { completion in
                switch completion {
                case .finished:
                    toast(NSLocalizedString("reader_bookmark_success_message", comment: "Success message when adding a bookmark"), on: self.view, duration: 1)
                case .failure(let error):
                    print(error)
                    toast(NSLocalizedString("reader_bookmark_failure_message", comment: "Error message when adding a new bookmark failed"), on: self.view, duration: 2)
                }
            } receiveValue: { _ in }
            .store(in: &subscriptions)
    }
    
    // MARK: - Search
    @objc func showSearchUI() {
        if searchViewModel == nil {
            searchViewModel = SearchViewModel(publication: publication)
            searchViewModel?.$selectedLocator.sink(receiveValue: { locator in
                self.searchViewController?.dismiss(animated: true, completion: nil)
                if let locator = locator {
                    self.navigator.go(to: locator, animated: true) {
                        if let decorator = self.navigator as? DecorableNavigator {
                            let decoration = Decoration(id: "selectedSearchResult", locator: locator, style: Decoration.Style.highlight(tint: .yellow, isActive: false))
                            decorator.apply(decorations: [decoration], in: "search")
                        }
                    }
                }
            }).store(in: &subscriptions)
        }
        
        let searchView = SearchView(viewModel: searchViewModel!)
        let vc = UIHostingController(rootView: searchView)
        vc.modalPresentationStyle = .pageSheet
        present(vc, animated: true, completion: nil)
        searchViewController = vc
    }
    
    // MARK: - Highlights
    
    private func addHighlightDecorationsObserverOnce() {
        if highlights == nil { return }
        
        if let decorator = self.navigator as? DecorableNavigator {
            decorator.observeDecorationInteractions(inGroup: highlightDecorationGroup) { event in
                self.activateDecoration(event)
            }
        }
    }
    
    private func updateHighlightDecorations() {
        guard let highlights = highlights else { return }
        
        highlights.all(for: bookId)
            .assertNoFailure()
            .sink { highlights in
                if let decorator = self.navigator as? DecorableNavigator {
                    let decorations = highlights.map { Decoration(id: $0.id, locator: $0.locator, style: .highlight(tint: $0.color.uiColor, isActive: false)) }
                    decorator.apply(decorations: decorations, in: self.highlightDecorationGroup)
                }
            }
            .store(in: &subscriptions)
    }

    private func activateDecoration(_ event: OnDecorationActivatedEvent) {
        guard let highlights = highlights else { return }
        
        currentHighlightCancellable = highlights.highlight(for: event.decoration.id).sink { completion in
        } receiveValue: { [weak self] highlight in
            guard let self = self else { return }
            self.activateDecoration(for: highlight, on: event)
        }
    }
    
    private func activateDecoration(for highlight: Highlight, on event: OnDecorationActivatedEvent) {
        if highlightContextMenu != nil {
            highlightContextMenu?.removeFromParent()
        }
        
        let menuView = HighlightContextMenu(colors: [.red, .green, .blue, .yellow],
                                            systemFontSize: 20,
                                            colorScheme: colorScheme)
        
        menuView.selectedColorPublisher.sink { color in
            self.currentHighlightCancellable?.cancel()
            self.updateHighlight(event.decoration.id, withColor: color)
            self.highlightContextMenu?.dismiss(animated: true, completion: nil)
        }
        .store(in: &subscriptions)
        
        menuView.selectedDeletePublisher.sink { _ in
            self.currentHighlightCancellable?.cancel()
            self.deleteHighlight(event.decoration.id)
            self.highlightContextMenu?.dismiss(animated: true, completion: nil)
        }
        .store(in: &subscriptions)
        
        self.highlightContextMenu = UIHostingController(rootView: menuView)
        
        highlightContextMenu!.preferredContentSize = menuView.preferredSize
        highlightContextMenu!.modalPresentationStyle = .popover
        highlightContextMenu!.view.backgroundColor = UIColor(colorScheme.mainColor)
        
        if let popoverController = highlightContextMenu!.popoverPresentationController {
            popoverController.permittedArrowDirections = .down
            popoverController.sourceRect = event.rect ?? .zero
            popoverController.sourceView = self.view
            popoverController.backgroundColor = .cyan
            popoverController.delegate = self
            present(highlightContextMenu!, animated: true, completion: nil)
        }
    }
    
    // MARK: - DRM
    
    @objc func presentDRMManagement() {
        guard publication.isProtected else {
            return
        }
        moduleDelegate?.presentDRM(for: publication, from: self)
    }
    

    // MARK: - Accessibility
    
    /// Constraint used to shift the content under the navigation bar, since it is always visible when VoiceOver is running.
    private lazy var accessibilityTopMargin: NSLayoutConstraint = {
        let topAnchor: NSLayoutYAxisAnchor = {
            if #available(iOS 11.0, *) {
                return self.view.safeAreaLayoutGuide.topAnchor
            } else {
                return self.topLayoutGuide.bottomAnchor
            }
        }()
        return self.stackView.topAnchor.constraint(equalTo: topAnchor)
    }()
    
    private lazy var accessibilityToolbar: UIToolbar = {
        func makeItem(_ item: UIBarButtonItem.SystemItem, label: String? = nil, action: UIKit.Selector? = nil) -> UIBarButtonItem {
            let button = UIBarButtonItem(barButtonSystemItem: item, target: (action != nil) ? self : nil, action: action)
            button.accessibilityLabel = label
            return button
        }
        
        let toolbar = UIToolbar(frame: .zero)
        toolbar.items = [
            makeItem(.flexibleSpace),
            makeItem(.rewind, label: NSLocalizedString("reader_backward_a11y_label", comment: "Accessibility label to go backward in the publication"), action: #selector(goBackward)),
            makeItem(.flexibleSpace),
            makeItem(.fastForward, label: NSLocalizedString("reader_forward_a11y_label", comment: "Accessibility label to go forward in the publication"), action: #selector(goForward)),
            makeItem(.flexibleSpace),
        ]
        toolbar.isHidden = !UIAccessibility.isVoiceOverRunning
        toolbar.tintColor = UIColor.black
        return toolbar
    }()

    private lazy var playerToolbar: UIStackView = {
        stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.alignment = .top
        stackView.distribution = .fillEqually

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.tintColor = .black
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)

        stackView.addSubview(playButton)
        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: stackView.centerXAnchor),
            playButton.widthAnchor.constraint(equalToConstant: playButtonSize),
            playButton.heightAnchor.constraint(equalToConstant: playButtonSize),
        ])


        rateButton.translatesAutoresizingMaskIntoConstraints = false
        rateButton.addTarget(self, action: #selector(rateChanged), for: .touchUpInside)

        stackView.addSubview(rateButton)
        NSLayoutConstraint.activate([
            rateButton.leftAnchor.constraint(equalTo: stackView.leftAnchor),
//            rateButton.bottomAnchor.constraint(equalTo: stackView.bottomAnchor),
            rateButton.widthAnchor.constraint(equalToConstant: rateButtonFrameSize),
            rateButton.heightAnchor.constraint(equalToConstant: rateButtonFrameSize),
        ])

        rateButton.setTitle(rateOptionsLabels[rateOptionsSelectedIdx], for: .normal)
        rateButton.setTitleColor(.black, for: .normal)
        rateButton.titleLabel?.font =  UIFont.systemFont(ofSize: rateButtonSize)

        rateButton.titleEdgeInsets = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 0)


        return stackView
    }()
    
    private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
    
    @objc private func voiceOverStatusDidChange() {
        let isRunning = UIAccessibility.isVoiceOverRunning
        // Avoids excessive settings refresh when the status didn't change.
        guard isVoiceOverRunning != isRunning else {
            return
        }
        isVoiceOverRunning = isRunning
        accessibilityTopMargin.isActive = isRunning
        accessibilityToolbar.isHidden = !isRunning
        updateNavigationBar()
    }
    
    @objc private func goBackward() {
        navigator.goBackward()
    }

    @objc private func goForward() {
        navigator.goForward()
    }

    // MARK: - AudioPlayer

    func setPlayButtonState(forAudioPlayerState state: SAPlayingStatus) {
        playButton.setImage(state == .playing ? UIImage(systemName: "pause", withConfiguration: playButtonImageConfig)
                : UIImage(systemName: "play", withConfiguration: playButtonImageConfig), for: .normal)
    }

    @objc func togglePlay(_ sender: Any) {
        SAPlayer.shared.togglePlayAndPause()
    }

    func updatePlayHighlight() {
        if (playbackStatus != .playing) {
            return  // doesn't need to do anything when player is not playing
        }
        // Check if we're correct number of words away from the end of cache
        if (wordIdxToCacheIdx(latestWordIdx) >= syncPathCache.count - wordsLeftToReloadSyncPathCache) {
            updateSyncPathCache()
        }
        // TODO: find a better way to load text on spread load
        if textCache.count == 0 || latestWordIdx != -1 && wordEndTextIdx[latestWordIdx - textWordOffset] >= textCacheFirstTextIdx + textCache.count - charsLeftToReloadTextCache {
            updateTextCache()
            return
        }

        elapsed += 0.02 * Double(SAPlayer.shared.rate ?? 1)  // fake update elapsed cuz by default it gets updated only ~3/sec
        let currAudioIdx: Int = Int(elapsed / 0.02)

        var nextCacheIdx = wordIdxToCacheIdx(latestWordIdx) + 1
        if (nextCacheIdx >= syncPathCache.count) {  // if exceeding current cache size
            nextCacheIdx = wordIdxToCacheIdx(latestWordIdx) // keep latest word
        }

        if (currAudioIdx < syncPathCache[nextCacheIdx]) { // next word didn't start yet
            return // already showing the needed word, no need to do anything
        }

        // If reached here, need to update the highlight

        let currWordIdx = cacheIdxToWordIdx(nextCacheIdx)
        guard let decorator = navigator as? DecorableNavigator else {
            return
        }
        decorator.apply(decorations: [], in: "player")  // remove previous highlight
        latestWordIdx = currWordIdx  // save the current word to not re-highlight it
        let locator = wordIdxToLocator(currWordIdx)
        let decoration = Decoration(id: "playerWord", locator: locator, style: Decoration.Style.highlight(tint: .blue, isActive: false))
        decorator.apply(decorations: [decoration], in: "player")
    }

    func wordIdxToLocator(_ wordIdx: Int) -> Locator {
        let curr = navigator.currentLocation!
        let startIdx = textCache.index(textCache.startIndex, offsetBy: wordStartTextIdx[wordIdx] - textCacheFirstTextIdx)
        let endIdx = textCache.index(textCache.startIndex, offsetBy: wordEndTextIdx[wordIdx] - textCacheFirstTextIdx + 1)
        return Locator(href: curr.href, type: curr.type, title: curr.type, locations: curr.locations,
                text: Locator.Text(
                        after: String(textCache[endIdx...].prefix(200)),
                        before: String(textCache[..<startIdx].suffix(200)),
                        highlight: String(textCache[startIdx..<endIdx])
                ))
    }

    private func wordIdxToCacheIdx(_ wordIdx: Int) -> Int {
        wordIdx - syncPathCacheFirstIdx
    }

    private func cacheIdxToWordIdx(_ cacheIdx: Int) -> Int {
        cacheIdx + syncPathCacheFirstIdx
    }

    private final let singleQuotes: Array<Character> = Array("'‘’‛")  // ensures words like "there's" count as one word
    private func isPartOfWord(_ char: Character) -> Bool {
        return char.isLetter || char.isNumber || singleQuotes.contains(char)
    }

    private func updateTextCache() {
        if isTextCacheUpdatingNow { return }  // don't re-execute if already executing
        isTextCacheUpdatingNow = true
        evaluateJavaScript("document.body.textContent.substr(\(textCacheOffset), \(textCacheOffset + textCacheSize))") { [self] result in
            switch result {
            case .success(let value):
                let newText: String = value as! String

                // (same as in updateSyncCache) move last safety batch to the beginning and add new text at the end
                let nTransferable: Int = min(charsLeftToReloadTextCache, textCache.count)
                textCache = String(textCache.suffix(nTransferable) + newText)
                textCacheFirstTextIdx = textCacheOffset - nTransferable
                textCacheOffset += newText.count  // commit offset

                var currWordIdx = textWordOffset  // TODO: do caching of these based on uncached text

                var prevIdx: String.Index;
                if nTransferable != 0 {  // if transferred characters from previous cache, continue the latest word
                    prevIdx = textCache.index(textCache.startIndex, offsetBy: nTransferable - 1)
                } else {  // otherwise, use the first character
                    prevIdx = textCache.index(textCache.startIndex, offsetBy: 0)
                }
                var isInWord = isPartOfWord(textCache[prevIdx])

                for (idx, char) in textCache.enumerated() {
                    if idx < nTransferable  // skip existing characters but preserve idx from beginning
                               || isPartOfWord(char) == isInWord {  // either was in word and still is, or not and still isn't
                        continue
                    }
                    if isPartOfWord(char) {  // start of new word
                        currWordIdx += 1
                        wordStartTextIdx.append(idx + textCacheFirstTextIdx)
                        isInWord = true
                    } else {
                        wordEndTextIdx.append(idx - 1 + textCacheFirstTextIdx)  // mark previous position to end this word
                        isInWord = false
                    }
                }
                isTextCacheUpdatingNow = false  // let update again  TODO: set to false even if fails
            case .failure(let error):
                self.log(.error, error)
                isTextCacheUpdatingNow = false
            }
        }
    }

    private func updateSyncPathCache() {
        if isSyncPathCacheUpdatingNow { return }  // do not update at the same time
        isSyncPathCacheUpdatingNow = true
        books.getSyncPath(id: bookId,
                        limit: syncPathCacheSize,
                        offset: syncPathCacheOffset).receive(on: DispatchQueue.main)
                .sink { completion in
                    switch completion {
                    case .finished:
                        self.log(.debug, "Successfully refreshed sync path cache")
                    case .failure(let error):
                        print(error)
                        self.moduleDelegate?.presentError(error, from: self)
                    }
                } receiveValue: { minWordIdx, audioIdxs in
                    // Step 1: move last safety batch: to the beginning [~~~~~~~|###] -> [###|_______]
                    // can't move move more than there is
                    let nTransferable = min(self.wordsLeftToReloadSyncPathCache, self.syncPathCache.count)
                    self.syncPathCache[0..<nTransferable] = self.syncPathCache[self.syncPathCache.count - nTransferable..<self.syncPathCache.count]
                    // Step 1.5: fit cache to the data to be added (make smaller or larger - most cases nothing)
                    let nSlotsForNewData = self.syncPathCache.count - nTransferable
                    if (audioIdxs.count != nSlotsForNewData) { // happens in the beginning and at the end
                        // add dummy elements that are about to be replaced by new data if not enough
                        self.syncPathCache += [Int](repeating: -1, count: max(0, audioIdxs.count - nSlotsForNewData))
                        // if we're at the end, there isn't enough data to fill the whole cache, drop excess slots
                        self.syncPathCache = Array(self.syncPathCache[0..<nTransferable + audioIdxs.count])
                    }

                    // Step 2: add new data: [###|_______] -> [###|#######]
                    self.syncPathCache[nTransferable..<nTransferable + audioIdxs.count] = audioIdxs[0..<audioIdxs.count]
                    self.syncPathCacheFirstIdx = self.syncPathCacheOffset - nTransferable
                    self.syncPathCacheOffset += audioIdxs.count  // commit offset
                    self.isSyncPathCacheUpdatingNow = false  // let update again
                }
                .store(in: &subscriptions)
    }

    func evaluateJavaScript(_ script: String, completion: ((Result<Any, Error>) -> Void)? = nil) {
        (self.navigator as! R2Navigator.EPUBNavigatorViewController).evaluateJavaScript(script, completion: completion)
    }

    func subscribeToChanges() {
        elapsedId = SAPlayer.Updates.ElapsedTime.subscribe { [weak self] (position) in
            guard let self = self else { return }

//            self.currentTimestampLabel.text = SAPlayer.prettifyTimestamp(position)
            self.elapsed = position

            guard self.duration != 0 else { return }

//            self.scrubberSlider.value = Float(position/self.duration)
        }

        playingStatusId = SAPlayer.Updates.PlayingStatus.subscribe { [weak self] (playing) in
            guard let self = self else { return }

            self.playbackStatus = playing

            self.setPlayButtonState(forAudioPlayerState: self.playbackStatus)

        }

    }

    func unsubscribeFromChanges() {
        guard let elapsedId = self.elapsedId,
              let downloadId = self.downloadId,
              let playingStatusId = self.playingStatusId else { return }

        SAPlayer.Updates.ElapsedTime.unsubscribe(elapsedId)
        SAPlayer.Updates.AudioDownloading.unsubscribe(downloadId)
        SAPlayer.Updates.PlayingStatus.unsubscribe(playingStatusId)
    }


    @IBAction func scrubberStartedSeeking(_ sender: UISlider) {
//        beingSeeked = true
    }

    @IBAction func scrubberSeeked(_ sender: Any) {
//        let value = Double(scrubberSlider.value) * duration
//        SAPlayer.shared.seekTo(seconds: value)
//        beingSeeked = false
    }


    @IBAction func rateChanged(_ sender: Any) {
        // Once clicked, go to next rate option and loop around (1x -> 1.5x -> 2x -> 0.5x -> 1x)
        let newRateOptionIdx = (rateOptionsSelectedIdx + 1) % rateOptions.count
        SAPlayer.shared.rate = Float(rateOptions[newRateOptionIdx])
        rateButton.setTitle(rateOptionsLabels[newRateOptionIdx], for: .normal)
        rateOptionsSelectedIdx = newRateOptionIdx
    }

    @IBAction func playPauseTouched(_ sender: Any) {
        SAPlayer.shared.togglePlayAndPause()
    }

    @objc func importAudioBook(_ sender: Any) {
        let documentPicker = UIDocumentPickerViewController(documentTypes: ["public.mp3"], in: .import)
        documentPicker.delegate = self
        present(documentPicker, animated: true, completion: nil)

    }

    /// Moves the given `sourceURL` to the user Documents/ directory.
    private func moveAudiobookToDocuments(from source: URL, title: String, mediaType: MediaType) -> AnyPublisher<URL, Error> {
        Paths.makeDocumentURL(title: title, mediaType: mediaType)
                .flatMap { destination in
                    Future(on: .global()) { [self] promise in
                        // Necessary to read URL exported from the Files app, for example.
                        let shouldRelinquishAccess = source.startAccessingSecurityScopedResource()
                        defer {
                            if shouldRelinquishAccess {
                                source.stopAccessingSecurityScopedResource()
                            }
                        }

                        do {
                            try FileManager.default.copyItem(at: source, to: destination)
                            books.addAudioPath(id: bookId, audioPath: destination)
                                    .receive(on: DispatchQueue.main)
                                    .sink { completion in
                                        switch completion {
                                        case .finished:
                                            print("Finished audio link updating")
                                        case .failure(let error):
                                            print(error)
                                            self.moduleDelegate?.presentError(error, from: self)
                                        }
                                    } receiveValue: {}
                                    .store(in: &subscriptions)
                            // When returning .finished for some reason,
                            // it spirals into infinite loop and keeps copying files, so have to throw an error
                            // FIXME: Fix infinite loop when returning .finished
                            return promise(.failure(LibraryError.cancelled))
                        } catch {
                            return promise(.failure(LibraryError.importFailed(error)))
                        }
                    }
                }
                .eraseToAnyPublisher()
    }

    func importAudiobook(from url: URL) -> AnyPublisher<(), Error> {
        books.get(id: bookId).flatMap { [self] book in
                    moveAudiobookToDocuments(from: url, title: book!.title, mediaType: MediaType.mp3).flatMap { url in
                        books.addAudioPath(id: bookId, audioPath: url)
                    }
                }
                .eraseToAnyPublisher()
    }

}

extension ReaderViewController: NavigatorDelegate {

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        books.saveProgress(for: bookId, locator: locator)
            .sink { completion in
                if case .failure(let error) = completion {
                    self.moduleDelegate?.presentError(error, from: self)
                }
            } receiveValue: { _ in }
            .store(in: &subscriptions)

        positionLabel.text = {
            if let position = locator.locations.position {
                return "\(position) / \(publication.positions.count)"
            } else if let progression = locator.locations.totalProgression {
                return "\(progression)%"
            } else {
                return nil
            }
        }()
    }
    
    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        // SFSafariViewController crashes when given an URL without an HTTP scheme.
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }
    
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        moduleDelegate?.presentError(error, from: self)
    }
    
    func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: R2Shared.Link, content: String, referrer: String?) -> Bool {
    
        var title = referrer
        if let t = title {
            title = try? clean(t, .none())
        }
        if !suitableTitle(title) {
            title = nil
        }
        
        let content = (try? clean(content, .none())) ?? ""
        let page =
        """
        <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
            </head>
            <body>
                \(content)
            </body>
        </html>
        """
        
        let wk = WKWebView()
        wk.loadHTMLString(page, baseURL: nil)
        
        let vc = UIViewController()
        vc.view = wk
        vc.navigationItem.title = title
        vc.navigationItem.leftBarButtonItem = BarButtonItem(barButtonSystemItem: .done, actionHandler: { (item) in
            vc.dismiss(animated: true, completion: nil)
        })
        
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        self.present(nav, animated: true, completion: nil)
        
        return false
    }
    
    /// Checks to ensure the title is non-nil and contains at least 2 letters.
    func suitableTitle(_ title: String?) -> Bool {
        guard let title = title else { return false }
        let range = NSRange(location: 0, length: title.utf16.count)
        let match = ReaderViewController.noterefTitleRegex.firstMatch(in: title, range: range)
        return match != nil
    }
    
}

extension ReaderViewController: VisualNavigatorDelegate {
    
    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        // clear a current search highlight
        if let decorator = self.navigator as? DecorableNavigator {
            decorator.apply(decorations: [], in: "search")
        }
        
        let viewport = navigator.view.bounds
        // Skips to previous/next pages if the tap is on the content edges.
        let thresholdRange = 0...(0.2 * viewport.width)
        var moved = false
        if thresholdRange ~= point.x {
            moved = navigator.goLeft(animated: false)
        } else if thresholdRange ~= (viewport.maxX - point.x) {
            moved = navigator.goRight(animated: false)
        }
        
        if !moved {
            toggleNavigationBar()
        }
    }
    
}

// MARK: - Highlights management

extension ReaderViewController {
    func saveHighlight(_ highlight: Highlight) {
        guard let highlights = highlights else { return }
        
        highlights.add(highlight)
            .sink { completion in
                switch completion {
                case .finished:
                    toast(NSLocalizedString("reader_highlight_success_message", comment: "Success message when adding a bookmark"), on: self.view, duration: 1)
                case .failure(let error):
                    print(error)
                    toast(NSLocalizedString("reader_highlight_failure_message", comment: "Error message when adding a new bookmark failed"), on: self.view, duration: 2)
                }
            } receiveValue: { _ in }
            .store(in: &subscriptions)
    }

    func updateHighlight(_ highlightID: Highlight.Id, withColor color: HighlightColor) {
        guard let highlights = highlights else { return }
        
        highlights.update(highlightID, color: color)
            .assertNoFailure()
            .sink { completion in
                
            }
            .store(in: &subscriptions)
    }

    func deleteHighlight(_ highlightID: Highlight.Id)  {
        guard let highlights = highlights else { return }
        
        highlights.remove(highlightID)
            .assertNoFailure()
            .sink {}
            .store(in: &subscriptions)
    }
}

extension ReaderViewController: UIPopoverPresentationControllerDelegate {
    // Prevent the popOver to be presented fullscreen on iPhones.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle
    {
        return .none
    }
}

extension ReaderViewController: UIDocumentPickerDelegate {

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller.documentPickerMode == .import else {
            return
        }
        importFiles(at: urls)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        importFiles(at: [url])
    }

    private func importFiles(at urls: [URL]) {
        importAudiobook(from: urls[0])
                .receive(on: DispatchQueue.main)
                .sink { completion in
                    switch completion {
                    case .finished:
                        toast(NSLocalizedString("reader_audio_import_success_message", comment: "Success message when importing an audiobook into an open book"), on: self.view, duration: 1)
                    case .failure(let error):
                        print(error)
                        self.moduleDelegate?.presentError(error, from: self)
                    }
                } receiveValue: {}
                .store(in: &subscriptions)
    }

}
