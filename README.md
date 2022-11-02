# Tiny

A terminal program for assembling and testing tiny programs in batches

Author: Andrew Phillips

## Checklist

This section is an informal gauge of the completion of the project. (NOT chronological)

- [x] create machine to emulate the tiny machine
- [ ] implement the four ROM functions such that their semantics are correct
- [ ] write assembler
- [ ] decide whether an intermediate representation is needed or wanted; see issue TODO: make issue
- [ ] prototype a testing framework
- [ ] prototype a UI (aka how nicely can Mrs. Fields use all the capabilities of the system)

## Design Considerations

How do we want testing to work? Here are some options:

### As a library:

1. Grader writes `tests.zig`, which contains unit tests of the student code
  - tests must be written so that they call some `test_all_sources` function or iterate over programs
2. Because each test tests each student, all that is needed is to run `zig test` in the command line.
3. outputs would be displayed on the command line but can be piped into a file. Format not well defined

Benefits:
- project does not need any fancy testing framework; perhaps not even a TUI. It could just be a library.

Drawbacks:
- makes writing tests for student code more complicated (on user end)
- because tests iterate through each student, it would not naturally separate the test results by student.
- tests are not supposed to perform IO, but the standard output of test results is probably not what we want.
- project would be dependent on zig instead of being fully compiled
  - Grader needs zig installed
  - changes to zig might break the project

### As a `build.zig` script:

1. Grader writes `tests.zig`, which contains unit tests of the student code
  - the script can import parts of the project as a library;
  - the script has access to `@import("machine")`, which is the instance of the machine (or other IR) to be tested
  - each test is written to only test one facet of one machine
2. Grader copies the template `build.zig` script which would be a part of this repo
3. Grader runs `zig build test` in the command line.
4. outputs are put into i.e. `results.txt` and separated by tiny program.

Benefits
- the entire `tests.zig` file only needs to know about one Tiny program at a time
- the most complicated parts of the logic would be part of the build script, easy to change

Drawbacks
- project would be dependent on zig
  - Grader needs zig installed
  - changes to zig _will_ break the project, as the build system is one of the more volatile aspects of the language.

Other considerations
- I have never made a sophisticated `build.zig` script like this. I have seen some that are this complex, so I know it's possible.
  I just don't know how easy it will be to develop.

### As a fully-compiled project

1. Grader writes `tests.zig`
2. grader runs `tiny test submissions-folder/* -o results.txt`
3. voila

Benefits
- not dependent on zig; will never break so long as it is not recompiled
- potential for adding useful features to the CLI later

Drawbacks
- complicated: all testing logic is part of compiled program
- _not_ actually independent on zig; the tests are still written in zig

Other considerations
- a big enough project can "do anything" by merit of it not existing
  - when we dream big we can't always tell how feasible our aspirations are

Without further input from the client, I will aim for the `build.zig` method. Of course, most of the workhorse code still needs
to be written that should be independent of the actual method by which the user uses the library/framework/CLI
