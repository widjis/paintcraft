// Lists on-screen windows owned by the given app name.
// Prints: <windowNumber> <x> <y> <w> <h> <title>
import CoreGraphics
import Foundation
let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PaintCraft"
guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("cannot read window list\n".utf8)); exit(1)
}
var found = 0
for w in raw {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner.contains(want) else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
    let ww = b["Width"] as? Double ?? 0, hh = b["Height"] as? Double ?? 0
    if ww < 100 || hh < 100 { continue }
    print("\(num) \(Int(x)) \(Int(y)) \(Int(ww)) \(Int(hh)) \(name)")
    found += 1
}
exit(found > 0 ? 0 : 2)
