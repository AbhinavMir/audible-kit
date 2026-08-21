import Foundation
import Testing
@testable import AudibleKit

/// Chapters come from a publisher's data, which is not always tidy.
@Suite("Fuzzing chapters")
struct ChapterFuzzTests {

    static func license(_ chapters: String) -> Data {
        Data("""
        {"content_license": {"status_code": "Granted", "license_response": "x",
         "content_metadata": {"content_url": {"offline_url": "https://x.invalid/a.aax"},
         "chapter_info": {"chapters": [\(chapters)]}}}}
        """.utf8)
    }

    @Test("Chapters of every awkward shape are read or dropped, never fatal")
    func awkwardChapters() {
        let shapes = [
            #"{"title": "A", "start_offset_ms": 0, "length_ms": 0}"#,
            #"{"title": "A", "start_offset_ms": -5000, "length_ms": 1000}"#,
            #"{"title": "A", "start_offset_ms": 0, "length_ms": -1000}"#,
            #"{"title": "", "start_offset_ms": 0, "length_ms": 1000}"#,
            #"{"start_offset_ms": 0, "length_ms": 1000}"#,
            #"{"title": "A"}"#,
            #"{"title": "A", "start_offset_ms": "0", "length_ms": "1000"}"#,
            #"{"title": "B", "start_offset_ms": 5000, "length_ms": 1000},{"title": "A", "start_offset_ms": 0, "length_ms": 1000}"#,
            #"{"title": "A", "start_offset_ms": 0, "length_ms": 9e300}"#,
            #"{"title": "A", "start_offset_ms": 1e308, "length_ms": 1000}"#
        ]
        for shape in shapes {
            let metadata = (try? JSONSerialization.jsonObject(
                with: Self.license(shape)) as? [String: Any])
                .flatMap { ($0?["content_license"] as? [String: Any])?["content_metadata"] }
                as? [String: Any] ?? [:]
            let chapters = LicenseService.chapters(in: metadata)

            for chapter in chapters {
                // Whatever arrives, a chapter that reaches a player must be a
                // place a player can go to.
                #expect(chapter.start.isFinite, "start: \(chapter.start)")
                #expect(chapter.duration.isFinite, "length: \(chapter.duration)")
                #expect(chapter.start >= 0, "start: \(chapter.start)")
                #expect(chapter.duration >= 0, "length: \(chapter.duration)")
                #expect(chapter.end >= chapter.start)
            }
        }
    }

    @Test("A very long chapter list is read without trouble")
    func manyChapters() {
        let many = (0..<5_000).map {
            #"{"title": "Chapter \#($0)", "start_offset_ms": \#($0 * 1000), "length_ms": 1000}"#
        }.joined(separator: ",")
        let metadata = (try? JSONSerialization.jsonObject(
            with: Self.license(many)) as? [String: Any])
            .flatMap { ($0?["content_license"] as? [String: Any])?["content_metadata"] }
            as? [String: Any] ?? [:]
        #expect(LicenseService.chapters(in: metadata).count == 5_000)
    }

    @Test("A chapter list that is not a list is no chapters")
    func chapterListOfTheWrongShape() {
        for text in [#"{"chapter_info": {"chapters": "none"}}"#,
                     #"{"chapter_info": {"chapters": 5}}"#,
                     #"{"chapter_info": "none"}"#,
                     #"{"chapter_info": {}}"#,
                     "{}"] {
            let metadata = (try? JSONSerialization.jsonObject(
                with: Data(text.utf8))) as? [String: Any] ?? [:]
            #expect(LicenseService.chapters(in: metadata).isEmpty)
        }
    }
}
