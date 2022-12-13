# Tiny

A terminal program for assembling and testing tiny programs in batches

Author: Andrew Phillips

## Checklist

- [x] create machine to emulate the tiny machine
  - [x] fully functional machine
  - [x] semantic equivalence to TIDE's machine (allowing minor details)
  - [x] warnings and error messages
- [x] write assembler
  - [x] able to assemble a majority (~90%?) of the tiny spec
  - [x] work out all the kinks in parsing (dc + comments/escape sequences)
  - [x] make the assembler nice (error messages with line numbers)
- [ ] I/O testing
- [ ] Command Line Interface
- [ ] Batch file processing, logging, sorting

## Testing

I have regressed (progressed?) in my vision of how testing should work.
I figure that only basic output-comparison tests should be necessary.
These could be supplemented with some statistics about the number of comments
versus source line per file, or the label names used, et cetera.
If more sophisticated testing is desired, please file an issue.
