# Zig Parser Compiler

[Documentation](https://zpc.hexten.net/)

## Negatives

- not as fast as SIMD
- no streaming - slice input
- stops at first error
- tokens can't contain e.g. parsed numbers
- source locations must be recovered - can't live in token
