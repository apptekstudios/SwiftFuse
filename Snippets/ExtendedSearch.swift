import Fuse

let items = ["Old Man's War", "The Lock Artist", "HTML5", "Right Ho Jeeves", "Thank You Jeeves", "The DaVinci Code"]
let fuse = Fuse(items, options: FuseOptions(useExtendedSearch: true))

func show(_ query: String) {
    print(query.padding(toLength: 22, withPad: " ", startingAt: 0), fuse.search(query).map(\.item))
}

show("jeeves")            // fuzzy match
show("=HTML5")            // exact match
show("'code")             // include-match
show("^the")              // prefix-exact-match
show("!^the")             // inverse-prefix-exact-match
show("jeeves$")           // suffix-exact-match
show("!jeeves$")          // inverse-suffix-exact-match
show("!the")              // inverse-exact-match
show("^the 'code")        // AND: starts with "the" and includes "code"
show("html | jeeves")     // OR
show("=\"Old Man's War\"") // quoted terms may contain spaces
