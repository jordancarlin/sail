default Order dec
$include <prelude.sail>

// Integer ranges that do not fit in 64 bits but fit in 128 bits. With
// --c-int128 the C backend uses __int128 for these, otherwise sail_int.

struct wide = {
    lo : range(0, 2 ^ 65),
    hi : range(- (2 ^ 70), 2 ^ 70),
}

val add_u : (bits(64), bits(64)) -> range(0, 2 ^ 65 - 2)

function add_u(x, y) = unsigned(x) + unsigned(y)

val mul_u : (bits(64), bits(64)) -> range(0, (2 ^ 64 - 1) * (2 ^ 64 - 1))

function mul_u(x, y) = unsigned(x) * unsigned(y)

val sub_u : (bits(64), bits(64)) -> range(- (2 ^ 64 - 1), 2 ^ 64 - 1)

function sub_u(x, y) = unsigned(x) - unsigned(y)

val end_addr : (bits(64), range(0, 4096)) -> range(0, 2 ^ 64 + 4095)

function end_addr(x, n) = unsigned(x) + n

val in_range : (bits(64), range(0, 4096), bits(64)) -> bool

function in_range(addr, n, limit) = end_addr(addr, n) <= unsigned(limit)

val main : unit -> unit

function main() = {
    let a : bits(64) = 0xFFFFFFFFFFFFFFFF;
    let b : bits(64) = 0x8000000000000000;
    let c : bits(64) = 0x0000000000000003;
    print_int("add_u ", add_u(a, a));
    print_int("add_u ", add_u(b, c));
    print_int("mul_u ", mul_u(a, a));
    print_int("mul_u ", mul_u(b, c));
    print_int("sub_u ", sub_u(c, a));
    print_int("sub_u ", sub_u(a, c));
    print_int("end_addr ", end_addr(a, 4096));
    print_endline(if in_range(b, 8, a) then "in range" else "out of range");
    print_endline(if in_range(a, 8, a) then "in range" else "out of range");
    let lit : range(0, 2 ^ 65) = 2 ^ 64 + 5;
    print_int("lit ", lit);
    let neg : range(- (2 ^ 70), 0) = - (2 ^ 66) - 7;
    print_int("neg ", neg);
    let w : wide = struct { lo = add_u(b, b), hi = neg };
    print_int("w.lo ", w.lo);
    print_int("w.hi ", w.hi);
    let i : int = w.lo + w.hi;
    print_int("sum ", i);
    print_endline(if w.lo == 2 ^ 64 then "eq" else "ne")
}
