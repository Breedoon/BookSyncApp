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
import SwiftAudioPlayer


/// This class is meant to be subclassed by each publication format view controller. It contains the shared behavior, eg. navigation bar toggling.
class ReaderViewController: UIViewController, Loggable {
    weak var moduleDelegate: ReaderFormatModuleDelegate?
    
    let navigator: UIViewController & Navigator
    let publication: Publication
    let bookId: Book.Id
    let books: BookRepository
    private let bookmarks: BookmarkRepository
    private let highlights: HighlightRepository?

    private(set) var stackView: UIStackView!
    private lazy var positionLabel = UILabel()
    internal var subscriptions = Set<AnyCancellable>()
    
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
    private var syncPathImported: Bool = false

    private var lastLoadFailed: Bool = false

    let playButton = UIButton()
    let playButtonSize = CGFloat(40)
    var playButtonImageConfig: UIImage.SymbolConfiguration;

    let skipBackwardButton = UIButton()
    let skipBackwardButtonSize = CGFloat(40)
    var skipBackwardButtonImageConfig: UIImage.SymbolConfiguration;

    let skipForwardButton = UIButton()
    let skipForwardButtonSize = CGFloat(40)
    var skipForwardButtonImageConfig: UIImage.SymbolConfiguration;

    let rateButton = UIButton()
    let rateButtonFrameSize = CGFloat(40)
    let rateButtonSize = CGFloat(15)
    let rateOptions = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    let rateOptionsLabels = ["½×", "¾×", "1×", "1¼×", "1½×", "1¾×", "2×"]
    final var rateOptionsDefaultIdx = 2  // 1x by default
    var rateOptionsSelectedIdx: Int

    var zoomModeEnabled = false;

    private var timer = Timer()

    private final var syncPathCacheSize = 20;  /* words retained in memory at every time (fetched from db) */
    private final var wordsLeftToReloadSyncPathCache = 2;  /* reload cache when reached Xth word from end of cache */
    private var syncPathCacheOffset = 0;
    private var syncPathCacheFirstIdx = 0;
    private var syncPathCache: [Int] = [];
    private var isSyncPathCacheUpdatingNow = false;
    var latestWordIdx = -1;  // TODO: make into an optional value

