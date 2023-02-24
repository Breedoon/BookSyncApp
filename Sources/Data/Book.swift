//
//  Copyright 2021 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Combine
import Foundation
import GRDB
import R2Shared

struct Book: Codable {
    struct Id: EntityId { let rawValue: Int64 }
    
    let id: Id?
    /// Canonical identifier for the publication, extracted from its metadata.
    var identifier: String?
    /// Title of the publication, extracted from its metadata.
    var title: String
    /// Authors of the publication, separated by commas.
    var authors: String?
    /// Media type associated to the publication.
    var type: String
    /// Location of the packaged publication or a manifest.
    var path: String
    /// Location of the cover.
    var coverPath: String?
    /// Last read location in the publication.
    var locator: Locator? {
        didSet { progression = locator?.locations.totalProgression ?? 0 }
    }
    /// Current progression in the publication, extracted from the locator.
    var progression: Double
    /// Location of the audiobook attached to this book
    var audioPath: String?;
    /// Number of word in the text that has been played (0-indexed)
    var lastPlayedWordId: Int;
    /// Date of creation.
    var created: Date
    
    var mediaType: MediaType { MediaType.of(mediaType: type) ?? .binary }
    
    init(id: Id? = nil, identifier: String? = nil, title: String, authors: String? = nil, type: String, path: String, coverPath: String? = nil, locator: Locator? = nil, audioPath: String? = nil, lastPlayedWordId: Int? = nil, created: Date = Date()) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.authors = authors
        self.type = type
        self.path = path
        self.coverPath = coverPath
        self.locator = locator
        self.progression = locator?.locations.totalProgression ?? 0
        self.audioPath = audioPath
        self.lastPlayedWordId = lastPlayedWordId ?? -1
        self.created = created
    }
    
    var cover: URL? {
        coverPath.map { Paths.covers.appendingPathComponent($0) }
    }
}

extension Book: TableRecord, FetchableRecord, PersistableRecord {
    enum Columns: String, ColumnExpression {
        case id, identifier, title, type, path, coverPath, locator, progression, created
    }
}

final class BookRepository {
    private let db: Database
    
    init(db: Database) {
        self.db = db
    }
    
    func all() -> AnyPublisher<[Book], Error> {
        db.observe { db in
            try Book.order(Book.Columns.created).fetchAll(db)
        }
    }
    
    func add(_ book: Book) -> AnyPublisher<Book.Id, Error> {
        return db.write { db in
            try book.insert(db)
            return Book.Id(rawValue: db.lastInsertedRowID)
        }.eraseToAnyPublisher()
    }
    
    func remove(_ id: Book.Id) -> AnyPublisher<Void, Error> {
        db.write { db in try Book.deleteOne(db, key: id) }
    }
    
    func saveProgress(for id: Book.Id, locator: Locator) -> AnyPublisher<Void, Error> {
        guard let json = locator.jsonString else {
            return .just(())
        }
        
        return db.write { db in
            try db.execute(literal: """
                UPDATE book
                   SET locator = \(json), progression = \(locator.locations.totalProgression ?? 0)
                 WHERE id = \(id)
            """)
        }
    }

    func get(id: Book.Id) -> AnyPublisher<Book?, Error> {
        db.read { db in
            return try Book.filter(Book.Columns.id == id).fetchOne(db)
        }
    }

    func addAudioPath(id: Book.Id, audioPath: URL) -> AnyPublisher<Void, Error> {
        db.write { db in
            let url = (audioPath.isFileURL || audioPath.scheme == nil) ? audioPath.lastPathComponent : audioPath.absoluteString
            try db.execute(literal: """
                                        UPDATE book
                                           SET audioPath = \(url)
                                         WHERE id = \(id)
                                    """)
        }
    }

    func addSyncPath(id: Book.Id, pathToCSV: String) -> AnyPublisher<Void, Error> {
        db.write { db in
            var path: String = try String(contentsOfFile: pathToCSV)
            path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let sql = "INSERT INTO syncpaths (bookId, wordId, startTimeStep) VALUES (\(id.rawValue)," + path.replacingOccurrences(of: "\n", with: ");\nINSERT INTO syncpaths (bookId, wordId, startTimeStep) VALUES (\(id.rawValue),") + ");"
            try db.execute(sql: sql)
        }
    }

    func getSyncPath(id: Book.Id, limit: Int = 500, offset: Int = 0) -> AnyPublisher<(Int, [Int]), Error> {
        db.observe { db in
            do {
                var audioIdxs: [Int] = []
                var wordIdxs: [Int] = []
                audioIdxs.reserveCapacity(limit)
                wordIdxs.reserveCapacity(limit)
                for row in try Row.fetchAll(db.makeStatement(sql: """
                                                                  SELECT wordId, startTimeStep 
                                                                    FROM syncpaths 
                                                                    WHERE bookId = \(id.rawValue)
                                                                    ORDER by wordId
                                                                    LIMIT \(limit)
                                                                    OFFSET \(offset)
                                                                  """)) {
                    wordIdxs.append(row[0])
                    audioIdxs.append(row[1])
                }
                let minIdx: Int = wordIdxs.first ?? 0
                return (minIdx, audioIdxs)
            } catch {
                return (0, [])
            }
        }
    }

    func saveLastPlayedWordId(id: Book.Id, wordIdx: Int) -> AnyPublisher<Void, Error> {
        db.write { db in
            try db.execute(literal: """
                                        UPDATE book
                                           SET lastPlayedWordId = \(wordIdx)
                                         WHERE id = \(id.rawValue)
                                    """)
        }
    }

    func saveChapterOffset(id: Book.Id, href: String, nWordsAtStart: Int) -> AnyPublisher<Void, Error> {
        db.write { db in
            // TODO: possible error if app closed midway indexing and it might not index later chapters
            try db.execute(sql: """
                                        INSERT INTO chapterWordOffsets (chapterHREF, bookId, nWordsAtStart)
                                            VALUES ('\(href)', \(id.rawValue), \(nWordsAtStart))
                                    """)
        }
    }

    func getChapterOffset(id: Book.Id, href: String) -> AnyPublisher<Int?, Error> {
        db.observe { db in  // TODO: possible error if app closed midway indexing and it might not index later chapters

            do {
                    for row in try Row.fetchAll(db.makeStatement(sql: """
                                                                  SELECT nWordsAtStart 
                                                                         FROM chapterWordOffsets 
                                                                         WHERE bookId = \(id.rawValue)
                                                                         AND chapterHREF = '\(href)'
                                                                  """)) {
                    return row[0]  // TODO: idk how to fetch only one so leaving for future
                }
            } catch {
                return nil
            }
            return nil
        }
    }
}
