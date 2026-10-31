import XCTest
@testable import QuotaCore

final class TokenDisplayTests: XCTestCase {
    func testReadableValuesFromRealUsageExamples() {
        XCTAssertEqual(TokenDisplayValue.format(209_758_837).text, "2.10 亿")
        XCTAssertEqual(TokenDisplayValue.format(110_660_293).text, "1.11 亿")
        XCTAssertEqual(TokenDisplayValue.format(203_436_713).text, "2.03 亿")
        XCTAssertEqual(TokenDisplayValue.format(910_652).text, "91.07 万")
        XCTAssertEqual(TokenDisplayValue.format(5_409_092).text, "540.91 万")
    }

    func testSmallCountsStayExactAndUnitThresholdsStayReadable() {
        XCTAssertEqual(TokenDisplayValue.format(0).text, "0")
        XCTAssertEqual(TokenDisplayValue.format(2_380).text, "2,380")
        XCTAssertEqual(TokenDisplayValue.format(9_999).text, "9,999")
        XCTAssertEqual(TokenDisplayValue.format(10_000).text, "1.00 万")
        XCTAssertEqual(TokenDisplayValue.format(99_999_949).text, "9,999.99 万")
        XCTAssertEqual(TokenDisplayValue.format(99_999_950).text, "1.00 亿")
        XCTAssertEqual(TokenDisplayValue.format(100_000_000).text, "1.00 亿")
    }

    func testLargeCountsUseDecimalArithmeticWithoutOverflow() {
        XCTAssertEqual(TokenDisplayValue.format(1_000_000_000_000).text, "1.00 万亿")
        XCTAssertEqual(TokenDisplayValue.format(Int64.max).text, "9,223,372.04 万亿")
    }
}
