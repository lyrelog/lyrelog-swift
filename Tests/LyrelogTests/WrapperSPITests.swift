import Foundation
import Testing
@_spi(Wrapper) import Lyrelog

/// How Lyrelog's React Native and Flutter SDKs name themselves: `Configuration.wrapper` is SPI,
/// visible only to a file that imports `@_spi(Wrapper) import Lyrelog`.
struct WrapperSPITests {
    @Test func aWrapperSetsItsNameThroughTheSPI() {
        var configuration = Lyrelog.Configuration(apiKey: "lyr_ing_x")
        #expect(configuration.wrapper == nil)
        configuration.wrapper = "lyrelog-flutter/1.0.0"
        #expect(configuration.wrapper == "lyrelog-flutter/1.0.0")
    }
}
