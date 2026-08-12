# TODO

- ~~what to do when progress stops?~~ `advances()`
- ~~`lookup()` - bridge between toking and parsing; looks up a parsed span against a keyword table~~
- ~~or `reparse(lower: Parser, upper: Parser)` - parse, span, reparse~~ `refine()`
- ~~`reparse` suggests also `rest` - which gets all the remaining input; would allow e.g. switching grammar at the top level.~~ `rest()`
- ~~make sure we can parse at comptime~~
- `alt`'s `furthest` doesn't work with tokens that return literal slices rather than slices from the input.
- how to parse e.g. YAML, Python?
  - custom context + parsers to track current indent?
- parsing non-text binaries?
