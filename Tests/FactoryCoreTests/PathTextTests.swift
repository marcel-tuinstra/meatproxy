import Foundation
import Testing
@testable import FactoryCore

/// A session file names its folders the way its own system writes them. These run on every platform: a Windows path is
/// read the same on a Mac as on Windows.
@Suite struct PathTextTests {
    @Test func aDriveOrAShareIsWrittenTheWindowsWay() {
        #expect(PathText.isWindows(#"C:\Users\you\Projects\shop"#))
        #expect(PathText.isWindows("c:/Users/you"))
        #expect(PathText.isWindows("D:"))
        #expect(PathText.isWindows(#"\\server\share\shop"#) && PathText.isWindows("//server/share/shop"))
        #expect(!PathText.isWindows("/Users/you/Projects/shop"))
        #expect(!PathText.isWindows("~/Projects/shop"))
        #expect(!PathText.isWindows("shop"))
        #expect(!PathText.isWindows("C"))
        #expect(!PathText.isWindows("C:shop"))          // a file called "C:shop" on a Mac, not a drive
        #expect(!PathText.isWindows(""))
    }

    @Test func theNameIsTheLastFolderWithEitherSlash() {
        #expect(PathText.name(#"C:\Users\you\Projects\shop"#) == "shop")
        #expect(PathText.name(#"C:\Users\you\Projects\shop\"#) == "shop")
        #expect(PathText.name("C:/Users/you/Projects/shop") == "shop")
        #expect(PathText.name(#"C:\Users\you/Projects\web shop"#) == "web shop")
        #expect(PathText.name(#"\\server\share\shop"#) == "shop")
        #expect(PathText.name(#"C:\"#) == "C:")
        // the Mac and Linux way is left as it was
        #expect(PathText.name("/Users/you/Projects/shop") == "shop")
        #expect(PathText.name("/Users/you/Projects/shop/") == "shop")
        #expect(PathText.name("shop") == "shop")
        #expect(PathText.name("/") == "/")
        #expect(PathText.name("") == "")
    }

    @Test func theParentStopsAtTheDriveOrTheShare() {
        #expect(PathText.parent(#"C:\Users\you\shop"#) == "C:/Users/you")
        #expect(PathText.parent("C:/Users") == "C:/")
        #expect(PathText.parent(#"C:\"#) == "C:/")
        #expect(PathText.parent(#"\\server\share\shop\code"#) == "//server/share/shop")
        #expect(PathText.parent("//server/share") == "//server/share")
        #expect(PathText.parent("/Users/you/shop") == "/Users/you")
        #expect(PathText.parent("/Users") == "/")
    }

    /// Foundation on Windows gives a path forward slashes (`URL.path` is `C:/Users/you/shop`): that is the one spelling.
    @Test func oneSpellingForAWindowsFolder() {
        #expect(PathText.windows(#"c:\Users\you\Projects\shop\"#) == "C:/Users/you/Projects/shop")
        #expect(PathText.windows("C:/Users/you/Projects/shop") == "C:/Users/you/Projects/shop")
        #expect(PathText.windows(#"C:\Users\\you\.\Projects\..\shop"#) == "C:/Users/you/shop")
        #expect(PathText.windows("c:") == "C:/")
        #expect(PathText.windows(#"C:\"#) == "C:/")
        #expect(PathText.windows(#"C:\.."#) == "C:/")
        #expect(PathText.windows(#"\\server\share\shop\"#) == "//server/share/shop")
        #expect(PathText.windows("//server/share/") == "//server/share")
        // any other folder stays as it is written
        #expect(PathText.native(#"c:\Users\you"#) == "C:/Users/you")
        #expect(PathText.native("/Users/you/Projects/shop/") == "/Users/you/Projects/shop/")
        #expect(PathText.native("~") == "~")
    }

    @Test func aFloorIsNamedAfterItsWindowsFolder() {
        var w = World(now: Date(), buildings: Provider.allCases.map { ProviderBuilding(provider: $0, projects: []) })
        WorldBuilder.pin([#"C:\Users\you\Projects\web-shop"#], to: &w)
        #expect(w.projects.map(\.name) == ["Web Shop"])
    }
}
