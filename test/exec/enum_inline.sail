default Order dec
$include <prelude.sail>

// The C backend inlines calls f(C) of a function that matches on its enum
// parameter. Check nested calls, guards, a wildcard case, and a case body
// that uses a register defined after an earlier caller.

enum ext = { A, B, C, D, E }

val early : unit -> bool

val enabled : ext -> bool

// Defined before the register that enabled(D) reads.
val first : unit -> bool

function first() = enabled(D)

val supported : ext -> bool

function supported(e) = match e {
    A => true,
    B => false,
    C => true,
    D => true,
    E => false,
}

register enabled_d : bool = false

function enabled(e) = match e {
    A => supported(A),
    B => supported(B) & enabled(A),
    C => supported(C) & enabled(A),
    D => supported(D) & enabled_d & enabled(C),
    E if enabled_d => true,
    _ => false,
}

val enabled_measure : ext -> int

function enabled_measure(e) = match e {
    A => 0,
    D => 2,
    _ => 1,
}

termination_measure enabled(e) = enabled_measure(e)

function early() = enabled(D)

val main : unit -> unit

function main() = {
    print_endline(if enabled(A) then "A on" else "A off");
    print_endline(if enabled(B) then "B on" else "B off");
    print_endline(if enabled(C) then "C on" else "C off");
    print_endline(if enabled(D) then "D on" else "D off");
    print_endline(if early() then "early on" else "early off");
    print_endline(if first() then "first on" else "first off");
    print_endline(if enabled(E) then "E on" else "E off");
    enabled_d = true;
    print_endline(if enabled(D) then "D on" else "D off");
    print_endline(if early() then "early on" else "early off");
    print_endline(if first() then "first on" else "first off");
    print_endline(if enabled(E) then "E on" else "E off")
}
