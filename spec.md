# Tiny

A toy assembler language from Harding University

## Virtual Machine Architecture

The Tiny machine is 900 words, with each word's value in the range (-100000, 100000).
The machine has 4 registers to keep track of its state:
- the _instruction pointer_ (IP) which points to the next word to execute,
- the _accumulator_ (ACC) which holds the current value for arithmetic and motion operations,
- the _stack pointer_ (SP) which points to the bottom of the stack,
- and the _base pointer_ (BP) which points to the stack frame of the currently evaluating function.

The IP, SP, and BP all hold values in the range [0, 900).
The ACC holds a word (-100000, 100000).

## Operations

An operation is composed of an _operation code_ (opcode) and _argument_.
In Tiny, opcodes are not written, but _mnemonics_ are used which correspond to opcodes.
The argument may be either a number literal (in the range [0, 1000)) or a label name,
depending on the operation. See the [list of all operations](#operation-list)

## Labels

## Directives

## Functions and Call Frames

## Operation List
