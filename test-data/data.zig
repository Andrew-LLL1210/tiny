pub const hello =
    \\jmp main
    \\    string: dc "hello world\n"
    \\; comment
    \\main:
    \\    ; this "function" has complicated: logic
    \\    lda string
    \\    call printString
    \\    stop
;
