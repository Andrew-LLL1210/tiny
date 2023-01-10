# Tiny <!-- omit in toc -->

An Assembler and Testing Toolkit for the Tiny Language

Author: Andrew Phillips

- [Checklist](#checklist)
- [Installation](#installation)
  - [Option 1: Prebuilt Binary](#option-1-prebuilt-binary)
  - [Option 2: Build from Source](#option-2-build-from-source)
- [Usage](#usage)
  - [Assemble and Run a Program](#assemble-and-run-a-program)

## Checklist

- [x] create machine to emulate the tiny machine
  - [x] fully functional machine
  - [x] semantic equivalence to TIDE's machine (allowing minor details)
  - [x] warnings and error messages
- [x] write assembler
  - [x] able to assemble a majority (~90%?) of the tiny spec
  - [x] work out all the kinks in parsing (dc + comments/escape sequences)
  - [x] make the assembler nice (error messages with line numbers)
- [x] Command Line Interface
- [ ] I/O testing
  - [ ] Batch file processing, logging, sorting
- [ ] Program analysis
  - [ ] determine if a program is likely to hang before running it
  - [ ] view the logical structure of a program
  - [ ] add "caused by" notes to runtime errors such as overflow

## Installation

### Option 1: Prebuilt Binary

Go to the [releases](https://github.com/Andrew-LLL1210/tiny/releases) page
to see if there is a prebuilt binary for your system. Currently I provide
binaries for x86_64 Windows, Mac, and Linux. If you need a different
architecture or OS, file an issue and I can compile a binary for you.

### Option 2: Build from Source

Requirements:
- [Zig](https://github.com/ziglang/zig) 0.10.0

1. Clone this repository (`https://github.com/Andrew-LLL1210/tiny`)
2. Build with `zig build -Drelease-safe` for your native system or
  `zig build -Drelease-safe -Dtarget=TARGET` for any zig-supported target.
3. Add the binary from `zig-out/bin/` to your PATH

## Usage

### Assemble and Run a Program

```tiny
; hello.tny

lda hello
call printString
stop

hello: dc "hello world\n"
```

```shell
$ tiny run hello.tny
hello world
```

Tiny will detect any assembly errors or runtime errors and notify the user:

```tiny
; typo.tny
jmp mian

main:
stop
```

```tiny
; math.tny
ld 8
div 0
call printInteger
stop
```

```tiny
; hang.tny
main:
jmp main
stop
```

```shell
$ tiny run typo.tny
typo.tny:1: error: unknown label 'mian'
$ tiny run math.tny
error: divide by zero
$ tiny run hang.tny
error: program forcefully stopped after 8000 cycles
```

Assembly errors come with a nice reference pointing you to where the error is.
In many text editors, interacting with this message in the console will take you
directly to the error. Runtime errors do not yet have this feature, as it is
difficult to determine where in the code an error originated while running;
but this feature will be implemented in a later release.
