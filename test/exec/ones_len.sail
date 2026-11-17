default Order dec
$include <prelude.sail>

// sail_ones with a constant length, a variable length of at most 64, and an
// unbounded length.

val mask_small : forall 'n, 0 <= 'n <= 64. int('n) -> bits('n)

function mask_small(n) = sail_ones(n)

val mask_any : forall 'n, 'n >= 0. int('n) -> bits('n)

function mask_any(n) = sail_ones(n)

val main : unit -> unit

function main() = {
    let a : bits(12) = sail_ones(12);
    print_bits("const12 ", a);
    print_bits("const64 ", sail_ones(64) : bits(64));
    print_bits("small0 ", mask_small(0));
    print_bits("small5 ", mask_small(5));
    print_bits("small64 ", mask_small(64));
    print_bits("any3 ", mask_any(3));
    print_bits("any64 ", mask_any(64));
    print_bits("any70 ", mask_any(70));
    let b : bits(64) = sail_zero_extend(mask_small(7), 64);
    print_bits("ext ", b)
}
