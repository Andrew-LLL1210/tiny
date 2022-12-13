# Spec

This is just a place to document all the hidden attributes of Tiny
(or TIDE's implementation) in order to reproduce them faithfully if I want to.

## Values

- memory addresses are in range [0, 899]
- registers and memory slots allowed in range [-99999, 99999]
- argument of an operation in range [0, 999]

## Edge Behavior

- division truncates (rounds towards zero) regardless of sign
- when an overflow happens, the number is repeatedly decremented/incremented by 19999 until it fits in allowed range
- attempting to access memory at a negative or large address is fatal

## Labels

Labels are case insensitive. They may contain:

- any alphanumeric character
- a pair of (single or double) quotation marks, not necessarily adjacent to each other (I think this is likely a bug in TIDE)
- an escaped single or double quote (again, probably a bug)
- a digit anywhere (including the beginning of the label)
- literally any other graphical character

```tiny
jmp 2-4'm'@!a#i"strin;g"\"[n\'$\-_}{
-!"wh]~\at"\+*$%)).,<>/?=^&(: ds 1
2-4'm'@!a#i"strin;g"\"[n\'$\-_}{:
stop
```

```tiny
ld 7
add 3
call printInteger
stop

7: db 40
3: db 2
```

## Strings

- strings can be enclosed by either single or double quotes
