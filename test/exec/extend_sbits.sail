default Order dec
$include <prelude.sail>

// Extend to a length that is not a constant, unsigned of 64-bit values,
// and min_int/max_int of 64-bit integers.

val ext : forall 'n 'm, 0 < 'n <= 'm <= 64. (int('m), bits('n)) -> unit

function ext(m, v) = {
    let z : bits('m) = sail_zero_extend(v, m);
    let s : bits('m) = sail_sign_extend(v, m);
    print_bits("zero_extend = ", z);
    print_bits("sign_extend = ", s);
    print_int("unsigned z = ", unsigned(z));
    print_int("unsigned s = ", unsigned(s));
    print_int("signed s = ", signed(s))
}

val ext_fixed : forall 'm, 8 <= 'm <= 64. (int('m), bits(8)) -> unit

function ext_fixed(m, v) = {
    let z : bits('m) = sail_zero_extend(v, m);
    let s : bits('m) = sail_sign_extend(v, m);
    print_bits("zero_extend = ", z);
    print_bits("sign_extend = ", s);
    print_int("unsigned s = ", unsigned(s))
}

val min_max : forall 'a 'b, -1000 <= 'a <= 1000 & -1000 <= 'b <= 1000. (int('a), int('b)) -> unit

function min_max(a, b) = {
    print_int("min = ", min_int(a, b));
    print_int("max = ", max_int(a, b))
}

val main : unit -> unit

function main() = {
    ext(64, 0xFF);
    ext(12, 0x9);
    ext(12, 0b1001);
    ext(64, 0x8000000000000000);
    ext(64, 0x7FFFFFFFFFFFFFFF);
    ext(33, 0b1);
    ext_fixed(8, 0x80);
    ext_fixed(16, 0x7F);
    ext_fixed(64, 0x80);
    let w : bits(64) = 0xFFFFFFFFFFFFFFFF;
    print_int("unsigned w = ", unsigned(w));
    let w : bits(64) = 0x0000000000000001;
    print_int("unsigned w = ", unsigned(w));
    min_max(3, -7);
    min_max(-1000, 1000)
}
