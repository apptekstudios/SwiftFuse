import Fuse

let fuse = Fuse(["Old Man's War", "The Lock Artist", "The DaVinci Code"], options: FuseOptions(includeMatches: true))

for result in fuse.search("old war") {
    for match in result.matches {
        // `indices` are Character offsets; `ranges` are ready-to-use String.Index ranges.
        var highlighted = match.value
        for range in match.ranges.reversed() {
            highlighted.replaceSubrange(range, with: "[\(match.value[range])]")
        }
        print(highlighted)
    }
}
