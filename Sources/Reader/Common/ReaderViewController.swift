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

    let transcriptWords = ["with", "the", "progressive", "dawn", "the", "outlines", "of", "an", "immense", "camp", "became", "visible", "long", "stretches", "of", "several", "rows", "of", "barbed", "wire", "fences", "watch", "towers", "searchlights", "and", "long", "columns", "of", "ragged", "human", "figures", "grey", "in", "the", "greyness", "of", "dawn", "trekking", "along", "the", "straight", "desolate", "roads", "to", "what", "destination", "we", "did", "not", "know"]
    let transcriptWordPath = [0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,4,4,4,4,4,4,4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,6,6,6,6,6,6,6,6,6,7,7,7,7,7,7,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,14,14,14,14,14,14,14,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,17,17,17,17,17,17,17,17,17,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,22,22,22,22,22,22,22,22,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,24,24,24,24,24,24,24,24,24,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,27,27,27,27,27,27,27,27,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,32,32,32,32,32,33,33,33,33,33,33,33,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,35,35,35,35,35,35,35,35,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,37,37,37,37,37,37,37,37,37,37,37,37,37,37,37,37,37,37,38,38,38,38,38,38,38,38,38,38,38,38,38,39,39,39,39,39,39,39,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,43,43,43,43,43,43,43,43,44,44,44,44,44,44,44,44,44,44,44,44,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,46,46,46,46,46,46,46,47,47,47,47,47,47,47,47,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49]
    var latestWordIdx = -1;

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
      
        navigationItem.rightBarButtonItems = makeNavigationBarButtons()
        updateNavigationBar(animated: false)
        
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

        let documents = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        SAPlayer.shared.startSavedAudio(withSavedUrl: documents.appendingPathComponent("02-test-20sec.mp3"))
        subscribeToChanges()
        setPlayButtonState(forAudioPlayerState: playbackStatus)
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true, block: { _ in
            self.updatePlayHighlight()
        })
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

        return buttons
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
        elapsed += 0.02 * Double(SAPlayer.shared.rate ?? 1)  // fake update elapsed cuz by default it gets updated only ~3/sec
        let currAudioIdx: Int = Int(elapsed / 0.02)
        let currWordIdx = transcriptWordPath[currAudioIdx]
        if (currWordIdx == latestWordIdx) {
            return // already showing the needed word, no need to do anything
        }
        // If reached here, need to update the highlight
        if let decorator = self.navigator as? DecorableNavigator {
            decorator.apply(decorations: [], in: "player")  // remove previous highlight
        }

        latestWordIdx = currWordIdx  // save the current word to not re-highlight it
        print(transcriptWords[currWordIdx])
        let curr = navigator.currentLocation!
        var locator = Locator(href: curr.href, type: curr.type, title: curr.type, locations: curr.locations,
                text: Locator.Text(
                        after: String(Array(transcriptWords[currWordIdx...]).dropFirst(1).joined(separator: " ").prefix(200)),
                        before: String(Array(transcriptWords[0...currWordIdx]).dropLast(1).joined(separator: " ").prefix(200)),
                        highlight: transcriptWords[currWordIdx]
                ))
        if let decorator = self.navigator as? DecorableNavigator {
            let decoration = Decoration(id: "playerWord", locator: locator, style: Decoration.Style.highlight(tint: .blue, isActive: false))
            decorator.apply(decorations: [decoration], in: "player")
        }

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
                    moveAudiobookToDocuments(from: url, title: book.title, mediaType: MediaType.mp3).flatMap { url in
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
