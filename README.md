# Tiny

An interpreter and semantic analysis tool for the Tiny assembler language

By Andrew Phillips

- [Installation](#installation)
  - [Option 1: Prebuilt Binary](#option-1-prebuilt-binary)
  - [Option 2: Build from Source](#option-2-build-from-source)

## Installation

### Option 1: Prebuilt Binary

Go to the [releases page](https://github.com/Andrew-LLL1210/tiny/releases)
to see if there is a prebuilt binary for your system. Currently I provide
binaries for x86_64 Windows, Mac, and Linux. If you need a different
architecture or OS, file an issue and I can compile a binary for you.

### Option 2: Build from Source

Requires [Zig 0.14.0-dev.2569+30169d1d2](https://github.com/ziglang/zig) or later


```
> git clone https://github.com/Andrew-LLL1210/tiny
> cd tiny
> zig build
(or zig build -p PREFIX to install to a particular location)
```