    var playerHighlightColor: UIColor = .blue
    var playerHighlightAlpha: Double = 0.3

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
                skipBackwardButton.isEnabled = true
                skipForwardButton.isEnabled = true
            } else {
                playButton.isEnabled = false
                rateButton.isEnabled = false
                skipBackwardButton.isEnabled = false
                skipForwardButton.isEnabled = false
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
        self.skipBackwardButtonImageConfig = UIImage.SymbolConfiguration(pointSize: skipBackwardButtonSize, weight: .bold, scale: .medium)
        self.skipForwardButtonImageConfig = UIImage.SymbolConfiguration(pointSize: skipForwardButtonSize, weight: .bold, scale: .medium)
        self.syncPathCache.reserveCapacity(self.syncPathCacheSize + self.wordsLeftToReloadSyncPathCache)
        self.rateOptionsSelectedIdx = rateOptionsDefaultIdx

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

        SAPlayer.shared.rate = Float(rateOptions[rateOptionsDefaultIdx])

        stackView.addArrangedSubview(playerToolbar)
        NSLayoutConstraint.activate([
            playerToolbar.heightAnchor.constraint(equalToConstant: 20 + playButtonSize * 1.5),  // TODO: make less arbitrary
        ])

        subscribeToPlayerChanges()
        setPlayButtonState(forAudioPlayerState: playbackStatus)
        skipBackwardButton.setImage(UIImage(systemName: "chevron.backward", withConfiguration: skipBackwardButtonImageConfig), for: .normal)
        skipForwardButton.setImage(UIImage(systemName: "chevron.forward", withConfiguration: skipForwardButtonImageConfig), for: .normal)

        updateSyncPathCache()
    }
    
    override func willMove(toParent parent: UIViewController?) {
        // Restore library's default UI colors
        navigationController?.navigationBar.tintColor = .black
        navigationController?.navigationBar.barTintColor = .white
        SAPlayer.shared.clear()
        timer.invalidate()
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
//        buttons.append(UIBarButtonItem(image: #imageLiteral(resourceName: "menuIcon"), style: .plain, target: self, action: #selector(presentOutline)))
        // DRM management
        if publication.isProtected {
            buttons.append(UIBarButtonItem(image: #imageLiteral(resourceName: "drm"), style: .plain, target: self, action: #selector(presentDRMManagement)))
        }
        // Bookmarks
//        buttons.append(UIBarButtonItem(image: #imageLiteral(resourceName: "bookmark"), style: .plain, target: self, action: #selector(bookmarkCurrentPosition)))
        
        // Search
        if publication._isSearchable {
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), style: .plain, target: self, action: #selector(showSearchUI)))
        }

        if audioBookPath == nil {  // no audiobook added yet, so add button for that
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "waveform.path.badge.plus"), style: .plain, target: self, action: #selector(importAudioBook)))
        }
        if syncPathCache.count == 0 {
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "text.badge.plus"), style: .plain, target: self, action: #selector(importSyncPath)))
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
                    latestWordIdx = book.lastPlayedWordId
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

        skipBackwardButton.translatesAutoresizingMaskIntoConstraints = false
        skipBackwardButton.tintColor = .black
        skipBackwardButton.addTarget(self, action: #selector(skipBackward), for: .touchUpInside)

        stackView.addSubview(skipBackwardButton)
        NSLayoutConstraint.activate([
            // centering between left and play button, from https://stackoverflow.com/a/67700762
            stackView.leftAnchor.anchorWithOffset(to: skipBackwardButton.centerXAnchor).constraint(equalTo: skipBackwardButton.centerXAnchor.anchorWithOffset(to: playButton.centerXAnchor)),
            skipBackwardButton.widthAnchor.constraint(equalToConstant: skipBackwardButtonSize),
            skipBackwardButton.heightAnchor.constraint(equalToConstant: skipBackwardButtonSize),
        ])

        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false
        skipForwardButton.tintColor = .black
        skipForwardButton.addTarget(self, action: #selector(skipForward), for: .touchUpInside)

        stackView.addSubview(skipForwardButton)
        NSLayoutConstraint.activate([
            // centering between left and play button, from https://stackoverflow.com/a/67700762
            stackView.rightAnchor.anchorWithOffset(to: skipForwardButton.centerXAnchor).constraint(equalTo: skipForwardButton.centerXAnchor.anchorWithOffset(to: playButton.centerXAnchor)),
            skipForwardButton.widthAnchor.constraint(equalToConstant: skipForwardButtonSize),
            skipForwardButton.heightAnchor.constraint(equalToConstant: skipForwardButtonSize),
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

    @objc func togglePlay() {
        SAPlayer.shared.togglePlayAndPause()
    }

    @objc func skipBackward() {
        skipOnce(self.latestWordIdx) { [self] prev, curr, next in
            guard let curr = curr else {return}
            if curr == self.latestWordIdx {  // current word is the first in its sentence
                guard let prev = prev else {return}
                seekToWordIdx(prev)
            } else {
                seekToWordIdx(curr)  // if current word is not first in its sentence, skip to start of current sentence
            }
        }
    }

    @objc func skipForward() {
        skipOnce(self.latestWordIdx) { [self] prev, curr, next in
            guard let next = next else {return}
            seekToWordIdx(next)
        }
    }

    func skipOnce(_ wordIdx: Int, completion: @escaping (Int?, Int?, Int?) -> Void) {
        /* To be implemented by children;
        Runs the completion providing it with 3 ids of first word in three sentence: previous, current, and next.
        eg: if our text is "...This is. A |very| complete. Full sentence..." and current word is "very",
            will return indexes of: (This, A, Full) */

        toast(NSLocalizedString("reader_player_format_not_supported", comment: "Method for word highlighting has not been overridden in format-specific view controller"), on: self.view, duration: 2)
    }

    func updatePlayHighlight() {
        if (playbackStatus != .playing) {
            return  // doesn't need to do anything when player is not playing
        }
        // Check if we're correct number of words away from the end of cache
        if (wordIdxToCacheIdx(latestWordIdx) >= syncPathCache.count - wordsLeftToReloadSyncPathCache) {
            updateSyncPathCache()
            if wordIdxToCacheIdx(latestWordIdx) >= syncPathCache.count {  // can't even display current word yet b/c it's not loaded
                return
            }
        }

        elapsed += 0.02 * Double(SAPlayer.shared.rate ?? 1)  // fake update elapsed cuz by default it gets updated only ~3 times/sec
        let currAudioIdx: Int = Int(elapsed / 0.02)

        var nextCacheIdx = wordIdxToCacheIdx(latestWordIdx) + 1
        if (nextCacheIdx >= syncPathCache.count) {  // if exceeding current cache size
            nextCacheIdx = wordIdxToCacheIdx(latestWordIdx) // keep latest word
        }
        if !((0 <= nextCacheIdx) && (nextCacheIdx < syncPathCache.count)) {
            return  // something went wrong, index out of range, just skip until it loads
        }
        if (currAudioIdx < syncPathCache[nextCacheIdx]) { // next word didn't start yet
            return // already showing the needed word, no need to do anything
        }

        // If reached here, need to update the highlight

        let currWordIdx = cacheIdxToWordIdx(nextCacheIdx)

        if zoomModeEnabled { zoomInOnNthWord(currWordIdx) }
        highlightNthWord(currWordIdx)

        latestWordIdx = currWordIdx  // save the current word to not re-highlight it

        saveLatestWordIdx()
    }

    private func wordIdxToCacheIdx(_ wordIdx: Int) -> Int {
        wordIdx - syncPathCacheFirstIdx
    }

    private func cacheIdxToWordIdx(_ cacheIdx: Int) -> Int {
        cacheIdx + syncPathCacheFirstIdx
    }

    private func updateSyncPathCache(completion: (() -> Void)? = nil) {
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

                    if let completion = completion {
                        completion()
                    }
                }
                .store(in: &subscriptions)
    }


    func seekToWordIdx(_ wordIdx: Int = 0, startPlaying: Bool = false) {
        syncPathCacheOffset = wordIdx
        syncPathCache = []
        syncPathCache.reserveCapacity(syncPathCacheSize)
        latestWordIdx = wordIdx
        if zoomModeEnabled { zoomInOnNthWord(wordIdx) }
        highlightNthWord(wordIdx)
        updateSyncPathCache { [self] in
            if !(0..<syncPathCache.count ~= wordIdxToCacheIdx(wordIdx)) { return }
            SAPlayer.shared.seekTo(seconds: 0.02 * Double(syncPathCache[wordIdxToCacheIdx(wordIdx)]))
            if startPlaying && playbackStatus != .playing {
                togglePlay()
            }
        }
    }

    func highlightNthWord(_ wordIdx: Int) {
        toast(NSLocalizedString("reader_player_format_not_supported", comment: "Method for word highlighting has not been overridden in format-specific view controller"), on: self.view, duration: 2)
    }
    
    func zoomInOnNthWord(_ wordIdx: Int) {
        toast(NSLocalizedString("reader_player_format_not_supported", comment: "Method for word highlighting has not been overridden in format-specific view controller"), on: self.view, duration: 2)
    }

    func calculateZoomAndOffsets(
            frameWidth: Double, frameHeight: Double,
            minZoom: Double, maxZoom: Double,
            wordLeftOffset: Double, wordTopOffset: Double,
            wordWidth: Double, wordHeight: Double,
            containerWidth: Double? = nil, containerHeight: Double? = nil
    ) -> (zoomLevel: Double, leftOffset: Double, topOffset: Double) {
        /* calculates zoom and offset to fit a word of given size and location onto the screen
            if container size is non-nil, will ensure the frame does not exceed 0-size in the given dimension */

        // Calculate the width and height ratios of the frame to the word (in case word is too tall?)
        let widthRatio = frameWidth / wordWidth
        let heightRatio = frameHeight / wordHeight

        // Determine the zoom level by using the smaller of the two ratios, constrained by maxZoom and minZoom
        let zoomLevel = max(minZoom, min(min(widthRatio, heightRatio), maxZoom))

        // Calculate spacing of the word within the frame
        let centeredLeftOffset = abs((frameWidth / zoomLevel) - wordWidth) / 2
        let centeredTopOffset = abs((frameHeight / zoomLevel) - wordHeight) / 2

        // Calculate the left full offset
        var leftOffset = wordLeftOffset - centeredLeftOffset
        var topOffset = wordTopOffset - centeredTopOffset

        // Apply constraints within givne dimsnsions
        if let lowerBound = containerHeight {
            topOffset = max(0, min(topOffset, lowerBound - frameHeight / zoomLevel))
        }
        if let rightBound = containerWidth {
            leftOffset = max(0, min(leftOffset, rightBound - frameWidth / zoomLevel))
        }

        return (zoomLevel, leftOffset, topOffset)
    }

    func saveLatestWordIdx() {
        books.saveLastPlayedWordId(id: bookId, wordIdx: latestWordIdx)
                .receive(on: DispatchQueue.main)
                .sink { completion in
                    switch completion {
                    case .finished:
                        self.log(.debug, "Successfully updated play position in database")
                    case .failure(let error):
                        self.log(.error, error)
                    }
                } receiveValue: { _ in }

    }

    func subscribeToPlayerChanges() {
        elapsedId = SAPlayer.Updates.ElapsedTime.subscribe { [weak self] (position) in
            guard let self = self else { return }

//            self.currentTimestampLabel.text = SAPlayer.prettifyTimestamp(position)
            self.elapsed = position

            guard self.duration != 0 else { return }

//            self.scrubberSlider.value = Float(position/self.duration)
        }

        playingStatusId = SAPlayer.Updates.PlayingStatus.subscribe { [weak self] (playing) in
            guard let self = self else { return }

            if (playing == .playing) {  // if started playing, do highlighting
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true, block: { _ in
                    self.updatePlayHighlight()
                })
                RunLoop.main.add(self.timer, forMode: .common)
            } else {  // stopped
                self.timer.invalidate()
//                self.saveLatestWordIdx()
            }

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

    @objc func importSyncPath(_ sender: Any) {
        let documentPicker = UIDocumentPickerViewController(documentTypes: ["public.comma-separated-values-text"], in: .import)
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
                            return promise(.success(destination))
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

    func exportWords(completion: @escaping (Result<Int, Error>) -> Void) {

    }


    func writeWordsToFile(words: [String]) {
        books.get(id: bookId)
        .receive(on: DispatchQueue.main)
                .sink { completion in
                    if case .failure(let error) = completion {
                        self.log(.error, error)
                    }


                } receiveValue: { book in
                    guard let book = book else { return }
                    let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(book.title).words")
                    let joinedWords = words.joined(separator: "\n") + "\n"
                    guard let data = joinedWords.data(using: .utf8) else { self.log(.error, "Error converting String to data"); return }
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            let fileHandle = try FileHandle(forWritingTo: destination)
                            fileHandle.seekToEndOfFile()
                            fileHandle.write(data)
                            fileHandle.closeFile()
                        } else {
                            try data.write(to: destination)
                        }
                    } catch {
                        self.log(.error, error)
                    }
                }
                .store(in: &subscriptions)
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
        let url: URL = urls[0]
        if url.absoluteString.hasSuffix(".csv") {
            books.addSyncPath(id: bookId, pathToCSV: url.path)
                    .receive(on: DispatchQueue.main)
                    .sink { completion in
                        if case .failure(let error) = completion {
                            self.log(.error, error)
                            self.moduleDelegate?.presentError(error, from: self)
                        }
                    } receiveValue: { [self] in
                        updateSyncPathCache() {
                            self.makeNavigationBar(animated: true)
                            self.seekToWordIdx(0)
                        }
                    }
                    .store(in: &subscriptions)

        } else {
            importAudiobook(from: urls[0])
                    .receive(on: DispatchQueue.main)
                    .sink { completion in
                        switch completion {
                        case .finished:
                            self.exportWords() { result in
                                switch result {
                                case .success(let value):
                                    self.log(.info, "Result words: \(value)")
                                    toast(NSLocalizedString("reader_audio_import_success_message", comment: "Success message when importing an audiobook into an open book"), on: self.view, duration: 1)
                                case .failure(let error):
                                    self.log(.error, error)
                                }
                            }
                        case .failure(let error):
                            print(error)
                            self.moduleDelegate?.presentError(error, from: self)
                        }
                    } receiveValue: { [self] in
                        updateAudioBookPath()
                    }
                    .store(in: &subscriptions)
        }
    }

}
