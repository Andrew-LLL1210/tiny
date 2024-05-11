# Tiny

An interpreter and semantic analysis tool for the Tiny assembler language

By Andrew Phillips

- [Installation](#installation)
  - [Option 1: Prebuilt Binary](#option-1-prebuilt-binary)
  - [Option 2: Build from Source](#option-2-build-from-source)
- [Usage](#usage)
- [Future](#future)


## Installation

### Option 1: Prebuilt Binary

Go to the [releases](https://github.com/Andrew-LLL1210/tiny/releases) page
to see if there is a prebuilt binary for your system. Currently I provide
binaries for x86_64 Windows, Mac, and Linux. If you need a different
architecture or OS, file an issue and I can compile a binary for you.

### Option 2: Build from Source

Requires [Zig 0.12.0](https://github.com/ziglang/zig)

1. Clone this repository (`https://github.com/Andrew-LLL1210/tiny`)
2. Build with `zig build`
   (use `zig build --help` to see advanced build options)

## Usage

- `tiny run program.tny`: assemble and run Tiny code
  - `tiny run main.tny function.tny`: concatenate multiple Tiny files and run as one program
- `tiny flow program.tny`: inspect the control flow of a Tiny program

## Future

- Automatic formatting of Tiny code: ([#17](https://github.com/Andrew-LLL1210/tiny/issues/17))
- Semantic analysis of label structure
- Semantic detection of common Tiny mistakes
